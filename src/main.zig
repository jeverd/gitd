//! gitd entry point. Wires modules together; no feature logic (R1.1).

const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const Db = @import("db.zig").Db;
const store = @import("store.zig");
const server = @import("server.zig");

const usage =
    \\usage:
    \\  gitd serve [--data DIR] [--listen HOST:PORT]
    \\  gitd admin create-key [--data DIR]
    \\
    \\  --data    data directory (env GITD_DATA, default ./data)
    \\  --listen  address to listen on (env GITD_LISTEN, default 127.0.0.1:8080)
    \\
    \\  env GITD_IDLE_TIMEOUT_SECONDS: drop a connection idle this long (default 60)
    \\
;

const Options = struct {
    data_dir: []const u8,
    listen: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return usageError();

    var opts: Options = .{
        .data_dir = init.environ_map.get("GITD_DATA") orelse "data",
        .listen = init.environ_map.get("GITD_LISTEN") orelse "127.0.0.1:8080",
    };
    const command = args[1];
    var rest = args[2..];
    var sub: ?[]const u8 = null;
    if (std.mem.eql(u8, command, "admin")) {
        if (rest.len == 0) return usageError();
        sub = rest[0];
        rest = rest[1..];
    }
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const flag = rest[i];
        if (i + 1 >= rest.len) return usageError();
        if (std.mem.eql(u8, flag, "--data")) {
            opts.data_dir = rest[i + 1];
        } else if (std.mem.eql(u8, flag, "--listen")) {
            opts.listen = rest[i + 1];
        } else return usageError();
        i += 1;
    }

    if (std.mem.eql(u8, command, "serve")) return serve(init, opts);
    if (std.mem.eql(u8, command, "admin") and std.mem.eql(u8, sub.?, "create-key")) return createKey(init, opts);
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }
    return usageError();
}

fn usageError() u8 {
    std.debug.print("{s}", .{usage});
    return 2;
}

fn createKey(init: std.process.Init, opts: Options) !u8 {
    const io = init.io;
    const data = try store.DataDir.prepare(io, init.arena.allocator(), opts.data_dir);
    var db: Db = try .open(data.db);
    defer db.close();

    var random: [32]u8 = undefined;
    try io.randomSecure(&random);
    const key = auth.formatKey(&random);
    const hash = auth.hashKey(&key);
    try db.insertApiKey(io, &hash, server.unixNow(io));

    var buf: [128]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    try stdout.interface.print("{s}\n", .{key});
    try stdout.interface.flush();
    return 0;
}

fn serve(init: std.process.Init, opts: Options) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    // Block the stop signals before any other thread starts, so they are
    // only ever taken by `sigwait` below and shutdown runs normally.
    var stop_signals = std.posix.sigemptyset();
    std.posix.sigaddset(&stop_signals, .INT);
    std.posix.sigaddset(&stop_signals, .TERM);
    // A shell starts background jobs with SIGINT ignored, and an ignored
    // signal is dropped even while blocked. Restore the defaults first.
    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &default_action, null);
    std.posix.sigaction(.TERM, &default_action, null);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &stop_signals, null);

    const address = Io.net.IpAddress.parseLiteral(opts.listen) catch {
        std.log.err("--listen must be HOST:PORT with a numeric host, got {s}", .{opts.listen});
        return 2;
    };

    const idle_timeout = if (init.environ_map.get("GITD_IDLE_TIMEOUT_SECONDS")) |text|
        std.fmt.parseInt(u32, text, 10) catch {
            std.log.err("GITD_IDLE_TIMEOUT_SECONDS must be a whole number of seconds", .{});
            return 2;
        }
    else
        server.default_idle_timeout_seconds;

    const data = try store.DataDir.prepare(io, arena, opts.data_dir);
    try data.clearTmp(io);
    const secret = try auth.loadSecret(io, data.secret);
    var db: Db = try .open(data.db);
    defer db.close();
    const repo_store: store.Store = .{
        .root = data.repos,
        .tmp = data.tmp,
        .path_env = init.environ_map.get("PATH") orelse "/usr/bin:/bin",
    };

    var app: server.App = .{
        .io = io,
        .gpa = init.gpa,
        .db = &db,
        .store = &repo_store,
        .secret = &secret,
        .idle_timeout_seconds = idle_timeout,
    };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("listening on {f}, data in {s}", .{ listener.socket.address, data.root });

    var accept_loop = try io.concurrent(server.run, .{ &app, &listener });

    var signal: c_int = 0;
    if (std.c.sigwait(&stop_signals, &signal) != 0) {
        std.log.err("sigwait failed", .{});
    }
    std.log.info("stopping (signal {d})", .{signal});
    // The loop only ends by cancellation, so its result is always
    // error.Canceled and carries nothing to report.
    accept_loop.cancel(io) catch {};
    return 0;
}

test {
    _ = @import("repo_name.zig");
    _ = @import("auth.zig");
    _ = @import("db.zig");
    _ = @import("git_http.zig");
    _ = @import("store.zig");
    _ = @import("git_proxy.zig");
    _ = @import("server.zig");
    _ = @import("timed_reader.zig");
}
