//! Runs `git http-backend` for one authorized git request.
//!
//! The request body is spooled to a temp file first and given to the CGI
//! as stdin, and stderr goes to another temp file. Both files are unlinked
//! as soon as they are created, so nothing is left on disk whatever happens.
//! Only stdout is a pipe, and gitd reads it to the end, so the child can
//! never block on a pipe nobody reads.
//!
//! The CGI runs in its own process group. If the client goes away mid
//! response, gitd closes the pipe and SIGKILLs the whole group
//! (`http-backend`, `upload-pack`, `pack-objects`). gitd blocks SIGTERM for
//! its own shutdown handling and children inherit that mask, so a plain
//! `Child.kill` (SIGTERM, then wait) would wait forever.

const std = @import("std");
const Io = std.Io;
const git_http = @import("git_http.zig");
const store_mod = @import("store.zig");
const http_util = @import("http_util.zig");

/// Largest request body accepted, which bounds a single push.
pub const max_body_bytes: u64 = 2 * 1024 * 1024 * 1024;
const max_stderr_logged = 4 * 1024;

/// Request details copied out of the HTTP head before the body is read,
/// because reading the body invalidates the head's strings.
pub const CgiInput = struct {
    method: std.http.Method,
    /// `/{ns}/{repo}.git/...`, passed as PATH_INFO.
    path_info: []const u8,
    query: []const u8,
    content_type: []const u8 = "",
    content_encoding: []const u8 = "",
    git_protocol: []const u8 = "",
    /// Extra git config entries appended after `store.forced_config`.
    git_config: []const [2][]const u8 = &.{},
};

pub const ProxyError = error{
    BodyTooLarge,
    /// The client stopped sending the body (closed, reset, or went idle).
    /// git was not run.
    ClientGone,
    /// Set up failed before anything was sent; the caller can still respond.
    ProxyFailed,
    /// Failed after the response started; the connection must be dropped.
    ResponseBroken,
} || Io.Cancelable || std.mem.Allocator.Error;

/// A request body spooled to an unlinked temp file, read from offset 0.
pub const Body = struct {
    file: Io.File,
    len: u64,

    pub fn close(b: Body, io: Io) void {
        b.file.close(io);
    }

    /// Reads up to `buf.len` leading bytes, for inspecting the start of a
    /// push without disturbing the offset git reads from.
    pub fn head(b: Body, io: Io, buf: []u8) ProxyError![]u8 {
        const n = b.file.readPositionalAll(io, buf, 0) catch |err| return fail("reading body", err);
        return buf[0..n];
    }
};

/// Spools the request body. Call before `serve` for rpc routes.
pub fn spool(io: Io, store: *const store_mod.Store, request: *std.http.Server.Request) ProxyError!Body {
    const file = try createUnlinked(io, store, "body");
    errdefer file.close(io);
    const len = try spoolBody(io, request, file);
    return .{ .file = file, .len = len };
}

/// Runs `git http-backend` for the request and relays its response. `body`
/// is the spooled body for rpc routes and null for info/refs.
pub fn serve(
    io: Io,
    gpa: std.mem.Allocator,
    store: *const store_mod.Store,
    request: *std.http.Server.Request,
    route: git_http.Route,
    input: CgiInput,
    body: ?Body,
    after: ?After,
) ProxyError!std.http.Status {
    const body_file: ?Io.File = if (body) |b| b.file else null;
    const body_len: u64 = if (body) |b| b.len else 0;

    const err_file = try createUnlinked(io, store, "err");
    defer err_file.close(io);

    var env = try store_mod.gitEnv(gpa, store.path_env);
    defer env.deinit();
    if (input.git_config.len > 0) {
        var count_buf: [16]u8 = undefined;
        const total = store_mod.forced_config_count + input.git_config.len;
        try env.put("GIT_CONFIG_COUNT", std.mem.print(&count_buf, "{d}", .{total}) catch return error.ProxyFailed);
        for (input.git_config, 0..) |kv, offset| {
            const idx = store_mod.forced_config_count + offset;
            var key_buf: [32]u8 = undefined;
            var val_buf: [32]u8 = undefined;
            try env.put(std.mem.print(&key_buf, "GIT_CONFIG_KEY_{d}", .{idx}) catch return error.ProxyFailed, kv[0]);
            try env.put(std.mem.print(&val_buf, "GIT_CONFIG_VALUE_{d}", .{idx}) catch return error.ProxyFailed, kv[1]);
        }
    }
    var len_buf: [24]u8 = undefined;
    try env.put("GIT_PROJECT_ROOT", store.root);
    try env.put("GIT_HTTP_EXPORT_ALL", "1");
    try env.put("PATH_INFO", input.path_info);
    try env.put("REQUEST_METHOD", @tagName(input.method));
    try env.put("QUERY_STRING", input.query);
    try env.put("REMOTE_USER", "gitd");
    if (input.content_type.len > 0) try env.put("CONTENT_TYPE", input.content_type);
    if (input.content_encoding.len > 0) try env.put("HTTP_CONTENT_ENCODING", input.content_encoding);
    if (input.git_protocol.len > 0) try env.put("GIT_PROTOCOL", input.git_protocol);
    if (route.kind == .rpc) {
        try env.put("CONTENT_LENGTH", std.mem.print(&len_buf, "{d}", .{body_len}) catch unreachable);
    }

    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "http-backend" },
        .environ_map = &env,
        .stdin = if (body_file) |f| .{ .file = f } else .ignore,
        .stdout = .pipe,
        .stderr = .{ .file = err_file },
        // pgid 0 makes the child the leader of a new group, so `killGroup`
        // reaches git's own children too.
        .pgid = 0,
    }) catch |err| return fail("spawning git http-backend", err);
    defer killGroup(io, &child);

    var read_buf: [git_http.max_cgi_head_len * 2]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var response: std.http.BodyWriter = undefined;
    const status = relay(io, request, child.stdout.?, &read_buf, &send_buf, &response) catch |err| {
        // git may already have moved refs. Stop it, then let the caller
        // record whatever actually changed, before giving up on the client.
        killGroup(io, &child);
        if (after) |a| a.run(a.ctx);
        return err;
    };

    // The response is under way: from here a failure is only logged, so
    // the caller never writes a second response.
    const term: ?std.process.Child.Term = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => blk: {
            std.log.err("git proxy waiting for git http-backend: {t}", .{err});
            break :blk null;
        },
    };
    if (term) |t| switch (t) {
        .exited => |code| if (code != 0 or @backingInt(status) >= 500) logStderr(io, err_file, status, code),
        .signal, .stopped, .unknown => logStderr(io, err_file, status, null),
    };
    // git has finished: let the caller record what it changed before the
    // client sees the end of the response, so anyone who reads the event
    // log after `git push` returns sees the push.
    if (after) |a| a.run(a.ctx);
    response.end() catch return error.ResponseBroken;
    return status;
}

/// Work to run after git exits and before the response ends.
pub const After = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque) void,
};

/// Reads the CGI head from `stdout`, starts the response in `response`,
/// and streams git's output into it, leaving it open for the caller to
/// end. Returns the status sent.
fn relay(
    io: Io,
    request: *std.http.Server.Request,
    stdout: Io.File,
    read_buf: []u8,
    send_buf: []u8,
    response: *std.http.BodyWriter,
) ProxyError!std.http.Status {
    var reader = stdout.readerStreaming(io, read_buf);
    const r = &reader.interface;

    const head = while (true) {
        if (git_http.parseCgiHead(r.buffered())) |head| {
            break head;
        } else |err| switch (err) {
            error.CgiHeadInvalid => return fail("parsing CGI head", err),
            error.CgiHeadIncomplete => {
                if (r.bufferedLen() >= git_http.max_cgi_head_len) return fail("CGI head too long", err);
                r.fillMore() catch |fill_err| return fail("reading CGI head", fill_err);
            },
        }
    };

    response.* = request.respondStreaming(send_buf, .{
        .respond_options = .{
            .status = head.status,
            .keep_alive = http_util.keepAlive(request),
            .extra_headers = head.forwarded(),
        },
    }) catch return error.ResponseBroken;
    // `head` borrows the reader's buffer; it is not used after this point.
    r.toss(head.body_start);
    _ = r.streamRemaining(&response.writer) catch return error.ResponseBroken;
    return head.status;
}

/// Stops the CGI and everything it started. Does nothing after `wait`.
fn killGroup(io: Io, child: *std.process.Child) void {
    const pid = child.id orelse return;
    // Close our end first, so a child blocked writing to the pipe wakes up.
    if (child.stdout) |f| {
        f.close(io);
        child.stdout = null;
    }
    // ESRCH just means the group already exited.
    std.posix.kill(-pid, .KILL) catch {};
    child.kill(io);
}

/// Creates a temp file only the owner can read, and unlinks it at once:
/// the returned handle keeps the data, and nothing is left behind if the
/// request fails or gitd stops.
fn createUnlinked(io: Io, store: *const store_mod.Store, kind: []const u8) ProxyError!Io.File {
    var path_buf: [store_mod.Store.max_path_len]u8 = undefined;
    const path = try tempPath(io, store, &path_buf, kind);
    const cwd = Io.Dir.cwd();
    const file = cwd.createFile(io, path, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) }) catch |err|
        return fail("creating temp file", err);
    cwd.deleteFile(io, path) catch |err| {
        file.close(io);
        return fail("unlinking temp file", err);
    };
    return file;
}

/// Writes the request body to `file` and leaves its offset at 0, ready to
/// be the child's stdin.
fn spoolBody(io: Io, request: *std.http.Server.Request, file: Io.File) ProxyError!u64 {
    var write_buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    var read_buf: [64 * 1024]u8 = undefined;
    const body = request.readerExpectContinue(&read_buf) catch |err| return fail("reading body", err);
    var total: u64 = 0;
    while (true) {
        const n = body.stream(&writer.interface, .limited(read_buf.len)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ClientGone,
            error.WriteFailed => return fail("spooling body", err),
        };
        total += n;
        if (total > max_body_bytes) return error.BodyTooLarge;
    }
    // A connection that closes mid-body also ends the stream. Only a body
    // read to its declared end leaves the server ready for the next request,
    // so anything else is a cut-off upload that git must never see.
    if (request.server.reader.state != .ready) return error.ClientGone;
    writer.interface.flush() catch |err| return fail("writing body", err);
    // Positional writes leave the offset alone; a streaming fallback moves
    // it. Either way the child must start reading at 0.
    writer.seekTo(0) catch |err| return fail("rewinding body", err);
    return total;
}

fn tempPath(io: Io, store: *const store_mod.Store, buf: *[store_mod.Store.max_path_len]u8, kind: []const u8) ProxyError![]const u8 {
    var random: [8]u8 = undefined;
    io.random(&random);
    return std.mem.print(buf, "{s}/{x}.{s}", .{ store.tmp, random, kind }) catch error.ProxyFailed;
}

fn logStderr(io: Io, err_file: Io.File, status: std.http.Status, code: ?u8) void {
    var buf: [max_stderr_logged]u8 = undefined;
    const n = err_file.readPositionalAll(io, &buf, 0) catch 0;
    const text = std.mem.trimEnd(u8, buf[0..n], "\n");
    if (code) |c| {
        std.log.warn("git http-backend sent {d} and exited {d}: {f}", .{ @backingInt(status), c, std.zig.fmtString(text) });
    } else {
        std.log.warn("git http-backend sent {d} and did not exit normally: {f}", .{ @backingInt(status), std.zig.fmtString(text) });
    }
}

fn fail(what: []const u8, err: anyerror) ProxyError {
    if (err == error.Canceled) return error.Canceled;
    std.log.err("git proxy {s}: {t}", .{ what, err });
    return error.ProxyFailed;
}
