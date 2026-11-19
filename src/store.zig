//! Repo storage on local disk (R1.2).
//!
//! Each repo is a bare git repo at `<root>/<ns>/<repo>.git`. Callers go
//! through `Store` so disk can later be swapped for object storage.
//! `git http-backend` still needs a real directory, so `repoPath` is part
//! of the interface for now.
//!
//! Every `git` that gitd runs gets an environment from `gitEnv`, which
//! turns off hooks and every config source except our own (R2.4).

const std = @import("std");
const Io = std.Io;
const repo_name = @import("repo_name.zig");

/// The data directory: `repos/`, `tmp/`, `gitd.db`, and `secret`. Paths
/// are absolute.
pub const DataDir = struct {
    root: []const u8,
    repos: []const u8,
    tmp: []const u8,
    db: [:0]const u8,
    secret: []const u8,

    /// Creates the layout if missing. Strings are allocated in `arena`.
    pub fn prepare(io: Io, arena: std.mem.Allocator, data_dir: []const u8) !DataDir {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, data_dir);
        const root = try cwd.realPathFileAlloc(io, data_dir, arena);
        const d: DataDir = .{
            .root = root,
            .repos = try arena.print("{s}/repos", .{root}),
            .tmp = try arena.print("{s}/tmp", .{root}),
            .db = try arena.dupeSentinel(u8, try arena.print("{s}/gitd.db", .{root}), 0),
            .secret = try arena.print("{s}/secret", .{root}),
        };
        try cwd.createDirPath(io, d.repos);
        try cwd.createDirPath(io, d.tmp);
        return d;
    }

    /// Anything left in tmp is from a stopped server and safe to drop.
    /// Only `serve` calls this, so `admin` commands cannot pull files out
    /// from under a running server.
    pub fn clearTmp(d: DataDir, io: Io) !void {
        const cwd = Io.Dir.cwd();
        try cwd.deleteTree(io, d.tmp);
        try cwd.createDirPath(io, d.tmp);
    }
};

pub const Store = struct {
    /// Absolute path of the repos directory.
    root: []const u8,
    /// Absolute path of a scratch directory on the same filesystem as
    /// `root`, so a finished repo can be renamed into place.
    tmp: []const u8,
    /// The `PATH` gitd was started with, used to find `git`.
    path_env: []const u8,

    pub const max_path_len = std.Io.Dir.max_path_bytes;

    /// Writes `<root>/<ns>/<repo>.git` into `buf`.
    pub fn repoPath(s: *const Store, buf: *[max_path_len]u8, name: repo_name.Name) error{NameTooLong}![]const u8 {
        return std.mem.print(buf, "{s}/{s}/{s}.git", .{ s.root, name.namespace, name.repo }) catch error.NameTooLong;
    }

    pub const CreateError = error{ GitFailed, NameTooLong, StorageError } || Io.Cancelable || std.mem.Allocator.Error;

    /// Creates an empty bare repo. Any leftover directory at the target is
    /// removed first; the caller guarantees no live repo has this name.
    /// The repo is built in `tmp` and renamed into place, so a crash never
    /// leaves a half-made repo at the real path.
    pub fn create(s: *const Store, io: Io, gpa: std.mem.Allocator, name: repo_name.Name) CreateError!void {
        var final_buf: [max_path_len]u8 = undefined;
        const final_path = try s.repoPath(&final_buf, name);

        var random: [8]u8 = undefined;
        io.random(&random);
        var tmp_buf: [max_path_len]u8 = undefined;
        const tmp_path = std.mem.print(&tmp_buf, "{s}/{x}.git", .{ s.tmp, random }) catch return error.NameTooLong;
        errdefer Io.Dir.cwd().deleteTree(io, tmp_path) catch |err| {
            std.log.err("removing {s}: {t}", .{ tmp_path, err });
        };

        var env = try gitEnv(gpa, s.path_env);
        defer env.deinit();
        const result = std.process.run(gpa, io, .{
            .argv = &.{ "git", "init", "--bare", "--quiet", "--initial-branch=main", tmp_path },
            .environ_map = &env,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.err("git init: {t}", .{err});
                return error.GitFailed;
            },
        };
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.log.err("git init exited {d}: {s}", .{ code, result.stderr });
                return error.GitFailed;
            },
            .signal, .stopped, .unknown => {
                std.log.err("git init did not exit normally", .{});
                return error.GitFailed;
            },
        }

        const cwd = Io.Dir.cwd();
        cwd.deleteTree(io, final_path) catch |err| return storageError("clearing", final_path, err);
        const parent = std.Io.Dir.path.dirname(final_path) orelse return error.StorageError;
        cwd.createDirPath(io, parent) catch |err| return storageError("creating", parent, err);
        cwd.rename(tmp_path, cwd, final_path, io) catch |err| return storageError("moving into", final_path, err);
    }

    pub const DeleteError = error{ NameTooLong, StorageError } || Io.Cancelable;

    pub fn delete(s: *const Store, io: Io, name: repo_name.Name) DeleteError!void {
        var buf: [max_path_len]u8 = undefined;
        const path = try s.repoPath(&buf, name);
        Io.Dir.cwd().deleteTree(io, path) catch |err| return storageError("deleting", path, err);
    }
};

fn storageError(what: []const u8, path: []const u8, err: anyerror) error{ StorageError, Canceled } {
    if (err == error.Canceled) return error.Canceled;
    std.log.err("{s} {s}: {t}", .{ what, path, err });
    return error.StorageError;
}

/// Config that gitd forces on every git process. Command-line config, which
/// these become, outranks anything in a repo's own config.
const forced_config = [_][2][]const u8{
    // No hooks run, whatever a repo's config or hooks directory says (R2.4).
    .{ "core.hooksPath", "/dev/null" },
    // Pushes are checked for malformed objects before refs move (R2.3).
    .{ "receive.fsckObjects", "true" },
    // gitd checks auth itself; git must not ask for REMOTE_USER.
    .{ "http.receivepack", "true" },
    .{ "http.uploadpack", "true" },
    .{ "http.getanyfile", "false" },
    // A repo's config must not name a program for git to run (R2.4).
    .{ "core.fsmonitor", "false" },
};

/// A minimal environment for running `git`: our `PATH`, no system or
/// global config, no prompts, and `forced_config`. The caller owns it.
pub fn gitEnv(gpa: std.mem.Allocator, path_env: []const u8) std.mem.Allocator.Error!std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(gpa);
    errdefer env.deinit();
    try env.put("PATH", path_env);
    try env.put("HOME", "/nonexistent");
    try env.put("LANG", "C");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_TERMINAL_PROMPT", "0");

    var count_buf: [8]u8 = undefined;
    try env.put("GIT_CONFIG_COUNT", std.mem.print(&count_buf, "{d}", .{forced_config.len}) catch unreachable);
    for (forced_config, 0..) |kv, i| {
        var key_buf: [32]u8 = undefined;
        var value_buf: [32]u8 = undefined;
        // `i` is below forced_config.len, so these always fit.
        try env.put(std.mem.print(&key_buf, "GIT_CONFIG_KEY_{d}", .{i}) catch unreachable, kv[0]);
        try env.put(std.mem.print(&value_buf, "GIT_CONFIG_VALUE_{d}", .{i}) catch unreachable, kv[1]);
    }
    return env;
}

test "gitEnv sets the forced config and nothing from the parent" {
    var env = try gitEnv(std.testing.allocator, "/usr/bin");
    defer env.deinit();
    try std.testing.expectEqualStrings("/usr/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("core.hooksPath", env.get("GIT_CONFIG_KEY_0").?);
    try std.testing.expectEqualStrings("/dev/null", env.get("GIT_CONFIG_VALUE_0").?);
    try std.testing.expectEqual(null, env.get("GIT_DIR"));
}

test "repoPath joins root and name" {
    const s: Store = .{ .root = "/data/repos", .tmp = "/data/tmp", .path_env = "" };
    var buf: [Store.max_path_len]u8 = undefined;
    const name = try repo_name.parse("acme/web");
    try std.testing.expectEqualStrings("/data/repos/acme/web.git", try s.repoPath(&buf, name));
}
