//! Multi-branch conflict radar (R1.1, R2.1, R3.4):
//!
//!   POST /v1/repos/{ns}/{repo}/merges/check
//!     {"base": "main", "heads": ["agent/a", "agent/b", ...], "include_file_overlaps": false}
//!
//! Simulates merging each head into `base` in memory using `git merge-tree`,
//! builds unreferenced single-parent virtual commits `C_i` on `base` (compatible
//! with Git 2.38+, no refs mutated, no events recorded), and checks every clean
//! pair `(C_i, C_j)` for pairwise conflicts.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const api = @import("api.zig");
const server = @import("server.zig");
const repo_name = @import("repo_name.zig");
const repo_git = @import("repo_git.zig");
const content = @import("content.zig");

pub const max_heads = 16;
const check_budget_ms: i64 = 15_000;

const BranchStatus = struct {
    head: []const u8,
    sha: []const u8,
    mergeable: bool,
    conflicts: []const []const u8,
};

const PairConflict = struct {
    a: []const u8,
    b: []const u8,
    conflicts: []const []const u8,
};

const FileOverlap = struct {
    a: []const u8,
    b: []const u8,
    paths: []const []const u8,
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
    _ = name;
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
                    .conflicts = dupeStrings(arena, c.paths) catch return api.internal(request),
                };
            },
            .clean => |tree| {
                statuses[i] = .{ .head = head_name, .sha = head_sha_owned, .mergeable = true, .conflicts = &.{} };
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

    return api.respondJson(app.gpa, request, .ok, .{
        .base = body.base,
        .base_sha = base_sha_owned,
        .branches = statuses,
        .pair_conflicts = pairs.items,
        .file_overlaps = overlaps.items,
    });
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
