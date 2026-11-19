//! The HTTP server: accepts connections, routes requests, and checks auth.
//!
//! Routes:
//!   GET    /healthz
//!   POST   /v1/repos               {"name": "acme/web"}          admin key
//!   GET    /v1/repos                                             admin key
//!   GET    /v1/repos/{ns}/{repo}                                 admin key
//!   DELETE /v1/repos/{ns}/{repo}                                 admin key
//!   POST   /v1/tokens              {"repo", "scopes", "ttl_seconds"}  admin key
//!   GET    /{ns}/{repo}.git/info/refs?service=...                repo token
//!   POST   /{ns}/{repo}.git/git-upload-pack | git-receive-pack   repo token

const std = @import("std");
const Io = std.Io;
const http = std.http;
const auth = @import("auth.zig");
const repo_name = @import("repo_name.zig");
const git_http = @import("git_http.zig");
const git_proxy = @import("git_proxy.zig");
const Db = @import("db.zig").Db;
const Store = @import("store.zig").Store;
const timed = @import("timed_stream.zig");
const receive_pack = @import("receive_pack.zig");
const repo_git = @import("repo_git.zig");
const events = @import("events.zig");
const ui = @import("ui.zig");
const content = @import("content.zig");
const http_util = @import("http_util.zig");
const keepAlive = http_util.keepAlive;

pub const App = struct {
    io: Io,
    gpa: std.mem.Allocator,
    db: *Db,
    store: *const Store,
    secret: *const auth.Secret,
    /// A connection with no traffic for this long is dropped.
    idle_timeout_seconds: u32 = default_idle_timeout_seconds,
    /// The whole request head must arrive within this long, however slowly
    /// it trickles in.
    head_timeout_seconds: u32 = default_head_timeout_seconds,
    /// Serializes repo create and delete, so the database row and the
    /// directory on disk change together (R1.3). gitd runs one server.
    repo_lock: Io.Mutex = .init,
    /// Each connection holds a slot, which caps threads and file
    /// descriptors. When all are taken, new clients wait in the kernel's
    /// accept queue.
    connection_slots: Io.Semaphore = .{ .permits = max_connections },
    peers: http_util.PeerLimit = .{ .max_per_peer = max_connections_per_peer },
    /// Serve the read-only activity page at /ui, to loopback clients only.
    ui_enabled: bool = false,
};

pub const default_idle_timeout_seconds = 60;
pub const max_connections = 512;
pub const max_connections_per_peer = 64;
pub const default_head_timeout_seconds = 10;
const head_buffer_len = 16 * 1024;

/// Accepts connections until canceled, serving each one concurrently.
pub fn run(app: *App, listener: *Io.net.Server) Io.Cancelable!void {
    const io = app.io;
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        try app.connection_slots.wait(io);
        const stream = listener.accept(io) catch |err| {
            app.connection_slots.post(io);
            switch (err) {
                error.Canceled => return error.Canceled,
                error.ConnectionAborted => continue,
                else => {
                    std.log.err("accept: {t}", .{err});
                    // Out of file descriptors and similar: back off briefly
                    // instead of spinning.
                    try io.sleep(.fromMilliseconds(100), .awake);
                    continue;
                },
            }
        };
        if (!app.peers.acquire(io, app.gpa, stream.socket.address)) {
            std.log.info("dropping connection: too many from one address", .{});
            stream.close(io);
            app.connection_slots.post(io);
            continue;
        }
        group.concurrent(io, serveConnection, .{ app, stream }) catch |err| {
            std.log.err("starting connection task: {t}", .{err});
            app.peers.release(io, stream.socket.address);
            stream.close(io);
            app.connection_slots.post(io);
        };
    }
}

fn serveConnection(app: *App, stream: Io.net.Stream) Io.Cancelable!void {
    const io = app.io;
    defer app.connection_slots.post(io);
    defer app.peers.release(io, stream.socket.address);
    defer stream.close(io);
    var in_buf: [head_buffer_len]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    // Every read and write times out, so a client that stalls or stops
    // reading frees its slot and its git processes (R3.4).
    const idle: Io.Duration = .fromSeconds(app.idle_timeout_seconds);
    var net_reader: timed.TimedReader = .init(stream, io, &in_buf, idle);
    var net_writer: timed.TimedWriter = .init(stream, io, &out_buf, idle);
    var server: http.Server = .init(&net_reader.interface, &net_writer.interface);

    while (server.reader.state == .ready) {
        net_reader.deadline = .fromNow(io, .{ .raw = .fromSeconds(app.head_timeout_seconds), .clock = .awake });
        const head = server.receiveHead();
        net_reader.deadline = null;
        var request = head catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.log.debug("bad request head: {t}", .{err});
                return;
            },
        };
        handle(app, &request, stream.socket.address) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // The client went away or the response broke midway; nothing
            // more can be sent on this connection.
            else => return,
        };
    }
}

const api = @import("api.zig");
const HandleError = api.HandleError;
const respondError = api.respondError;
const internal = api.internal;
const findHeader = api.findHeader;
const copyBounded = api.copyBounded;
const pathOf = api.pathOf;
const copyTruncated = api.copyTruncated;
pub const unixNow = api.unixNow;

fn handle(app: *App, request: *http.Server.Request, peer: Io.net.IpAddress) HandleError!void {
    const start = Io.Clock.awake.now(app.io);
    const method = request.head.method;
    var target_buf: [256]u8 = undefined;
    // Copy for the log line; the head's strings die when the body is read.
    const logged_target = copyTruncated(&target_buf, pathOf(request.head.target));

    const status = route(app, request, peer) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        // Clients hang up mid-transfer routinely (a canceled clone or
        // push), so these are not errors.
        error.ResponseBroken, error.ClientGone => |e| {
            std.log.info("{t} {s}: client went away ({t})", .{ method, logged_target, e });
            return e;
        },
        error.WriteFailed, error.HttpExpectationFailed => |e| return e,
    };
    const elapsed = start.durationTo(Io.Clock.awake.now(app.io));
    std.log.info("{t} {s} {d} {d}ms", .{ method, logged_target, @backingInt(status), elapsed.toMilliseconds() });
}

/// Handles one request and returns the status it sent.
fn route(app: *App, request: *http.Server.Request, peer: Io.net.IpAddress) HandleError!http.Status {
    const target = request.head.target;
    const path = pathOf(target);
    const query = if (std.mem.findScalar(u8, target, '?')) |q| target[q + 1 ..] else "";

    if (std.mem.eql(u8, path, "/healthz")) {
        if (request.head.method != .GET) return respondError(request, .method_not_allowed, "method_not_allowed", "use GET");
        try request.respond("ok\n", .{
            .keep_alive = keepAlive(request),
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
        return .ok;
    }

    if (git_http.match(request.head.method, path, query)) |maybe_route| {
        if (maybe_route) |git_route| return serveGit(app, request, git_route, query);
    } else |err| switch (err) {
        error.BadGitRequest => return respondError(request, .bad_request, "bad_git_request", "only the git smart HTTP protocol is served"),
        error.MethodNotAllowed => return respondError(request, .method_not_allowed, "method_not_allowed", "wrong method for this git endpoint"),
    }

    if (std.mem.startsWith(u8, path, "/v1/")) return serveApi(app, request, path, query);
    if (std.mem.eql(u8, path, "/ui") or std.mem.startsWith(u8, path, "/ui/")) {
        if (!app.ui_enabled) return respondError(request, .not_found, "not_found", "start gitd with --ui to serve this page");
        if (!isLoopback(peer)) return respondError(request, .forbidden, "forbidden", "the UI is only served to this machine");
        return ui.serve(app, request, path, query);
    }
    return respondError(request, .not_found, "not_found", "no such route");
}

// ---- Admin API ----

fn serveApi(app: *App, request: *http.Server.Request, path: []const u8, query: []const u8) HandleError!http.Status {
    // Per-repo content routes accept a repo token as well as the admin key.
    if (std.mem.startsWith(u8, path, "/v1/repos/")) {
        if (splitRepoPath(path["/v1/repos/".len..])) |parts| return serveContent(app, request, parts.name, parts.rest, query);
    }
    switch (checkAdmin(app, request)) {
        .ok => {},
        .missing => return respondError(request, .unauthorized, "unauthorized", "send Authorization: Bearer <admin key>"),
        .invalid => return respondError(request, .unauthorized, "unauthorized", "unknown admin key"),
        .failed => return respondError(request, .internal_server_error, "internal", "could not check the admin key"),
    }

    const method = request.head.method;
    if (std.mem.eql(u8, path, "/v1/repos")) {
        return switch (method) {
            .POST => createRepo(app, request),
            .GET => listRepos(app, request),
            else => respondError(request, .method_not_allowed, "method_not_allowed", "use GET or POST"),
        };
    }
    if (std.mem.startsWith(u8, path, "/v1/repos/")) {
        const name = repo_name.parse(path["/v1/repos/".len..]) catch
            return respondError(request, .bad_request, "invalid_repo_name", repo_name_help);
        return switch (method) {
            .GET => getRepo(app, request, name),
            .DELETE => deleteRepo(app, request, name),
            else => respondError(request, .method_not_allowed, "method_not_allowed", "use GET or DELETE"),
        };
    }
    if (std.mem.eql(u8, path, "/v1/tokens")) {
        if (method != .POST) return respondError(request, .method_not_allowed, "method_not_allowed", "use POST");
        return createToken(app, request);
    }
    return respondError(request, .not_found, "not_found", "no such route");
}

pub const RepoPath = struct { name: repo_name.Name, rest: []const u8 };

/// Splits `{ns}/{repo}/{rest}`. Null when there is no non-empty rest or
/// the name is invalid.
pub fn splitRepoPath(text: []const u8) ?RepoPath {
    const first = std.mem.findScalar(u8, text, '/') orelse return null;
    const second = std.mem.findScalarPos(u8, text, first + 1, '/') orelse return null;
    if (second + 1 >= text.len) return null;
    const name = repo_name.parse(text[0..second]) catch return null;
    return .{ .name = name, .rest = text[second + 1 ..] };
}

/// Authenticates a per-repo content request: the admin key, or a repo
/// token for this repo (by name and id) sent as `Authorization: Bearer`.
fn serveContent(app: *App, request: *http.Server.Request, name: repo_name.Name, rest: []const u8, query: []const u8) HandleError!http.Status {
    const header = findHeader(request, "authorization") orelse
        return respondError(request, .unauthorized, "unauthorized", "send Authorization: Bearer <admin key or repo token>");
    const bearer = auth.bearer(header) orelse
        return respondError(request, .unauthorized, "unauthorized", "send Authorization: Bearer <admin key or repo token>");

    const repo = (app.db.getRepo(app.io, app.gpa, name.full) catch return internal(request)) orelse
        return respondError(request, .not_found, "not_found", "no such repo");
    defer repo.deinit(app.gpa);

    if (std.mem.startsWith(u8, bearer, auth.token_prefix)) {
        const claims = auth.verify(app.secret, bearer, unixNow(app.io)) catch
            return respondError(request, .unauthorized, "unauthorized", "invalid or expired token");
        if (!std.mem.eql(u8, claims.repo(), name.full) or !std.mem.eql(u8, &claims.repo_id, repo.id)) {
            return respondError(request, .forbidden, "forbidden", "this token is for another repo");
        }
        return content.serve(app, request, name, rest, query, .{ .claims = &claims });
    }
    switch (checkAdmin(app, request)) {
        .ok => return content.serve(app, request, name, rest, query, .{ .claims = null }),
        .missing, .invalid => return respondError(request, .unauthorized, "unauthorized", "unknown admin key or token"),
        .failed => return internal(request),
    }
}

const repo_name_help = "repo names look like ns/repo: lowercase letters, digits, '.', '_', '-'";

const AdminCheck = enum { ok, missing, invalid, failed };

fn checkAdmin(app: *App, request: *http.Server.Request) AdminCheck {
    const header = findHeader(request, "authorization") orelse return .missing;
    const key = auth.bearer(header) orelse return .missing;
    const hash = auth.hashKey(key);
    const exists = app.db.apiKeyExists(app.io, &hash) catch return .failed;
    return if (exists) .ok else .invalid;
}

fn createRepo(app: *App, request: *http.Server.Request) HandleError!http.Status {
    const Body = struct { name: []const u8 };
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    const name = repo_name.parse(parsed.value.name) catch
        return respondError(request, .bad_request, "invalid_repo_name", repo_name_help);

    const io = app.io;
    try app.repo_lock.lock(io);
    defer app.repo_lock.unlock(io);

    const existing = app.db.getRepo(io, app.gpa, name.full) catch return internal(request);
    if (existing) |repo| {
        repo.deinit(app.gpa);
        return respondError(request, .conflict, "already_exists", "a repo with this name exists");
    }
    const id = auth.newRepoId(io) catch return internal(request);
    app.store.create(io, app.gpa, name) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return internal(request),
    };
    const now = unixNow(io);
    app.db.insertRepo(io, name.full, &id, now) catch |err| {
        // Keep disk and database in step: remove the repo we just made.
        app.store.delete(io, name) catch |del_err| std.log.err("cleaning up {s}: {t}", .{ name.full, del_err });
        return switch (err) {
            error.AlreadyExists => respondError(request, .conflict, "already_exists", "a repo with this name exists"),
            else => internal(request),
        };
    };
    events.record(app, .{ .repo = name.full, .kind = "repo_created", .created_at = now });
    return api.respondJson(app.gpa, request, .created, RepoJson{ .name = name.full, .id = &id, .created_at = now });
}

fn listRepos(app: *App, request: *http.Server.Request) HandleError!http.Status {
    const repos = app.db.listRepos(app.io, app.gpa) catch return internal(request);
    defer Db.freeRepos(app.gpa, repos);
    const items = app.gpa.alloc(RepoJson, repos.len) catch return internal(request);
    defer app.gpa.free(items);
    for (repos, items) |repo, *item| item.* = .{ .name = repo.name, .id = repo.id, .created_at = repo.created_at };
    return api.respondJson(app.gpa, request, .ok, .{ .repos = items });
}

fn getRepo(app: *App, request: *http.Server.Request, name: repo_name.Name) HandleError!http.Status {
    const repo = (app.db.getRepo(app.io, app.gpa, name.full) catch return internal(request)) orelse
        return respondError(request, .not_found, "not_found", "no such repo");
    defer repo.deinit(app.gpa);
    return api.respondJson(app.gpa, request, .ok, RepoJson{ .name = repo.name, .id = repo.id, .created_at = repo.created_at });
}

fn deleteRepo(app: *App, request: *http.Server.Request, name: repo_name.Name) HandleError!http.Status {
    const io = app.io;
    try app.repo_lock.lock(io);
    defer app.repo_lock.unlock(io);
    // Database first: once the row is gone the repo is unreachable, and a
    // leftover directory is cleared by the next create of the same name.
    const deleted = app.db.deleteRepo(io, name.full) catch return internal(request);
    if (!deleted) return respondError(request, .not_found, "not_found", "no such repo");
    app.store.delete(io, name) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => std.log.err("removing files of deleted repo {s}: {t}", .{ name.full, err }),
    };
    events.record(app, .{ .repo = name.full, .kind = "repo_deleted", .created_at = unixNow(io) });
    try request.respond("", .{ .status = .no_content, .keep_alive = keepAlive(request) });
    return .no_content;
}

fn createToken(app: *App, request: *http.Server.Request) HandleError!http.Status {
    const Body = struct {
        repo: []const u8,
        scopes: []const []const u8,
        ttl_seconds: i64 = auth.default_ttl_seconds,
        /// Ref patterns the token may write, like "refs/heads/agent/7/*".
        /// Omitted means any ref.
        refs: []const []const u8 = &.{},
    };
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    const body = parsed.value;

    const name = repo_name.parse(body.repo) catch
        return respondError(request, .bad_request, "invalid_repo_name", repo_name_help);
    var scopes: auth.Scopes = .{};
    for (body.scopes) |scope| {
        scopes = scopes.merge(auth.Scopes.fromName(scope) orelse
            return respondError(request, .bad_request, "invalid_scope", "scopes are git:read and git:write"));
    }
    if (scopes.isEmpty()) return respondError(request, .bad_request, "invalid_scope", "give at least one scope");
    if (body.ttl_seconds < 1 or body.ttl_seconds > auth.max_ttl_seconds) {
        return respondError(request, .bad_request, "invalid_ttl", "ttl_seconds must be between 1 and 86400");
    }

    const repo = (app.db.getRepo(app.io, app.gpa, name.full) catch return internal(request)) orelse
        return respondError(request, .not_found, "not_found", "no such repo");
    defer repo.deinit(app.gpa);

    const expires_at = unixNow(app.io) + body.ttl_seconds;
    var claims = auth.Claims.init(name.full, repo.id, scopes, expires_at) catch return internal(request);
    for (body.refs) |pattern| claims.addRefPattern(pattern) catch |err| return switch (err) {
        error.InvalidRefPattern => respondError(request, .bad_request, "invalid_ref_pattern", "ref patterns are full ref names, optionally ending in /*, like refs/heads/agent/7/*"),
        error.TooManyRefPatterns => respondError(request, .bad_request, "invalid_ref_pattern", "at most 4 ref patterns, 600 bytes in total"),
    };
    var token_buf: [auth.max_token_len]u8 = undefined;
    const token = auth.mint(app.secret, &claims, &token_buf) catch return internal(request);
    return api.respondJson(app.gpa, request, .created, .{ .token = token, .expires_at = expires_at });
}

const RepoJson = struct {
    name: []const u8,
    id: []const u8,
    created_at: i64,
};

// ---- Git ----

fn serveGit(app: *App, request: *http.Server.Request, git_route: git_http.Route, query: []const u8) HandleError!http.Status {
    var scratch: [auth.max_token_len + 256]u8 = undefined;
    const password = if (findHeader(request, "authorization")) |h| auth.basicPassword(h, &scratch) else null;
    const token = password orelse return respondGitAuth(request);
    const claims = auth.verify(app.secret, token, unixNow(app.io)) catch return respondGitAuth(request);

    if (!std.mem.eql(u8, claims.repo(), git_route.repo.full)) {
        return respondError(request, .forbidden, "forbidden", "this token is for another repo");
    }
    const repo = (app.db.getRepo(app.io, app.gpa, git_route.repo.full) catch return internal(request)) orelse
        return respondError(request, .not_found, "not_found", "no such repo");
    const same_repo = std.mem.eql(u8, repo.id, &claims.repo_id);
    repo.deinit(app.gpa);
    // The name matches but the repo was deleted and made again since the
    // token was minted.
    if (!same_repo) return respondError(request, .forbidden, "forbidden", "this token is for a deleted repo");

    const allowed = switch (git_route.service) {
        .upload_pack => claims.scopes.git_read,
        .receive_pack => claims.scopes.git_write,
    };
    if (!allowed) return respondError(request, .forbidden, "forbidden", "this token lacks the scope for this operation");

    // The ref advertisement is a GET; a body there is never read, and std
    // would otherwise try to drain it after the response (R3.4).
    if (git_route.kind == .info_refs and http_util.hasBody(request)) {
        return respondError(request, .bad_request, "bad_git_request", "info/refs takes no request body");
    }

    // Copy what the CGI needs before the body is read. Oversize values are
    // rejected rather than cut, so git never sees a changed header (R2.3).
    var ct_buf: [128]u8 = undefined;
    var proto_buf: [128]u8 = undefined;
    var query_buf: [64]u8 = undefined;
    var path_buf: [repo_name.max_len + 64]u8 = undefined;
    const too_long = "a git request header is too long";
    const input: git_proxy.CgiInput = .{
        .method = request.head.method,
        .path_info = copyBounded(&path_buf, git_route.path_info) orelse
            return respondError(request, .bad_request, "bad_git_request", too_long),
        .query = copyBounded(&query_buf, query) orelse
            return respondError(request, .bad_request, "bad_git_request", too_long),
        .content_type = copyBounded(&ct_buf, request.head.content_type orelse "") orelse
            return respondError(request, .bad_request, "bad_git_request", too_long),
        .content_encoding = switch (request.head.transfer_compression) {
            .identity => "",
            .gzip => "gzip",
            else => return respondError(request, .unsupported_media_type, "unsupported_encoding", "only gzip request bodies are supported"),
        },
        .git_protocol = copyBounded(&proto_buf, findHeader(request, "git-protocol") orelse "") orelse
            return respondError(request, .bad_request, "bad_git_request", too_long),
    };

    // `git_route.repo` borrows the request target, which reading the body
    // overwrites; events are recorded after that, so keep a copy.
    var name_buf: [repo_name.max_len]u8 = undefined;
    const repo_copy = repo_name.parse(copyBounded(&name_buf, git_route.repo.full) orelse unreachable) catch unreachable; // already valid and in bounds

    if (git_route.service == .receive_pack and input.content_encoding.len > 0) {
        // gitd must read a push's commands to check and record them.
        return respondError(request, .unsupported_media_type, "unsupported_encoding", "push bodies must not be compressed");
    }

    var body: ?git_proxy.Body = null;
    defer if (body) |b| b.close(app.io);
    if (git_route.kind == .rpc) {
        body = git_proxy.spool(app.io, app.store, request) catch |err| return proxyError(request, err);
    }

    // Read what a push will change before git runs (R2.2).
    var push: ?Push = null;
    defer if (push) |*p| p.deinit(app.gpa);
    if (git_route.service == .receive_pack and git_route.kind == .rpc) {
        push = Push.read(app, body.?) catch |err| switch (err) {
            error.InvalidPush, error.TooManyCommands => return respondError(request, .bad_request, "bad_git_request", "could not read the push commands"),
            error.OutOfMemory => return internal(request),
            else => |e| return proxyError(request, e),
        };
        if (!push.?.allowedBy(&claims)) return rejectPush(app, request, &push.?, &claims, repo_copy);
    }

    var recorder: Push.Recorder = .{ .app = app, .push = if (push) |*p| p else null, .repo = repo_copy };
    const after: ?git_proxy.After = if (push != null) .{ .ctx = &recorder, .run = Push.Recorder.run } else null;
    return git_proxy.serve(app.io, app.gpa, app.store, request, git_route, input, body, after) catch |err|
        proxyError(request, err);
}

fn proxyError(request: *http.Server.Request, err: git_proxy.ProxyError) HandleError!http.Status {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.ResponseBroken => error.ResponseBroken,
        error.ClientGone => error.ClientGone,
        error.BodyTooLarge => respondError(request, .payload_too_large, "too_large", "request body is too large"),
        error.ProxyFailed, error.OutOfMemory => respondError(request, .bad_gateway, "git_failed", "git could not handle the request"),
    };
}

/// Refuses a push that touches a ref outside the token's patterns (R2.2).
/// git never runs, so nothing changes; the client gets git's normal report
/// with a reason per ref, and each refused ref is logged.
fn rejectPush(app: *App, request: *http.Server.Request, push: *const Push, claims: *const auth.Claims, name: repo_name.Name) HandleError!http.Status {
    var allowed_buf: [auth.max_ref_patterns_bytes + 16]u8 = undefined;
    var allowed: std.Io.Writer = .fixed(&allowed_buf);
    for (0..claims.refs_count) |i| {
        if (i > 0) allowed.writeAll(", ") catch {};
        allowed.writeAll(claims.refPattern(i)) catch {};
    }
    var reason_buf: [auth.max_ref_patterns_bytes + 64]u8 = undefined;
    const reason = std.mem.print(&reason_buf, "token may only push to {s}", .{allowed.buffered()}) catch "token may not push here";
    const other = "push refused: another ref in it is not allowed";

    var reasons: [receive_pack.max_commands][]const u8 = undefined;
    const now = unixNow(app.io);
    for (push.commands, 0..) |cmd, i| {
        const ok = claims.allowsRef(cmd.ref);
        reasons[i] = if (ok) other else reason;
        if (!ok) events.record(app, .{ .repo = name.full, .kind = "push_rejected", .ref = cmd.ref, .old = cmd.old, .new = cmd.new, .detail = reason, .created_at = now });
    }
    // Rejection lines are the same in report-status and report-status-v2.
    if (!receive_pack.hasCapability(push.caps, "report-status") and !receive_pack.hasCapability(push.caps, "report-status-v2")) {
        return respondError(request, .forbidden, "forbidden", reason);
    }
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    var msg_buf: [auth.max_ref_patterns_bytes + 96]u8 = undefined;
    const message = std.mem.print(&msg_buf, "gitd: push rejected: {s}", .{reason}) catch "gitd: push rejected";
    receive_pack.writeRejection(&out.writer, push.caps, push.commands, reasons[0..push.commands.len], message) catch return internal(request);
    try request.respond(out.written(), .{
        .keep_alive = keepAlive(request),
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-git-receive-pack-result" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
    return .ok;
}

/// The ref updates a push asks for, read from its spooled body.
const Push = struct {
    head: []u8,
    commands_buf: *[receive_pack.max_commands]receive_pack.Command,
    commands: []receive_pack.Command,
    /// The client's capabilities, borrowing `head`.
    caps: []const u8,

    fn allowedBy(p: *const Push, claims: *const auth.Claims) bool {
        for (p.commands) |cmd| if (!claims.allowsRef(cmd.ref)) return false;
        return true;
    }

    fn read(app: *App, body: git_proxy.Body) (receive_pack.ParseError || git_proxy.ProxyError)!Push {
        const buf = try app.gpa.alloc(u8, receive_pack.max_commands_bytes);
        errdefer app.gpa.free(buf);
        const head = try body.head(app.io, buf);
        const commands_buf = try app.gpa.create([receive_pack.max_commands]receive_pack.Command);
        errdefer app.gpa.destroy(commands_buf);
        var caps: []const u8 = undefined;
        const commands = try receive_pack.parse(head, commands_buf, &caps);
        return .{ .head = buf, .commands_buf = commands_buf, .commands = commands, .caps = caps };
    }

    /// Runs `record` from inside the proxy, after git exits.
    const Recorder = struct {
        app: *App,
        push: ?*Push,
        repo: repo_name.Name,

        fn run(ctx: *anyopaque) void {
            const self: *Recorder = @ptrCast(@alignCast(ctx));
            if (self.push) |p| p.record(self.app, self.repo);
        }
    };

    fn deinit(p: *Push, gpa: std.mem.Allocator) void {
        gpa.destroy(p.commands_buf);
        gpa.free(p.head);
    }

    /// Records an event for each ref git actually moved. git can refuse
    /// some or all commands (a stale old value, fsck), so each ref is
    /// checked rather than trusting the request.
    fn record(p: *const Push, app: *App, name: repo_name.Name) void {
        const repo = repo_git.Repo.open(app.io, app.gpa, app.store, name) catch return;
        const now = unixNow(app.io);
        for (p.commands) |cmd| {
            var buf: [64]u8 = undefined;
            const current = repo.refValue(cmd.ref, &buf) catch |err| {
                std.log.err("reading {s} after push: {t}", .{ cmd.ref, err });
                continue;
            };
            const applied = if (cmd.isDelete()) current == null else (current != null and std.mem.eql(u8, current.?, cmd.new));
            if (!applied) continue;
            const detail = if (cmd.isCreate()) "created" else if (cmd.isDelete()) "deleted" else "updated";
            events.record(app, .{ .repo = name.full, .kind = "push", .ref = cmd.ref, .old = cmd.old, .new = cmd.new, .detail = detail, .created_at = now });
        }
    }
};

fn respondGitAuth(request: *http.Server.Request) HandleError!http.Status {
    try request.respond("authentication required\n", .{
        .status = .unauthorized,
        .keep_alive = keepAlive(request),
        .extra_headers = &.{
            .{ .name = "www-authenticate", .value = "Basic realm=\"gitd\"" },
            .{ .name = "content-type", .value = "text/plain" },
        },
    });
    return .unauthorized;
}

fn isLoopback(address: Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| std.mem.eql(u8, &a.bytes, &(@as([15]u8, @splat(0)) ++ [_]u8{1})) or
            (std.mem.eql(u8, a.bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }) and a.bytes[12] == 127),
    };
}

test splitRepoPath {
    const p = splitRepoPath("acme/web/files/src/a.zig").?;
    try std.testing.expectEqualStrings("acme/web", p.name.full);
    try std.testing.expectEqualStrings("files/src/a.zig", p.rest);
    try std.testing.expectEqual(null, splitRepoPath("acme/web"));
    try std.testing.expectEqual(null, splitRepoPath("acme/web/"));
    try std.testing.expectEqual(null, splitRepoPath("acme/../x/log"));
}
