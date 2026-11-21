//! Commit status checks API and validation (R1.1, R2.1, R2.3, R5.1).
//!
//!   POST /v1/repos/{ns}/{repo}/commits/{sha}/checks   admin key or checks:write
//!   GET  /v1/repos/{ns}/{repo}/commits/{sha}/checks   admin key or git:read

const std = @import("std");
const http = std.http;
const api = @import("api.zig");
const server = @import("server.zig");
const repo_name = @import("repo_name.zig");
const repo_git = @import("repo_git.zig");
const receive_pack = @import("receive_pack.zig");
const content = @import("content.zig");
const events = @import("events.zig");
const Db = @import("db.zig").Db;

pub const max_name_len = 64;
pub const max_summary_len = 1024;
pub const max_url_len = 512;
pub const max_required_checks = 16;

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '/', '-' => {},
        else => return false,
    };
    return true;
}

pub fn validStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "pending") or
        std.mem.eql(u8, status, "running") or
        std.mem.eql(u8, status, "passed") or
        std.mem.eql(u8, status, "failed");
}

pub fn validSummary(summary: []const u8) bool {
    if (summary.len > max_summary_len) return false;
    return std.mem.findScalar(u8, summary, 0) == null;
}

pub fn validUrl(url: []const u8) bool {
    if (url.len == 0) return true;
    if (url.len > max_url_len) return false;
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return false;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    return true;
}

pub const JoinError = error{ InvalidCheckName, TooManyChecks, DuplicateCheck, OutOfMemory };

/// Validates `names` and serializes them as a comma-separated string owned by `gpa`.
pub fn joinRequired(gpa: std.mem.Allocator, names: []const []const u8) JoinError![]u8 {
    if (names.len > max_required_checks) return error.TooManyChecks;
    var total: usize = 0;
    for (names, 0..) |name, i| {
        if (!validName(name)) return error.InvalidCheckName;
        for (names[0..i]) |prev| {
            if (std.mem.eql(u8, prev, name)) return error.DuplicateCheck;
        }
        total += name.len + @intFromBool(i > 0);
    }
    if (names.len == 0) return try gpa.dupe(u8, "");
    const out = try gpa.alloc(u8, total);
    var pos: usize = 0;
    for (names, 0..) |name, i| {
        if (i > 0) {
            out[pos] = ',';
            pos += 1;
        }
        @memcpy(out[pos .. pos + name.len], name);
        pos += name.len;
    }
    return out;
}

/// Splits a comma-separated `required_checks` column into borrowed slices.
pub fn splitRequired(gpa: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    if (raw.len == 0) return try gpa.alloc([]const u8, 0);
    var items: std.ArrayList([]const u8) = .empty;
    errdefer items.deinit(gpa);
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        try items.append(gpa, part);
    }
    return items.toOwnedSlice(gpa);
}

pub fn rollupStatus(rows: []const Db.CommitCheck) []const u8 {
    if (rows.len == 0) return "none";
    var has_pending = false;
    for (rows) |r| {
        if (std.mem.eql(u8, r.status, "failed")) return "failed";
        if (!std.mem.eql(u8, r.status, "passed")) has_pending = true;
    }
    return if (has_pending) "pending" else "passed";
}

pub const CheckJson = struct {
    name: []const u8,
    status: []const u8,
    summary: []const u8,
    url: []const u8,
    updated_at: i64,
};

fn toJson(c: Db.CommitCheck) CheckJson {
    return .{
        .name = c.name,
        .status = c.status,
        .summary = c.summary,
        .url = c.url,
        .updated_at = c.updated_at,
    };
}

pub fn serveApi(
    app: *server.App,
    request: *http.Server.Request,
    repo: *const repo_git.Repo,
    name: repo_name.Name,
    raw_sha: []const u8,
    access: content.Access,
) api.HandleError!http.Status {
    const method = request.head.method;
    if (method != .GET and method != .POST) {
        return api.respondError(request, .method_not_allowed, "method_not_allowed", "use GET or POST");
    }
    if (!receive_pack.isOid(raw_sha)) {
        return api.respondError(request, .bad_request, "invalid_sha", "commit sha must be a 40-character commit id");
    }
    var oid_buf: [64]u8 = undefined;
    const sha = (repo.resolveCommit(raw_sha, &oid_buf) catch |err| return content.gitError(request, err)) orelse {
        return api.respondError(request, .not_found, "not_found", "no such commit");
    };
    return switch (method) {
        .GET => list(app, request, name, sha, access),
        .POST => upsert(app, request, name, sha, access),
        else => unreachable,
    };
}

fn list(
    app: *server.App,
    request: *http.Server.Request,
    name: repo_name.Name,
    sha: []const u8,
    access: content.Access,
) api.HandleError!http.Status {
    if (!access.canRead()) {
        return api.respondError(request, .forbidden, "forbidden", "this token lacks git:read");
    }
    const rows = app.db.listCommitChecks(app.io, app.gpa, name.full, sha) catch return api.internal(request);
    defer Db.freeCommitChecks(app.gpa, rows);
    const items = app.gpa.alloc(CheckJson, rows.len) catch return api.internal(request);
    defer app.gpa.free(items);
    for (rows, items) |r, *out| out.* = toJson(r);
    return api.respondJson(app.gpa, request, .ok, .{
        .sha = sha,
        .rollup = rollupStatus(rows),
        .checks = items,
    });
}

fn upsert(
    app: *server.App,
    request: *http.Server.Request,
    name: repo_name.Name,
    sha: []const u8,
    access: content.Access,
) api.HandleError!http.Status {
    if (!access.canWriteChecks()) {
        return api.respondError(request, .forbidden, "forbidden", "posting checks requires admin key or checks:write scope");
    }
    const Body = struct {
        name: []const u8,
        status: []const u8,
        summary: []const u8 = "",
        url: []const u8 = "",
    };
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    const body = parsed.value;

    if (!validName(body.name)) {
        return api.respondError(request, .bad_request, "invalid_check", "name must be 1-64 characters from [A-Za-z0-9._/-]");
    }
    if (!validStatus(body.status)) {
        return api.respondError(request, .bad_request, "invalid_check", "status must be pending, running, passed, or failed");
    }
    if (!validSummary(body.summary)) {
        return api.respondError(request, .bad_request, "invalid_check", "summary must be at most 1024 bytes with no NUL");
    }
    if (!validUrl(body.url)) {
        return api.respondError(request, .bad_request, "invalid_check", "url must be empty or an http(s) URL up to 512 bytes");
    }

    const now = api.unixNow(app.io);
    app.db.upsertCommitCheck(app.io, name.full, sha, body.name, body.status, body.summary, body.url, now) catch
        return api.internal(request);

    var detail_buf: [max_name_len + 16]u8 = undefined;
    const detail = std.mem.print(&detail_buf, "{s}: {s}", .{ body.name, body.status }) catch "check updated";
    events.record(app, .{
        .repo = name.full,
        .kind = "check_updated",
        .ref = sha,
        .new = sha,
        .detail = detail,
        .created_at = now,
    });
    return api.respondJson(app.gpa, request, .ok, .{
        .sha = sha,
        .name = body.name,
        .status = body.status,
        .summary = body.summary,
        .url = body.url,
        .updated_at = now,
    });
}

const testing = std.testing;

test "check validation and rollup" {
    try testing.expect(validName("tests"));
    try testing.expect(validName("ci/unit-1.2_a"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("a,b"));
    try testing.expect(!validName("a b"));

    try testing.expect(validStatus("pending"));
    try testing.expect(validStatus("running"));
    try testing.expect(validStatus("passed"));
    try testing.expect(validStatus("failed"));
    try testing.expect(!validStatus("error"));

    try testing.expect(validUrl(""));
    try testing.expect(validUrl("https://ci.example/runs/1"));
    try testing.expect(!validUrl("javascript:alert(1)"));
    try testing.expect(!validUrl("https://bad url/1"));

    const joined = try joinRequired(testing.allocator, &.{ "tests", "lint" });
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("tests,lint", joined);
    const parts = try splitRequired(testing.allocator, joined);
    defer testing.allocator.free(parts);
    try testing.expectEqual(@as(usize, 2), parts.len);
    try testing.expectEqualStrings("tests", parts[0]);
    try testing.expectEqualStrings("lint", parts[1]);

    try testing.expectError(error.DuplicateCheck, joinRequired(testing.allocator, &.{ "tests", "tests" }));
    try testing.expectError(error.InvalidCheckName, joinRequired(testing.allocator, &.{"bad name"}));

    const empty: []const Db.CommitCheck = &.{};
    try testing.expectEqualStrings("none", rollupStatus(empty));
    const passing = [_]Db.CommitCheck{
        .{ .name = "a", .status = "passed", .summary = "", .url = "", .updated_at = 1 },
        .{ .name = "b", .status = "passed", .summary = "", .url = "", .updated_at = 1 },
    };
    try testing.expectEqualStrings("passed", rollupStatus(&passing));
    const pending = [_]Db.CommitCheck{
        .{ .name = "a", .status = "passed", .summary = "", .url = "", .updated_at = 1 },
        .{ .name = "b", .status = "running", .summary = "", .url = "", .updated_at = 1 },
    };
    try testing.expectEqualStrings("pending", rollupStatus(&pending));
    const failing = [_]Db.CommitCheck{
        .{ .name = "a", .status = "running", .summary = "", .url = "", .updated_at = 1 },
        .{ .name = "b", .status = "failed", .summary = "", .url = "", .updated_at = 1 },
    };
    try testing.expectEqualStrings("failed", rollupStatus(&failing));
}

test "fuzz validate check" {
    try testing.fuzz({}, fuzzValidateCheck, .{
        .corpus = &.{ "tests,lint", "bad name", "https://ci.example/1\x00passed" },
    });
}

fn fuzzValidateCheck(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const raw = buf[0..smith.slice(&buf)];
    if (validName(raw)) {
        try testing.expect(raw.len >= 1 and raw.len <= max_name_len);
        try testing.expect(std.mem.findScalar(u8, raw, ',') == null);
    }
    _ = validStatus(raw);
    _ = validSummary(raw);
    _ = validUrl(raw);
    const parts = try splitRequired(testing.allocator, raw);
    defer testing.allocator.free(parts);
    const rejoined = joinRequired(testing.allocator, parts) catch return;
    testing.allocator.free(rejoined);
}
