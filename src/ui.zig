//! The read-only activity page at /ui, for watching agents work and for
//! recording demos. Only served with `gitd serve --ui`, and only to
//! loopback clients (checked by the caller). It never shows tokens, keys,
//! or webhook secrets (R2.5).
//!
//!   GET /ui                      the page
//!   GET /ui/api/state            repos and their branches
//!   GET /ui/api/events?after=N   events with id > N
//!   GET /ui/api/deliveries       the newest webhook deliveries (no secrets)

const std = @import("std");
const http = std.http;
const api = @import("api.zig");
const server = @import("server.zig");
const repo_name = @import("repo_name.zig");
const repo_git = @import("repo_git.zig");
const Db = @import("db.zig").Db;
const content = @import("content.zig");

const page = @embedFile("ui.html");
const max_events = 500;

pub fn serve(app: *server.App, request: *http.Server.Request, path: []const u8, query: []const u8) api.HandleError!http.Status {
    if (request.head.method != .GET) return api.respondError(request, .method_not_allowed, "method_not_allowed", "use GET");
    if (std.mem.eql(u8, path, "/ui") or std.mem.eql(u8, path, "/ui/")) {
        try request.respond(page, .{
            .keep_alive = @import("http_util.zig").keepAlive(request),
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-store" },
            },
        });
        return .ok;
    }
    if (std.mem.eql(u8, path, "/ui/api/state")) return state(app, request);
    if (std.mem.eql(u8, path, "/ui/api/events")) return eventsSince(app, request, query);
    if (std.mem.eql(u8, path, "/ui/api/deliveries")) return @import("webhooks.zig").recent(app, request, "", 20);
    if (std.mem.startsWith(u8, path, "/ui/api/repos/")) {
        const parts = server.splitRepoPath(path["/ui/api/repos/".len..]) orelse
            return api.respondError(request, .not_found, "not_found", "no such UI route");
        const repo = (app.db.getRepo(app.io, app.gpa, parts.name.full) catch return api.internal(request)) orelse
            return api.respondError(request, .not_found, "not_found", "no such repo");
        defer repo.deinit(app.gpa);
        return @import("content.zig").serve(app, request, parts.name, parts.rest, query, .{ .claims = null, .read_only = true, .repo_id = repo.id });
    }
    return api.respondError(request, .not_found, "not_found", "no such UI route");
}

const RepoJson = struct {
    name: []const u8,
    branches: []const content.BranchJson,
};

fn state(app: *server.App, request: *http.Server.Request) api.HandleError!http.Status {
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const repos = app.db.listRepos(app.io, app.gpa) catch return api.internal(request);
    defer Db.freeRepos(app.gpa, repos);
    const out = arena.alloc(RepoJson, repos.len) catch return api.internal(request);
    for (repos, out) |repo, *item| {
        const name = repo_name.parse(repo.name) catch return api.internal(request);
        const r = repo_git.Repo.open(app.io, arena, app.store, name) catch return api.internal(request);
        const branches = r.listBranches() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // The repo may be mid-delete; show it without branches.
            else => repo_git.Repo.Branches{ .raw = &.{}, .items = &.{} },
        };
        const ttls = app.db.listBranchTtls(app.io, arena, repo.name, 0, 10_000) catch return api.internal(request);
        const locks = app.db.listBranchLocks(app.io, arena, repo.name) catch return api.internal(request);
        const items = content.branchesWithMeta(arena, branches, ttls, locks) catch return api.internal(request);
        item.* = .{ .name = repo.name, .branches = items };
    }
    return api.respondJson(app.gpa, request, .ok, .{ .now = api.unixNow(app.io), .repos = out });
}

fn eventsSince(app: *server.App, request: *http.Server.Request, query: []const u8) api.HandleError!http.Status {
    const after = queryInt(query, "after") orelse 0;
    const list = app.db.listEvents(app.io, app.gpa, "", after, max_events) catch return api.internal(request);
    defer Db.freeEvents(app.gpa, list);
    return api.respondJson(app.gpa, request, .ok, .{ .events = list });
}

/// Reads `name=<integer>` from a query string.
pub fn queryInt(query: []const u8, name: []const u8) ?i64 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return std.fmt.parseInt(i64, pair[eq + 1 ..], 10) catch null;
    }
    return null;
}

test queryInt {
    try std.testing.expectEqual(@as(?i64, 5), queryInt("after=5", "after"));
    try std.testing.expectEqual(@as(?i64, 7), queryInt("x=1&after=7", "after"));
    try std.testing.expectEqual(@as(?i64, null), queryInt("after=x", "after"));
    try std.testing.expectEqual(@as(?i64, null), queryInt("", "after"));
}
