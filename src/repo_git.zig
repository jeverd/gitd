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
        // Records end in NUL, RS, NUL: commit text cannot break the split
        // unless it contains that exact sequence.
        const format = "--format=%H%x00%P%x00%an%x00%ae%x00%ct%x00%s%x00%b%x00%x1e%x00";
        const raw = if (path) |p|
            try r.gitOutput(&.{ "log", format, n, "--end-of-options", commit, "--", p }, .{})
        else if (single)
            try r.gitOutput(&.{ "log", format, n, "--no-walk", "--end-of-options", commit }, .{})
        else
            try r.gitOutput(&.{ "log", format, n, "--end-of-options", commit }, .{});
        errdefer r.gpa.free(raw);
        var list: std.ArrayList(Commit) = .empty;
        errdefer list.deinit(r.gpa);
        var records = std.mem.splitSequence(u8, raw, "\x00\x1e\x00");
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
                try info.print(r.gpa, "100644 {s}\t{s}\x00", .{ oid, change.path });
            } else {
                // Mode 0 removes the path from the index.
                try info.print(r.gpa, "0 0000000000000000000000000000000000000000\t{s}\x00", .{change.path});
            }
        }
        if (info.items.len > 0) {
            // -z: records end in NUL and paths are taken literally. Without
            // it git C-unquotes a path that starts with '"'.
            r.gpa.free(try r.gitOutput(&.{ "update-index", "-z", "--index-info" }, .{ .env = &index_env, .stdin = info.items }));
        }
        // git silently skips paths it considers unsafe (some .git look-alikes
        // on case-insensitive or HFS file systems). Refuse rather than
        // report a commit that lacks a file the caller sent.
        try r.checkIndexHas(&index_env, changes);
        const tree_raw = try r.gitOutput(&.{"write-tree"}, .{ .env = &index_env });
        defer r.gpa.free(tree_raw);
        const tree = std.mem.trimEnd(u8, tree_raw, "\n");

        const parents: []const []const u8 = if (parent) |p| &.{p} else &.{};
        return r.commitTree(tree, parents, message, author, out);
    }

    fn checkIndexHas(r: *const Repo, index_env: []const [2][]const u8, changes: []const Change) git_cmd.Error!void {
        const listing = try r.gitOutput(&.{ "ls-files", "-z" }, .{ .env = index_env });
        defer r.gpa.free(listing);
        for (changes) |change| {
            if (change.content == null) continue;
            var found = false;
            var it = std.mem.splitScalar(u8, listing, 0);
            while (it.next()) |p| if (std.mem.eql(u8, p, change.path)) {
                found = true;
                break;
            };
            if (!found) return error.PathRejected;
        }
    }

    /// Writes a commit of `tree` with `parents` and returns its oid.
    pub fn commitTree(r: *const Repo, tree: []const u8, parents: []const []const u8, message: []const u8, author: Author, out: *[64]u8) git_cmd.Error![]const u8 {
        const ident_env = [_][2][]const u8{
            .{ "GIT_AUTHOR_NAME", author.name },
            .{ "GIT_AUTHOR_EMAIL", author.email },
            .{ "GIT_COMMITTER_NAME", "gitd" },
            .{ "GIT_COMMITTER_EMAIL", "gitd@localhost" },
        };
        var args: [8][]const u8 = undefined;
        var n: usize = 0;
        args[n] = "commit-tree";
        n += 1;
        args[n] = tree;
        n += 1;
        for (parents) |p| {
            args[n] = "-p";
            args[n + 1] = p;
            n += 2;
        }
        args[n] = "-F";
        args[n + 1] = "-";
        n += 2;
        const commit_raw = try r.gitOutput(args[0..n], .{ .env = &ident_env, .stdin = message });
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

    /// The best common ancestor of two commits, or null if they share none.
    pub fn mergeBase(r: *const Repo, a: []const u8, b: []const u8, out: *[64]u8) git_cmd.Error!?[]const u8 {
        const result = try r.git(&.{ "merge-base", "--end-of-options", a, b }, .{});
        defer result.deinit(r.gpa);
        if (result.code != 0) return null;
        const oid = std.mem.trimEnd(u8, result.stdout, "\n");
        if (oid.len > out.len) return error.GitFailed;
        @memcpy(out[0..oid.len], oid);
        return out[0..oid.len];
    }

    /// Whether `ancestor` is reachable from `descendant` (or equal to it).
    pub fn isAncestor(r: *const Repo, ancestor: []const u8, descendant: []const u8) git_cmd.Error!bool {
        const result = try r.git(&.{ "merge-base", "--is-ancestor", "--end-of-options", ancestor, descendant }, .{});
        defer result.deinit(r.gpa);
        return switch (result.code) {
            0 => true,
            1 => false,
            else => error.GitFailed,
        };
    }

    /// Commits only in `head` (ahead) and only in `base` (behind).
    pub fn aheadBehind(r: *const Repo, base: []const u8, head: []const u8) git_cmd.Error!struct { ahead: u64, behind: u64 } {
        var range_buf: [140]u8 = undefined;
        const range = std.mem.print(&range_buf, "{s}...{s}", .{ base, head }) catch return error.GitFailed;
        const raw = try r.gitOutput(&.{ "rev-list", "--left-right", "--count", "--end-of-options", range }, .{});
        defer r.gpa.free(raw);
        var it = std.mem.tokenizeAny(u8, raw, "\t \n");
        const behind = std.fmt.parseInt(u64, it.next() orelse return error.GitFailed, 10) catch return error.GitFailed;
        const ahead = std.fmt.parseInt(u64, it.next() orelse return error.GitFailed, 10) catch return error.GitFailed;
        return .{ .ahead = ahead, .behind = behind };
    }

    /// Flags for every diff gitd runs: no external diff or textconv
    /// programs (R2.4), no color, no rename detection.
    const diff_flags = [_][]const u8{ "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames" };

    pub const FileChange = struct {
        /// Slices borrow `FileChanges.raw_*`.
        path: []const u8,
        status: []const u8,
        /// Null for binary files.
        additions: ?u64,
        deletions: ?u64,
    };

    pub const FileChanges = struct {
        raw_status: []u8,
        raw_numstat: []u8,
        items: []FileChange,

        pub fn deinit(f: FileChanges, gpa: std.mem.Allocator) void {
            gpa.free(f.items);
            gpa.free(f.raw_status);
            gpa.free(f.raw_numstat);
        }
    };

    /// Files that differ between commits `from` and `to`.
    pub fn diffFiles(r: *const Repo, from: []const u8, to: []const u8) git_cmd.Error!FileChanges {
        const raw_status = try r.gitOutput(&(.{ "diff", "--name-status", "-z" } ++ diff_flags ++ .{ "--end-of-options", from, to }), .{});
        errdefer r.gpa.free(raw_status);
        const raw_numstat = try r.gitOutput(&(.{ "diff", "--numstat", "-z" } ++ diff_flags ++ .{ "--end-of-options", from, to }), .{});
        errdefer r.gpa.free(raw_numstat);

        var list: std.ArrayList(FileChange) = .empty;
        errdefer list.deinit(r.gpa);
        var it = std.mem.splitScalar(u8, raw_status, 0);
        while (it.next()) |status| {
            if (status.len == 0) break;
            const path = it.next() orelse break;
            try list.append(r.gpa, .{ .path = path, .status = status, .additions = null, .deletions = null });
        }
        // numstat -z: "<add>\t<del>\t<path>\0", in the same order.
        var nit = std.mem.splitScalar(u8, raw_numstat, 0);
        var i: usize = 0;
        while (nit.next()) |rec| : (i += 1) {
            if (rec.len == 0 or i >= list.items.len) break;
            var f = std.mem.splitScalar(u8, rec, '\t');
            list.items[i].additions = std.fmt.parseInt(u64, f.next() orelse "-", 10) catch null;
            list.items[i].deletions = std.fmt.parseInt(u64, f.next() orelse "-", 10) catch null;
        }
        return .{ .raw_status = raw_status, .raw_numstat = raw_numstat, .items = try list.toOwnedSlice(r.gpa) };
    }

    /// The unified diff from `from` to `to`, or null if it exceeds `max`.
    pub fn diffPatch(r: *const Repo, from: []const u8, to: []const u8, max: usize) git_cmd.Error!?[]u8 {
        return r.gitOutput(&(.{"diff"} ++ diff_flags ++ .{ "--end-of-options", from, to }), .{ .max_output = max }) catch |err| switch (err) {
            error.OutputTooLarge => null,
            else => |e| e,
        };
    }

    pub const MergeTree = union(enum) {
        /// The merged tree's oid, written into the caller's buffer.
        clean: []const u8,
        /// Conflicted paths; the caller frees `raw`.
        conflicts: struct { raw: []u8, paths: [][]const u8 },
    };

    /// Merges `ours` and `theirs` without a work tree (`git merge-tree
    /// --write-tree`). The caller frees `.conflicts.raw` and `.paths`.
    pub fn mergeTree(r: *const Repo, ours: []const u8, theirs: []const u8, tree_out: *[64]u8) git_cmd.Error!MergeTree {
        const result = try r.git(&.{ "merge-tree", "--write-tree", "--name-only", "-z", "--end-of-options", ours, theirs }, .{});
        errdefer r.gpa.free(result.stdout);
        defer r.gpa.free(result.stderr);
        // Output: <tree>\0, then on conflict <path>\0 ... \0\0 and messages.
        var it = std.mem.splitScalar(u8, result.stdout, 0);
        const tree = it.next() orelse return error.GitFailed;
        switch (result.code) {
            0 => {
                if (tree.len > tree_out.len) return error.GitFailed;
                @memcpy(tree_out[0..tree.len], tree);
                r.gpa.free(result.stdout);
                return .{ .clean = tree_out[0..tree.len] };
            },
            1 => {
                var paths: std.ArrayList([]const u8) = .empty;
                errdefer paths.deinit(r.gpa);
                while (it.next()) |p| {
                    if (p.len == 0) break;
                    try paths.append(r.gpa, p);
                }
                return .{ .conflicts = .{ .raw = result.stdout, .paths = try paths.toOwnedSlice(r.gpa) } };
            },
            else => {
                std.log.err("git merge-tree exited {d}: {s}", .{ result.code, std.mem.trimEnd(u8, result.stderr, "\n") });
                return error.GitFailed;
            },
        }
    }

    pub const GrepOptions = struct {
        fixed: bool = false,
        ignore_case: bool = false,
        path: ?[]const u8 = null,
        limit: u32 = 100,
        max_output: usize = 4 * 1024 * 1024,
        timeout_ms: i64 = 10_000,
    };

    pub const GrepMatch = struct {
        /// Slices borrow `GrepResult.raw`.
        path: []const u8,
        line: u64,
        text: []const u8,
    };

    pub const GrepResult = struct {
        raw: []u8,
        items: []GrepMatch,
        truncated: bool,

        pub fn deinit(g: GrepResult, gpa: std.mem.Allocator) void {
            gpa.free(g.items);
            gpa.free(g.raw);
        }
    };

    pub const GrepError = error{InvalidQuery} || git_cmd.Error;

    /// Searches tracked text files at `commit` (R2.4: `--no-textconv`, `-I`
    /// skips binary). Exit 1 means no matches; exit 128 is an invalid pattern.
    pub fn grep(r: *const Repo, commit: []const u8, query: []const u8, opts: GrepOptions) GrepError!GrepResult {
        var args: [16][]const u8 = undefined;
        var n: usize = 0;
        for ([_][]const u8{ "grep", "-n", "-z", "-I", "--no-color", "--no-textconv" }) |a| {
            args[n] = a;
            n += 1;
        }
        if (opts.fixed) {
            args[n] = "-F";
            n += 1;
        }
        if (opts.ignore_case) {
            args[n] = "-i";
            n += 1;
        }
        args[n] = "-e";
        args[n + 1] = query;
        args[n + 2] = commit;
        n += 3;
        if (opts.path) |p| {
            args[n] = "--";
            args[n + 1] = p;
            n += 2;
        }
        const result = try r.git(args[0..n], .{ .max_output = opts.max_output, .timeout_ms = opts.timeout_ms });
        defer r.gpa.free(result.stderr);
        switch (result.code) {
            0 => return parseGrepMatches(r.gpa, result.stdout, commit, opts.limit),
            1 => {
                r.gpa.free(result.stdout);
                return .{ .raw = &.{}, .items = &.{}, .truncated = false };
            },
            128 => {
                r.gpa.free(result.stdout);
                return error.InvalidQuery;
            },
            else => {
                std.log.err("git grep exited {d}: {s}", .{ result.code, std.mem.trimEnd(u8, result.stderr, "\n") });
                r.gpa.free(result.stdout);
                return error.GitFailed;
            },
        }
    }

    pub const ArchiveFormat = enum {
        @"tar.gz",
        tar,
        zip,

        pub fn contentType(f: ArchiveFormat) []const u8 {
            return switch (f) {
                .@"tar.gz" => "application/gzip",
                .tar => "application/x-tar",
                .zip => "application/zip",
            };
        }

        pub fn formatFlag(f: ArchiveFormat) []const u8 {
            return switch (f) {
                .@"tar.gz" => "--format=tar.gz",
                .tar => "--format=tar",
                .zip => "--format=zip",
            };
        }
    };

    /// Produces an archive of `commit` (or `path` within it). Caller frees the bytes.
    pub fn archive(r: *const Repo, commit: []const u8, format: ArchiveFormat, path: ?[]const u8, max: usize) git_cmd.Error![]u8 {
        if (path) |p| {
            return r.gitOutput(&.{ "archive", format.formatFlag(), commit, "--", p }, .{ .max_output = max });
        }
        return r.gitOutput(&.{ "archive", format.formatFlag(), commit }, .{ .max_output = max });
    }
};

/// Parses `git grep -n -z` output (`<commit>:<path>\0<line>\0<text>\n`).
/// Takes ownership of `raw` and frees it on error.
pub fn parseGrepMatches(gpa: std.mem.Allocator, raw: []u8, commit: []const u8, limit: u32) std.mem.Allocator.Error!Repo.GrepResult {
    errdefer gpa.free(raw);
    var list: std.ArrayList(Repo.GrepMatch) = .empty;
    errdefer list.deinit(gpa);
    var truncated = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |rec| {
        if (rec.len == 0) continue;
        if (rec.len <= commit.len or !std.mem.startsWith(u8, rec, commit) or rec[commit.len] != ':') continue;
        var fields = std.mem.splitScalar(u8, rec[commit.len + 1 ..], 0);
        const path = fields.next() orelse continue;
        if (path.len == 0) continue;
        const line_str = fields.next() orelse continue;
        const line_num = std.fmt.parseInt(u64, line_str, 10) catch continue;
        const text = fields.rest();
        if (list.items.len >= limit) {
            truncated = true;
            break;
        }
        try list.append(gpa, .{ .path = path, .line = line_num, .text = text });
    }
    return .{ .raw = raw, .items = try list.toOwnedSlice(gpa), .truncated = truncated };
}

test "parseGrepMatches parses records, handles colons in paths, and truncates" {
    const gpa = std.testing.allocator;
    const sha = "0123456789abcdef0123456789abcdef01234567";
    const input = sha ++ ":dir/a:b.txt\x0012\x00hello world\n" ++
        sha ++ ":src/main.zig\x003\x00const x = 1;\n" ++
        sha ++ ":src/more.zig\x009\x00extra\n";
    const res = try parseGrepMatches(gpa, try gpa.dupe(u8, input), sha, 2);
    defer res.deinit(gpa);
    try std.testing.expect(res.truncated);
    try std.testing.expectEqual(@as(usize, 2), res.items.len);
    try std.testing.expectEqualStrings("dir/a:b.txt", res.items[0].path);
    try std.testing.expectEqual(@as(u64, 12), res.items[0].line);
    try std.testing.expectEqualStrings("hello world", res.items[0].text);
    try std.testing.expectEqualStrings("src/main.zig", res.items[1].path);
    try std.testing.expectEqual(@as(u64, 3), res.items[1].line);
    try std.testing.expectEqualStrings("const x = 1;", res.items[1].text);
}

test "fuzz parse grep" {
    try std.testing.fuzz({}, fuzzParseGrep, .{
        .corpus = &.{
            "abcd:a.txt\x001\x00hi\n",
            "abcd:\x00\x00\n",
            "no-prefix\n",
        },
    });
}

fn fuzzParseGrep(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var buf: [512]u8 = undefined;
    const raw = try gpa.dupe(u8, buf[0..smith.slice(&buf)]);
    const res = try parseGrepMatches(gpa, raw, "abcd", 16);
    defer res.deinit(gpa);
    try std.testing.expect(res.items.len <= 16);
}
