//! Runs one git plumbing command against a repo and captures its output.
//!
//! Every command gets `store.gitEnv` (no hooks, no outside config, R2.4),
//! an explicit GIT_DIR, its own process group (killed if gitd gives up
//! early), bounded stdout and stderr, and an optional stdin from an unlinked
//! temp file. Output is read from both pipes together, so a chatty stderr
//! cannot block a large stdout or the other way round.

const std = @import("std");
const Io = std.Io;
const store_mod = @import("store.zig");

pub const default_max_output = 16 * 1024 * 1024;
const max_stderr = 64 * 1024;

pub const Options = struct {
    /// Bytes written to the command's stdin. Empty means no stdin.
    stdin: []const u8 = "",
    /// Extra environment, such as GIT_INDEX_FILE or author identity.
    env: []const [2][]const u8 = &.{},
    max_output: usize = default_max_output,
};

pub const Result = struct {
    /// Exit code; 0 is success. Callers decide what other codes mean.
    code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(r: Result, gpa: std.mem.Allocator) void {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
};

pub const Error = error{ GitFailed, OutputTooLarge } || Io.Cancelable || std.mem.Allocator.Error;

/// Runs `git <args>` with GIT_DIR set to `git_dir`. The caller owns the
/// result. Returns error.GitFailed only when git could not be run or was
/// killed; a non-zero exit is returned in `Result.code`.
pub fn run(
    io: Io,
    gpa: std.mem.Allocator,
    store: *const store_mod.Store,
    git_dir: []const u8,
    args: []const []const u8,
    options: Options,
) Error!Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);

    var env = try store_mod.gitEnv(gpa, store.path_env);
    defer env.deinit();
    try env.put("GIT_DIR", git_dir);
    // Paths are literal: no `:(glob)` or other pathspec magic from callers.
    try env.put("GIT_LITERAL_PATHSPECS", "1");
    for (options.env) |kv| try env.put(kv[0], kv[1]);

    var stdin_file: ?Io.File = null;
    defer if (stdin_file) |f| f.close(io);
    if (options.stdin.len > 0) {
        const f = try createUnlinked(io, store);
        stdin_file = f;
        f.writePositionalAll(io, options.stdin, 0) catch |err| return fail("writing stdin", err);
    }

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = &env,
        .stdin = if (stdin_file) |f| .{ .file = f } else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| return fail("spawning git", err);
    defer killGroup(io, &child);

    var mr_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(4096, .none)) |_| {
        if (mr.reader(0).buffered().len > options.max_output) return error.OutputTooLarge;
        if (mr.reader(1).buffered().len > max_stderr) return error.OutputTooLarge;
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Canceled => return error.Canceled,
        else => return fail("reading git output", err),
    }
    mr.checkAnyError() catch |err| return fail("reading git output", err);

    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return fail("waiting for git", err),
    };
    const code: u8 = switch (term) {
        .exited => |c| c,
        .signal, .stopped, .unknown => return fail("git did not exit normally", error.GitKilled),
    };
    const stdout = try mr.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    const stderr = try mr.toOwnedSlice(1);
    return .{ .code = code, .stdout = stdout, .stderr = stderr };
}

/// Like `run`, but a non-zero exit is an error (logged with git's stderr).
/// Returns stdout, owned by the caller.
pub fn output(
    io: Io,
    gpa: std.mem.Allocator,
    store: *const store_mod.Store,
    git_dir: []const u8,
    args: []const []const u8,
    options: Options,
) Error![]u8 {
    const result = try run(io, gpa, store, git_dir, args, options);
    if (result.code != 0) {
        std.log.err("git {s} exited {d}: {s}", .{ args[0], result.code, std.mem.trimEnd(u8, result.stderr, "\n") });
        result.deinit(gpa);
        return error.GitFailed;
    }
    gpa.free(result.stderr);
    return result.stdout;
}

fn killGroup(io: Io, child: *std.process.Child) void {
    const pid = child.id orelse return;
    // ESRCH just means the group already exited.
    std.posix.kill(-pid, .KILL) catch {};
    child.kill(io);
}

fn createUnlinked(io: Io, store: *const store_mod.Store) Error!Io.File {
    var random: [8]u8 = undefined;
    io.random(&random);
    var buf: [store_mod.Store.max_path_len]u8 = undefined;
    const path = std.mem.print(&buf, "{s}/{x}.stdin", .{ store.tmp, random }) catch return error.GitFailed;
    const cwd = Io.Dir.cwd();
    const file = cwd.createFile(io, path, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) }) catch |err|
        return fail("creating stdin file", err);
    cwd.deleteFile(io, path) catch |err| {
        file.close(io);
        return fail("unlinking stdin file", err);
    };
    return file;
}

fn fail(what: []const u8, err: anyerror) Error {
    if (err == error.Canceled) return error.Canceled;
    std.log.err("git command {s}: {t}", .{ what, err });
    return error.GitFailed;
}
