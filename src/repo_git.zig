//! Read and write operations on one repo.
//!
//! Hot reads (`listBranches`, `refValue`, `resolveCommit`, `lsTree`,
//! `readBlob`, `log`) and API writes (`buildCommit`, `commitTree`,
//! `updateRef`) run in-process via `libgit2` (`git2.zig`). Remaining operations
//! (`mergeBase`, `diffFiles`, `mergeTree`, `grep`, `archive`, `gc`) run via
//! `git_cmd`, where inputs are validated by callers and passed after `--`.

const std = @import("std");
const Io = std.Io;
const git_cmd = @import("git_cmd.zig");
const git2 = @import("git2.zig");
const store_mod = @import("store.zig");
const repo_name = @import("repo_name.zig");
const repo_path = @import("repo_path.zig");

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

    fn openBare(r: *const Repo) git_cmd.Error!*git2.Repository {
        return git2.openBare(r.gitDir()) orelse {
            std.log.err("git2 open_bare {s}: {s}", .{ r.gitDir(), git2.lastErrorMessage() });
            return error.GitFailed;
        };
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
        const repo = try r.openBare();
        defer git2.git_repository_free(repo);

        var iter: ?*git2.ReferenceIterator = null;
        if (git2.git_reference_iterator_glob_new(&iter, repo, "refs/heads/*") != git2.ok) {
            std.log.err("git2 branch iterator: {s}", .{git2.lastErrorMessage()});
            return error.GitFailed;
        }
        defer git2.git_reference_iterator_free(iter.?);

        const Meta = struct {
            name_off: usize,
            name_len: usize,
            commit_off: usize,
            committed_at: i64,
            subject_off: usize,
            subject_len: usize,
        };
        var metas: std.ArrayList(Meta) = .empty;
        defer metas.deinit(r.gpa);
        var raw_buf: std.ArrayList(u8) = .empty;
        errdefer raw_buf.deinit(r.gpa);

        while (true) {
            var ref: ?*git2.Reference = null;
            const rc = git2.git_reference_next(&ref, iter.?);
            if (rc == git2.err_iter_over) break;
            if (rc != git2.ok) {
                std.log.err("git2 branch iter next: {s}", .{git2.lastErrorMessage()});
                return error.GitFailed;
            }
            defer git2.git_reference_free(ref.?);

            const full_name = std.mem.span(git2.git_reference_name(ref.?));
            const prefix = "refs/heads/";
            if (!std.mem.startsWith(u8, full_name, prefix)) continue;
            const short_name = full_name[prefix.len..];

            var resolved: ?*git2.Reference = null;
            defer if (resolved) |res| git2.git_reference_free(res);
            const direct: *const git2.Reference = if (git2.git_reference_type(ref.?) == git2.ref_direct)
                ref.?
            else blk: {
                if (git2.git_reference_resolve(&resolved, ref.?) != git2.ok) continue;
                break :blk resolved.?;
            };
            const oid = git2.git_reference_target(direct) orelse continue;

            const commit = lookupCommitByOid(repo, oid) orelse continue;
            defer git2.git_commit_free(commit);

            var oid_hex: [git2.oid_hex_len]u8 = undefined;
            _ = git2.formatOid(oid, &oid_hex);
            const committed_at = git2.git_commit_time(commit);
            const subject = if (git2.git_commit_summary(commit)) |s| std.mem.span(s) else "";

            const name_off = raw_buf.items.len;
            try raw_buf.appendSlice(r.gpa, short_name);
            const commit_off = raw_buf.items.len;
            try raw_buf.appendSlice(r.gpa, &oid_hex);
            const subject_off = raw_buf.items.len;
            try raw_buf.appendSlice(r.gpa, subject);

            try metas.append(r.gpa, .{
                .name_off = name_off,
                .name_len = short_name.len,
                .commit_off = commit_off,
                .committed_at = committed_at,
                .subject_off = subject_off,
                .subject_len = subject.len,
            });
        }

        const raw = try raw_buf.toOwnedSlice(r.gpa);
        errdefer r.gpa.free(raw);
        const items = try r.gpa.alloc(Branch, metas.items.len);
        for (metas.items, items) |m, *b| {
            b.* = .{
                .name = raw[m.name_off..][0..m.name_len],
                .commit = raw[m.commit_off..][0..git2.oid_hex_len],
                .committed_at = m.committed_at,
                .subject = raw[m.subject_off..][0..m.subject_len],
            };
        }
        std.mem.sort(Branch, items, {}, struct {
            fn lessThan(_: void, a: Branch, b: Branch) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        return .{ .raw = raw, .items = items };
    }

    /// The commit a full ref name points at, or null if it does not exist.
    /// Writes the oid into `out`.
    pub fn refValue(r: *const Repo, ref: []const u8, out: *[64]u8) git_cmd.Error!?[]const u8 {
        const repo = try r.openBare();
        defer git2.git_repository_free(repo);
        var buf: [512]u8 = undefined;
        const ref_z = toCStringBuf(&buf, ref) orelse return null;
        var oid: git2.Oid = .{};
        if (git2.git_reference_name_to_id(&oid, repo, ref_z.ptr) != git2.ok) return null;
        return formatOidOut(&oid, out);
    }

    /// Resolves `rev` (a full ref name or an oid) to a commit oid written
    /// into `out`, or null if it names no commit.
    pub fn resolveCommit(r: *const Repo, rev: []const u8, out: *[64]u8) git_cmd.Error!?[]const u8 {
        const repo = try r.openBare();
        defer git2.git_repository_free(repo);
        const commit = lookupCommit(repo, rev) orelse return null;
        defer git2.git_commit_free(commit);
        return formatOidOut(git2.git_commit_id(commit), out);
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

    const EntryMeta = struct {
        mode_off: usize,
        mode_len: usize,
        kind: EntryKind,
        oid_off: usize,
        size: ?u64,
        path_off: usize,
        path_len: usize,
    };

    /// Lists `dir` (null for the root) at `commit`, or with `exact`, the
    /// single entry at `dir` itself.
    pub fn lsTree(r: *const Repo, commit: []const u8, dir: ?[]const u8, exact: bool) git_cmd.Error!Entries {
        const repo = try r.openBare();
        defer git2.git_repository_free(repo);

        const root_tree = lookupRootTree(repo, commit) orelse return error.GitFailed;
        defer git2.git_tree_free(root_tree);

        var odb: ?*git2.Odb = null;
        if (git2.git_repository_odb(&odb, repo) != git2.ok) return error.GitFailed;
        defer git2.git_odb_free(odb.?);

        var metas: std.ArrayList(EntryMeta) = .empty;
        defer metas.deinit(r.gpa);
        var raw_buf: std.ArrayList(u8) = .empty;
        errdefer raw_buf.deinit(r.gpa);

        if (dir) |d| {
            var dir_buf: [repo_path.max_len + 1]u8 = undefined;
            const dir_z = toCStringBuf(&dir_buf, d) orelse return error.PathRejected;
            var entry: ?*git2.TreeEntry = null;
            const rc = git2.git_tree_entry_bypath(&entry, root_tree, dir_z.ptr);
            if (rc == git2.err_not_found) {
                return .{ .raw = try raw_buf.toOwnedSlice(r.gpa), .items = try r.gpa.alloc(Entry, 0) };
            }
            if (rc != git2.ok) return error.GitFailed;
            defer git2.git_tree_entry_free(entry.?);

            if (exact) {
                try appendTreeEntry(r.gpa, odb.?, &metas, &raw_buf, null, d, entry.?);
            } else if (git2.git_tree_entry_type(entry.?) == git2.obj_tree) {
                var sub_tree: ?*git2.Tree = null;
                if (git2.git_tree_lookup(&sub_tree, repo, git2.git_tree_entry_id(entry.?)) != git2.ok) return error.GitFailed;
                defer git2.git_tree_free(sub_tree.?);
                try collectTreeChildren(r.gpa, odb.?, &metas, &raw_buf, d, sub_tree.?);
            }
        } else {
            try collectTreeChildren(r.gpa, odb.?, &metas, &raw_buf, null, root_tree);
        }

        const raw = try raw_buf.toOwnedSlice(r.gpa);
        errdefer r.gpa.free(raw);
        const items = try r.gpa.alloc(Entry, metas.items.len);
        for (metas.items, items) |m, *e| {
            e.* = .{
                .mode = raw[m.mode_off..][0..m.mode_len],
                .kind = m.kind,
                .oid = raw[m.oid_off..][0..git2.oid_hex_len],
                .size = m.size,
                .path = raw[m.path_off..][0..m.path_len],
            };
        }
        return .{ .raw = raw, .items = items };
    }

    fn collectTreeChildren(
        gpa: std.mem.Allocator,
        odb: *git2.Odb,
        metas: *std.ArrayList(EntryMeta),
        raw_buf: *std.ArrayList(u8),
        prefix: ?[]const u8,
        tree: *const git2.Tree,
    ) git_cmd.Error!void {
        const count = git2.git_tree_entrycount(tree);
        for (0..count) |i| {
            const entry = git2.git_tree_entry_byindex(tree, i) orelse continue;
            const child_name = std.mem.span(git2.git_tree_entry_name(entry));
            try appendTreeEntry(gpa, odb, metas, raw_buf, prefix, child_name, entry);
        }
    }

    fn appendTreeEntry(
        gpa: std.mem.Allocator,
        odb: *git2.Odb,
        metas: *std.ArrayList(EntryMeta),
        raw_buf: *std.ArrayList(u8),
        prefix: ?[]const u8,
        leaf: []const u8,
        entry: *const git2.TreeEntry,
    ) git_cmd.Error!void {
        const kind: EntryKind = switch (git2.git_tree_entry_type(entry)) {
            git2.obj_blob => .blob,
            git2.obj_tree => .tree,
            git2.obj_commit => .commit,
            else => return,
        };
        const filemode: u32 = @intCast(git2.git_tree_entry_filemode(entry));
        var mode_buf: [16]u8 = undefined;
        const mode_text = std.mem.print(&mode_buf, "{o:0>6}", .{filemode}) catch return error.GitFailed;

        const oid_ptr = git2.git_tree_entry_id(entry);
        var oid_hex: [git2.oid_hex_len]u8 = undefined;
        _ = git2.formatOid(oid_ptr, &oid_hex);

        var size: ?u64 = null;
        if (kind == .blob) {
            var obj_len: usize = 0;
            var obj_type: c_int = 0;
            if (git2.git_odb_read_header(&obj_len, &obj_type, odb, oid_ptr) == git2.ok) {
                size = @intCast(obj_len);
            }
        }

        const mode_off = raw_buf.items.len;
        try raw_buf.appendSlice(gpa, mode_text);
        const oid_off = raw_buf.items.len;
        try raw_buf.appendSlice(gpa, &oid_hex);
        const path_off = raw_buf.items.len;
        if (prefix) |p| {
            try raw_buf.appendSlice(gpa, p);
            try raw_buf.append(gpa, '/');
        }
        try raw_buf.appendSlice(gpa, leaf);
        const path_len = raw_buf.items.len - path_off;

        try metas.append(gpa, .{
            .mode_off = mode_off,
            .mode_len = mode_text.len,
            .kind = kind,
            .oid_off = oid_off,
            .size = size,
            .path_off = path_off,
            .path_len = path_len,
        });
    }

    /// The contents of blob `oid`. Fails with error.OutputTooLarge past
    /// `max` bytes.
    pub fn readBlob(r: *const Repo, oid: []const u8, max: usize) git_cmd.Error![]u8 {
        const repo = try r.openBare();
        defer git2.git_repository_free(repo);

        const target_oid = lookupBlobOid(repo, oid) orelse return error.GitFailed;

        var odb: ?*git2.Odb = null;
        if (git2.git_repository_odb(&odb, repo) != git2.ok) return error.GitFailed;
        defer git2.git_odb_free(odb.?);

        var obj_len: usize = 0;
        var obj_type: c_int = 0;
        if (git2.git_odb_read_header(&obj_len, &obj_type, odb.?, &target_oid) != git2.ok or obj_type != git2.obj_blob) {
            return error.GitFailed;
        }
        if (obj_len > max) return error.OutputTooLarge;

        var blob: ?*git2.Blob = null;
        if (git2.git_blob_lookup(&blob, repo, &target_oid) != git2.ok) return error.GitFailed;
        defer git2.git_blob_free(blob.?);

        const raw_len = git2.git_blob_rawsize(blob.?);
        if (raw_len > max) return error.OutputTooLarge;
        const len: usize = @intCast(raw_len);
        const out = try r.gpa.alloc(u8, len);
        if (len > 0) {
            const ptr: [*]const u8 = @ptrCast(git2.git_blob_rawcontent(blob.?) orelse {
                r.gpa.free(out);
                return error.GitFailed;
            });
            @memcpy(out, ptr[0..len]);
        }
        return out;
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

    const CommitMeta = struct {
        sha_off: usize,
        parents_off: usize,
        parents_len: usize,
        author_name_off: usize,
        author_name_len: usize,
        author_email_off: usize,
        author_email_len: usize,
        time: i64,
        subject_off: usize,
        subject_len: usize,
        body_off: usize,
        body_len: usize,
    };

    /// Up to `limit` commits reachable from `commit`, newest first, touching
    /// `path` if given. With `single`, only `commit` itself.
    pub fn log(r: *const Repo, commit: []const u8, limit: u32, path: ?[]const u8, single: bool) git_cmd.Error!Log {
        const repo = try r.openBare();
        defer git2.git_repository_free(repo);

        const tip = lookupCommit(repo, commit) orelse return error.GitFailed;
        defer git2.git_commit_free(tip);

        var path_buf: [repo_path.max_len + 1]u8 = undefined;
        const path_z: ?[:0]const u8 = if (path) |p|
            (toCStringBuf(&path_buf, p) orelse return error.PathRejected)
        else
            null;

        var metas: std.ArrayList(CommitMeta) = .empty;
        defer metas.deinit(r.gpa);
        var raw_buf: std.ArrayList(u8) = .empty;
        errdefer raw_buf.deinit(r.gpa);

        if (single) {
            if (path_z == null or try commitTouchesPath(tip, path_z.?)) {
                try appendCommitMeta(r.gpa, &metas, &raw_buf, tip);
            }
        } else if (limit > 0) {
            var walk: ?*git2.Revwalk = null;
            if (git2.git_revwalk_new(&walk, repo) != git2.ok) return error.GitFailed;
            defer git2.git_revwalk_free(walk.?);
            _ = git2.git_revwalk_sorting(walk.?, git2.sort_topological | git2.sort_time);
            if (git2.git_revwalk_push(walk.?, git2.git_commit_id(tip)) != git2.ok) return error.GitFailed;

            while (metas.items.len < limit) {
                var cur_oid: git2.Oid = .{};
                const rc = git2.git_revwalk_next(&cur_oid, walk.?);
                if (rc == git2.err_iter_over) break;
                if (rc != git2.ok) return error.GitFailed;

                var cur: ?*git2.Commit = null;
                if (git2.git_commit_lookup(&cur, repo, &cur_oid) != git2.ok) return error.GitFailed;
                defer git2.git_commit_free(cur.?);

                if (path_z) |pz| {
                    if (!(try commitTouchesPath(cur.?, pz))) continue;
                }
                try appendCommitMeta(r.gpa, &metas, &raw_buf, cur.?);
            }
        }

        const raw = try raw_buf.toOwnedSlice(r.gpa);
        errdefer r.gpa.free(raw);
        const items = try r.gpa.alloc(Commit, metas.items.len);
        for (metas.items, items) |m, *c| {
            c.* = .{
                .sha = raw[m.sha_off..][0..git2.oid_hex_len],
                .parents = raw[m.parents_off..][0..m.parents_len],
                .author_name = raw[m.author_name_off..][0..m.author_name_len],
                .author_email = raw[m.author_email_off..][0..m.author_email_len],
                .time = m.time,
                .subject = raw[m.subject_off..][0..m.subject_len],
                .body = raw[m.body_off..][0..m.body_len],
            };
        }
        return .{ .raw = raw, .items = items };
    }

    fn appendCommitMeta(
        gpa: std.mem.Allocator,
        metas: *std.ArrayList(CommitMeta),
        raw_buf: *std.ArrayList(u8),
        c: *git2.Commit,
    ) std.mem.Allocator.Error!void {
        var sha_hex: [git2.oid_hex_len]u8 = undefined;
        _ = git2.formatOid(git2.git_commit_id(c), &sha_hex);
        const sha_off = raw_buf.items.len;
        try raw_buf.appendSlice(gpa, &sha_hex);

        const parents_off = raw_buf.items.len;
        const pcount = git2.git_commit_parentcount(c);
        for (0..pcount) |pi| {
            if (pi > 0) try raw_buf.append(gpa, ' ');
            if (git2.git_commit_parent_id(c, @intCast(pi))) |p_oid| {
                var p_hex: [git2.oid_hex_len]u8 = undefined;
                _ = git2.formatOid(p_oid, &p_hex);
                try raw_buf.appendSlice(gpa, &p_hex);
            }
        }
        const parents_len = raw_buf.items.len - parents_off;

        const author_sig = git2.git_commit_author(c);
        const a_name = std.mem.span(author_sig.name);
        const a_email = std.mem.span(author_sig.email);
        const author_name_off = raw_buf.items.len;
        try raw_buf.appendSlice(gpa, a_name);
        const author_email_off = raw_buf.items.len;
        try raw_buf.appendSlice(gpa, a_email);

        const subject = if (git2.git_commit_summary(c)) |s| std.mem.span(s) else "";
        const body_raw = if (git2.git_commit_body(c)) |b| std.mem.span(b) else "";
        const body = std.mem.trimEnd(u8, body_raw, "\n");
        const subject_off = raw_buf.items.len;
        try raw_buf.appendSlice(gpa, subject);
        const body_off = raw_buf.items.len;
        try raw_buf.appendSlice(gpa, body);

        try metas.append(gpa, .{
            .sha_off = sha_off,
            .parents_off = parents_off,
            .parents_len = parents_len,
            .author_name_off = author_name_off,
            .author_name_len = a_name.len,
            .author_email_off = author_email_off,
            .author_email_len = a_email.len,
            .time = git2.git_commit_time(c),
            .subject_off = subject_off,
            .subject_len = subject.len,
            .body_off = body_off,
            .body_len = body.len,
        });
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
        const repo = try r.openBare();
        defer git2.git_repository_free(repo);

        var parent_commit: ?*git2.Commit = null;
        var base_tree: ?*git2.Tree = null;
        if (parent) |p| {
            parent_commit = lookupCommit(repo, p) orelse return error.GitFailed;
            if (git2.git_commit_tree(&base_tree, parent_commit.?) != git2.ok) {
                git2.git_commit_free(parent_commit.?);
                return error.GitFailed;
            }
        }
        defer if (base_tree) |t| git2.git_tree_free(t);
        defer if (parent_commit) |p| git2.git_commit_free(p);

        var arena_state: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var root_node: DirNode = .{};
        for (changes) |change| {
            repo_path.validate(change.path) catch return error.PathRejected;
            const blob_oid: ?git2.Oid = if (change.content) |data| blk: {
                var oid: git2.Oid = .{};
                const buf_ptr: *const anyopaque = if (data.len == 0) @ptrCast("") else @ptrCast(data.ptr);
                if (git2.git_blob_create_from_buffer(&oid, repo, buf_ptr, data.len) != git2.ok) {
                    std.log.err("git2 blob_create: {s}", .{git2.lastErrorMessage()});
                    return error.GitFailed;
                }
                break :blk oid;
            } else null;
            try insertTrieChange(arena, &root_node, change.path, blob_oid);
        }

        const root_tree_oid = (try writeDirNode(arena, repo, &root_node, base_tree, true)) orelse return error.GitFailed;
        var new_tree: ?*git2.Tree = null;
        if (git2.git_tree_lookup(&new_tree, repo, &root_tree_oid) != git2.ok) return error.GitFailed;
        defer git2.git_tree_free(new_tree.?);

        const parents: []const *const git2.Commit = if (parent_commit) |p| &.{p} else &.{};
        return createCommitOnRepo(arena, repo, new_tree.?, parents, message, author, out);
    }

    const ChildState = union(enum) {
        file: git2.Oid,
        delete,
        dir: *DirNode,
    };

    const ChildEntry = struct {
        name: []const u8,
        state: ChildState,
    };

    const DirNode = struct {
        ignore_base: bool = false,
        children: std.ArrayList(ChildEntry) = .empty,

        fn findChildIndex(node: *const DirNode, name: []const u8) ?usize {
            for (node.children.items, 0..) |c, i| {
                if (std.mem.eql(u8, c.name, name)) return i;
            }
            return null;
        }
    };

    fn insertTrieChange(
        arena: std.mem.Allocator,
        root: *DirNode,
        path: []const u8,
        blob_oid: ?git2.Oid,
    ) git_cmd.Error!void {
        var cur = root;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |seg| {
            const is_last = it.rest().len == 0;
            if (is_last) {
                const state: ChildState = if (blob_oid) |oid| .{ .file = oid } else .delete;
                if (cur.findChildIndex(seg)) |idx| {
                    cur.children.items[idx].state = state;
                } else {
                    try cur.children.append(arena, .{ .name = seg, .state = state });
                }
                return;
            }
            if (cur.findChildIndex(seg)) |idx| {
                switch (cur.children.items[idx].state) {
                    .dir => |sub| cur = sub,
                    .file, .delete => {
                        // File replaced or subtree deleted earlier in this same commit:
                        // start the directory fresh instead of inheriting old base_tree children.
                        const sub = try arena.create(DirNode);
                        sub.* = .{ .ignore_base = true };
                        cur.children.items[idx].state = .{ .dir = sub };
                        cur = sub;
                    },
                }
            } else {
                const sub = try arena.create(DirNode);
                sub.* = .{};
                try cur.children.append(arena, .{ .name = seg, .state = .{ .dir = sub } });
                cur = sub;
            }
        }
    }

    fn writeDirNode(
        arena: std.mem.Allocator,
        repo: *git2.Repository,
        node: *const DirNode,
        base_tree: ?*const git2.Tree,
        is_root: bool,
    ) git_cmd.Error!?git2.Oid {
        const source_tree: ?*const git2.Tree = if (node.ignore_base) null else base_tree;
        var bld: ?*git2.TreeBuilder = null;
        if (git2.git_treebuilder_new(&bld, repo, source_tree) != git2.ok) {
            std.log.err("git2 treebuilder_new: {s}", .{git2.lastErrorMessage()});
            return error.GitFailed;
        }
        defer git2.git_treebuilder_free(bld.?);

        for (node.children.items) |child| {
            const name_z = arena.dupeSentinel(u8, child.name, 0) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            switch (child.state) {
                .file => |oid| {
                    if (git2.git_treebuilder_insert(null, bld.?, name_z.ptr, &oid, git2.mode_blob) != git2.ok) {
                        return error.PathRejected;
                    }
                },
                .delete => {
                    if (git2.git_treebuilder_get(bld.?, name_z.ptr) != null) {
                        if (git2.git_treebuilder_remove(bld.?, name_z.ptr) != git2.ok) {
                            std.log.err("git2 treebuilder_remove {s}: {s}", .{ child.name, git2.lastErrorMessage() });
                            return error.GitFailed;
                        }
                    }
                },
                .dir => |subnode| {
                    const existing = if (source_tree) |st| git2.git_tree_entry_byname(st, name_z.ptr) else null;
                    const was_tree = existing != null and git2.git_tree_entry_type(existing.?) == git2.obj_tree;
                    var sub_base: ?*git2.Tree = null;
                    if (was_tree) {
                        if (git2.git_tree_lookup(&sub_base, repo, git2.git_tree_entry_id(existing.?)) != git2.ok) return error.GitFailed;
                    }
                    defer if (sub_base) |st| git2.git_tree_free(st);

                    if (try writeDirNode(arena, repo, subnode, sub_base, false)) |sub_oid| {
                        if (git2.git_treebuilder_insert(null, bld.?, name_z.ptr, &sub_oid, git2.mode_tree) != git2.ok) {
                            return error.PathRejected;
                        }
                    } else if (was_tree and git2.git_treebuilder_get(bld.?, name_z.ptr) != null) {
                        // Deleting the last entry in an existing directory prunes the empty subtree.
                        if (git2.git_treebuilder_remove(bld.?, name_z.ptr) != git2.ok) return error.GitFailed;
                    }
                },
            }
        }

        if (!is_root and git2.git_treebuilder_entrycount(bld.?) == 0) return null;

        var out_oid: git2.Oid = .{};
        if (git2.git_treebuilder_write(&out_oid, bld.?) != git2.ok) {
            std.log.err("git2 treebuilder_write: {s}", .{git2.lastErrorMessage()});
            return error.GitFailed;
        }
        return out_oid;
    }

    /// Writes a commit of `tree` with `parents` and returns its oid.
    pub fn commitTree(r: *const Repo, tree: []const u8, parents: []const []const u8, message: []const u8, author: Author, out: *[64]u8) git_cmd.Error![]const u8 {
        const repo = try r.openBare();
        defer git2.git_repository_free(repo);

        const tree_obj = lookupTreeObject(repo, tree) orelse return error.GitFailed;
        defer git2.git_tree_free(tree_obj);

        var parent_objs: std.ArrayList(*git2.Commit) = .empty;
        defer {
            for (parent_objs.items) |p| git2.git_commit_free(p);
            parent_objs.deinit(r.gpa);
        }
        for (parents) |p| {
            const c = lookupCommit(repo, p) orelse return error.GitFailed;
            errdefer git2.git_commit_free(c);
            try parent_objs.append(r.gpa, c);
        }

        var arena_state: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena_state.deinit();
        const c_ptrs: []const *const git2.Commit = @ptrCast(parent_objs.items);
        return createCommitOnRepo(arena_state.allocator(), repo, tree_obj, c_ptrs, message, author, out);
    }

    fn createCommitOnRepo(
        arena: std.mem.Allocator,
        repo: *git2.Repository,
        tree: *const git2.Tree,
        parents: []const *const git2.Commit,
        message: []const u8,
        author: Author,
        out: *[64]u8,
    ) git_cmd.Error![]const u8 {
        const name_z = toCStringArena(arena, author.name) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Invalid => error.GitFailed,
        };
        const email_z = toCStringArena(arena, author.email) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Invalid => error.GitFailed,
        };
        const msg_z = toCStringArena(arena, message) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Invalid => error.GitFailed,
        };

        var author_sig: ?*git2.Signature = null;
        if (git2.git_signature_now(&author_sig, name_z.ptr, email_z.ptr) != git2.ok) {
            std.log.err("git2 signature_now: {s}", .{git2.lastErrorMessage()});
            return error.GitFailed;
        }
        defer git2.git_signature_free(author_sig.?);

        var committer_sig: ?*git2.Signature = null;
        if (git2.git_signature_new(
            &committer_sig,
            "gitd",
            "gitd@localhost",
            author_sig.?.when.time,
            author_sig.?.when.offset,
        ) != git2.ok) return error.GitFailed;
        defer git2.git_signature_free(committer_sig.?);

        var commit_oid: git2.Oid = .{};
        const p_ptr: ?[*]const *const git2.Commit = if (parents.len == 0) null else parents.ptr;
        if (git2.git_commit_create(
            &commit_oid,
            repo,
            null,
            author_sig.?,
            committer_sig.?,
            null,
            msg_z.ptr,
            tree,
            parents.len,
            p_ptr,
        ) != git2.ok) {
            std.log.err("git2 commit_create: {s}", .{git2.lastErrorMessage()});
            return error.GitFailed;
        }
        return formatOidOut(&commit_oid, out);
    }

    pub const RefUpdate = enum { updated, stale };

    /// Atomically moves `ref` from `expected` to `new` (R3.2). `expected`
    /// null means the ref must not exist yet, except when deleting (`new`
    /// null), where it means delete whatever the ref points at.
    /// Returns .stale when the ref was not at `expected`. libgit2 takes
    /// the ref's `.lock` and compares under it, so this is a
    /// compare-and-swap against every other writer, pushes included.
    /// Modeled in tests/tla/commit_cas/CommitCAS.tla (`NoLostUpdate`).
    pub fn updateRef(r: *const Repo, ref: []const u8, new: ?[]const u8, expected: ?[]const u8) git_cmd.Error!RefUpdate {
        const repo = try r.openBare();
        defer git2.git_repository_free(repo);

        var ref_buf: [512]u8 = undefined;
        const ref_z = toCStringBuf(&ref_buf, ref) orelse return error.GitFailed;

        const new_oid: ?git2.Oid = if (new) |n|
            (git2.parseOid(n) orelse return error.GitFailed)
        else
            null;
        const exp_oid: ?git2.Oid = if (expected) |e|
            (git2.parseOid(e) orelse return .stale)
        else
            null;

        // Wait out brief `.lock` races (50-200us) under high same-branch concurrency.
        var backoff_us: i64 = 250;
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const outcome = try updateRefOnce(repo, ref_z, new_oid, exp_oid);
            if (outcome) |res| return res;
            if (attempt >= 35) {
                std.log.err("git2 updateRef {s} locked after {d} retries", .{ ref, attempt });
                return error.GitFailed;
            }
            try r.io.sleep(.fromMicroseconds(backoff_us), .awake);
            backoff_us = @min(backoff_us * 2, 16_000);
        }
    }

    /// Returns null only when `.lock` contention (`GIT_ELOCKED`) asks for retry.
    fn updateRefOnce(
        repo: *git2.Repository,
        ref_z: [:0]const u8,
        new_oid: ?git2.Oid,
        exp_oid: ?git2.Oid,
    ) git_cmd.Error!?RefUpdate {
        if (new_oid) |n| {
            if (exp_oid) |e| {
                var existing: ?*git2.Reference = null;
                const lrc = git2.git_reference_lookup(&existing, repo, ref_z.ptr);
                if (lrc == git2.err_not_found) return .stale;
                if (lrc == git2.err_locked) return null;
                if (lrc != git2.ok) {
                    std.log.err("git2 reference_lookup {s}: {s}", .{ ref_z, git2.lastErrorMessage() });
                    return error.GitFailed;
                }
                defer git2.git_reference_free(existing.?);

                if (!refMatchesExpected(existing.?, e)) return .stale;

                var updated: ?*git2.Reference = null;
                const rc = git2.git_reference_set_target(&updated, existing.?, &n, "gitd");
                defer if (updated) |u| git2.git_reference_free(u);
                if (rc == git2.ok) return .updated;
                if (rc == git2.err_modified or rc == git2.err_not_found) return .stale;
                if (rc == git2.err_locked) return null;
                std.log.err("git2 reference_set_target {s}: {s}", .{ ref_z, git2.lastErrorMessage() });
                return error.GitFailed;
            } else {
                var created: ?*git2.Reference = null;
                const rc = git2.git_reference_create(&created, repo, ref_z.ptr, &n, 0, "gitd");
                defer if (created) |c| git2.git_reference_free(c);
                if (rc == git2.ok) return .updated;
                if (rc == git2.err_exists) return .stale;
                if (rc == git2.err_locked) return null;
                std.log.err("git2 reference_create {s}: {s}", .{ ref_z, git2.lastErrorMessage() });
                return error.GitFailed;
            }
        } else if (exp_oid) |e| {
            var existing: ?*git2.Reference = null;
            const lrc = git2.git_reference_lookup(&existing, repo, ref_z.ptr);
            if (lrc == git2.err_not_found) return .stale;
            if (lrc == git2.err_locked) return null;
            if (lrc != git2.ok) {
                std.log.err("git2 reference_lookup {s}: {s}", .{ ref_z, git2.lastErrorMessage() });
                return error.GitFailed;
            }
            defer git2.git_reference_free(existing.?);

            if (!refMatchesExpected(existing.?, e)) return .stale;

            const rc = git2.git_reference_delete(existing.?);
            if (rc == git2.ok) return .updated;
            if (rc == git2.err_modified or rc == git2.err_not_found) return .stale;
            if (rc == git2.err_locked) return null;
            std.log.err("git2 reference_delete {s}: {s}", .{ ref_z, git2.lastErrorMessage() });
            return error.GitFailed;
        } else {
            const rc = git2.git_reference_remove(repo, ref_z.ptr);
            if (rc == git2.ok or rc == git2.err_not_found) return .updated;
            if (rc == git2.err_locked) return null;
            std.log.err("git2 reference_remove {s}: {s}", .{ ref_z, git2.lastErrorMessage() });
            return error.GitFailed;
        }
    }

    fn refMatchesExpected(ref: *const git2.Reference, expected: git2.Oid) bool {
        if (git2.git_reference_type(ref) != git2.ref_direct) return false;
        const cur_oid = git2.git_reference_target(ref) orelse return false;
        return std.mem.eql(u8, &cur_oid.id, &expected.id);
    }

    fn toCStringBuf(buf: []u8, s: []const u8) ?[:0]const u8 {
        if (s.len >= buf.len or std.mem.findScalar(u8, s, 0) != null) return null;
        @memcpy(buf[0..s.len], s);
        buf[s.len] = 0;
        return buf[0..s.len :0];
    }

    fn toCStringArena(arena: std.mem.Allocator, s: []const u8) error{ Invalid, OutOfMemory }![:0]const u8 {
        if (std.mem.findScalar(u8, s, 0) != null) return error.Invalid;
        return try arena.dupeSentinel(u8, s, 0);
    }

    fn formatOidOut(oid: *const git2.Oid, out: *[64]u8) []const u8 {
        _ = git2.git_oid_fmt(out, oid);
        return out[0..git2.oid_hex_len];
    }

    fn lookupCommitByOid(repo: *git2.Repository, oid: *const git2.Oid) ?*git2.Commit {
        var commit: ?*git2.Commit = null;
        if (git2.git_commit_lookup(&commit, repo, oid) == git2.ok) return commit;
        var obj: ?*git2.Object = null;
        if (git2.git_object_lookup(&obj, repo, oid, git2.obj_any) != git2.ok) return null;
        defer git2.git_object_free(obj.?);
        var peeled: ?*git2.Object = null;
        if (git2.git_object_peel(&peeled, obj.?, git2.obj_commit) != git2.ok) return null;
        const peeled_oid = git2.git_object_id(peeled.?).*;
        git2.git_object_free(peeled.?);
        if (git2.git_commit_lookup(&commit, repo, &peeled_oid) == git2.ok) return commit;
        return null;
    }

    fn lookupCommit(repo: *git2.Repository, rev: []const u8) ?*git2.Commit {
        if (git2.parseOid(rev)) |oid| {
            if (lookupCommitByOid(repo, &oid)) |commit| return commit;
        }
        if (std.mem.startsWith(u8, rev, "refs/")) {
            var buf: [512]u8 = undefined;
            const ref_z = toCStringBuf(&buf, rev) orelse return null;
            var oid: git2.Oid = .{};
            if (git2.git_reference_name_to_id(&oid, repo, ref_z.ptr) != git2.ok) return null;
            return lookupCommitByOid(repo, &oid);
        }
        var buf: [512]u8 = undefined;
        const rev_z = toCStringBuf(&buf, rev) orelse return null;
        var obj: ?*git2.Object = null;
        if (git2.git_revparse_single(&obj, repo, rev_z.ptr) != git2.ok) return null;
        defer git2.git_object_free(obj.?);
        var peeled: ?*git2.Object = null;
        if (git2.git_object_peel(&peeled, obj.?, git2.obj_commit) != git2.ok) return null;
        const oid = git2.git_object_id(peeled.?).*;
        git2.git_object_free(peeled.?);
        var commit: ?*git2.Commit = null;
        if (git2.git_commit_lookup(&commit, repo, &oid) == git2.ok) return commit;
        return null;
    }

    fn lookupRootTree(repo: *git2.Repository, rev: []const u8) ?*git2.Tree {
        if (lookupCommit(repo, rev)) |commit| {
            defer git2.git_commit_free(commit);
            var tree: ?*git2.Tree = null;
            if (git2.git_commit_tree(&tree, commit) == git2.ok) return tree;
            return null;
        }
        if (git2.parseOid(rev)) |oid| {
            var tree: ?*git2.Tree = null;
            if (git2.git_tree_lookup(&tree, repo, &oid) == git2.ok) return tree;
        }
        return null;
    }

    fn lookupTreeObject(repo: *git2.Repository, rev: []const u8) ?*git2.Tree {
        if (git2.parseOid(rev)) |oid| {
            var tree: ?*git2.Tree = null;
            if (git2.git_tree_lookup(&tree, repo, &oid) == git2.ok) return tree;
        }
        var buf: [512]u8 = undefined;
        const rev_z = toCStringBuf(&buf, rev) orelse return null;
        var obj: ?*git2.Object = null;
        if (git2.git_revparse_single(&obj, repo, rev_z.ptr) != git2.ok) return null;
        defer git2.git_object_free(obj.?);
        var peeled: ?*git2.Object = null;
        if (git2.git_object_peel(&peeled, obj.?, git2.obj_tree) != git2.ok) return null;
        const oid = git2.git_object_id(peeled.?).*;
        git2.git_object_free(peeled.?);
        var tree: ?*git2.Tree = null;
        if (git2.git_tree_lookup(&tree, repo, &oid) == git2.ok) return tree;
        return null;
    }

    fn lookupBlobOid(repo: *git2.Repository, oid_or_rev: []const u8) ?git2.Oid {
        if (git2.parseOid(oid_or_rev)) |oid| return oid;
        var buf: [512]u8 = undefined;
        const rev_z = toCStringBuf(&buf, oid_or_rev) orelse return null;
        var obj: ?*git2.Object = null;
        if (git2.git_revparse_single(&obj, repo, rev_z.ptr) != git2.ok) return null;
        defer git2.git_object_free(obj.?);
        return git2.git_object_id(obj.?).*;
    }

    const TreeEntryInfo = struct {
        oid: git2.Oid,
        mode: c_int,
    };

    fn lookupTreeEntryInfo(tree: *const git2.Tree, path_z: [:0]const u8) git_cmd.Error!?TreeEntryInfo {
        var entry: ?*git2.TreeEntry = null;
        const rc = git2.git_tree_entry_bypath(&entry, tree, path_z.ptr);
        if (rc == git2.err_not_found) return null;
        if (rc != git2.ok) return error.GitFailed;
        defer git2.git_tree_entry_free(entry.?);
        return .{
            .oid = git2.git_tree_entry_id(entry.?).*,
            .mode = git2.git_tree_entry_filemode(entry.?),
        };
    }

    fn commitTouchesPath(commit: *const git2.Commit, path_z: [:0]const u8) git_cmd.Error!bool {
        var c_tree: ?*git2.Tree = null;
        if (git2.git_commit_tree(&c_tree, commit) != git2.ok) return error.GitFailed;
        defer git2.git_tree_free(c_tree.?);

        const c_info = try lookupTreeEntryInfo(c_tree.?, path_z);
        const pcount = git2.git_commit_parentcount(commit);
        if (pcount == 0) return c_info != null;

        for (0..pcount) |pi| {
            var parent: ?*git2.Commit = null;
            if (git2.git_commit_parent(&parent, commit, @intCast(pi)) != git2.ok) return error.GitFailed;
            defer git2.git_commit_free(parent.?);

            var p_tree: ?*git2.Tree = null;
            if (git2.git_commit_tree(&p_tree, parent.?) != git2.ok) return error.GitFailed;
            defer git2.git_tree_free(p_tree.?);

            const p_info = try lookupTreeEntryInfo(p_tree.?, path_z);
            const same = if (c_info) |ci|
                (p_info != null and ci.mode == p_info.?.mode and std.mem.eql(u8, &ci.oid.id, &p_info.?.oid.id))
            else
                p_info == null;
            // TREESAME to any parent means this commit did not introduce a change to `path`.
            if (same) return false;
        }
        return true;
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

    pub const ObjectStats = struct {
        objects_loose: u64 = 0,
        size_loose_kb: u64 = 0,
        objects_packed: u64 = 0,
        size_pack_kb: u64 = 0,
    };

    pub fn countObjects(r: *const Repo) git_cmd.Error!ObjectStats {
        const raw = try r.gitOutput(&.{ "count-objects", "-v" }, .{});
        defer r.gpa.free(raw);
        return parseCountObjects(raw);
    }

    /// Runs `git gc --quiet` with the configured prune grace period
    /// (0 = prune immediately). Inherits hooks-off and no-detach from gitEnv (R2.4, R3.4).
    pub fn gc(r: *const Repo, prune_seconds: u32) git_cmd.Error!void {
        var arg_buf: [40]u8 = undefined;
        const prune_arg = if (prune_seconds == 0)
            "--prune=now"
        else
            std.mem.print(&arg_buf, "--prune={d}.seconds.ago", .{prune_seconds}) catch unreachable;
        r.gpa.free(try r.gitOutput(&.{ "gc", "--quiet", prune_arg }, .{ .timeout_ms = 120_000 }));
    }
};

/// Parses `git count-objects -v` key/value output.
pub fn parseCountObjects(raw: []const u8) Repo.ObjectStats {
    var out: Repo.ObjectStats = .{};
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t\r");
        const val_str = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        const val = std.fmt.parseInt(u64, val_str, 10) catch continue;
        if (std.mem.eql(u8, key, "count")) {
            out.objects_loose = val;
        } else if (std.mem.eql(u8, key, "size")) {
            out.size_loose_kb = val;
        } else if (std.mem.eql(u8, key, "in-pack")) {
            out.objects_packed = val;
        } else if (std.mem.eql(u8, key, "size-pack")) {
            out.size_pack_kb = val;
        }
    }
    return out;
}

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

test "parseCountObjects extracts loose and packed stats" {
    const sample =
        \\count: 14
        \\size: 56
        \\in-pack: 420
        \\packs: 1
        \\size-pack: 1280
        \\prune-packable: 0
        \\garbage: 0
        \\
    ;
    const stats = parseCountObjects(sample);
    try std.testing.expectEqual(@as(u64, 14), stats.objects_loose);
    try std.testing.expectEqual(@as(u64, 56), stats.size_loose_kb);
    try std.testing.expectEqual(@as(u64, 420), stats.objects_packed);
    try std.testing.expectEqual(@as(u64, 1280), stats.size_pack_kb);
}

test "fuzz parse count-objects" {
    try std.testing.fuzz({}, fuzzParseCountObjects, .{
        .corpus = &.{
            "count: 1\nsize: 4\nin-pack: 10\nsize-pack: 8\n",
            "garbage line without colon\ncount: notanumber\n",
        },
    });
}

fn fuzzParseCountObjects(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    _ = parseCountObjects(input);
}

test "libgit2 buildCommit, lsTree, readBlob, log, listBranches, updateRef, and git fsck" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repos");
    try tmp.dir.createDirPath(io, "tmp");
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const repos_dir = try std.mem.concat(gpa, u8, &.{ base, "/repos" });
    defer gpa.free(repos_dir);
    const tmp_dir = try std.mem.concat(gpa, u8, &.{ base, "/tmp" });
    defer gpa.free(tmp_dir);

    const store: store_mod.Store = .{
        .root = repos_dir,
        .tmp = tmp_dir,
        .path_env = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
    };
    const name = try repo_name.parse("acme/test");
    try store.create(io, gpa, name);
    const repo = try Repo.open(io, gpa, &store, name);

    var ref_buf: [64]u8 = undefined;
    // Unborn main/HEAD returns null.
    try std.testing.expect((try repo.refValue("refs/heads/main", &ref_buf)) == null);
    try std.testing.expect((try repo.refValue("HEAD", &ref_buf)) == null);
    try std.testing.expect((try repo.resolveCommit("refs/heads/main", &ref_buf)) == null);

    const author: Repo.Author = .{ .name = "Agent One", .email = "a1@example.com" };

    // Path safety: `.git` segment rejected without touching repo.
    try std.testing.expectError(
        error.PathRejected,
        repo.buildCommit(null, &.{.{ .path = ".git/config", .content = "bad" }}, "bad", author, &ref_buf),
    );

    // Root commit with nested directories and an empty blob.
    var c1_buf: [64]u8 = undefined;
    const c1 = try repo.buildCommit(null, &.{
        .{ .path = "README.md", .content = "hello\n" },
        .{ .path = "src/main.zig", .content = "pub fn main() void {}\n" },
        .{ .path = "src/empty.txt", .content = "" },
        .{ .path = "docs/guide/intro.md", .content = "guide\n" },
    }, "initial commit\n\nDetailed body.", author, &c1_buf);
    try std.testing.expectEqual(@as(usize, 40), c1.len);

    // CAS create + stale second create.
    try std.testing.expectEqual(Repo.RefUpdate.updated, try repo.updateRef("refs/heads/main", c1, null));
    try std.testing.expectEqual(Repo.RefUpdate.stale, try repo.updateRef("refs/heads/main", c1, null));

    // refValue & resolveCommit work through HEAD and refs/heads/main.
    var h_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(c1, (try repo.refValue("HEAD", &h_buf)).?);
    try std.testing.expectEqualStrings(c1, (try repo.resolveCommit("HEAD", &h_buf)).?);
    try std.testing.expectEqualStrings(c1, (try repo.resolveCommit("main", &h_buf)).?);

    // Non-existent ref CAS update returns .stale, never recreates missing branch.
    try std.testing.expectEqual(Repo.RefUpdate.stale, try repo.updateRef("refs/heads/ghost", c1, c1));
    try std.testing.expect((try repo.refValue("refs/heads/ghost", &h_buf)) == null);

    // Same-OID CAS update succeeds cleanly.
    try std.testing.expectEqual(Repo.RefUpdate.updated, try repo.updateRef("refs/heads/main", c1, c1));

    // Commit 2: update file, delete last file in `docs/guide`, replace file<->dir, duplicate path in slice,
    // plus no-op deletion under a blob path (`README.md/nope` must NOT delete `README.md`).
    var c2_buf: [64]u8 = undefined;
    const c2 = try repo.buildCommit(c1, &.{
        .{ .path = "docs/guide/intro.md", .content = null },
        .{ .path = "README.md/nope", .content = null },
        .{ .path = "src/empty.txt", .content = "tmp" },
        .{ .path = "src/empty.txt", .content = "replaced" },
        .{ .path = "src/empty.txt/nested.txt", .content = "dir now" },
        .{ .path = "docs/v2.md", .content = "v2" },
        .{ .path = "z_gone.txt", .content = null },
    }, "second commit", author, &c2_buf);
    try std.testing.expectEqual(Repo.RefUpdate.updated, try repo.updateRef("refs/heads/main", c2, c1));

    // Deleting a non-empty subtree via missing parent dir/tree: verify `docs/guide` was pruned!
    const root_entries = try repo.lsTree(c2, null, false);
    defer root_entries.deinit(gpa);
    var saw_docs = false;
    var saw_readme = false;
    var readme_oid: []const u8 = "";
    for (root_entries.items) |e| {
        if (std.mem.eql(u8, e.path, "docs")) saw_docs = true;
        if (std.mem.eql(u8, e.path, "README.md")) {
            saw_readme = true;
            readme_oid = e.oid;
            try std.testing.expectEqual(Repo.EntryKind.blob, e.kind);
            try std.testing.expectEqual(@as(?u64, 6), e.size);
        }
    }
    try std.testing.expect(saw_docs);
    try std.testing.expect(saw_readme);

    // Note `c1` commit tree still works, and `docs` at `c2` only contains `v2.md` (`docs/guide` pruned).
    const docs_entries = try repo.lsTree(c2, "docs", false);
    defer docs_entries.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), docs_entries.items.len);
    try std.testing.expectEqualStrings("docs/v2.md", docs_entries.items[0].path);

    // Exact entry & non-exact on a blob path returns empty, missing returns empty.
    const exact_nested = try repo.lsTree(c2, "src/empty.txt/nested.txt", true);
    defer exact_nested.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), exact_nested.items.len);
    try std.testing.expectEqual(Repo.EntryKind.blob, exact_nested.items[0].kind);
    try std.testing.expectEqual(@as(?u64, 7), exact_nested.items[0].size);

    // Blob size limits: exact max succeeds, max - 1 returns OutputTooLarge.
    const readme_bytes = try repo.readBlob(readme_oid, 6);
    defer gpa.free(readme_bytes);
    try std.testing.expectEqualStrings("hello\n", readme_bytes);
    try std.testing.expectError(error.OutputTooLarge, repo.readBlob(readme_oid, 5));
    // resolveCommit rejects blob OID.
    try std.testing.expect((try repo.resolveCommit(readme_oid, &h_buf)) == null);

    const blob_as_dir = try repo.lsTree(c2, "README.md", false);
    defer blob_as_dir.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), blob_as_dir.items.len);

    // Branch listing ordered alphabetically, with commit metadata.
    var c_feat_buf: [64]u8 = undefined;
    const c_feat = try repo.buildCommit(c1, &.{
        .{ .path = "feat.txt", .content = "feature" },
    }, "feature work", author, &c_feat_buf);
    try std.testing.expectEqual(Repo.RefUpdate.updated, try repo.updateRef("refs/heads/alpha", c_feat, null));

    const branches = try repo.listBranches();
    defer branches.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), branches.items.len);
    try std.testing.expectEqualStrings("alpha", branches.items[0].name);
    try std.testing.expectEqualStrings(c_feat, branches.items[0].commit);
    try std.testing.expectEqualStrings("feature work", branches.items[0].subject);
    try std.testing.expectEqualStrings("main", branches.items[1].name);
    try std.testing.expectEqualStrings(c2, branches.items[1].commit);
    try std.testing.expectEqualStrings("second commit", branches.items[1].subject);

    // Two-parent commit via commitTree + path-filtered log + single log.
    const c2_tree = (try repo.lsTree(c2, null, false));
    c2_tree.deinit(gpa);
    const rev_tree_raw = try repo.gitOutput(&.{ "rev-parse", "--verify", "main^{tree}" }, .{});
    defer gpa.free(rev_tree_raw);
    const tree_sha = std.mem.trimEnd(u8, rev_tree_raw, "\n");
    var merge_buf: [64]u8 = undefined;
    const merge_sha = try repo.commitTree(tree_sha, &.{ c2, c_feat }, "merge alpha", author, &merge_buf);
    try std.testing.expectEqual(Repo.RefUpdate.updated, try repo.updateRef("refs/heads/main", merge_sha, c2));

    const single_log = try repo.log(c1, 10, null, true);
    defer single_log.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), single_log.items.len);
    try std.testing.expectEqualStrings(c1, single_log.items[0].sha);
    try std.testing.expectEqualStrings("", single_log.items[0].parents);
    try std.testing.expectEqualStrings("Agent One", single_log.items[0].author_name);
    try std.testing.expectEqualStrings("initial commit", single_log.items[0].subject);
    try std.testing.expectEqualStrings("Detailed body.", single_log.items[0].body);

    // Path-filtered log on `docs` dir finds both c2 (`docs/v2.md` + deleted `docs/guide`) and c1 (`docs/guide/intro.md`),
    // skipping merge_sha because merge_sha's `docs` tree matches `c2`!
    const docs_log = try repo.log(merge_sha, 10, "docs", false);
    defer docs_log.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), docs_log.items.len);
    try std.testing.expectEqualStrings(c2, docs_log.items[0].sha);
    try std.testing.expectEqualStrings(c1, docs_log.items[1].sha);

    // Annotated tag resolves cleanly by ref name and by raw tag OID, and works with lsTree.
    gpa.free(try repo.gitOutput(
        &.{ "tag", "-a", "v1", "-m", "release", c1 },
        .{ .env = &.{ .{ "GIT_COMMITTER_NAME", "gitd" }, .{ "GIT_COMMITTER_EMAIL", "gitd@localhost" } } },
    ));
    const tag_raw = try repo.gitOutput(&.{ "rev-parse", "--verify", "refs/tags/v1" }, .{});
    defer gpa.free(tag_raw);
    const tag_oid = std.mem.trimEnd(u8, tag_raw, "\n");
    try std.testing.expectEqualStrings(c1, (try repo.resolveCommit("refs/tags/v1", &h_buf)).?);
    try std.testing.expectEqualStrings(c1, (try repo.resolveCommit(tag_oid, &h_buf)).?);
    const tag_tree = try repo.lsTree("refs/tags/v1", null, false);
    defer tag_tree.deinit(gpa);
    try std.testing.expect(tag_tree.items.len > 0);

    // CAS delete & unconditional delete.
    try std.testing.expectEqual(Repo.RefUpdate.stale, try repo.updateRef("refs/heads/alpha", null, c1));
    try std.testing.expectEqual(Repo.RefUpdate.updated, try repo.updateRef("refs/heads/alpha", null, c_feat));
    try std.testing.expect((try repo.refValue("refs/heads/alpha", &h_buf)) == null);
    try std.testing.expectEqual(Repo.RefUpdate.updated, try repo.updateRef("refs/heads/alpha", null, null));

    // Real git fsck verifies every tree/blob/commit created in-process is 100% valid.
    const fsck_out = try repo.gitOutput(&.{ "fsck", "--strict", "--full" }, .{});
    gpa.free(fsck_out);
}
