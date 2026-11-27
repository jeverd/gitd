//! The activity log and live event stream (R2.1, R3.4, R3.5).
//!
//! Every change gitd makes or refuses is recorded in SQLite and broadcast
//! through `Hub` so SSE clients wake immediately without polling.
//!
//!   GET /v1/repos/{ns}/{repo}/events[?after=N&kind=K&ref=R&limit=N&stream=1]

const std = @import("std");
const Io = std.Io;
const http = std.http;
const api = @import("api.zig");
const server = @import("server.zig");
const repo_name = @import("repo_name.zig");
const ref_name = @import("ref_name.zig");
const content = @import("content.zig");
const http_util = @import("http_util.zig");
const Db = @import("db.zig").Db;
const auth = @import("auth.zig");

pub const Event = Db.Event;

pub const max_events_limit: i64 = 200;
pub const default_events_limit: i64 = 50;

pub const Hub = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    seq: u64 = 0,
    active_streams: usize = 0,
    closing: bool = false,
    peers: http_util.PeerLimit = .{ .max_per_peer = max_sse_per_peer },

    pub const max_sse_streams: usize = 64;
    pub const max_sse_per_peer: u32 = 8;
    pub const WaitResult = enum { signaled, timeout, closing };

    pub fn deinit(h: *Hub, gpa: std.mem.Allocator) void {
        h.peers.deinit(gpa);
    }

    pub fn currentSeq(h: *Hub, io: Io) u64 {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        return h.seq;
    }

    pub fn notify(h: *Hub, io: Io) void {
        h.mutex.lockUncancelable(io);
        h.seq +%= 1;
        h.mutex.unlock(io);
        h.cond.broadcast(io);
    }

    pub fn shutdown(h: *Hub, io: Io) void {
        h.mutex.lockUncancelable(io);
        h.closing = true;
        h.seq +%= 1;
        h.mutex.unlock(io);
        h.cond.broadcast(io);
    }

    pub fn acquireStream(h: *Hub, io: Io, gpa: std.mem.Allocator, peer: Io.net.IpAddress) bool {
        if (!h.peers.acquire(io, gpa, peer)) return false;
        h.mutex.lockUncancelable(io);
        const reject = h.closing or h.active_streams >= max_sse_streams;
        if (!reject) h.active_streams += 1;
        h.mutex.unlock(io);
        if (reject) {
            h.peers.release(io, peer);
            return false;
        }
        return true;
    }

    pub fn releaseStream(h: *Hub, io: Io, peer: Io.net.IpAddress) void {
        h.mutex.lockUncancelable(io);
        h.active_streams -= 1;
        h.mutex.unlock(io);
        h.peers.release(io, peer);
    }

    pub fn waitChange(h: *Hub, io: Io, seen_seq: u64, timeout_ms: u32) Io.Cancelable!WaitResult {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        if (h.closing) return .closing;
        if (h.seq != seen_seq) return .signaled;
        h.cond.waitTimeout(io, &h.mutex, .{
            .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake },
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout => return if (h.closing) .closing else .timeout,
        };
        return if (h.closing) .closing else .signaled;
    }
};

/// Records `event` and notifies any live SSE listeners. A DB failure is logged
/// and ignored: the change itself already happened, and losing its log entry
/// must not undo it or fail the request.
pub fn record(app: *server.App, event: Event) void {
    _ = app.db.insertEvent(app.io, event) catch |err| {
        std.log.err("recording {s} event for {s}: {t}", .{ event.kind, event.repo, err });
        return;
    };
    app.event_hub.notify(app.io);
}

/// `event` with the token's principal and on_behalf_of claims. `claims`
/// is null for the admin key. The strings borrow from `claims`.
pub fn withActor(event: Event, claims: ?*const auth.Claims) Event {
    var e = event;
    if (claims) |c| {
        e.principal = c.principal() orelse "";
        e.on_behalf_of = c.onBehalfOf() orelse "";
    }
    return e;
}

fn validKind(kind: []const u8) bool {
    if (kind.len == 0 or kind.len > 64) return false;
    for (kind) |c| switch (c) {
        'a'...'z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

const EventTarget = union(enum) {
    repo_wide,
    ref: []const u8,
    commit_oid,
};

fn classifyEventTarget(ref: []const u8) EventTarget {
    if (ref.len == 0) return .repo_wide;
    if (std.mem.startsWith(u8, ref, "refs/")) return .{ .ref = ref };
    return .commit_oid;
}

pub fn eventVisible(e: Event, access: content.Access) bool {
    if (!access.isReadRefRestricted()) return true;
    return switch (classifyEventTarget(e.ref)) {
        .repo_wide => true,
        .ref => |r| access.canReadRef(r),
        .commit_oid => false,
    };
}

pub fn serveApi(
    app: *server.App,
    request: *http.Server.Request,
    name: repo_name.Name,
    query: []const u8,
    access: content.Access,
) api.HandleError!http.Status {
    if (request.head.method != .GET) {
        return api.respondError(request, .method_not_allowed, "method_not_allowed", "use GET");
    }
    if (!access.canRead()) {
        return api.respondError(request, .forbidden, "forbidden", "this token lacks git:read");
    }

    const accept = api.findHeader(request, "accept") orelse "";
    const wants_sse_header = std.mem.find(u8, accept, "text/event-stream") != null;
    var last_event_id_buf: [32]u8 = undefined;
    const last_event_id_raw = api.copyBounded(&last_event_id_buf, api.findHeader(request, "last-event-id") orelse "") orelse "";
    const header_after: ?i64 = if (last_event_id_raw.len > 0) blk: {
        const parsed_id = std.fmt.parseInt(i64, last_event_id_raw, 10) catch null;
        break :blk if (parsed_id) |v| (if (v >= 0) v else null) else null;
    } else null;

    var stream_buf: [16]u8 = undefined;
    const stream_q: ?bool = if (std.mem.find(u8, query, "stream=") != null) blk: {
        const v = api.queryValue(&stream_buf, query, "stream") orelse
            return api.respondError(request, .bad_request, "invalid_query", "stream must be 0, 1, true, or false");
        if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) break :blk true;
        if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) break :blk false;
        return api.respondError(request, .bad_request, "invalid_query", "stream must be 0, 1, true, or false");
    } else null;
    const is_stream = stream_q orelse wants_sse_header;

    var after: i64 = header_after orelse 0;
    var after_buf: [32]u8 = undefined;
    if (std.mem.find(u8, query, "after=") != null) {
        const raw = api.queryValue(&after_buf, query, "after") orelse
            return api.respondError(request, .bad_request, "invalid_after", "after must be a non-negative integer");
        const val = std.fmt.parseInt(i64, raw, 10) catch
            return api.respondError(request, .bad_request, "invalid_after", "after must be a non-negative integer");
        if (val < 0) return api.respondError(request, .bad_request, "invalid_after", "after must be a non-negative integer");
        after = val;
    }

    var kind_buf: [64]u8 = undefined;
    var kind_filter: []const u8 = "";
    if (std.mem.find(u8, query, "kind=") != null) {
        const k = api.queryValue(&kind_buf, query, "kind") orelse
            return api.respondError(request, .bad_request, "invalid_kind", "kind must be 1-64 lowercase event characters");
        if (k.len > 0 and !validKind(k)) {
            return api.respondError(request, .bad_request, "invalid_kind", "kind must be 1-64 lowercase event characters");
        }
        kind_filter = k;
    }

    var ref_raw_buf: [ref_name.max_len]u8 = undefined;
    var ref_norm_buf: [ref_name.max_len]u8 = undefined;
    var ref_filter: []const u8 = "";
    if (std.mem.find(u8, query, "ref=") != null) {
        const r = api.queryValue(&ref_raw_buf, query, "ref") orelse
            return api.respondError(request, .bad_request, "invalid_ref", "ref must be a branch name or full ref");
        if (r.len > 0) {
            if (std.mem.startsWith(u8, r, "refs/")) {
                ref_name.validate(r) catch
                    return api.respondError(request, .bad_request, "invalid_ref", "ref must be a branch name or full ref");
                ref_filter = r;
            } else {
                ref_filter = ref_name.validateBranch(r, &ref_norm_buf) catch
                    return api.respondError(request, .bad_request, "invalid_ref", "ref must be a branch name or full ref");
            }
        }
    }

    var limit: i64 = default_events_limit;
    var limit_buf: [16]u8 = undefined;
    if (std.mem.find(u8, query, "limit=") != null) {
        const raw = api.queryValue(&limit_buf, query, "limit") orelse
            return api.respondError(request, .bad_request, "invalid_limit", "limit must be 1-200");
        limit = std.fmt.parseInt(i64, raw, 10) catch
            return api.respondError(request, .bad_request, "invalid_limit", "limit must be 1-200");
        if (limit < 1 or limit > max_events_limit) {
            return api.respondError(request, .bad_request, "invalid_limit", "limit must be 1-200");
        }
    }

    if (is_stream) {
        return serveSse(app, request, name, access, after, kind_filter, ref_filter);
    }

    const rows = app.db.listRepoEventsFiltered(app.io, app.gpa, name.full, after, kind_filter, ref_filter, @intCast(limit)) catch
        return api.internal(request);
    defer Db.freeEvents(app.gpa, rows);

    var next_after: i64 = after;
    var visible: std.ArrayList(Event) = .empty;
    defer visible.deinit(app.gpa);
    for (rows) |e| {
        next_after = @max(next_after, e.id);
        if (eventVisible(e, access)) {
            visible.append(app.gpa, e) catch return api.internal(request);
        }
    }
    return api.respondJson(app.gpa, request, .ok, .{
        .events = visible.items,
        .next_after = next_after,
    });
}

fn writeAndFlush(response: *http.BodyWriter, bytes: []const u8) !void {
    try response.writer.writeAll(bytes);
    try response.writer.flush();
    try response.flush();
}

fn serveSse(
    app: *server.App,
    request: *http.Server.Request,
    name: repo_name.Name,
    access: content.Access,
    start_after: i64,
    kind_filter: []const u8,
    ref_filter: []const u8,
) api.HandleError!http.Status {
    if (!app.event_hub.acquireStream(app.io, app.gpa, access.peer)) {
        return api.respondError(request, .too_many_requests, "too_many_streams", "too many concurrent event streams");
    }
    defer app.event_hub.releaseStream(app.io, access.peer);

    var send_buf: [16 * 1024]u8 = undefined;
    var response = request.respondStreaming(&send_buf, .{
        .respond_options = .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "x-accel-buffering", .value = "no" },
            },
        },
    }) catch return error.ResponseBroken;
    writeAndFlush(&response, ": connected\n\n") catch return error.ResponseBroken;

    var cursor: i64 = start_after;
    const started = Io.Clock.awake.now(app.io);
    const max_ms: i64 = @as(i64, app.sse_max_seconds) * 1000;

    while (true) {
        const seen_seq = app.event_hub.currentSeq(app.io);
        while (true) {
            const rows = app.db.listRepoEventsFiltered(
                app.io,
                app.gpa,
                name.full,
                cursor,
                kind_filter,
                ref_filter,
                max_events_limit,
            ) catch return error.ResponseBroken;
            defer Db.freeEvents(app.gpa, rows);

            var wrote = false;
            for (rows) |e| {
                cursor = @max(cursor, e.id);
                if (!eventVisible(e, access)) continue;
                response.writer.print("id: {d}\nevent: {s}\ndata: {f}\n\n", .{
                    e.id,
                    e.kind,
                    std.json.fmt(e, .{}),
                }) catch return error.ResponseBroken;
                wrote = true;
            }
            if (wrote) {
                response.writer.flush() catch return error.ResponseBroken;
                response.flush() catch return error.ResponseBroken;
            }
            if (rows.len < max_events_limit) break;
        }

        if (started.durationTo(Io.Clock.awake.now(app.io)).toMilliseconds() >= max_ms) break;

        switch (try app.event_hub.waitChange(app.io, seen_seq, app.sse_keepalive_ms)) {
            .signaled => {},
            .closing => return error.Canceled,
            .timeout => {
                if (started.durationTo(Io.Clock.awake.now(app.io)).toMilliseconds() >= max_ms) break;
                writeAndFlush(&response, ": keepalive\n\n") catch return error.ResponseBroken;
            },
        }
    }

    response.end() catch return error.ResponseBroken;
    return .ok;
}

const testing = std.testing;

test "Hub caps streams per peer and wakes on notify" {
    const io = testing.io;
    const gpa = testing.allocator;
    var hub: Hub = .{};
    defer hub.deinit(gpa);

    const peer: Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 1234 } };
    for (0..Hub.max_sse_per_peer) |_| {
        try testing.expect(hub.acquireStream(io, gpa, peer));
    }
    try testing.expect(!hub.acquireStream(io, gpa, peer));
    for (0..Hub.max_sse_per_peer) |_| {
        hub.releaseStream(io, peer);
    }
    try testing.expect(hub.acquireStream(io, gpa, peer));
    hub.releaseStream(io, peer);

    const seq = hub.currentSeq(io);
    try testing.expectEqual(Hub.WaitResult.timeout, try hub.waitChange(io, seq, 5));
    hub.notify(io);
    try testing.expectEqual(Hub.WaitResult.signaled, try hub.waitChange(io, seq, 5));
    hub.shutdown(io);
    try testing.expect(!hub.acquireStream(io, gpa, peer));
    try testing.expectEqual(Hub.WaitResult.closing, try hub.waitChange(io, seq + 1, 5));
}
