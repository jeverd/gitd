//! The per-repo content API: read files, trees, history, and branches
//! without cloning.
//!
//! Under /v1/repos/{ns}/{repo}/ (admin key, or a repo token with git:read):
//!   GET branches
//!   GET files/{path}?ref=REF        raw bytes
//!   GET tree[/{path}]?ref=REF       directory listing
//!   GET log?ref=REF&limit=N&path=P  commits, newest first
//!   GET commits/{sha}
//!   GET compare/{base}...{head}     ahead/behind, changed files, patch
//!
//! Writes (admin key, or a repo token with git:write whose ref patterns
//! cover the branch):
//!   POST   commits              {"branch", "expected_head", "message", "changes", ...}
//!   POST   branches             {"name", "from"}
//!   DELETE branches/{name}?expected=SHA
//!   POST   merges               {"base", "head", "strategy", "expected_base_head", ...}
//!
//! Every ref change is a compare-and-swap (R3.2): a commit names the head
//! it was built on, and loses with 409 if the branch moved.
//!
//! REF is a branch name (`agent/3/work`), a full ref (`refs/heads/main`), or
//! a commit oid. It defaults to `main`. The UI serves the same reads under
//! /ui/api/repos/{ns}/{repo}/.

const std = @import("std");
const http = std.http;
const api = @import("api.zig");
const auth = @import("auth.zig");
const server = @import("server.zig");
const repo_name = @import("repo_name.zig");
const repo_path = @import("repo_path.zig");
const ref_name = @import("ref_name.zig");
const repo_git = @import("repo_git.zig");
const receive_pack = @import("receive_pack.zig");
const events = @import("events.zig");
const http_util = @import("http_util.zig");
const expiry = @import("expiry.zig");
const Db = @import("db.zig").Db;

const max_file_bytes = 10 * 1024 * 1024;
const max_commit_body = 16 * 1024 * 1024;
const max_changes = 100;
const max_message = 64 * 1024;
const max_patch_bytes = 1024 * 1024;
const default_log_limit = 50;
const max_log_limit = 500;

/// Who is asking. `claims` is null for the admin key and the UI.
pub const Access = struct {
    claims: ?*const auth.Claims,
    /// The UI may only read.
    read_only: bool = false,
    /// The repo's id, for anything stored against it.
    repo_id: []const u8,

    /// Whether this caller may write anything at all.
    pub fn canWriteAny(a: Access) bool {
        if (a.read_only) return false;
        const c = a.claims orelse return true;
        return c.scopes.git_write;
    }

    /// The lifetime of a branch this caller creates: `requested`, else the
    /// token's branch_ttl, else none.
    pub fn branchTtl(a: Access, requested: ?i64) ?i64 {
        if (requested) |r| return r;
        const c = a.claims orelse return null;
        return if (c.branch_ttl > 0) c.branch_ttl else null;
    }

    pub fn canRead(a: Access) bool {
        const c = a.claims orelse return true;
        return c.scopes.git_read;
    }

    /// Whether `ref` (a full ref name) may be created, moved, or deleted.
    pub fn canWrite(a: Access, ref: []const u8) bool {
        if (a.read_only) return false;
        const c = a.claims orelse return true;
        return c.scopes.git_write and c.allowsRef(ref);
    }
};

const Error = api.HandleError;

pub fn serve(
    app: *server.App,
    request: *http.Server.Request,
    name: repo_name.Name,
    rest: []const u8,
    query: []const u8,
    access: Access,
) Error!http.Status {
    const method = request.head.method;
    if (std.mem.eql(u8, rest, "webhooks") or std.mem.startsWith(u8, rest, "webhooks/")) {
        return @import("webhooks.zig").serveApi(app, request, name, rest, query, access);
    }
    const repo = repo_git.Repo.open(app.io, app.gpa, app.store, name) catch return api.internal(request);

    if (method == .GET) {
        if (!access.canRead()) return api.respondError(request, .forbidden, "forbidden", "this token lacks git:read");
        if (std.mem.eql(u8, rest, "branches")) return listBranches(app, request, &repo, name);
        if (std.mem.startsWith(u8, rest, "files/")) return readFile(app, request, &repo, rest["files/".len..], query);
        if (std.mem.eql(u8, rest, "tree")) return readTree(app, request, &repo, null, query);
        if (std.mem.startsWith(u8, rest, "tree/")) return readTree(app, request, &repo, rest["tree/".len..], query);
        if (std.mem.eql(u8, rest, "log")) return readLog(app, request, &repo, query);
        if (std.mem.startsWith(u8, rest, "commits/")) return readCommit(app, request, &repo, rest["commits/".len..]);
        if (std.mem.startsWith(u8, rest, "compare/")) return compare(app, request, &repo, rest["compare/".len..]);
    }
    if (method == .POST and std.mem.eql(u8, rest, "merges")) return merge(app, request, &repo, name, access);
    if (method == .POST and std.mem.eql(u8, rest, "commits")) return createCommit(app, request, &repo, name, access);
    if (method == .POST and std.mem.eql(u8, rest, "branches")) return createBranch(app, request, &repo, name, access);
    if (method == .DELETE and std.mem.startsWith(u8, rest, "branches/")) return deleteBranch(app, request, &repo, name, rest["branches/".len..], query, access);
    return api.respondError(request, .not_found, "not_found", "no such repo route");
}

// ---- Helpers ----

/// Turns the `ref` query value (default `main`) into a commit oid, or
/// responds with 400/404 and returns null.
fn commitFromQuery(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, query: []const u8, out: *[64]u8) Error!?[]const u8 {
    var decoded: [ref_name.max_len]u8 = undefined;
    const ref = if (std.mem.find(u8, query, "ref=") != null)
        (api.queryValue(&decoded, query, "ref") orelse {
            _ = try api.respondError(request, .bad_request, "invalid_ref", "ref is not valid");
            return null;
        })
    else
        "main";
    var full_buf: [ref_name.max_len]u8 = undefined;
    const rev = revFromName(ref, &full_buf) orelse {
        _ = try api.respondError(request, .bad_request, "invalid_ref", "ref must be a branch name, a full ref, or a commit oid");
        return null;
    };
    const commit = repo.resolveCommit(rev, out) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            _ = try api.internal(request);
            return null;
        },
    };
    _ = app;
    return commit orelse {
        _ = try api.respondError(request, .not_found, "not_found", "no such ref or commit");
        return null;
    };
}

/// Accepts an oid, a full ref (`refs/...`), or a branch name, and returns
/// what git should resolve. Null when it is none of these.
pub fn revFromName(text: []const u8, buf: *[ref_name.max_len]u8) ?[]const u8 {
    if (receive_pack.isOid(text)) return text;
    if (std.mem.startsWith(u8, text, "refs/")) {
        ref_name.validate(text) catch return null;
        return text;
    }
    return ref_name.validateBranch(text, buf) catch null;
}

/// Decodes and validates a path taken from the URL.
fn pathFromUrl(request: *http.Server.Request, raw: []const u8, out: *[repo_path.max_len]u8) Error!?[]const u8 {
    const decoded = api.percentDecode(out, raw, false) orelse {
        _ = try api.respondError(request, .bad_request, "invalid_path", "the path is not valid");
        return null;
    };
    repo_path.validate(decoded) catch {
        _ = try api.respondError(request, .bad_request, "invalid_path", "paths are slash-separated names with no empty, '.', '..', or '.git' parts");
        return null;
    };
    return decoded;
}

fn gitError(request: *http.Server.Request, err: anyerror) Error!http.Status {
    if (err == error.Canceled) return error.Canceled;
    if (err == error.OutputTooLarge) return api.respondError(request, .payload_too_large, "too_large", "the result is too large");
    if (err == error.PathRejected) return api.respondError(request, .bad_request, "invalid_path", "git refused one of the paths");
    if (err == error.GitTimedOut) return api.respondError(request, .service_unavailable, "timeout", "the operation took too long");
    return api.internal(request);
}

// ---- Reads ----

pub const BranchJson = struct { name: []const u8, commit: []const u8, committed_at: i64, subject: []const u8, expires_at: ?i64 };

/// Every branch in `repo` with its expiry, if any. Strings borrow
/// `branches` and `ttls`; the caller frees the result.
pub fn branchesWithExpiry(gpa: std.mem.Allocator, branches: repo_git.Repo.Branches, ttls: []const Db.BranchTtl) ![]BranchJson {
    const items = try gpa.alloc(BranchJson, branches.items.len);
    for (branches.items, items) |b, *i| {
        var expires_at: ?i64 = null;
        for (ttls) |t| {
            if (std.mem.startsWith(u8, t.ref, "refs/heads/") and std.mem.eql(u8, t.ref["refs/heads/".len..], b.name)) expires_at = t.expires_at;
        }
        i.* = .{ .name = b.name, .commit = b.commit, .committed_at = b.committed_at, .subject = b.subject, .expires_at = expires_at };
    }
    return items;
}

fn listBranches(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, name: repo_name.Name) Error!http.Status {
    const branches = repo.listBranches() catch |err| return gitError(request, err);
    defer branches.deinit(app.gpa);
    const ttls = app.db.listBranchTtls(app.io, app.gpa, name.full, 0, 10_000) catch return api.internal(request);
    defer Db.freeBranchTtls(app.gpa, ttls);
    const items = branchesWithExpiry(app.gpa, branches, ttls) catch return api.internal(request);
    defer app.gpa.free(items);
    return api.respondJson(app.gpa, request, .ok, .{ .branches = items });
}

/// Validates an optional `ttl_seconds` and records the expiry of `ref`.
fn ttlInvalid(ttl: ?i64) bool {
    const t = ttl orelse return false;
    return t < 1 or t > expiry.max_ttl_seconds;
}

fn setTtl(app: *server.App, name: repo_name.Name, repo_id: []const u8, ref: []const u8, ttl: ?i64) void {
    const t = ttl orelse return;
    app.db.setBranchTtl(app.io, name.full, repo_id, ref, api.unixNow(app.io) + t) catch |err| std.log.err("setting expiry of {s}: {t}", .{ ref, err });
}

fn readFile(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, raw_path: []const u8, query: []const u8) Error!http.Status {
    var path_buf: [repo_path.max_len]u8 = undefined;
    const path = (try pathFromUrl(request, raw_path, &path_buf)) orelse return .bad_request;
    var oid_buf: [64]u8 = undefined;
    const commit = (try commitFromQuery(app, request, repo, query, &oid_buf)) orelse return .not_found;

    const entries = repo.lsTree(commit, path, true) catch |err| return gitError(request, err);
    defer entries.deinit(app.gpa);
    if (entries.items.len != 1 or entries.items[0].kind != .blob) {
        return api.respondError(request, .not_found, "not_found", "no such file at that ref");
    }
    const entry = entries.items[0];
    if ((entry.size orelse 0) > max_file_bytes) return api.respondError(request, .payload_too_large, "too_large", "files over 10 MiB are not served");
    const data = repo.readBlob(entry.oid, max_file_bytes) catch |err| return gitError(request, err);
    defer app.gpa.free(data);
    try request.respond(data, .{
        .keep_alive = @import("http_util.zig").keepAlive(request),
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/octet-stream" },
            .{ .name = "x-gitd-commit", .value = commit },
            .{ .name = "x-content-type-options", .value = "nosniff" },
        },
    });
    return .ok;
}

fn readTree(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, raw_path: ?[]const u8, query: []const u8) Error!http.Status {
    var path_buf: [repo_path.max_len]u8 = undefined;
    const dir: ?[]const u8 = if (raw_path) |p| ((try pathFromUrl(request, p, &path_buf)) orelse return .bad_request) else null;
    var oid_buf: [64]u8 = undefined;
    const commit = (try commitFromQuery(app, request, repo, query, &oid_buf)) orelse return .not_found;

    if (dir) |d| {
        // A path that is missing or is not a directory is a 404.
        const self = repo.lsTree(commit, d, true) catch |err| return gitError(request, err);
        defer self.deinit(app.gpa);
        if (self.items.len != 1 or self.items[0].kind != .tree) {
            return api.respondError(request, .not_found, "not_found", "no such directory at that ref");
        }
    }
    const entries = repo.lsTree(commit, dir, false) catch |err| return gitError(request, err);
    defer entries.deinit(app.gpa);
    const Item = struct { name: []const u8, path: []const u8, type: []const u8, mode: []const u8, oid: []const u8, size: ?u64 };
    const items = app.gpa.alloc(Item, entries.items.len) catch return api.internal(request);
    defer app.gpa.free(items);
    for (entries.items, items) |e, *i| i.* = .{
        .name = std.Io.Dir.path.basename(e.path),
        .path = e.path,
        .type = @tagName(e.kind),
        .mode = e.mode,
        .oid = e.oid,
        .size = e.size,
    };
    return api.respondJson(app.gpa, request, .ok, .{ .commit = commit, .path = dir orelse "", .entries = items });
}

const CommitJson = struct {
    sha: []const u8,
    parents: []const []const u8,
    author: struct { name: []const u8, email: []const u8 },
    time: i64,
    subject: []const u8,
    body: []const u8,
};

fn commitsJson(arena: std.mem.Allocator, commits: []const repo_git.Repo.Commit) ![]CommitJson {
    const out = try arena.alloc(CommitJson, commits.len);
    for (commits, out) |c, *o| {
        var parents: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, c.parents, ' ');
        while (it.next()) |p| try parents.append(arena, p);
        o.* = .{
            .sha = c.sha,
            .parents = parents.items,
            .author = .{ .name = c.author_name, .email = c.author_email },
            .time = c.time,
            .subject = c.subject,
            .body = c.body,
        };
    }
    return out;
}

fn readLog(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, query: []const u8) Error!http.Status {
    var oid_buf: [64]u8 = undefined;
    const commit = (try commitFromQuery(app, request, repo, query, &oid_buf)) orelse return .not_found;
    const limit_raw = @import("ui.zig").queryInt(query, "limit") orelse default_log_limit;
    if (limit_raw < 1 or limit_raw > max_log_limit) return api.respondError(request, .bad_request, "invalid_limit", "limit must be 1-500");
    var path_buf: [repo_path.max_len]u8 = undefined;
    var path: ?[]const u8 = null;
    if (std.mem.find(u8, query, "path=") != null) {
        const p = api.queryValue(&path_buf, query, "path") orelse return api.respondError(request, .bad_request, "invalid_path", "the path is not valid");
        repo_path.validate(p) catch return api.respondError(request, .bad_request, "invalid_path", "the path is not valid");
        path = p;
    }
    const log = repo.log(commit, @intCast(limit_raw), path, false) catch |err| return gitError(request, err);
    defer log.deinit(app.gpa);
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const items = commitsJson(arena_state.allocator(), log.items) catch return api.internal(request);
    return api.respondJson(app.gpa, request, .ok, .{ .commits = items });
}

fn readCommit(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, sha: []const u8) Error!http.Status {
    if (!receive_pack.isOid(sha)) return api.respondError(request, .bad_request, "invalid_sha", "give a full commit oid");
    var oid_buf: [64]u8 = undefined;
    const commit = (repo.resolveCommit(sha, &oid_buf) catch |err| return gitError(request, err)) orelse
        return api.respondError(request, .not_found, "not_found", "no such commit");
    const log = repo.log(commit, 1, null, true) catch |err| return gitError(request, err);
    defer log.deinit(app.gpa);
    if (log.items.len != 1) return api.respondError(request, .not_found, "not_found", "no such commit");
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const items = commitsJson(arena_state.allocator(), log.items) catch return api.internal(request);
    return api.respondJson(app.gpa, request, .ok, items[0]);
}

// ---- Writes ----

const AuthorJson = struct { name: []const u8, email: []const u8 };

fn validAuthorField(text: []const u8) bool {
    if (text.len == 0 or text.len > 200) return false;
    for (text) |c| if (c < 0x20 or c == '<' or c == '>' or c == 0x7f) return false;
    return true;
}

fn forbiddenRef(request: *http.Server.Request, ref: []const u8) Error!http.Status {
    var buf: [ref_name.max_len + 64]u8 = undefined;
    const msg = std.mem.print(&buf, "this token may not write {s}", .{ref}) catch "this token may not write that branch";
    return api.respondError(request, .forbidden, "forbidden", msg);
}

fn createCommit(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, name: repo_name.Name, access: Access) Error!http.Status {
    const ChangeJson = struct {
        path: []const u8,
        content: ?[]const u8 = null,
        content_base64: ?[]const u8 = null,
        delete: bool = false,
    };
    const Body = struct {
        branch: []const u8,
        /// The head this commit is built on; null to create the branch.
        expected_head: ?[]const u8,
        /// Base for a new branch (a ref or oid). Omitted: a root commit.
        from: ?[]const u8 = null,
        message: []const u8,
        author: ?AuthorJson = null,
        changes: []const ChangeJson,
        /// When creating the branch: delete it after this many seconds.
        ttl_seconds: ?i64 = null,
    };
    // Refuse before buffering up to 16 MiB for a caller that cannot write.
    if (!access.canWriteAny()) return api.respondError(request, .forbidden, "forbidden", "this token lacks git:write");
    var parsed = api.readJsonLimit(Body, app.gpa, request, max_commit_body) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    const body = parsed.value;

    var ref_buf: [ref_name.max_len]u8 = undefined;
    const ref = ref_name.validateBranch(body.branch, &ref_buf) catch
        return api.respondError(request, .bad_request, "invalid_branch", "branch must be a valid branch name like agent/3/work");
    if (!access.canWrite(ref)) return forbiddenRef(request, ref);
    if (body.message.len == 0 or body.message.len > max_message or std.mem.findScalar(u8, body.message, 0) != null) {
        return api.respondError(request, .bad_request, "invalid_message", "message must be 1-65536 bytes with no NUL");
    }
    if (body.changes.len == 0 or body.changes.len > max_changes) return api.respondError(request, .bad_request, "invalid_changes", "give 1-100 changes");
    if (ttlInvalid(body.ttl_seconds)) return api.respondError(request, .bad_request, "invalid_ttl", "ttl_seconds must be 1-604800");
    if (body.ttl_seconds != null and body.expected_head != null) return api.respondError(request, .bad_request, "invalid_ttl", "ttl_seconds applies only when creating a branch (expected_head null)");
    const author: repo_git.Repo.Author = if (body.author) |a| blk: {
        if (!validAuthorField(a.name) or !validAuthorField(a.email)) return api.respondError(request, .bad_request, "invalid_author", "author name and email must be 1-200 plain characters");
        break :blk .{ .name = a.name, .email = a.email };
    } else .{ .name = "gitd agent", .email = "agent@gitd" };

    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const changes = arena.alloc(repo_git.Repo.Change, body.changes.len) catch return api.internal(request);
    for (body.changes, changes) |c, *out| {
        repo_path.validate(c.path) catch return api.respondError(request, .bad_request, "invalid_path", "a change has an invalid path");
        const given = @as(u8, @intFromBool(c.content != null)) + @intFromBool(c.content_base64 != null) + @intFromBool(c.delete);
        if (given != 1) return api.respondError(request, .bad_request, "invalid_changes", "each change needs exactly one of content, content_base64, or delete");
        const data: ?[]const u8 = if (c.content) |t| t else if (c.content_base64) |b64| blk: {
            const dec = std.base64.standard.Decoder;
            const len = dec.calcSizeForSlice(b64) catch return api.respondError(request, .bad_request, "invalid_changes", "content_base64 is not valid base64");
            const buf = arena.alloc(u8, len) catch return api.internal(request);
            dec.decode(buf, b64) catch return api.respondError(request, .bad_request, "invalid_changes", "content_base64 is not valid base64");
            break :blk buf;
        } else null;
        out.* = .{ .path = c.path, .content = data };
    }

    var parent_buf: [64]u8 = undefined;
    const parent: ?[]const u8 = if (body.expected_head) |e| blk: {
        if (!receive_pack.isOid(e)) return api.respondError(request, .bad_request, "invalid_expected_head", "expected_head must be a full commit oid or null");
        break :blk (repo.resolveCommit(e, &parent_buf) catch |err| return gitError(request, err)) orelse
            return staleHead(app, request, repo, name, ref, e);
    } else if (body.from) |f| blk: {
        var full: [ref_name.max_len]u8 = undefined;
        const rev = revFromName(f, &full) orelse return api.respondError(request, .bad_request, "invalid_ref", "from must be a branch name, a full ref, or a commit oid");
        break :blk (repo.resolveCommit(rev, &parent_buf) catch |err| return gitError(request, err)) orelse
            return api.respondError(request, .not_found, "not_found", "from names no commit");
    } else null;

    var sha_buf: [64]u8 = undefined;
    const sha = repo.buildCommit(parent, changes, body.message, author, &sha_buf) catch |err| return gitError(request, err);
    const outcome = repo.updateRef(ref, sha, body.expected_head) catch |err| return gitError(request, err);
    if (outcome == .stale) return staleHead(app, request, repo, name, ref, body.expected_head);

    // A branch made by commit gets the token's lifetime like a pushed one.
    setTtl(app, name, access.repo_id, ref, if (body.expected_head == null) access.branchTtl(body.ttl_seconds) else null);
    const subject = body.message[0 .. std.mem.findScalar(u8, body.message, '\n') orelse body.message.len];
    events.record(app, .{
        .repo = name.full,
        .kind = "commit",
        .ref = ref,
        .old = body.expected_head orelse "",
        .new = sha,
        .detail = truncateUtf8(subject, 200),
        .created_at = api.unixNow(app.io),
    });
    return api.respondJson(app.gpa, request, .created, .{ .sha = sha, .branch = body.branch, .parent = parent });
}

/// Answers a commit that lost the race: 409 with the branch's real head,
/// so the caller can rebuild on it. Logged as commit_conflict.
fn staleHead(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, name: repo_name.Name, ref: []const u8, expected: ?[]const u8) Error!http.Status {
    var buf: [64]u8 = undefined;
    const current = repo.refValue(ref, &buf) catch |err| return gitError(request, err);
    events.record(app, .{
        .repo = name.full,
        .kind = "commit_conflict",
        .ref = ref,
        .old = expected orelse "",
        .new = current orelse "",
        .detail = "branch moved; rebuild on the current head",
        .created_at = api.unixNow(app.io),
    });
    const Err = struct { code: []const u8, message: []const u8 };
    return api.respondJson(app.gpa, request, .conflict, .{
        .@"error" = Err{ .code = "stale_head", .message = "the branch is not at expected_head; rebuild on current_head" },
        .current_head = current,
    });
}

fn createBranch(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, name: repo_name.Name, access: Access) Error!http.Status {
    const Body = struct { name: []const u8, from: []const u8 = "main", ttl_seconds: ?i64 = null };
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    var ref_buf: [ref_name.max_len]u8 = undefined;
    const ref = ref_name.validateBranch(parsed.value.name, &ref_buf) catch
        return api.respondError(request, .bad_request, "invalid_branch", "name must be a valid branch name like agent/3/try-2");
    if (!access.canWrite(ref)) return forbiddenRef(request, ref);
    if (ttlInvalid(parsed.value.ttl_seconds)) return api.respondError(request, .bad_request, "invalid_ttl", "ttl_seconds must be 1-604800");
    var full: [ref_name.max_len]u8 = undefined;
    const rev = revFromName(parsed.value.from, &full) orelse return api.respondError(request, .bad_request, "invalid_ref", "from must be a branch name, a full ref, or a commit oid");
    var oid_buf: [64]u8 = undefined;
    const commit = (repo.resolveCommit(rev, &oid_buf) catch |err| return gitError(request, err)) orelse
        return api.respondError(request, .not_found, "not_found", "from names no commit");
    const outcome = repo.updateRef(ref, commit, null) catch |err| return gitError(request, err);
    if (outcome == .stale) return api.respondError(request, .conflict, "already_exists", "that branch already exists");
    setTtl(app, name, access.repo_id, ref, access.branchTtl(parsed.value.ttl_seconds));
    events.record(app, .{ .repo = name.full, .kind = "branch_created", .ref = ref, .new = commit, .created_at = api.unixNow(app.io) });
    return api.respondJson(app.gpa, request, .created, .{ .name = parsed.value.name, .commit = commit });
}

fn deleteBranch(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, name: repo_name.Name, raw: []const u8, query: []const u8, access: Access) Error!http.Status {
    var decoded: [ref_name.max_len]u8 = undefined;
    const branch = api.percentDecode(&decoded, raw, false) orelse return api.respondError(request, .bad_request, "invalid_branch", "the branch name is not valid");
    var ref_buf: [ref_name.max_len]u8 = undefined;
    const ref = ref_name.validateBranch(branch, &ref_buf) catch return api.respondError(request, .bad_request, "invalid_branch", "the branch name is not valid");
    if (!access.canWrite(ref)) return forbiddenRef(request, ref);
    var exp_buf: [64]u8 = undefined;
    const expected: ?[]const u8 = if (std.mem.find(u8, query, "expected=") != null) blk: {
        const e = api.queryValue(&exp_buf, query, "expected") orelse "";
        if (!receive_pack.isOid(e)) return api.respondError(request, .bad_request, "invalid_expected_head", "expected must be a full commit oid");
        break :blk e;
    } else null;
    var cur_buf: [64]u8 = undefined;
    const current = (repo.refValue(ref, &cur_buf) catch |err| return gitError(request, err)) orelse
        return api.respondError(request, .not_found, "not_found", "no such branch");
    const outcome = repo.updateRef(ref, null, expected) catch |err| return gitError(request, err);
    if (outcome == .stale) return api.respondError(request, .conflict, "stale_head", "the branch is not at the expected commit");
    app.db.clearBranchTtl(app.io, name.full, ref) catch |err| std.log.err("clearing expiry of {s}: {t}", .{ ref, err });
    events.record(app, .{ .repo = name.full, .kind = "branch_deleted", .ref = ref, .old = current, .created_at = api.unixNow(app.io) });
    try request.respond("", .{ .status = .no_content, .keep_alive = http_util.keepAlive(request) });
    return .no_content;
}

// ---- Diff and merge ----

/// Resolves a branch name, full ref, or oid to a commit; responds with
/// 400/404 and returns null when it cannot.
fn resolveNamed(request: *http.Server.Request, repo: *const repo_git.Repo, text: []const u8, what: []const u8, out: *[64]u8) Error!?[]const u8 {
    var full: [ref_name.max_len]u8 = undefined;
    const rev = revFromName(text, &full) orelse {
        var buf: [96]u8 = undefined;
        _ = try api.respondError(request, .bad_request, "invalid_ref", std.mem.print(&buf, "{s} must be a branch name, a full ref, or a commit oid", .{what}) catch "invalid ref");
        return null;
    };
    const commit = repo.resolveCommit(rev, out) catch |err| {
        _ = try gitError(request, err);
        return null;
    };
    return commit orelse {
        var buf: [64]u8 = undefined;
        _ = try api.respondError(request, .not_found, "not_found", std.mem.print(&buf, "{s} names no commit", .{what}) catch "no such commit");
        return null;
    };
}

fn compare(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, spec_raw: []const u8) Error!http.Status {
    var spec_buf: [2 * ref_name.max_len + 8]u8 = undefined;
    const spec = api.percentDecode(&spec_buf, spec_raw, false) orelse return api.respondError(request, .bad_request, "invalid_ref", "compare/{base}...{head}");
    const sep = std.mem.find(u8, spec, "...") orelse return api.respondError(request, .bad_request, "invalid_ref", "compare/{base}...{head}");
    var base_buf: [64]u8 = undefined;
    var head_buf: [64]u8 = undefined;
    const base = (try resolveNamed(request, repo, spec[0..sep], "base", &base_buf)) orelse return .not_found;
    const head = (try resolveNamed(request, repo, spec[sep + 3 ..], "head", &head_buf)) orelse return .not_found;

    var mb_buf: [64]u8 = undefined;
    const merge_base = repo.mergeBase(base, head, &mb_buf) catch |err| return gitError(request, err);
    const counts = repo.aheadBehind(base, head) catch |err| return gitError(request, err);
    // Like a pull request: what head changed since it left base.
    const from = merge_base orelse base;
    const files = repo.diffFiles(from, head) catch |err| return gitError(request, err);
    defer files.deinit(app.gpa);
    const patch = repo.diffPatch(from, head, max_patch_bytes) catch |err| return gitError(request, err);
    defer if (patch) |p| app.gpa.free(p);

    const FileJson = struct { path: []const u8, status: []const u8, additions: ?u64, deletions: ?u64 };
    const items = app.gpa.alloc(FileJson, files.items.len) catch return api.internal(request);
    defer app.gpa.free(items);
    for (files.items, items) |f, *i| i.* = .{ .path = f.path, .status = f.status, .additions = f.additions, .deletions = f.deletions };
    return api.respondJson(app.gpa, request, .ok, .{
        .base = base,
        .head = head,
        .merge_base = merge_base,
        .ahead = counts.ahead,
        .behind = counts.behind,
        .files = items,
        .patch = patch orelse "",
        .patch_truncated = patch == null,
    });
}

fn merge(app: *server.App, request: *http.Server.Request, repo: *const repo_git.Repo, name: repo_name.Name, access: Access) Error!http.Status {
    const Strategy = enum { merge, squash, @"fast-forward" };
    const Body = struct {
        base: []const u8,
        head: []const u8,
        strategy: Strategy = .merge,
        /// Only merge if base is still here.
        expected_base_head: ?[]const u8 = null,
        message: ?[]const u8 = null,
        author: ?AuthorJson = null,
    };
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    const body = parsed.value;

    var ref_buf: [ref_name.max_len]u8 = undefined;
    const base_ref = ref_name.validateBranch(body.base, &ref_buf) catch
        return api.respondError(request, .bad_request, "invalid_branch", "base must be a branch name");
    if (!access.canWrite(base_ref)) return forbiddenRef(request, base_ref);
    const author: repo_git.Repo.Author = if (body.author) |a| blk: {
        if (!validAuthorField(a.name) or !validAuthorField(a.email)) return api.respondError(request, .bad_request, "invalid_author", "author name and email must be 1-200 plain characters");
        break :blk .{ .name = a.name, .email = a.email };
    } else .{ .name = "gitd", .email = "gitd@localhost" };
    if (body.message) |m| if (m.len == 0 or m.len > max_message) return api.respondError(request, .bad_request, "invalid_message", "message must be 1-65536 bytes");

    var b_buf: [64]u8 = undefined;
    var h_buf: [64]u8 = undefined;
    const base = (try resolveNamed(request, repo, body.base, "base", &b_buf)) orelse return .not_found;
    const head = (try resolveNamed(request, repo, body.head, "head", &h_buf)) orelse return .not_found;
    if (body.expected_base_head) |e| {
        if (!std.mem.eql(u8, e, base)) return staleHead(app, request, repo, name, base_ref, e);
    }
    const now = api.unixNow(app.io);
    var detail_buf: [2 * ref_name.max_len + 32]u8 = undefined;

    if (repo.isAncestor(head, base) catch |err| return gitError(request, err)) {
        return api.respondJson(app.gpa, request, .ok, .{ .result = "up_to_date", .sha = base });
    }
    const can_ff = repo.isAncestor(base, head) catch |err| return gitError(request, err);
    if (body.strategy == .@"fast-forward" or (can_ff and body.strategy == .merge)) {
        if (!can_ff) return api.respondError(request, .conflict, "not_fast_forward", "base has commits head does not; use strategy merge or squash");
        const outcome = repo.updateRef(base_ref, head, base) catch |err| return gitError(request, err);
        if (outcome == .stale) return staleHead(app, request, repo, name, base_ref, base);
        const detail = std.mem.print(&detail_buf, "{s} into {s} (fast-forward)", .{ body.head, body.base }) catch "fast-forward";
        events.record(app, .{ .repo = name.full, .kind = "merge", .ref = base_ref, .old = base, .new = head, .detail = detail, .created_at = now });
        return api.respondJson(app.gpa, request, .created, .{ .result = "fast_forward", .sha = head });
    }

    var tree_buf: [64]u8 = undefined;
    const merged = repo.mergeTree(base, head, &tree_buf) catch |err| return gitError(request, err);
    switch (merged) {
        .conflicts => |c| {
            defer app.gpa.free(c.raw);
            defer app.gpa.free(c.paths);
            var list_buf: [512]u8 = undefined;
            var list: std.Io.Writer = .fixed(&list_buf);
            for (c.paths, 0..) |p, i| {
                if (i > 0) list.writeAll(", ") catch break;
                list.writeAll(p) catch break;
            }
            const detail = std.mem.print(&detail_buf, "{s} into {s}: {s}", .{ body.head, body.base, list.buffered() }) catch "conflicts";
            events.record(app, .{ .repo = name.full, .kind = "merge_conflict", .ref = base_ref, .old = base, .new = head, .detail = detail, .created_at = now });
            const Err = struct { code: []const u8, message: []const u8 };
            return api.respondJson(app.gpa, request, .conflict, .{
                .@"error" = Err{ .code = "merge_conflict", .message = "the branches change the same lines; resolve on head and retry" },
                .conflicts = c.paths,
            });
        },
        .clean => |tree| {
            var msg_buf: [2 * ref_name.max_len + 32]u8 = undefined;
            const message = body.message orelse (std.mem.print(&msg_buf, "Merge {s} into {s}", .{ body.head, body.base }) catch "Merge");
            const parents: []const []const u8 = if (body.strategy == .squash) &.{base} else &.{ base, head };
            var sha_buf: [64]u8 = undefined;
            const sha = repo.commitTree(tree, parents, message, author, &sha_buf) catch |err| return gitError(request, err);
            const outcome = repo.updateRef(base_ref, sha, base) catch |err| return gitError(request, err);
            if (outcome == .stale) return staleHead(app, request, repo, name, base_ref, base);
            const how = if (body.strategy == .squash) "squash" else "merge commit";
            const detail = std.mem.print(&detail_buf, "{s} into {s} ({s})", .{ body.head, body.base, how }) catch "merge";
            events.record(app, .{ .repo = name.full, .kind = "merge", .ref = base_ref, .old = base, .new = sha, .detail = detail, .created_at = now });
            return api.respondJson(app.gpa, request, .created, .{ .result = if (body.strategy == .squash) "squashed" else "merged", .sha = sha });
        },
    }
}

/// At most `max` bytes of `text`, cut before a UTF-8 sequence rather than
/// inside one.
pub fn truncateUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

test truncateUtf8 {
    try std.testing.expectEqualStrings("ab", truncateUtf8("ab", 5));
    try std.testing.expectEqualStrings("ab", truncateUtf8("ab\xc3\xa9", 3)); // é is 2 bytes
    try std.testing.expectEqualStrings("ab\xc3\xa9", truncateUtf8("ab\xc3\xa9x", 4));
}

test revFromName {
    var buf: [ref_name.max_len]u8 = undefined;
    try std.testing.expectEqualStrings("refs/heads/agent/3/work", revFromName("agent/3/work", &buf).?);
    try std.testing.expectEqualStrings("refs/tags/v1", revFromName("refs/tags/v1", &buf).?);
    const oid = "0123456789abcdef0123456789abcdef01234567";
    try std.testing.expectEqualStrings(oid, revFromName(oid, &buf).?);
    try std.testing.expectEqual(null, revFromName("../main", &buf));
    try std.testing.expectEqual(null, revFromName("HEAD~1", &buf));
    try std.testing.expectEqual(null, revFromName("refs/heads/x..y", &buf));
}
