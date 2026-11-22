const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const Db = @import("db.zig").Db;
const store = @import("store.zig");
const server = @import("server.zig");
const git2 = @import("git2.zig");

const usage =
    \\usage:
    \\  gitd serve [--data DIR] [--listen HOST:PORT] [--ui]
    \\  gitd admin create-key [--data DIR]
    \\  gitd admin add-key [--data DIR]    (reads a key made by create-key from stdin)
    \\
    \\  --data    data directory (env GITD_DATA, default ./data)
    \\  --listen  address to listen on (env GITD_LISTEN, default 127.0.0.1:8080)
    \\  --ui      serve the read-only activity page at /ui (to this machine only)
    \\
    \\  env GITD_IDLE_TIMEOUT_SECONDS: drop a connection idle this long (default 60)
    \\  env GITD_HEAD_TIMEOUT_SECONDS: time allowed to send a request head (default 10)
    \\  env GITD_WEBHOOK_BACKOFF_MS: webhook retry backoff unit (default 1000)
    \\  env GITD_WEBHOOK_TIMEOUT_MS: webhook delivery timeout (default 10000)
    \\  env GITD_DEFAULT_MAX_BRANCHES: default per-repo branch quota, 0 = unlimited
    \\  env GITD_DEFAULT_MAX_REPO_BYTES: default per-repo byte quota, 0 = unlimited
    \\  env GITD_GC_INTERVAL_SECONDS: background GC check interval, 0 = off (default 300)
    \\  env GITD_GC_PRUNE_SECONDS: unreferenced object grace period (default 300)
    \\  env GITD_GC_EXPIRED_THRESHOLD: expired branches before auto GC (default 20)
    \\  env GITD_SSE_KEEPALIVE_MS: SSE keepalive comment interval in ms (default 15000)
    \\  env GITD_SSE_MAX_SECONDS: max lifetime of one SSE stream in s (default 300)
    \\
;

const Options = struct {
    data_dir: []const u8,
    listen: []const u8,
    ui: bool = false,
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
        if (std.mem.eql(u8, flag, "--ui")) {
            opts.ui = true;
            continue;
        }
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
    if (std.mem.eql(u8, command, "admin") and std.mem.eql(u8, sub.?, "add-key")) return addKey(init, opts);
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

fn secondsFromEnv(init: std.process.Init, name: []const u8, default: u32) ?u32 {
    const text = init.environ_map.get(name) orelse return default;
    const seconds = std.fmt.parseInt(u32, text, 10) catch 0;
    if (seconds == 0 or seconds > 3600) {
        std.log.err("{s} must be between 1 and 3600", .{name});
        return null;
    }
    return seconds;
}

fn msFromEnv(init: std.process.Init, name: []const u8, default: i64) ?i64 {
    const text = init.environ_map.get(name) orelse return default;
    const ms = std.fmt.parseInt(i64, text, 10) catch 0;
    if (ms < 1 or ms > 600_000) {
        std.log.err("{s} must be between 1 and 600000", .{name});
        return null;
    }
    return ms;
}

fn boundedU64FromEnv(init: std.process.Init, name: []const u8, default: u64, max: u64) ?u64 {
    const text = init.environ_map.get(name) orelse return default;
    const val = std.fmt.parseInt(u64, text, 10) catch {
        std.log.err("{s} must be between 0 and {d}", .{ name, max });
        return null;
    };
    if (val > max) {
        std.log.err("{s} must be between 0 and {d}", .{ name, max });
        return null;
    }
    return val;
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

fn addKey(init: std.process.Init, opts: Options) !u8 {
    const io = init.io;
    var buf: [256]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &buf);
    var text: [auth.key_len + 2]u8 = undefined;
    const n = try stdin.interface.readSliceShort(&text);
    const key = std.mem.trimEnd(u8, text[0..n], "\r\n");
    if (!auth.isKey(key)) {
        std.log.err("stdin is not an admin key: expected {s} and 64 lowercase hex digits", .{auth.key_prefix});
        return 2;
    }
    const data = try store.DataDir.prepare(io, init.arena.allocator(), opts.data_dir);
    var db: Db = try .open(data.db);
    defer db.close();
    const hash = auth.hashKey(key);
    if (try db.apiKeyExists(io, &hash)) {
        std.log.info("admin key already present", .{});
        return 0;
    }
    try db.insertApiKey(io, &hash, server.unixNow(io));
    std.log.info("admin key added", .{});
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

    const idle_timeout = secondsFromEnv(init, "GITD_IDLE_TIMEOUT_SECONDS", server.default_idle_timeout_seconds) orelse return 2;
    const head_timeout = secondsFromEnv(init, "GITD_HEAD_TIMEOUT_SECONDS", server.default_head_timeout_seconds) orelse return 2;
    const backoff_ms = msFromEnv(init, "GITD_WEBHOOK_BACKOFF_MS", 1000) orelse return 2;
    const hook_timeout_ms = msFromEnv(init, "GITD_WEBHOOK_TIMEOUT_MS", 10_000) orelse return 2;
    const default_max_branches = boundedU64FromEnv(init, "GITD_DEFAULT_MAX_BRANCHES", 0, 1_000_000) orelse return 2;
    const default_max_repo_bytes = boundedU64FromEnv(init, "GITD_DEFAULT_MAX_REPO_BYTES", 0, 1024 * 1024 * 1024 * 1024) orelse return 2;
    const gc_interval_seconds: u32 = @intCast(boundedU64FromEnv(init, "GITD_GC_INTERVAL_SECONDS", 300, 86_400) orelse return 2);
    const gc_prune_seconds: u32 = @intCast(boundedU64FromEnv(init, "GITD_GC_PRUNE_SECONDS", 300, 604_800) orelse return 2);
    const gc_expired_threshold: u32 = @intCast(boundedU64FromEnv(init, "GITD_GC_EXPIRED_THRESHOLD", 20, 100_000) orelse return 2);
    const sse_keepalive_raw = msFromEnv(init, "GITD_SSE_KEEPALIVE_MS", 15_000) orelse return 2;
    if (sse_keepalive_raw < 50 or sse_keepalive_raw > 60_000) {
        std.log.err("GITD_SSE_KEEPALIVE_MS must be between 50 and 60000", .{});
        return 2;
    }
    const sse_keepalive_ms: u32 = @intCast(sse_keepalive_raw);
    const sse_max_seconds: u32 = secondsFromEnv(init, "GITD_SSE_MAX_SECONDS", 300) orelse return 2;

    const data = try store.DataDir.prepare(io, arena, opts.data_dir);
    try data.clearTmp(io);
    git2.init() catch |err| {
        std.log.err("initializing libgit2: {t}", .{err});
        return 1;
    };
    defer git2.deinit();
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
        .head_timeout_seconds = head_timeout,
        .ui_enabled = opts.ui,
        .webhook_backoff_ms = backoff_ms,
        .webhook_timeout_ms = hook_timeout_ms,
        .default_max_branches = default_max_branches,
        .default_max_repo_bytes = default_max_repo_bytes,
        .gc_interval_seconds = gc_interval_seconds,
        .gc_prune_seconds = gc_prune_seconds,
        .gc_expired_threshold = gc_expired_threshold,
        .sse_keepalive_ms = sse_keepalive_ms,
        .sse_max_seconds = sse_max_seconds,
    };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.log.info("listening on {f}, data in {s}", .{ listener.socket.address, data.root });
    if (opts.ui) std.log.info("activity page at http://{f}/ui", .{listener.socket.address});

    var accept_loop = try io.concurrent(server.run, .{ &app, &listener });

    var signal: c_int = 0;
    if (std.c.sigwait(&stop_signals, &signal) != 0) {
        std.log.err("sigwait failed", .{});
    }
    std.log.info("stopping (signal {d})", .{signal});
    defer app.maint.deinit(init.gpa);
    defer app.event_hub.deinit(init.gpa);
    defer app.peers.deinit(init.gpa);
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
    _ = @import("server.zig");
    _ = @import("timed_stream.zig");
    _ = @import("http_util.zig");
    _ = @import("git_cmd.zig");
    _ = @import("git2.zig");
    _ = @import("ref_name.zig");
    _ = @import("pktline.zig");
    _ = @import("receive_pack.zig");
    _ = @import("upload_pack.zig");
    _ = @import("repo_git.zig");
    _ = @import("events.zig");
    _ = @import("ui.zig");
    _ = @import("api.zig");
    _ = @import("repo_path.zig");
    _ = @import("content.zig");
    _ = @import("expiry.zig");
    _ = @import("webhooks.zig");
    _ = @import("sync.zig");
    _ = @import("rules.zig");
    _ = @import("merge_check.zig");
    _ = @import("maintenance.zig");
    _ = @import("checks.zig");
    _ = @import("patch.zig");
}
