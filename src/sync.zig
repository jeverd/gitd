//! Upstream Git sync: fetch a branch from an upstream remote into gitd, or
//! push a branch from gitd back to an upstream remote.
//!
//!   POST /v1/repos/{ns}/{repo}/sync   admin key only (R2.1)
//!
//! Credentials are per-request (`token`), passed to git via
//! `GIT_CONFIG_KEY/VALUE` `http.extraHeader`, never written to disk, never
//! passed in argv, and never logged (R2.4, R2.5). Local/ext git protocols are
//! disabled (`protocol.file.allow=never`, `protocol.ext.allow=never`, R2.3).

const std = @import("std");
const http = std.http;
const api = @import("api.zig");
const server = @import("server.zig");
const repo_name = @import("repo_name.zig");
const ref_name = @import("ref_name.zig");
const repo_git = @import("repo_git.zig");
const content = @import("content.zig");
const events = @import("events.zig");

const max_url_len = 2048;
const max_token_len = 2048;
const max_username_len = 128;
const sync_timeout_ms = 60_000;
const sync_max_output = 1024 * 1024;

pub fn serveApi(
    app: *server.App,
    request: *http.Server.Request,
    name: repo_name.Name,
    access: content.Access,
) api.HandleError!http.Status {
    if (access.claims != null or access.read_only) {
        return api.respondError(request, .forbidden, "forbidden", "sync needs the admin key");
    }
    if (request.head.method != .POST) {
        return api.respondError(request, .method_not_allowed, "method_not_allowed", "use POST");
    }

    const Body = struct {
        direction: []const u8,
        url: []const u8,
        branch: []const u8,
        remote_branch: ?[]const u8 = null,
        token: ?[]const u8 = null,
        username: ?[]const u8 = null,
        force: bool = false,
    };
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    const body = parsed.value;

    const Direction = enum { fetch, push };
    const dir = std.meta.stringToEnum(Direction, body.direction) orelse
        return api.respondError(request, .bad_request, "invalid_direction", "direction must be fetch or push");

    if (!validateUrl(body.url)) {
        return api.respondError(request, .bad_request, "invalid_url", "url must be an absolute http or https URL without embedded credentials");
    }

    var local_ref_buf: [ref_name.max_len]u8 = undefined;
    const local_ref = ref_name.validateBranch(body.branch, &local_ref_buf) catch
        return api.respondError(request, .bad_request, "invalid_branch", "branch is not a valid branch name");

    const remote_branch = body.remote_branch orelse body.branch;
    var remote_ref_buf: [ref_name.max_len]u8 = undefined;
    const remote_ref = ref_name.validateBranch(remote_branch, &remote_ref_buf) catch
        return api.respondError(request, .bad_request, "invalid_branch", "remote_branch is not a valid branch name");

    const username = body.username orelse "x-access-token";
    if (!validUsername(username)) {
        return api.respondError(request, .bad_request, "invalid_username", "username must be 1-128 printable characters without ':'");
    }
    if (body.token) |tok| {
        if (!validToken(tok)) {
            return api.respondError(request, .bad_request, "invalid_token", "token must be 1-2048 printable characters");
        }
    }

    var header_buf: [4096]u8 = undefined;
    var git_cfg_buf: [4][2][]const u8 = undefined;
    var cfg_n: usize = 0;
    git_cfg_buf[cfg_n] = .{ "protocol.file.allow", "never" };
    cfg_n += 1;
    git_cfg_buf[cfg_n] = .{ "protocol.ext.allow", "never" };
    cfg_n += 1;
    git_cfg_buf[cfg_n] = .{ "http.followRedirects", "initial" };
    cfg_n += 1;
    if (body.token) |tok| {
        const header = formatBasicAuthHeader(&header_buf, username, tok) orelse
            return api.respondError(request, .bad_request, "invalid_token", "credentials are too long");
        git_cfg_buf[cfg_n] = .{ "http.extraHeader", header };
        cfg_n += 1;
    }
    const git_cfg = git_cfg_buf[0..cfg_n];

    const repo = repo_git.Repo.open(app.io, app.gpa, app.store, name) catch return api.internal(request);
    var refspec_buf: [ref_name.max_len * 2 + 4]u8 = undefined;

    switch (dir) {
        .fetch => {
            var old_buf: [64]u8 = undefined;
            const old_sha = (repo.refValue(local_ref, &old_buf) catch |err| return syncGitError(request, err)) orelse "";
            const prefix: []const u8 = if (body.force) "+" else "";
            const refspec = std.mem.print(&refspec_buf, "{s}{s}:{s}", .{ prefix, remote_ref, local_ref }) catch return api.internal(request);

            const result = repo.git(&.{ "fetch", "--no-tags", "--quiet", body.url, refspec }, .{
                .git_config = git_cfg,
                .max_output = sync_max_output,
                .timeout_ms = sync_timeout_ms,
            }) catch |err| return syncGitError(request, err);
            defer result.deinit(app.gpa);
            if (result.code != 0) {
                return handleSyncFailure(request, "fetch", result.code, result.stderr, body.token != null);
            }

            var new_buf: [64]u8 = undefined;
            const new_sha = (repo.refValue(local_ref, &new_buf) catch |err| return syncGitError(request, err)) orelse "";
            events.record(app, .{
                .created_at = api.unixNow(app.io),
                .repo = name.full,
                .kind = "sync_fetch",
                .ref = local_ref,
                .old = old_sha,
                .new = new_sha,
                .detail = body.url,
            });
            return api.respondJson(app.gpa, request, .ok, .{
                .direction = "fetch",
                .branch = body.branch,
                .remote_branch = remote_branch,
                .old_sha = if (old_sha.len > 0) @as(?[]const u8, old_sha) else null,
                .new_sha = new_sha,
            });
        },
        .push => {
            var local_buf: [64]u8 = undefined;
            const local_sha = (repo.refValue(local_ref, &local_buf) catch |err| return syncGitError(request, err)) orelse
                return api.respondError(request, .not_found, "not_found", "no such branch");
            const prefix: []const u8 = if (body.force) "+" else "";
            const refspec = std.mem.print(&refspec_buf, "{s}{s}:{s}", .{ prefix, local_ref, remote_ref }) catch return api.internal(request);

            const result = repo.git(&.{ "push", "--quiet", body.url, refspec }, .{
                .git_config = git_cfg,
                .max_output = sync_max_output,
                .timeout_ms = sync_timeout_ms,
            }) catch |err| return syncGitError(request, err);
            defer result.deinit(app.gpa);
            if (result.code != 0) {
                return handleSyncFailure(request, "push", result.code, result.stderr, body.token != null);
            }

            events.record(app, .{
                .created_at = api.unixNow(app.io),
                .repo = name.full,
                .kind = "sync_push",
                .ref = local_ref,
                .old = "",
                .new = local_sha,
                .detail = body.url,
            });
            return api.respondJson(app.gpa, request, .ok, .{
                .direction = "push",
                .branch = body.branch,
                .remote_branch = remote_branch,
                .sha = local_sha,
            });
        },
    }
}

fn handleSyncFailure(request: *http.Server.Request, dir: []const u8, code: u8, stderr: []const u8, has_token: bool) api.HandleError!http.Status {
    if (has_token) {
        std.log.info("git {s} failed with exit code {d}", .{ dir, code });
    } else {
        std.log.info("git {s} failed with exit code {d}: {s}", .{ dir, code, std.mem.trimEnd(u8, stderr, "\n") });
    }
    if (std.mem.find(u8, stderr, "non-fast-forward") != null or
        std.mem.find(u8, stderr, "rejected") != null or
        std.mem.find(u8, stderr, "fetch first") != null)
    {
        return api.respondError(request, .conflict, "sync_rejected", "sync rejected (non-fast-forward or remote refused ref)");
    }
    if (std.mem.find(u8, stderr, "Authentication failed") != null or
        std.mem.find(u8, stderr, "401") != null or
        std.mem.find(u8, stderr, "403") != null)
    {
        return api.respondError(request, .bad_gateway, "sync_auth_failed", "upstream rejected authentication");
    }
    return api.respondError(request, .bad_gateway, "sync_failed", "upstream sync failed");
}

fn syncGitError(request: *http.Server.Request, err: anyerror) api.HandleError!http.Status {
    if (err == error.Canceled) return error.Canceled;
    if (err == error.GitTimedOut) return api.respondError(request, .gateway_timeout, "timeout", "upstream sync timed out");
    if (err == error.OutputTooLarge) return api.respondError(request, .bad_gateway, "sync_failed", "upstream output exceeded limit");
    return api.internal(request);
}

/// Accepts absolute http or https URLs with a host and no embedded user/pass
/// or fragment (R2.3, R2.5).
pub fn validateUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > max_url_len) return false;
    if (url[0] == '-') return false;
    for (url) |c| if (c <= 0x20 or c == 0x7f) return false;
    const uri = std.Uri.parse(url) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return false;
    if (uri.user != null or uri.password != null) return false;
    if (uri.fragment != null) return false;
    const host = uri.host orelse return false;
    return switch (host) {
        .raw, .percent_encoded => |h| h.len > 0,
    };
}

fn validUsername(user: []const u8) bool {
    if (user.len == 0 or user.len > max_username_len) return false;
    for (user) |c| if (c < 0x20 or c == 0x7f or c == ':') return false;
    return true;
}

fn validToken(tok: []const u8) bool {
    if (tok.len == 0 or tok.len > max_token_len) return false;
    for (tok) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn formatBasicAuthHeader(out: []u8, user: []const u8, tok: []const u8) ?[]const u8 {
    var raw_buf: [max_username_len + 1 + max_token_len]u8 = undefined;
    const raw = std.mem.print(&raw_buf, "{s}:{s}", .{ user, tok }) catch return null;
    const prefix = "Authorization: Basic ";
    const enc_len = std.base64.standard.Encoder.calcSize(raw.len);
    if (prefix.len + enc_len > out.len) return null;
    @memcpy(out[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(out[prefix.len .. prefix.len + enc_len], raw);
    return out[0 .. prefix.len + enc_len];
}

test "validateUrl accepts http/https and rejects credentials and other schemes" {
    try std.testing.expect(validateUrl("https://github.com/org/repo.git"));
    try std.testing.expect(validateUrl("http://127.0.0.1:8080/acme/web.git"));
    try std.testing.expect(!validateUrl(""));
    try std.testing.expect(!validateUrl("file:///etc/passwd"));
    try std.testing.expect(!validateUrl("ssh://git@github.com/org/repo.git"));
    try std.testing.expect(!validateUrl("ext::sh -c id"));
    try std.testing.expect(!validateUrl("https://user:pass@github.com/org/repo.git"));
    try std.testing.expect(!validateUrl("https://token@github.com/org/repo.git"));
    try std.testing.expect(!validateUrl("https://github.com/org/repo.git#frag"));
    try std.testing.expect(!validateUrl("https://github.com/org/repo.git\n"));
    try std.testing.expect(!validateUrl("-oProxyCommand=id"));
}

test "formatBasicAuthHeader encodes user:token" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Authorization: Basic dDpzZWNyZXQ=",
        formatBasicAuthHeader(&buf, "t", "secret").?,
    );
}

test "fuzz validate sync url" {
    try std.testing.fuzz({}, fuzzValidateUrl, .{
        .corpus = &.{
            "https://github.com/a/b.git",
            "https://u:p@github.com/a/b.git",
            "file:///tmp/x",
        },
    });
}

fn fuzzValidateUrl(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    if (validateUrl(input)) {
        try std.testing.expect(std.mem.startsWith(u8, input, "http://") or std.mem.startsWith(u8, input, "https://"));
        try std.testing.expect(std.mem.findScalar(u8, input, '\n') == null);
    }
}
