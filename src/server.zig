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
const TimedReader = @import("timed_reader.zig").TimedReader;

pub const App = struct {
    io: Io,
    gpa: std.mem.Allocator,
    db: *Db,
    store: *const Store,
    secret: *const auth.Secret,
    /// A connection with no traffic for this long is dropped.
    idle_timeout_seconds: u32 = default_idle_timeout_seconds,
    /// Serializes repo create and delete, so the database row and the
    /// directory on disk change together (R1.3). gitd runs one server.
    repo_lock: Io.Mutex = .init,
    /// Each connection holds a slot, which caps threads and file
    /// descriptors. When all are taken, new clients wait in the kernel's
    /// accept queue.
    connection_slots: Io.Semaphore = .{ .permits = max_connections },
};

pub const default_idle_timeout_seconds = 60;
pub const max_connections = 512;
const max_json_body = 64 * 1024;
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
        group.concurrent(io, serveConnection, .{ app, stream }) catch |err| {
            std.log.err("starting connection task: {t}", .{err});
            stream.close(io);
            app.connection_slots.post(io);
        };
    }
}

fn serveConnection(app: *App, stream: Io.net.Stream) Io.Cancelable!void {
    const io = app.io;
    defer app.connection_slots.post(io);
    defer stream.close(io);
    var in_buf: [head_buffer_len]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    // Every read times out, so an idle or stalled client frees its slot.
    var net_reader: TimedReader = .init(stream, io, &in_buf, .fromSeconds(app.idle_timeout_seconds));
    var net_writer = stream.writer(io, &out_buf);
    var server: http.Server = .init(&net_reader.interface, &net_writer.interface);

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.log.debug("bad request head: {t}", .{err});
                return;
            },
        };
        handle(app, &request) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // The client went away or the response broke midway; nothing
            // more can be sent on this connection.
            else => return,
        };
    }
}

const HandleError = error{ WriteFailed, ResponseBroken, ClientGone, HttpExpectationFailed } || Io.Cancelable;

fn handle(app: *App, request: *http.Server.Request) HandleError!void {
    const start = Io.Clock.awake.now(app.io);
    const method = request.head.method;
    var target_buf: [256]u8 = undefined;
    // Copy for the log line; the head's strings die when the body is read.
    const logged_target = copyTruncated(&target_buf, pathOf(request.head.target));

    const status = route(app, request) catch |err| switch (err) {
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
fn route(app: *App, request: *http.Server.Request) HandleError!http.Status {
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

    if (std.mem.startsWith(u8, path, "/v1/")) return serveApi(app, request, path);
    return respondError(request, .not_found, "not_found", "no such route");
}

// ---- Admin API ----

fn serveApi(app: *App, request: *http.Server.Request, path: []const u8) HandleError!http.Status {
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
    var parsed = readJson(Body, app, request) catch |err| return respondBodyError(request, err);
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
    return respondJson(app, request, .created, RepoJson{ .name = name.full, .id = &id, .created_at = now });
}

fn listRepos(app: *App, request: *http.Server.Request) HandleError!http.Status {
    const repos = app.db.listRepos(app.io, app.gpa) catch return internal(request);
    defer Db.freeRepos(app.gpa, repos);
    const items = app.gpa.alloc(RepoJson, repos.len) catch return internal(request);
    defer app.gpa.free(items);
    for (repos, items) |repo, *item| item.* = .{ .name = repo.name, .id = repo.id, .created_at = repo.created_at };
    return respondJson(app, request, .ok, .{ .repos = items });
}

fn getRepo(app: *App, request: *http.Server.Request, name: repo_name.Name) HandleError!http.Status {
    const repo = (app.db.getRepo(app.io, app.gpa, name.full) catch return internal(request)) orelse
        return respondError(request, .not_found, "not_found", "no such repo");
    defer repo.deinit(app.gpa);
    return respondJson(app, request, .ok, RepoJson{ .name = repo.name, .id = repo.id, .created_at = repo.created_at });
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
    try request.respond("", .{ .status = .no_content, .keep_alive = keepAlive(request) });
    return .no_content;
}

fn createToken(app: *App, request: *http.Server.Request) HandleError!http.Status {
    const Body = struct {
        repo: []const u8,
        scopes: []const []const u8,
        ttl_seconds: i64 = auth.default_ttl_seconds,
    };
    var parsed = readJson(Body, app, request) catch |err| return respondBodyError(request, err);
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
    const claims = auth.Claims.init(name.full, repo.id, scopes, expires_at) catch return internal(request);
    var token_buf: [auth.max_token_len]u8 = undefined;
    const token = auth.mint(app.secret, &claims, &token_buf) catch return internal(request);
    return respondJson(app, request, .created, .{ .token = token, .expires_at = expires_at });
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

    return git_proxy.serve(app.io, app.gpa, app.store, request, git_route, input) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.ResponseBroken => return error.ResponseBroken,
        error.ClientGone => return error.ClientGone,
        error.BodyTooLarge => return respondError(request, .payload_too_large, "too_large", "request body is too large"),
        error.ProxyFailed, error.OutOfMemory => return respondError(request, .bad_gateway, "git_failed", "git could not handle the request"),
    };
}

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

// ---- Helpers ----

const BodyError = error{ BodyTooLarge, InvalidJson, ReadFailed, OutOfMemory };

fn readJson(comptime T: type, app: *App, request: *http.Server.Request) BodyError!std.json.Parsed(T) {
    if (request.head.transfer_compression != .identity) return error.InvalidJson;
    var buf: [4096]u8 = undefined;
    const reader = request.readerExpectContinue(&buf) catch return error.ReadFailed;
    const bytes = reader.allocRemaining(app.gpa, .limited(max_json_body)) catch |err| return switch (err) {
        error.StreamTooLong => error.BodyTooLarge,
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => error.ReadFailed,
    };
    defer app.gpa.free(bytes);
    return std.json.parseFromSlice(T, app.gpa, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

fn respondBodyError(request: *http.Server.Request, err: BodyError) HandleError!http.Status {
    return switch (err) {
        error.BodyTooLarge => respondError(request, .payload_too_large, "too_large", "JSON bodies are limited to 64 KiB"),
        error.InvalidJson => respondError(request, .bad_request, "invalid_json", "the body does not match the expected JSON"),
        error.ReadFailed => error.WriteFailed,
        error.OutOfMemory => internal(request),
    };
}

fn respondJson(app: *App, request: *http.Server.Request, status: http.Status, value: anytype) HandleError!http.Status {
    const body = app.gpa.print("{f}\n", .{std.json.fmt(value, .{})}) catch return internal(request);
    defer app.gpa.free(body);
    try request.respond(body, .{ .status = status, .keep_alive = keepAlive(request), .extra_headers = &json_headers });
    return status;
}

const json_headers = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};

fn respondError(request: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) HandleError!http.Status {
    var buf: [512]u8 = undefined;
    const Err = struct { code: []const u8, message: []const u8 };
    // Codes and messages are short constants, so this always fits.
    const body = std.mem.print(&buf, "{f}\n", .{std.json.fmt(.{ .@"error" = Err{ .code = code, .message = message } }, .{})}) catch unreachable;
    try request.respond(body, .{ .status = status, .keep_alive = keepAlive(request), .extra_headers = &json_headers });
    return status;
}

fn internal(request: *http.Server.Request) HandleError!http.Status {
    return respondError(request, .internal_server_error, "internal", "internal error; see server logs");
}

/// Whether the connection can serve another request after this response.
///
/// When a request has a body that was never read (an auth failure, say),
/// std would read and discard all of it, with no size limit, to reuse the
/// connection. Instead gitd closes the connection, and drops any
/// `Expect: 100-continue` so the client is not invited to send the body.
fn keepAlive(request: *http.Server.Request) bool {
    if (request.server.reader.state != .received_head) return true;
    const has_body = request.head.transfer_encoding != .none or (request.head.content_length orelse 0) > 0;
    if (!has_body) return true;
    request.head.expect = null;
    return false;
}

fn findHeader(request: *http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn copyBounded(buf: []u8, text: []const u8) ?[]const u8 {
    if (text.len > buf.len) return null;
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

fn pathOf(target: []const u8) []const u8 {
    return target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
}

fn copyTruncated(buf: []u8, text: []const u8) []const u8 {
    const n = @min(buf.len, text.len);
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

pub fn unixNow(io: Io) i64 {
    const ns = Io.Clock.real.now(io).nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}
