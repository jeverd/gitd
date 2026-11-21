//! Storage quotas, repository stats, and safe garbage collection (R1.1, R2.1, R2.2, R3.4).
//!
//!   GET  /v1/repos/{ns}/{repo}/quotas   admin key only
//!   PUT  /v1/repos/{ns}/{repo}/quotas   admin key only
//!   GET  /v1/repos/{ns}/{repo}/stats    admin key only
//!   POST /v1/repos/{ns}/{repo}/gc       admin key only
//!
//! Concurrency between GC and `deleteRepo` / `createRepo` follows
//! tests/tla/repo_gc/RepoGC.tla (`NoGCOnDeletedRepo`, `NoCrossIncarnationGC`,
//! `NoConcurrentGC`).

const std = @import("std");
const Io = std.Io;
const http = std.http;
const api = @import("api.zig");
const server = @import("server.zig");
const repo_name = @import("repo_name.zig");
const repo_git = @import("repo_git.zig");
const content = @import("content.zig");
const events = @import("events.zig");
const Db = @import("db.zig").Db;

pub const max_quota_branches: u64 = 1_000_000;
pub const max_quota_bytes: u64 = 1024 * 1024 * 1024 * 1024; // 1 TiB
pub const max_prune_seconds: u32 = 7 * 24 * 60 * 60;

/// Synchronizes garbage collection and repo deletion/recreation per repo.
/// All fields are guarded by `app.repo_lock`. See `tests/tla/repo_gc/RepoGC.tla`.
pub const Coordinator = struct {
    cond: Io.Condition = .init,
    states: std.array_hash_map.String(State) = .empty,

    const State = struct {
        gc_running: bool = false,
        deleting: bool = false,
    };

    pub fn deinit(c: *Coordinator, gpa: std.mem.Allocator) void {
        for (c.states.keys()) |k| gpa.free(k);
        c.states.deinit(gpa);
    }

    fn isGcRunningLocked(c: *const Coordinator, name: []const u8) bool {
        return (c.states.get(name) orelse State{}).gc_running;
    }

    /// Marks `gc_running` under `app.repo_lock` if the repo incarnation matches
    /// and no delete/GC is already active. Returns false if busy, deleting, or gone.
    pub fn beginGc(c: *Coordinator, app: *server.App, name: []const u8, expected_repo_id: []const u8) !bool {
        const io = app.io;
        try app.repo_lock.lock(io);
        defer app.repo_lock.unlock(io);

        const existing = (try app.db.getRepo(io, app.gpa, name)) orelse return false;
        defer existing.deinit(app.gpa);
        if (!std.mem.eql(u8, existing.id, expected_repo_id)) return false;

        if (c.states.getPtr(name)) |st| {
            if (st.gc_running or st.deleting) return false;
            st.gc_running = true;
            return true;
        }
        const key = try app.gpa.dupe(u8, name);
        errdefer app.gpa.free(key);
        try c.states.put(app.gpa, key, .{ .gc_running = true });
        return true;
    }

    /// Clears `gc_running` under `repo_lock`, notifies any waiting delete, and
    /// records `last_gc_at` when `succeeded` and the repo incarnation still matches.
    pub fn endGc(c: *Coordinator, app: *server.App, name: []const u8, expected_repo_id: []const u8, now: i64, succeeded: bool) void {
        const io = app.io;
        app.repo_lock.lockUncancelable(io);
        defer app.repo_lock.unlock(io);

        if (c.states.getPtr(name)) |st| {
            if (st.deleting) {
                st.gc_running = false;
            } else if (c.states.fetchSwapRemove(name)) |kv| {
                app.gpa.free(kv.key);
            }
        }
        c.cond.broadcast(io);

        if (succeeded) {
            if (app.db.getRepo(io, app.gpa, name) catch null) |existing| {
                defer existing.deinit(app.gpa);
                if (std.mem.eql(u8, existing.id, expected_repo_id)) {
                    app.db.recordGcCompleted(io, name, now) catch {};
                }
            }
        }
    }

    /// Called by `deleteRepo` with `app.repo_lock` already held. Prevents new GC,
    /// waits until any in-flight GC finishes, and keeps `repo_lock` held for deletion.
    pub fn beginDeleteLocked(c: *Coordinator, mutex: *Io.Mutex, io: Io, name: []const u8) void {
        if (c.states.getPtr(name)) |st| {
            st.deleting = true;
        }
        while (c.isGcRunningLocked(name)) {
            c.cond.waitUncancelable(io, mutex);
        }
    }

    /// Called by `deleteRepo` with `app.repo_lock` still held after DB+disk deletion.
    pub fn endDeleteLocked(c: *Coordinator, io: Io, gpa: std.mem.Allocator, name: []const u8) void {
        if (c.states.fetchSwapRemove(name)) |kv| {
            gpa.free(kv.key);
        }
        c.cond.broadcast(io);
    }
};

// ---- Quotas ----

pub const EffectiveQuota = struct {
    configured_max_branches: u64,
    configured_max_repo_bytes: u64,
    max_branches: u64,
    max_repo_bytes: u64,
    updated_at: ?i64,
};

pub fn effectiveQuota(app: *server.App, repo: []const u8) !EffectiveQuota {
    const q_opt = try app.db.getRepoQuota(app.io, repo);
    const conf_b: u64 = if (q_opt) |q| @intCast(@max(0, q.max_branches)) else 0;
    const conf_bytes: u64 = if (q_opt) |q| @intCast(@max(0, q.max_repo_bytes)) else 0;
    return .{
        .configured_max_branches = conf_b,
        .configured_max_repo_bytes = conf_bytes,
        .max_branches = if (conf_b > 0) conf_b else app.default_max_branches,
        .max_repo_bytes = if (conf_bytes > 0) conf_bytes else app.default_max_repo_bytes,
        .updated_at = if (q_opt) |q| q.updated_at else null,
    };
}

pub const QuotaOutcome = enum { ok, exceeded };

pub fn checkBranchQuota(app: *server.App, repo: *const repo_git.Repo, name: repo_name.Name, additions: u64, ref_for_event: []const u8) !QuotaOutcome {
    if (additions == 0) return .ok;
    const eff = try effectiveQuota(app, name.full);
    if (eff.max_branches == 0) return .ok;
    const branches = try repo.listBranches();
    defer branches.deinit(app.gpa);
    if (@as(u64, branches.items.len) +| additions > eff.max_branches) {
        events.record(app, .{
            .repo = name.full,
            .kind = "quota_exceeded",
            .ref = ref_for_event,
            .detail = "branch quota exceeded",
            .created_at = api.unixNow(app.io),
        });
        return .exceeded;
    }
    return .ok;
}

pub fn checkDiskQuota(app: *server.App, name: repo_name.Name, incoming_bytes: u64, ref_for_event: []const u8) !QuotaOutcome {
    const eff = try effectiveQuota(app, name.full);
    if (eff.max_repo_bytes == 0) return .ok;
    const used = try app.store.repoDiskUsage(app.io, app.gpa, name);
    if (used +| incoming_bytes > eff.max_repo_bytes) {
        events.record(app, .{
            .repo = name.full,
            .kind = "quota_exceeded",
            .ref = ref_for_event,
            .detail = "disk quota exceeded",
            .created_at = api.unixNow(app.io),
        });
        return .exceeded;
    }
    return .ok;
}

// ---- GC execution & background reaper ----

pub const GcResult = struct {
    before_bytes: u64,
    after_bytes: u64,
    reclaimed_bytes: u64,
    duration_ms: i64,
};

pub const GcStatus = union(enum) {
    ok: GcResult,
    busy,
    gone,
    failed,
};

pub fn runGcOnce(app: *server.App, name: repo_name.Name, expected_repo_id: []const u8, prune_seconds: u32) Io.Cancelable!GcStatus {
    const acquired = app.maint.beginGc(app, name.full, expected_repo_id) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return .failed,
    };
    if (!acquired) {
        const exists = (app.db.getRepo(app.io, app.gpa, name.full) catch null);
        if (exists) |r| {
            r.deinit(app.gpa);
            return .busy;
        }
        return .gone;
    }

    var succeeded = false;
    const started_at = Io.Clock.awake.now(app.io);
    defer app.maint.endGc(app, name.full, expected_repo_id, api.unixNow(app.io), succeeded);

    const before = app.store.repoDiskUsage(app.io, app.gpa, name) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return .failed,
    };
    const repo = repo_git.Repo.open(app.io, app.gpa, app.store, name) catch return .failed;
    repo.gc(prune_seconds) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return .failed,
    };
    const after = app.store.repoDiskUsage(app.io, app.gpa, name) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return .failed,
    };
    succeeded = true;

    const reclaimed = if (before > after) before - after else 0;
    const elapsed_ms = started_at.durationTo(Io.Clock.awake.now(app.io)).toMilliseconds();
    var detail_buf: [64]u8 = undefined;
    const detail = std.mem.print(&detail_buf, "reclaimed {d} B in {d}ms", .{ reclaimed, elapsed_ms }) catch "gc";
    events.record(app, .{
        .repo = name.full,
        .kind = "gc_completed",
        .detail = detail,
        .created_at = api.unixNow(app.io),
    });
    return .{ .ok = .{
        .before_bytes = before,
        .after_bytes = after,
        .reclaimed_bytes = reclaimed,
        .duration_ms = elapsed_ms,
    } };
}

pub fn run(app: *server.App) Io.Cancelable!void {
    if (app.gc_interval_seconds == 0) return;
    while (true) {
        try app.io.sleep(.fromSeconds(app.gc_interval_seconds), .awake);
        try sweepDue(app);
    }
}

pub fn sweepDue(app: *server.App) Io.Cancelable!void {
    if (app.gc_expired_threshold == 0) return;
    const due = app.db.listReposDueForGc(app.io, app.gpa, app.gc_expired_threshold, 16) catch return;
    defer Db.freeRepoMaints(app.gpa, due);
    for (due) |item| {
        const name = repo_name.parse(item.repo) catch continue;
        const repo_row = (app.db.getRepo(app.io, app.gpa, item.repo) catch continue) orelse {
            app.db.deleteRepoMaint(app.io, item.repo) catch {};
            continue;
        };
        defer repo_row.deinit(app.gpa);
        _ = try runGcOnce(app, name, repo_row.id, app.gc_prune_seconds);
    }
}

// ---- Admin API ----

pub fn serveApi(
    app: *server.App,
    request: *http.Server.Request,
    repo: *const repo_git.Repo,
    name: repo_name.Name,
    rest: []const u8,
    access: content.Access,
) api.HandleError!http.Status {
    if (access.claims != null or access.read_only) {
        return api.respondError(request, .forbidden, "forbidden", "repo maintenance and quotas need the admin key");
    }
    const method = request.head.method;
    if (std.mem.eql(u8, rest, "quotas")) {
        return switch (method) {
            .GET => getQuotas(app, request, name),
            .PUT => putQuotas(app, request, name),
            else => api.respondError(request, .method_not_allowed, "method_not_allowed", "use GET or PUT"),
        };
    }
    if (std.mem.eql(u8, rest, "stats")) {
        if (method != .GET) return api.respondError(request, .method_not_allowed, "method_not_allowed", "use GET");
        return stats(app, request, repo, name);
    }
    if (std.mem.eql(u8, rest, "gc")) {
        if (method != .POST) return api.respondError(request, .method_not_allowed, "method_not_allowed", "use POST");
        return runGcEndpoint(app, request, name, access.repo_id);
    }
    return api.respondError(request, .not_found, "not_found", "no such maintenance route");
}

fn getQuotas(app: *server.App, request: *http.Server.Request, name: repo_name.Name) api.HandleError!http.Status {
    const eff = effectiveQuota(app, name.full) catch return api.internal(request);
    return api.respondJson(app.gpa, request, .ok, .{
        .max_branches = eff.configured_max_branches,
        .max_repo_bytes = eff.configured_max_repo_bytes,
        .effective_max_branches = eff.max_branches,
        .effective_max_repo_bytes = eff.max_repo_bytes,
        .updated_at = eff.updated_at,
    });
}

fn putQuotas(app: *server.App, request: *http.Server.Request, name: repo_name.Name) api.HandleError!http.Status {
    const Body = struct {
        max_branches: u64 = 0,
        max_repo_bytes: u64 = 0,
    };
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    const body = parsed.value;
    if (body.max_branches > max_quota_branches) {
        return api.respondError(request, .bad_request, "invalid_quota", "max_branches must be at most 1000000");
    }
    if (body.max_repo_bytes > max_quota_bytes) {
        return api.respondError(request, .bad_request, "invalid_quota", "max_repo_bytes must be at most 1 TiB");
    }
    const now = api.unixNow(app.io);
    app.db.setRepoQuota(app.io, name.full, @intCast(body.max_branches), @intCast(body.max_repo_bytes), now) catch return api.internal(request);
    return getQuotas(app, request, name);
}

fn stats(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, name: repo_name.Name) api.HandleError!http.Status {
    const branches = repo.listBranches() catch |err| return content.gitError(request, err);
    defer branches.deinit(app.gpa);
    const disk_bytes = app.store.repoDiskUsage(app.io, app.gpa, name) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => api.internal(request),
    };
    const objs = repo.countObjects() catch |err| return content.gitError(request, err);
    const maint_opt = app.db.getRepoMaint(app.io, app.gpa, name.full) catch return api.internal(request);
    defer if (maint_opt) |m| m.deinit(app.gpa);
    const eff = effectiveQuota(app, name.full) catch return api.internal(request);

    return api.respondJson(app.gpa, request, .ok, .{
        .branches = branches.items.len,
        .disk_bytes = disk_bytes,
        .objects_loose = objs.objects_loose,
        .size_loose_kb = objs.size_loose_kb,
        .objects_packed = objs.objects_packed,
        .size_pack_kb = objs.size_pack_kb,
        .last_gc_at = if (maint_opt) |m| (if (m.last_gc_at > 0) @as(?i64, m.last_gc_at) else null) else null,
        .expired_since_gc = if (maint_opt) |m| m.expired_since_gc else 0,
        .quotas = .{
            .max_branches = eff.max_branches,
            .max_repo_bytes = eff.max_repo_bytes,
        },
    });
}

fn runGcEndpoint(app: *server.App, request: *http.Server.Request, name: repo_name.Name, repo_id: []const u8) api.HandleError!http.Status {
    var prune: u32 = app.gc_prune_seconds;
    if (@import("http_util.zig").hasBody(request)) {
        const Body = struct { prune_seconds: ?u64 = null };
        var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
        defer parsed.deinit();
        if (parsed.value.prune_seconds) |ps| {
            if (ps > max_prune_seconds) {
                return api.respondError(request, .bad_request, "invalid_prune_seconds", "prune_seconds must be 0-604800");
            }
            prune = @intCast(ps);
        }
    }
    return switch (try runGcOnce(app, name, repo_id, prune)) {
        .ok => |res| api.respondJson(app.gpa, request, .ok, res),
        .busy => api.respondError(request, .conflict, "repo_busy", "garbage collection is already running for this repo"),
        .gone => api.respondError(request, .not_found, "not_found", "no such repo"),
        .failed => api.internal(request),
    };
}

test "coordinator blocks duplicate gc and releases on delete cleanup" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var db: Db = try .open(":memory:");
    defer db.close();
    try db.insertRepo(io, "acme/web", "id1", 10);
    const store_mod = @import("store.zig");
    const store: store_mod.Store = .{ .root = ".", .tmp = ".", .path_env = "" };
    const auth = @import("auth.zig");
    const secret: auth.Secret = @splat(1);
    var app: server.App = .{
        .io = io,
        .gpa = gpa,
        .db = &db,
        .store = &store,
        .secret = &secret,
    };
    defer app.maint.deinit(gpa);

    try std.testing.expect(try app.maint.beginGc(&app, "acme/web", "id1"));
    try std.testing.expect(!try app.maint.beginGc(&app, "acme/web", "id1")); // busy
    try std.testing.expect(!try app.maint.beginGc(&app, "acme/web", "wrong")); // mismatched incarnation
    app.maint.endGc(&app, "acme/web", "id1", 200, true);
    const m = (try db.getRepoMaint(io, gpa, "acme/web")).?;
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 200), m.last_gc_at);

    // Deleting when GC ran cleanly leaves zero leaked entries.
    try std.testing.expect(try app.maint.beginGc(&app, "acme/web", "id1"));
    try app.repo_lock.lock(io);
    defer app.repo_lock.unlock(io);
    if (app.maint.states.getPtr("acme/web")) |st| st.deleting = true;
    app.repo_lock.unlock(io);
    app.maint.endGc(&app, "acme/web", "id1", 201, false);
    try app.repo_lock.lock(io);
    app.maint.beginDeleteLocked(&app.repo_lock, io, "acme/web");
    app.maint.endDeleteLocked(io, gpa, "acme/web");
    try std.testing.expectEqual(@as(usize, 0), app.maint.states.count());
}
