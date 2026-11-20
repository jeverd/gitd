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

    pub fn gitDir(r: *const Repo) []const u8 {
        return r.path_buf[0..r.path_len];
    }

    pub fn git(r: *const Repo, args: []const []const u8, options: git_cmd.Options) git_cmd.Error!git_cmd.Result {
        return git_cmd.run(r.io, r.gpa, r.store, r.gitDir(), args, options);
    }

    pub fn gitOutput(r: *const Repo, args: []const []const u8, options: git_cmd.Options) git_cmd.Error![]u8 {
        return git_cmd.output(r.io, r.gpa, r.store, r.gitDir(), args, options);
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

    /// Resolves `rev` (a full ref name or an oid) to a commit oid written
    /// into `out`, or null if it names no commit.
    pub fn resolveCommit(r: *const Repo, rev: []const u8, out: *[64]u8) git_cmd.Error!?[]const u8 {
        var arg_buf: [300]u8 = undefined;
        const arg = std.mem.print(&arg_buf, "{s}^{{commit}}", .{rev}) catch return null;
        const result = try r.git(&.{ "rev-parse", "--verify", "--quiet", "--end-of-options", arg }, .{});
        defer result.deinit(r.gpa);
        if (result.code != 0) return null;
        const oid = std.mem.trimEnd(u8, result.stdout, "\n");
        if (oid.len > out.len) return error.GitFailed;
        @memcpy(out[0..oid.len], oid);
        return out[0..oid.len];
    }

    pub const EntryKind = enum { blob, tree, commit };

    pub const Entry = struct {
        /// Slices borrow `Entries.raw`.
        mode: []const u8,
        kind: EntryKind,
        oid: []const u8,
        /// Null for trees and submodules.
        size: ?u64,
        path: []const u8,
    };

    pub const Entries = struct {
        raw: []u8,
        items: []Entry,

        pub fn deinit(e: Entries, gpa: std.mem.Allocator) void {
            gpa.free(e.items);
            gpa.free(e.raw);
        }
    };

    /// Lists `dir` (null for the root) at `commit`, or with `exact`, the
    /// single entry at `dir` itself.
    pub fn lsTree(r: *const Repo, commit: []const u8, dir: ?[]const u8, exact: bool) git_cmd.Error!Entries {
        var path_buf: [4100]u8 = undefined;
        var args: [6][]const u8 = .{ "ls-tree", "-z", "-l", "--end-of-options", commit, "" };
        var argc: usize = 5;
        var with_path: [8][]const u8 = undefined;
        if (dir) |d| {
            const p = if (exact) d else (std.mem.print(&path_buf, "{s}/", .{d}) catch return error.GitFailed);
            @memcpy(with_path[0..argc], args[0..argc]);
            with_path[argc] = "--";
            with_path[argc + 1] = p;
            argc += 2;
            return r.parseEntries(try r.gitOutput(with_path[0..argc], .{}));
        }
        return r.parseEntries(try r.gitOutput(args[0..argc], .{}));
    }

    fn parseEntries(r: *const Repo, raw: []u8) git_cmd.Error!Entries {
        errdefer r.gpa.free(raw);
        var list: std.ArrayList(Entry) = .empty;
        errdefer list.deinit(r.gpa);
        var records = std.mem.splitScalar(u8, raw, 0);
        while (records.next()) |rec| {
            if (rec.len == 0) continue;
            const tab = std.mem.findScalar(u8, rec, '\t') orelse continue;
            var meta = std.mem.tokenizeScalar(u8, rec[0..tab], ' ');
            const mode = meta.next() orelse continue;
            const kind_text = meta.next() orelse continue;
            const oid = meta.next() orelse continue;
            const size_text = meta.next() orelse "-";
            const kind = std.meta.stringToEnum(EntryKind, kind_text) orelse continue;
            try list.append(r.gpa, .{
                .mode = mode,
                .kind = kind,
                .oid = oid,
                .size = std.fmt.parseInt(u64, size_text, 10) catch null,
                .path = rec[tab + 1 ..],
            });
        }
        return .{ .raw = raw, .items = try list.toOwnedSlice(r.gpa) };
    }

    /// The contents of blob `oid`. Fails with error.OutputTooLarge past
    /// `max` bytes.
    pub fn readBlob(r: *const Repo, oid: []const u8, max: usize) git_cmd.Error![]u8 {
        return r.gitOutput(&.{ "cat-file", "blob", oid }, .{ .max_output = max });
    }

    pub const Commit = struct {
        /// Slices borrow `Log.raw`.
        sha: []const u8,
        parents: []const u8,
        author_name: []const u8,
        author_email: []const u8,
        time: i64,
        subject: []const u8,
        body: []const u8,
    };

    pub const Log = struct {
        raw: []u8,
        items: []Commit,

        pub fn deinit(l: Log, gpa: std.mem.Allocator) void {
            gpa.free(l.items);
            gpa.free(l.raw);
        }
    };

    /// Up to `limit` commits reachable from `commit`, newest first, touching
    /// `path` if given. With `single`, only `commit` itself.
    pub fn log(r: *const Repo, commit: []const u8, limit: u32, path: ?[]const u8, single: bool) git_cmd.Error!Log {
        var n_buf: [24]u8 = undefined;
        const n = std.mem.print(&n_buf, "-n{d}", .{if (single) 1 else limit}) catch unreachable;
        const format = "--format=%H%x00%P%x00%an%x00%ae%x00%ct%x00%s%x00%b%x1e";
        const raw = if (path) |p|
            try r.gitOutput(&.{ "log", format, n, "--no-walk=unsorted", "--end-of-options", commit, "--", p }, .{})
        else if (single)
            try r.gitOutput(&.{ "log", format, n, "--no-walk", "--end-of-options", commit }, .{})
        else
            try r.gitOutput(&.{ "log", format, n, "--end-of-options", commit }, .{});
        errdefer r.gpa.free(raw);
        var list: std.ArrayList(Commit) = .empty;
        errdefer list.deinit(r.gpa);
        var records = std.mem.splitScalar(u8, raw, 0x1e);
        while (records.next()) |rec_raw| {
            const rec = std.mem.trimStart(u8, rec_raw, "\n");
            if (rec.len == 0) continue;
            var f = std.mem.splitScalar(u8, rec, 0);
            const sha = f.next() orelse continue;
            const parents = f.next() orelse continue;
            const name = f.next() orelse continue;
            const email = f.next() orelse continue;
            const when = f.next() orelse continue;
            const subject = f.next() orelse continue;
            const body = std.mem.trimEnd(u8, f.rest(), "\n");
            try list.append(r.gpa, .{
                .sha = sha,
                .parents = parents,
                .author_name = name,
                .author_email = email,
                .time = std.fmt.parseInt(i64, when, 10) catch 0,
                .subject = subject,
                .body = body,
            });
        }
        return .{ .raw = raw, .items = try list.toOwnedSlice(r.gpa) };
    }

    pub const Change = struct {
        /// Validated repo path.
        path: []const u8,
        /// New contents, or null to delete the file.
        content: ?[]const u8,
    };

    pub const Author = struct { name: []const u8, email: []const u8 };

    /// Builds a commit from `parent` (null for a root commit) plus
    /// `changes`, and writes its oid into `out`. Does not move any ref.
    pub fn buildCommit(
        r: *const Repo,
        parent: ?[]const u8,
        changes: []const Change,
        message: []const u8,
        author: Author,
        out: *[64]u8,
    ) git_cmd.Error![]const u8 {
        // A private index, so concurrent commits never share one.
        var random: [8]u8 = undefined;
        r.io.random(&random);
        var index_buf: [store_mod.Store.max_path_len]u8 = undefined;
        const index_path = std.mem.print(&index_buf, "{s}/{x}.index", .{ r.store.tmp, random }) catch return error.GitFailed;
        defer Io.Dir.cwd().deleteFile(r.io, index_path) catch {}; // may never have been created
        const index_env = [_][2][]const u8{.{ "GIT_INDEX_FILE", index_path }};

        if (parent) |p| {
            r.gpa.free(try r.gitOutput(&.{ "read-tree", "--end-of-options", p }, .{ .env = &index_env }));
        } else {
            r.gpa.free(try r.gitOutput(&.{ "read-tree", "--empty" }, .{ .env = &index_env }));
        }

        var info: std.ArrayList(u8) = .empty;
        defer info.deinit(r.gpa);
        for (changes) |change| {
            if (change.content) |data| {
                const oid_raw = try r.gitOutput(&.{ "hash-object", "-w", "--stdin" }, .{ .stdin = data });
                defer r.gpa.free(oid_raw);
                const oid = std.mem.trimEnd(u8, oid_raw, "\n");
                try info.print(r.gpa, "100644 {s}\t{s}\n", .{ oid, change.path });
            } else {
                // Mode 0 removes the path from the index.
                try info.print(r.gpa, "0 0000000000000000000000000000000000000000\t{s}\n", .{change.path});
            }
        }
        if (info.items.len > 0) {
            r.gpa.free(try r.gitOutput(&.{ "update-index", "--index-info" }, .{ .env = &index_env, .stdin = info.items }));
        }
        const tree_raw = try r.gitOutput(&.{"write-tree"}, .{ .env = &index_env });
        defer r.gpa.free(tree_raw);
        const tree = std.mem.trimEnd(u8, tree_raw, "\n");

        const ident_env = [_][2][]const u8{
            .{ "GIT_AUTHOR_NAME", author.name },
            .{ "GIT_AUTHOR_EMAIL", author.email },
            .{ "GIT_COMMITTER_NAME", "gitd" },
            .{ "GIT_COMMITTER_EMAIL", "gitd@localhost" },
        };
        const commit_raw = if (parent) |p|
            try r.gitOutput(&.{ "commit-tree", tree, "-p", p, "-F", "-" }, .{ .env = &ident_env, .stdin = message })
        else
            try r.gitOutput(&.{ "commit-tree", tree, "-F", "-" }, .{ .env = &ident_env, .stdin = message });
        defer r.gpa.free(commit_raw);
        const sha = std.mem.trimEnd(u8, commit_raw, "\n");
        if (sha.len > out.len) return error.GitFailed;
        @memcpy(out[0..sha.len], sha);
        return out[0..sha.len];
    }

    pub const RefUpdate = enum { updated, stale };

    /// Atomically moves `ref` from `expected` to `new` (R3.2). `expected`
    /// null means the ref must not exist yet, except when deleting (`new`
    /// null), where it means delete whatever the ref points at.
    /// Returns .stale when the ref was not at `expected`. git takes the
    /// ref's lock and compares under it, so this is a compare-and-swap
    /// against every other writer, pushes included. Modeled in
    /// tests/tla/commit_cas/CommitCAS.tla (`NoLostUpdate`).
    pub fn updateRef(r: *const Repo, ref: []const u8, new: ?[]const u8, expected: ?[]const u8) git_cmd.Error!RefUpdate {
        const zero = "0000000000000000000000000000000000000000";
        const old = expected orelse zero;
        const result = if (new) |n|
            try r.git(&.{ "update-ref", "-m", "gitd", "--no-deref", "--end-of-options", ref, n, old }, .{})
        else if (expected) |e|
            try r.git(&.{ "update-ref", "-m", "gitd", "--no-deref", "-d", "--end-of-options", ref, e }, .{})
        else
            try r.git(&.{ "update-ref", "-m", "gitd", "--no-deref", "-d", "--end-of-options", ref }, .{});
        defer result.deinit(r.gpa);
        if (result.code == 0) return .updated;
        // Distinguish a lost race from a real failure by looking again.
        var buf: [64]u8 = undefined;
        const current = try r.refValue(ref, &buf);
        const matches = if (expected) |e| (current != null and std.mem.eql(u8, current.?, e)) else current == null;
        if (!matches) return .stale;
        std.log.err("git update-ref {s} failed: {s}", .{ ref, std.mem.trimEnd(u8, result.stderr, "\n") });
        return error.GitFailed;
    }
};
