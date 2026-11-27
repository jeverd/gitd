//! The HTTP server: accepts connections, routes requests, and checks auth.
//!
//! Routes:
//!   GET    /healthz
//!   POST   /v1/repos               {"name": "acme/web"}          admin key
//!   GET    /v1/repos                                             admin key
//!   GET    /v1/repos/{ns}/{repo}                                 admin key
//!   DELETE /v1/repos/{ns}/{repo}                                 admin key
//!   POST   /v1/tokens              {"repo", "scopes", "ttl_seconds", "principal", "on_behalf_of", ...}  admin key
//!   GET    /{ns}/{repo}.git/info/refs?service=...                repo token
//!   POST   /{ns}/{repo}.git/git-upload-pack | git-receive-pack   repo token

const std = @import("std");
const Io = std.Io;
const http = std.http;
const auth = @import("auth.zig");
const repo_name = @import("repo_name.zig");
const git_http = @import("git_http.zig");
const Db = @import("db.zig").Db;
const Store = @import("store.zig").Store;
const timed = @import("timed_stream.zig");
const receive_pack = @import("receive_pack.zig");
const upload_pack = @import("upload_pack.zig");
const repo_git = @import("repo_git.zig");
const events = @import("events.zig");
const ui = @import("ui.zig");
const content = @import("content.zig");
const expiry = @import("expiry.zig");
const webhooks = @import("webhooks.zig");
const maintenance = @import("maintenance.zig");
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
    /// Serializes fence updates against promotes, so a promote's fence
    /// check and its ref move are one step (see promote.zig).
    promote_lock: Io.Mutex = .init,
    /// Each connection holds a slot, which caps threads and file
    /// descriptors. When all are taken, new clients wait in the kernel's
    /// accept queue.
    connection_slots: Io.Semaphore = .{ .permits = max_connections },
    peers: http_util.PeerLimit = .{ .max_per_peer = max_connections_per_peer },
    /// Serve the read-only activity page at /ui, to loopback clients only.
    ui_enabled: bool = false,
    /// How often the reaper looks for expired branches.
    reaper_interval_ms: i64 = 1000,
    /// Webhook retries wait 1, 2, 4, 8 times this.
    webhook_backoff_ms: i64 = 1000,
    /// A webhook delivery that takes longer than this counts as failed.
    webhook_timeout_ms: i64 = 10_000,
    /// Coordinates safe background/on-demand GC against deleteRepo.
    maint: maintenance.Coordinator = .{},
    default_max_branches: u64 = 0,
    default_max_repo_bytes: u64 = 0,
    gc_interval_seconds: u32 = 300,
    gc_prune_seconds: u32 = 300,
    gc_expired_threshold: u32 = 20,
    /// Broadcasts new events to live SSE listeners and caps open streams (R3.4).
    event_hub: events.Hub = .{},
    sse_keepalive_ms: u32 = 15_000,
    sse_max_seconds: u32 = 300,
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
    defer {
        app.event_hub.shutdown(io);
        group.cancel(io);
    }
    group.concurrent(io, expiry.run, .{app}) catch |err| {
        std.log.err("starting the branch reaper: {t}", .{err});
    };
    group.concurrent(io, webhooks.run, .{app}) catch |err| {
        std.log.err("starting the webhook worker: {t}", .{err});
    };
    group.concurrent(io, maintenance.run, .{app}) catch |err| {
        std.log.err("starting the gc worker: {t}", .{err});
    };
    while (true) {
        try app.connection_slots.wait(io);
        const stream = listener.accept(io) catch |err| {
            app.connection_slots.post(io);
            switch (err) {
                error.Canceled => return error.Canceled,
                error.ConnectionAborted => continue,
                else => {
                    std.log.err("accept: {t}", .{err});
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
    var log_buf: [256]u8 = undefined;
    const logged_target = copyTruncated(&log_buf, pathOf(request.head.target));
    // Every handler routes on this copy. The head's strings live in the
    // connection's read buffer, which reading the body overwrites, so a
    // name or path taken from `request.head.target` would change under a
    // handler that reads a body (it fits: the head is at most this big).
    var target_buf: [head_buffer_len]u8 = undefined;
    const target = copyBounded(&target_buf, request.head.target) orelse unreachable;

    const status = route(app, request, peer, target) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.ResponseBroken, error.ClientGone => |e| {
            std.log.info("{t} {s}: client went away ({t})", .{ method, logged_target, e });
            return e;
        },
        error.WriteFailed, error.HttpExpectationFailed => |e| return e,
    };
    const elapsed = start.durationTo(Io.Clock.awake.now(app.io));
    std.log.info("{t} {s} {d} {d}ms", .{ method, logged_target, @backingInt(status), elapsed.toMilliseconds() });
}

fn route(app: *App, request: *http.Server.Request, peer: Io.net.IpAddress, target: []const u8) HandleError!http.Status {
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
        if (maybe_route) |git_route| return serveGit(app, request, git_route);
    } else |err| switch (err) {
        error.BadGitRequest => return respondError(request, .bad_request, "bad_git_request", "only the git smart HTTP protocol is served"),
        error.MethodNotAllowed => return respondError(request, .method_not_allowed, "method_not_allowed", "wrong method for this git endpoint"),
    }

    if (std.mem.startsWith(u8, path, "/v1/")) return serveApi(app, request, peer, path, query);
    if (std.mem.eql(u8, path, "/ui") or std.mem.startsWith(u8, path, "/ui/")) {
        if (!app.ui_enabled) return respondError(request, .not_found, "not_found", "start gitd with --ui to serve this page");
        if (!isLoopback(peer)) return respondError(request, .forbidden, "forbidden", "the UI is only served to this machine");
        // A loopback peer is not enough: a web page can point its own
        // domain at 127.0.0.1 (DNS rebinding) and read the UI. The Host
        // header still names that domain, so require a loopback host.
        if (!loopbackHost(findHeader(request, "host") orelse "")) return respondError(request, .forbidden, "forbidden", "open the UI at 127.0.0.1, localhost, or [::1]");
        return ui.serve(app, request, path, query);
    }
    return respondError(request, .not_found, "not_found", "no such route");
}

fn serveApi(app: *App, request: *http.Server.Request, peer: Io.net.IpAddress, path: []const u8, query: []const u8) HandleError!http.Status {
    if (std.mem.startsWith(u8, path, "/v1/repos/")) {
        if (splitRepoPath(path["/v1/repos/".len..])) |parts| return serveContent(app, request, peer, parts.name, parts.rest, query);
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
    if (std.mem.startsWith(u8, path, "/v1/tokens/") and std.mem.endsWith(u8, path, "/revoke")) {
        if (method != .POST) return respondError(request, .method_not_allowed, "method_not_allowed", "use POST");
        const jti = path["/v1/tokens/".len .. path.len - "/revoke".len];
        return revokeToken(app, request, jti);
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

fn serveContent(app: *App, request: *http.Server.Request, peer: Io.net.IpAddress, name: repo_name.Name, rest: []const u8, query: []const u8) HandleError!http.Status {
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
        if (claims.jti) |*jti| {
            const revoked = app.db.isTokenRevoked(app.io, jti) catch return internal(request);
            if (revoked) return respondError(request, .unauthorized, "unauthorized", "token has been revoked");
        }
        if (!std.mem.eql(u8, claims.repo(), name.full) or !std.mem.eql(u8, &claims.repo_id, repo.id)) {
            return respondError(request, .forbidden, "forbidden", "this token is for another repo");
        }
        return content.serve(app, request, name, rest, query, .{ .claims = &claims, .repo_id = repo.id, .peer = peer });
    }
    switch (checkAdmin(app, request)) {
        .ok => return content.serve(app, request, name, rest, query, .{ .claims = null, .repo_id = repo.id, .peer = peer }),
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
    app.maint.beginDeleteLocked(&app.repo_lock, io, name.full);
    defer app.maint.endDeleteLocked(io, app.gpa, name.full);
    const deleted = app.db.deleteRepo(io, name.full) catch return internal(request);
    if (!deleted) return respondError(request, .not_found, "not_found", "no such repo");
    app.db.clearBranchTtl(io, name.full, "") catch |err| std.log.err("clearing expiries of {s}: {t}", .{ name.full, err });
    _ = app.db.unlockBranch(io, name.full, "") catch |err| std.log.err("clearing locks of {s}: {t}", .{ name.full, err });
    app.db.deleteRepoBranchRules(io, name.full) catch |err| std.log.err("clearing rules of {s}: {t}", .{ name.full, err });
    app.db.deleteRepoChecks(io, name.full) catch |err| std.log.err("clearing checks of {s}: {t}", .{ name.full, err });
    app.db.deleteRepoQuota(io, name.full) catch |err| std.log.err("clearing quotas of {s}: {t}", .{ name.full, err });
    app.db.deleteRepoMaint(io, name.full) catch |err| std.log.err("clearing maintenance of {s}: {t}", .{ name.full, err });
    app.db.deleteRepoFences(io, name.full) catch |err| std.log.err("clearing fences of {s}: {t}", .{ name.full, err });
    _ = app.db.deleteWebhooks(io, name.full, 0) catch |err| std.log.err("deleting webhooks of {s}: {t}", .{ name.full, err });
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
        refs: []const []const u8 = &.{},
        read_refs: []const []const u8 = &.{},
        paths: []const []const u8 = &.{},
        branch_ttl_seconds: i64 = 0,
        principal: ?[]const u8 = null,
        on_behalf_of: ?[]const u8 = null,
    };
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    const body = parsed.value;

    const name = repo_name.parse(body.repo) catch
        return respondError(request, .bad_request, "invalid_repo_name", repo_name_help);
    var scopes: auth.Scopes = .{};
    for (body.scopes) |scope| {
        scopes = scopes.merge(auth.Scopes.fromName(scope) orelse
            return respondError(request, .bad_request, "invalid_scope", "scopes are git:read, git:write, and checks:write"));
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
    for (body.read_refs) |pattern| claims.addReadRefPattern(pattern) catch |err| return switch (err) {
        error.InvalidRefPattern => respondError(request, .bad_request, "invalid_ref_pattern", "read_refs patterns are full ref names, optionally ending in /*, like refs/heads/agent/7/*"),
        error.TooManyRefPatterns => respondError(request, .bad_request, "invalid_ref_pattern", "at most 4 read_refs patterns, 600 bytes in total"),
    };
    for (body.paths) |pattern| claims.addPathPattern(pattern) catch |err| return switch (err) {
        error.InvalidPathPattern => respondError(request, .bad_request, "invalid_path_pattern", "paths are valid repo paths, optionally ending in /*, like docs/*"),
        error.TooManyPathPatterns => respondError(request, .bad_request, "invalid_path_pattern", "at most 4 path patterns, 600 bytes in total"),
    };
    if (body.branch_ttl_seconds < 0 or body.branch_ttl_seconds > expiry.max_ttl_seconds) {
        return respondError(request, .bad_request, "invalid_ttl", "branch_ttl_seconds must be 0-604800");
    }
    claims.branch_ttl = @intCast(body.branch_ttl_seconds);
    const principal_help = "principal and on_behalf_of are 1-128 characters of A-Z a-z 0-9 . _ - : @ / + =";
    if (body.principal) |text| claims.setPrincipal(text) catch
        return respondError(request, .bad_request, "invalid_principal", principal_help);
    if (body.on_behalf_of) |text| claims.setOnBehalfOf(text) catch
        return respondError(request, .bad_request, "invalid_principal", principal_help);
    const jti = auth.newJti(app.io) catch return internal(request);
    claims.jti = jti;
    var token_buf: [auth.max_token_len]u8 = undefined;
    const token = auth.mint(app.secret, &claims, &token_buf) catch return internal(request);
    return api.respondJson(app.gpa, request, .created, .{ .token = token, .jti = &jti, .expires_at = expires_at });
}

fn revokeToken(app: *App, request: *http.Server.Request, jti: []const u8) HandleError!http.Status {
    if (!auth.isJti(jti)) return respondError(request, .bad_request, "invalid_jti", "jti must be 32 lowercase hex characters");
    const expires_at = unixNow(app.io) + auth.max_ttl_seconds;
    app.db.revokeToken(app.io, jti, expires_at) catch return internal(request);
    try request.respond("", .{ .status = .no_content, .keep_alive = keepAlive(request) });
    return .no_content;
}

const RepoJson = struct {
    name: []const u8,
    id: []const u8,
    created_at: i64,
};

fn serveGit(app: *App, request: *http.Server.Request, git_route: git_http.Route) HandleError!http.Status {
    var scratch: [auth.max_token_len + 256]u8 = undefined;
    const password = if (findHeader(request, "authorization")) |h| auth.basicPassword(h, &scratch) else null;
    const token = password orelse return respondGitAuth(request);
    const claims = auth.verify(app.secret, token, unixNow(app.io)) catch return respondGitAuth(request);
    if (claims.jti) |*jti| {
        const revoked = app.db.isTokenRevoked(app.io, jti) catch return internal(request);
        if (revoked) return respondGitAuth(request);
    }

    if (!std.mem.eql(u8, claims.repo(), git_route.repo.full)) {
        return respondError(request, .forbidden, "forbidden", "this token is for another repo");
    }
    const repo = (app.db.getRepo(app.io, app.gpa, git_route.repo.full) catch return internal(request)) orelse
        return respondError(request, .not_found, "not_found", "no such repo");
    const same_repo = std.mem.eql(u8, repo.id, &claims.repo_id);
    repo.deinit(app.gpa);
    if (!same_repo) return respondError(request, .forbidden, "forbidden", "this token is for a deleted repo");

    const allowed = switch (git_route.service) {
        .upload_pack => claims.scopes.git_read,
        .receive_pack => claims.scopes.git_write,
    };
    if (!allowed) return respondError(request, .forbidden, "forbidden", "this token lacks the scope for this operation");
    if (claims.isPathRestricted()) {
        return respondError(request, .forbidden, "forbidden", "path-scoped tokens must use the HTTP API, not raw git clone/push");
    }

    // The ref advertisement is a GET; a body there is never read, and std
    // would otherwise try to drain it after the response (R3.4).
    if (git_route.kind == .info_refs) {
        if (http_util.hasBody(request)) {
            return respondError(request, .bad_request, "bad_git_request", "info/refs takes no request body");
        }
        var proto_buf: [128]u8 = undefined;
        const git_proto = copyBounded(&proto_buf, findHeader(request, "git-protocol") orelse "") orelse
            return respondError(request, .bad_request, "bad_git_request", "a git request header is too long");
        return upload_pack.serveInfoRefs(app, request, git_route.repo, git_route.service, git_proto, &claims);
    }

    var name_buf: [repo_name.max_len]u8 = undefined;
    const repo_copy = repo_name.parse(copyBounded(&name_buf, git_route.repo.full) orelse unreachable) catch unreachable;

    if (git_route.service == .receive_pack) {
        if (request.head.transfer_compression != .identity) {
            return respondError(request, .unsupported_media_type, "unsupported_encoding", "push bodies must not be compressed");
        }
        return receive_pack.serveRpc(app, request, repo_copy, &claims);
    }

    // Copy the Git-Protocol header before reading the request body (R3.5).
    var proto_buf: [128]u8 = undefined;
    const git_proto = copyBounded(&proto_buf, findHeader(request, "git-protocol") orelse "") orelse
        return respondError(request, .bad_request, "bad_git_request", "a git request header is too long");
    return upload_pack.serveRpc(app, request, repo_copy, git_proto, &claims);
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

/// Whether a Host header names this machine: 127.0.0.1, localhost, or
/// [::1], with or without a port.
pub fn loopbackHost(host: []const u8) bool {
    const name = if (std.mem.startsWith(u8, host, "[")) blk: {
        const end = std.mem.findScalar(u8, host, ']') orelse return false;
        break :blk host[0 .. end + 1];
    } else host[0 .. std.mem.findScalar(u8, host, ':') orelse host.len];
    const rest = host[name.len..];
    if (rest.len > 0) {
        if (rest[0] != ':' or rest.len == 1) return false;
        for (rest[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return std.ascii.eqlIgnoreCase(name, "localhost") or std.mem.eql(u8, name, "127.0.0.1") or std.mem.eql(u8, name, "[::1]");
}

test loopbackHost {
    for ([_][]const u8{ "127.0.0.1", "127.0.0.1:18910", "localhost:80", "LOCALHOST", "[::1]:8080", "[::1]" }) |h| try std.testing.expect(loopbackHost(h));
    for ([_][]const u8{ "", "evil.com", "evil.com:18910", "127.0.0.1.evil.com", "localhost.evil.com", "127.0.0.1:x", "127.0.0.1:", "[::2]:80" }) |h| try std.testing.expect(!loopbackHost(h));
}
