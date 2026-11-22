//! Multi-branch conflict radar & wave merge planner (R1.1, R2.1, R3.4):
//!
//!   POST /v1/repos/{ns}/{repo}/merges/check
//!     {"base": "main", "heads": ["agent/a", "agent/b", ...], "include_file_overlaps": false}
//!
//! Simulates merging each head into `base` in memory using `git merge-tree`,
//! builds unreferenced single-parent virtual commits `C_i` on `base` (compatible
//! with Git 2.38+, no refs mutated, no events recorded), checks every clean
//! pair `(C_i, C_j)` for pairwise conflicts, and groups ready branches into
//! `clean_heads`, `conflict_clusters`, and `blocked_heads`.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const api = @import("api.zig");
const server = @import("server.zig");
const repo_name = @import("repo_name.zig");
const ref_name = @import("ref_name.zig");
const repo_git = @import("repo_git.zig");
const content = @import("content.zig");
const rules = @import("rules.zig");
const Db = @import("db.zig").Db;

pub const max_heads = 16;
const check_budget_ms: i64 = 15_000;

pub const BranchStatus = struct {
    head: []const u8,
    sha: []const u8,
    mergeable: bool,
    blocked_by: ?[]const u8 = null,
    conflicts: []const []const u8,
    missing_checks: []const []const u8 = &.{},
};

pub const PairConflict = struct {
    a: []const u8,
    b: []const u8,
    conflicts: []const []const u8,
};

const FileOverlap = struct {
    a: []const u8,
    b: []const u8,
    paths: []const []const u8,
};

pub const ConflictCluster = struct {
    heads: []const []const u8,
    files: []const []const u8,
};

pub const BlockedHead = struct {
    head: []const u8,
    blocked_by: []const u8,
    conflicts: []const []const u8 = &.{},
    missing_checks: []const []const u8 = &.{},
};

pub const WavePlan = struct {
    clean_heads: []const []const u8,
    conflict_clusters: []const ConflictCluster,
    blocked_heads: []const BlockedHead,
};

fn overBudget(io: Io, start: Io.Timestamp) bool {
    return start.durationTo(Io.Clock.awake.now(io)).toMilliseconds() > check_budget_ms;
}

pub fn serveApi(
    app: *server.App,
    request: *http.Server.Request,
    repo: *const repo_git.Repo,
    name: repo_name.Name,
    access: content.Access,
) api.HandleError!http.Status {
    if (!access.canRead()) {
        return api.respondError(request, .forbidden, "forbidden", "this token lacks git:read");
    }
    if (access.isPathRestricted()) {
        return api.respondError(request, .forbidden, "forbidden", "path-scoped tokens may not run conflict checks");
    }

    const Body = struct {
        base: []const u8,
        heads: []const []const u8,
        include_file_overlaps: bool = false,
    };
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    const body = parsed.value;

    if (body.heads.len == 0 or body.heads.len > max_heads) {
        return api.respondError(request, .bad_request, "invalid_heads", "give 1-16 head refs");
    }
    for (body.heads, 0..) |h, i| {
        for (body.heads[0..i]) |prev| {
            if (std.mem.eql(u8, prev, h)) {
                return api.respondError(request, .bad_request, "invalid_heads", "duplicate head ref");
            }
        }
    }

    const start = Io.Clock.awake.now(app.io);
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var base_buf: [64]u8 = undefined;
    const base_sha = (try content.resolveNamed(request, repo, body.base, "base", access, &base_buf)) orelse return .not_found;
    const base_sha_owned = arena.dupe(u8, base_sha) catch return api.internal(request);

    var base_ref_buf: [ref_name.max_len]u8 = undefined;
    const maybe_base_ref: ?[]const u8 = ref_name.validateBranch(body.base, &base_ref_buf) catch null;
    const repo_rules = app.db.listBranchRules(app.io, app.gpa, name.full) catch return api.internal(request);
    defer Db.freeBranchRules(app.gpa, repo_rules);
    const req_checks: []const []const u8 = if (maybe_base_ref) |bref|
        (rules.collectRequiredChecks(app.gpa, repo_rules, bref) catch return api.internal(request))
    else
        &.{};
    defer if (maybe_base_ref != null) app.gpa.free(req_checks);

    const n = body.heads.len;
    const statuses = arena.alloc(BranchStatus, n) catch return api.internal(request);
    const virtuals = arena.alloc(?[]const u8, n) catch return api.internal(request);
    const touched = arena.alloc([]const []const u8, n) catch return api.internal(request);
    @memset(virtuals, null);
    @memset(touched, &.{});

    for (body.heads, 0..) |head_name, i| {
        if (overBudget(app.io, start)) {
            return api.respondError(request, .service_unavailable, "timeout", "conflict check exceeded time budget");
        }
        var h_buf: [64]u8 = undefined;
        const head_sha = (try content.resolveNamed(request, repo, head_name, "head", access, &h_buf)) orelse return .not_found;
        const head_sha_owned = arena.dupe(u8, head_sha) catch return api.internal(request);

        if (repo.isAncestor(head_sha_owned, base_sha_owned) catch |err| return content.gitError(request, err)) {
            statuses[i] = .{ .head = head_name, .sha = head_sha_owned, .mergeable = true, .conflicts = &.{} };
            continue;
        }

        const missing_checks = findMissingChecks(app, arena, name.full, head_sha_owned, req_checks) catch return api.internal(request);

        var tree_buf: [64]u8 = undefined;
        const merged = repo.mergeTree(base_sha_owned, head_sha_owned, &tree_buf) catch |err| return content.gitError(request, err);
        switch (merged) {
            .conflicts => |c| {
                defer app.gpa.free(c.raw);
                defer app.gpa.free(c.paths);
                statuses[i] = .{
                    .head = head_name,
                    .sha = head_sha_owned,
                    .mergeable = false,
                    .blocked_by = "merge_conflict",
                    .conflicts = dupeStrings(arena, c.paths) catch return api.internal(request),
                    .missing_checks = missing_checks,
                };
            },
            .clean => |tree| {
                const blocked_by: ?[]const u8 = if (missing_checks.len > 0) "missing_required_check" else null;
                statuses[i] = .{
                    .head = head_name,
                    .sha = head_sha_owned,
                    .mergeable = missing_checks.len == 0,
                    .blocked_by = blocked_by,
                    .conflicts = &.{},
                    .missing_checks = missing_checks,
                };
                var commit_buf: [64]u8 = undefined;
                const virt = repo.commitTree(
                    tree,
                    &.{base_sha_owned},
                    "gitd conflict check",
                    .{ .name = "gitd", .email = "gitd@localhost" },
                    &commit_buf,
                ) catch |err| return content.gitError(request, err);
                const virt_owned = arena.dupe(u8, virt) catch return api.internal(request);
                virtuals[i] = virt_owned;

                if (body.include_file_overlaps) {
                    const diff = repo.diffFiles(base_sha_owned, virt_owned) catch |err| return content.gitError(request, err);
                    defer diff.deinit(app.gpa);
                    const paths = arena.alloc([]const u8, diff.items.len) catch return api.internal(request);
                    for (diff.items, paths) |f, *out| out.* = arena.dupe(u8, f.path) catch return api.internal(request);
                    touched[i] = paths;
                }
            },
        }
    }

    var pairs: std.ArrayList(PairConflict) = .empty;
    var overlaps: std.ArrayList(FileOverlap) = .empty;
    for (0..n) |i| {
        const ci = virtuals[i] orelse continue;
        for (i + 1..n) |j| {
            const cj = virtuals[j] orelse continue;
            if (overBudget(app.io, start)) {
                return api.respondError(request, .service_unavailable, "timeout", "conflict check exceeded time budget");
            }
            var tree_buf: [64]u8 = undefined;
            const merged = repo.mergeTree(ci, cj, &tree_buf) catch |err| return content.gitError(request, err);
            switch (merged) {
                .clean => {},
                .conflicts => |c| {
                    defer app.gpa.free(c.raw);
                    defer app.gpa.free(c.paths);
                    pairs.append(arena, .{
                        .a = body.heads[i],
                        .b = body.heads[j],
                        .conflicts = dupeStrings(arena, c.paths) catch return api.internal(request),
                    }) catch return api.internal(request);
                },
            }
            if (body.include_file_overlaps and touched[i].len > 0 and touched[j].len > 0) {
                const common = intersectPaths(arena, touched[i], touched[j]) catch return api.internal(request);
                if (common.len > 0) {
                    overlaps.append(arena, .{
                        .a = body.heads[i],
                        .b = body.heads[j],
                        .paths = common,
                    }) catch return api.internal(request);
                }
            }
        }
    }

    const plan = computeWavePlan(arena, statuses, pairs.items) catch return api.internal(request);

    return api.respondJson(app.gpa, request, .ok, .{
        .base = body.base,
        .base_sha = base_sha_owned,
        .branches = statuses,
        .pair_conflicts = pairs.items,
        .file_overlaps = overlaps.items,
        .clean_heads = plan.clean_heads,
        .conflict_clusters = plan.conflict_clusters,
        .blocked_heads = plan.blocked_heads,
    });
}

fn findMissingChecks(
    app: *server.App,
    arena: std.mem.Allocator,
    repo_full: []const u8,
    head_sha: []const u8,
    req_checks: []const []const u8,
) ![]const []const u8 {
    if (req_checks.len == 0) return &.{};
    const commit_checks = try app.db.listCommitChecks(app.io, app.gpa, repo_full, head_sha);
    defer Db.freeCommitChecks(app.gpa, commit_checks);
    var missing: std.ArrayList([]const u8) = .empty;
    for (req_checks) |req_name| {
        var passed = false;
        for (commit_checks) |c| {
            if (std.mem.eql(u8, c.name, req_name) and std.mem.eql(u8, c.status, "passed")) {
                passed = true;
                break;
            }
        }
        if (!passed) try missing.append(arena, try arena.dupe(u8, req_name));
    }
    return missing.items;
}

/// Groups ready branches into `clean_heads` (isolated, zero pairwise conflicts)
/// and `conflict_clusters` (connected components of colliding branches), and
/// separates unmergeable/check-blocked branches into `blocked_heads`.
/// Allocates into `arena` (caller owns the arena).
pub fn computeWavePlan(
    arena: std.mem.Allocator,
    statuses: []const BranchStatus,
    pairs: []const PairConflict,
) std.mem.Allocator.Error!WavePlan {
    const n = statuses.len;
    var clean: std.ArrayList([]const u8) = .empty;
    var clusters: std.ArrayList(ConflictCluster) = .empty;
    var blocked: std.ArrayList(BlockedHead) = .empty;

    const ready = try arena.alloc(bool, n);
    for (statuses, ready) |st, *r| {
        if (st.mergeable and st.blocked_by == null) {
            r.* = true;
        } else {
            r.* = false;
            try blocked.append(arena, .{
                .head = st.head,
                .blocked_by = st.blocked_by orelse "merge_conflict",
                .conflicts = st.conflicts,
                .missing_checks = st.missing_checks,
            });
        }
    }

    const visited = try arena.alloc(bool, n);
    @memset(visited, false);
    const queue = try arena.alloc(usize, n);

    for (0..n) |start_idx| {
        if (!ready[start_idx] or visited[start_idx]) continue;

        var q_head: usize = 0;
        var q_tail: usize = 0;
        visited[start_idx] = true;
        queue[q_tail] = start_idx;
        q_tail += 1;

        var comp_indices: std.ArrayList(usize) = .empty;
        while (q_head < q_tail) {
            const cur = queue[q_head];
            q_head += 1;
            try comp_indices.append(arena, cur);

            for (pairs) |p| {
                const other_name: ?[]const u8 = if (std.mem.eql(u8, p.a, statuses[cur].head))
                    p.b
                else if (std.mem.eql(u8, p.b, statuses[cur].head))
                    p.a
                else
                    null;
                const oname = other_name orelse continue;
                for (0..n) |k| {
                    if (ready[k] and !visited[k] and std.mem.eql(u8, statuses[k].head, oname)) {
                        visited[k] = true;
                        queue[q_tail] = k;
                        q_tail += 1;
                    }
                }
            }
        }

        if (comp_indices.items.len == 1) {
            try clean.append(arena, statuses[comp_indices.items[0]].head);
        } else {
            // Preserve original input order for deterministic output.
            std.mem.sort(usize, comp_indices.items, {}, std.sort.asc(usize));
            const cheads = try arena.alloc([]const u8, comp_indices.items.len);
            for (comp_indices.items, cheads) |idx, *dst| dst.* = statuses[idx].head;

            var cfiles: std.ArrayList([]const u8) = .empty;
            for (pairs) |p| {
                if (containsStr(cheads, p.a) and containsStr(cheads, p.b)) {
                    for (p.conflicts) |f| {
                        if (!containsStr(cfiles.items, f)) try cfiles.append(arena, f);
                    }
                }
            }
            try clusters.append(arena, .{
                .heads = cheads,
                .files = cfiles.items,
            });
        }
    }

    return .{
        .clean_heads = clean.items,
        .conflict_clusters = clusters.items,
        .blocked_heads = blocked.items,
    };
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn dupeStrings(arena: std.mem.Allocator, items: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, items.len);
    for (items, out) |s, *dst| dst.* = try arena.dupe(u8, s);
    return out;
}

/// Returns paths present in both `a` and `b`. Caller owns the returned slice.
pub fn intersectPaths(
    gpa: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (a) |pa| {
        for (b) |pb| {
            if (std.mem.eql(u8, pa, pb)) {
                try out.append(gpa, pa);
                break;
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

test intersectPaths {
    const a = [_][]const u8{ "README.md", "src/auth.zig", "src/main.zig" };
    const b = [_][]const u8{ "src/auth.zig", "src/util.zig", "README.md" };
    const common = try intersectPaths(std.testing.allocator, &a, &b);
    defer std.testing.allocator.free(common);
    try std.testing.expectEqual(@as(usize, 2), common.len);
    try std.testing.expectEqualStrings("README.md", common[0]);
    try std.testing.expectEqualStrings("src/auth.zig", common[1]);
}

test "computeWavePlan separates clean heads, connected conflict clusters, and blocked heads" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const statuses = [_]BranchStatus{
        .{ .head = "agent/a", .sha = "1", .mergeable = true, .conflicts = &.{} },
        .{ .head = "agent/b", .sha = "2", .mergeable = true, .conflicts = &.{} },
        .{ .head = "agent/c", .sha = "3", .mergeable = true, .conflicts = &.{} },
        .{ .head = "agent/clean", .sha = "4", .mergeable = true, .conflicts = &.{} },
        .{ .head = "agent/d", .sha = "5", .mergeable = true, .conflicts = &.{} },
        .{ .head = "agent/e", .sha = "6", .mergeable = true, .conflicts = &.{} },
        .{
            .head = "agent/wip",
            .sha = "7",
            .mergeable = false,
            .blocked_by = "missing_required_check",
            .conflicts = &.{},
            .missing_checks = &.{"pytest"},
        },
    };
    // Cluster 1: a-b-c via transitive edges (a,b) and (b,c); Cluster 2: d-e; Isolated: clean; Blocked: wip.
    const pairs = [_]PairConflict{
        .{ .a = "agent/a", .b = "agent/b", .conflicts = &.{"app/main.py"} },
        .{ .a = "agent/b", .b = "agent/c", .conflicts = &.{ "app/main.py", "app/db.py" } },
        .{ .a = "agent/d", .b = "agent/e", .conflicts = &.{"static/app.js"} },
    };

    const plan = try computeWavePlan(arena, &statuses, &pairs);
    try std.testing.expectEqual(@as(usize, 1), plan.clean_heads.len);
    try std.testing.expectEqualStrings("agent/clean", plan.clean_heads[0]);

    try std.testing.expectEqual(@as(usize, 2), plan.conflict_clusters.len);
    try std.testing.expectEqual(@as(usize, 3), plan.conflict_clusters[0].heads.len);
    try std.testing.expectEqualStrings("agent/a", plan.conflict_clusters[0].heads[0]);
    try std.testing.expectEqualStrings("agent/b", plan.conflict_clusters[0].heads[1]);
    try std.testing.expectEqualStrings("agent/c", plan.conflict_clusters[0].heads[2]);
    try std.testing.expectEqual(@as(usize, 2), plan.conflict_clusters[0].files.len);
    try std.testing.expectEqualStrings("app/main.py", plan.conflict_clusters[0].files[0]);
    try std.testing.expectEqualStrings("app/db.py", plan.conflict_clusters[0].files[1]);

    try std.testing.expectEqual(@as(usize, 2), plan.conflict_clusters[1].heads.len);
    try std.testing.expectEqualStrings("agent/d", plan.conflict_clusters[1].heads[0]);
    try std.testing.expectEqualStrings("agent/e", plan.conflict_clusters[1].heads[1]);

    try std.testing.expectEqual(@as(usize, 1), plan.blocked_heads.len);
    try std.testing.expectEqualStrings("agent/wip", plan.blocked_heads[0].head);
    try std.testing.expectEqualStrings("missing_required_check", plan.blocked_heads[0].blocked_by);
}
