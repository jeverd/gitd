//! Read and write operations on one repo, built on git plumbing commands.
//!
//! Every git call goes through `git_cmd`, so the safety rules there apply.
//! Inputs (ref names, paths, oids) are validated by the caller before they
//! reach here; this module only passes them after `--` or as `refs/...`
//! arguments, never as options.

const std = @import("std");
const Io = std.Io;
const git_cmd = @import("git_cmd.zig");
const store_mod = @import("store.zig");
const repo_name = @import("repo_name.zig");

pub const Repo = struct {
    io: Io,
    gpa: std.mem.Allocator,
    store: *const store_mod.Store,
    path_buf: [store_mod.Store.max_path_len]u8 = undefined,
    path_len: usize = 0,

    pub fn open(io: Io, gpa: std.mem.Allocator, store: *const store_mod.Store, name: repo_name.Name) error{NameTooLong}!Repo {
        var r: Repo = .{ .io = io, .gpa = gpa, .store = store };
        const p = try store.repoPath(&r.path_buf, name);
        r.path_len = p.len;
        return r;
    }

    pub fn path(r: *const Repo) []const u8 {
        return r.path_buf[0..r.path_len];
    }

    pub fn git(r: *const Repo, args: []const []const u8, options: git_cmd.Options) git_cmd.Error!git_cmd.Result {
        return git_cmd.run(r.io, r.gpa, r.store, r.path(), args, options);
    }

    pub fn gitOutput(r: *const Repo, args: []const []const u8, options: git_cmd.Options) git_cmd.Error![]u8 {
        return git_cmd.output(r.io, r.gpa, r.store, r.path(), args, options);
    }

    pub const Branch = struct {
        /// Without `refs/heads/`. All slices borrow `Branches.raw`.
        name: []const u8,
        commit: []const u8,
        committed_at: i64,
        subject: []const u8,
    };

    pub const Branches = struct {
        raw: []u8,
        items: []Branch,

        pub fn deinit(b: Branches, gpa: std.mem.Allocator) void {
            gpa.free(b.items);
            gpa.free(b.raw);
        }
    };

    /// Every branch, ordered by name.
    pub fn listBranches(r: *const Repo) git_cmd.Error!Branches {
        const raw = try r.gitOutput(&.{
            "for-each-ref", "--format=%(refname:strip=2)%00%(objectname)%00%(committerdate:unix)%00%(subject)", "refs/heads/",
        }, .{});
        errdefer r.gpa.free(raw);
        var list: std.ArrayList(Branch) = .empty;
        errdefer list.deinit(r.gpa);
        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, 0);
            const name = fields.next() orelse continue;
            const commit = fields.next() orelse continue;
            const when = fields.next() orelse continue;
            const subject = fields.rest();
            try list.append(r.gpa, .{
                .name = name,
                .commit = commit,
                .committed_at = std.fmt.parseInt(i64, when, 10) catch 0,
                .subject = subject,
            });
        }
        return .{ .raw = raw, .items = try list.toOwnedSlice(r.gpa) };
    }

    /// The commit a full ref name points at, or null if it does not exist.
    /// Writes the oid into `out`.
    pub fn refValue(r: *const Repo, ref: []const u8, out: *[64]u8) git_cmd.Error!?[]const u8 {
        const result = try r.git(&.{ "rev-parse", "--verify", "--quiet", "--end-of-options", ref }, .{});
        defer result.deinit(r.gpa);
        if (result.code != 0) return null;
        const oid = std.mem.trimEnd(u8, result.stdout, "\n");
        if (oid.len > out.len) return error.GitFailed;
        @memcpy(out[0..oid.len], oid);
        return out[0..oid.len];
    }
};
