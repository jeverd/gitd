//! Hand-declared C ABI bindings for libgit2 (1.5+).
//!
//! Avoids `@cImport` per Zig 0.17 conventions and isolates process-wide global
//! initialization: external config search paths are cleared (R2.4), strict
//! object creation and hash verification are enabled (R2.3), and owner
//! validation is disabled for container/service-owned bare repositories.

const std = @import("std");

pub const Repository = opaque {};
pub const Commit = opaque {};
pub const Tree = opaque {};
pub const TreeBuilder = opaque {};
pub const TreeEntry = opaque {};
pub const Reference = opaque {};
pub const ReferenceIterator = opaque {};
pub const Revwalk = opaque {};
pub const Blob = opaque {};
pub const Object = opaque {};
pub const Odb = opaque {};
pub const Indexer = opaque {};
pub const Packbuilder = opaque {};

pub const PackbuilderForeachCb = *const fn (?*anyopaque, usize, ?*anyopaque) callconv(.c) c_int;

pub const IndexerProgress = extern struct {
    total_objects: c_uint = 0,
    indexed_objects: c_uint = 0,
    received_objects: c_uint = 0,
    local_objects: c_uint = 0,
    total_deltas: c_uint = 0,
    indexed_deltas: c_uint = 0,
    received_bytes: usize = 0,
};

pub const IndexerProgressCb = ?*const fn (*const IndexerProgress, ?*anyopaque) callconv(.c) c_int;

pub const IndexerOptions = extern struct {
    version: c_uint = 1,
    progress_cb: IndexerProgressCb = null,
    progress_cb_payload: ?*anyopaque = null,
    verify: u8 = 0,
};

pub const oid_raw_len = 20;
pub const oid_hex_len = 40;

pub const Oid = extern struct {
    id: [oid_raw_len]u8 = @splat(0),
};

pub const Time = extern struct {
    time: i64,
    offset: c_int,
    sign: u8,
};

pub const Signature = extern struct {
    name: [*:0]const u8,
    email: [*:0]const u8,
    when: Time,
};

pub const GitError = extern struct {
    message: [*:0]const u8,
    klass: c_int,
};

// Error codes from <git2/errors.h>
pub const ok: c_int = 0;
pub const err_not_found: c_int = -3;
pub const err_exists: c_int = -4;
pub const err_ambiguous: c_int = -5;
pub const err_bufs: c_int = -6;
pub const err_unborn_branch: c_int = -9;
pub const err_invalid_spec: c_int = -12;
pub const err_locked: c_int = -14;
pub const err_modified: c_int = -15;
pub const err_invalid: c_int = -21;
pub const err_iter_over: c_int = -31;

// Object types from <git2/types.h>
pub const obj_any: c_int = -2;
pub const obj_invalid: c_int = -1;
pub const obj_commit: c_int = 1;
pub const obj_tree: c_int = 2;
pub const obj_blob: c_int = 3;
pub const obj_tag: c_int = 4;

// File modes from <git2/types.h>
pub const mode_tree: c_int = 0o040000;
pub const mode_blob: c_int = 0o100644;
pub const mode_blob_executable: c_int = 0o100755;
pub const mode_link: c_int = 0o120000;
pub const mode_commit: c_int = 0o160000;

// Reference types from <git2/types.h>
pub const ref_direct: c_int = 1;
pub const ref_symbolic: c_int = 2;

// Revwalk sort modes from <git2/revwalk.h>
pub const sort_none: c_uint = 0;
pub const sort_topological: c_uint = 1 << 0;
pub const sort_time: c_uint = 1 << 1;

// Feature flags from <git2/common.h>
pub const feature_threads: c_int = 1 << 0;

// Global option keys from <git2/common.h>
pub const opt_set_search_path: c_int = 5;
pub const opt_enable_strict_object_creation: c_int = 14;
pub const opt_enable_strict_hash_verification: c_int = 22;
pub const opt_set_owner_validation: c_int = 36;

// Config levels from <git2/config.h>
pub const config_programdata: c_int = 1;
pub const config_system: c_int = 2;
pub const config_xdg: c_int = 3;
pub const config_global: c_int = 4;

pub extern fn git_libgit2_init() c_int;
pub extern fn git_libgit2_shutdown() c_int;
pub extern fn git_libgit2_features() c_int;
pub extern fn git_libgit2_opts(option: c_int, ...) c_int;
pub extern fn git_error_last() ?*const GitError;

pub extern fn git_oid_fromstr(out: *Oid, str: [*]const u8) c_int;
pub extern fn git_oid_fmt(out: [*]u8, id: *const Oid) c_int;

pub extern fn git_repository_open_bare(out: *?*Repository, bare_path: [*:0]const u8) c_int;
pub extern fn git_repository_free(repo: *Repository) void;
pub extern fn git_repository_odb(out: *?*Odb, repo: *Repository) c_int;

pub extern fn git_reference_lookup(out: *?*Reference, repo: *Repository, name: [*:0]const u8) c_int;
pub extern fn git_reference_name_to_id(out: *Oid, repo: *Repository, name: [*:0]const u8) c_int;
pub extern fn git_reference_create(
    out: *?*Reference,
    repo: *Repository,
    name: [*:0]const u8,
    id: *const Oid,
    force: c_int,
    log_message: ?[*:0]const u8,
) c_int;
pub extern fn git_reference_set_target(
    out: *?*Reference,
    ref: *Reference,
    id: *const Oid,
    log_message: ?[*:0]const u8,
) c_int;
pub extern fn git_reference_resolve(out: *?*Reference, ref: *const Reference) c_int;
pub extern fn git_reference_target(ref: *const Reference) ?*const Oid;
pub extern fn git_reference_symbolic_target(ref: *const Reference) ?[*:0]const u8;
pub extern fn git_reference_type(ref: *const Reference) c_int;
pub extern fn git_reference_name(ref: *const Reference) [*:0]const u8;
pub extern fn git_reference_delete(ref: *Reference) c_int;
pub extern fn git_reference_remove(repo: *Repository, name: [*:0]const u8) c_int;
pub extern fn git_reference_free(ref: *Reference) void;
pub extern fn git_reference_iterator_glob_new(
    out: *?*ReferenceIterator,
    repo: *Repository,
    glob: [*:0]const u8,
) c_int;
pub extern fn git_reference_next(out: *?*Reference, iter: *ReferenceIterator) c_int;
pub extern fn git_reference_iterator_free(iter: *ReferenceIterator) void;

pub extern fn git_revparse_single(out: *?*Object, repo: *Repository, spec: [*:0]const u8) c_int;
pub extern fn git_object_lookup(object: *?*Object, repo: *Repository, id: *const Oid, obj_type: c_int) c_int;
pub extern fn git_object_type(obj: *const Object) c_int;
pub extern fn git_object_peel(peeled: *?*Object, object: *const Object, target_type: c_int) c_int;
pub extern fn git_object_id(obj: *const Object) *const Oid;
pub extern fn git_object_free(object: *Object) void;

pub extern fn git_commit_lookup(commit: *?*Commit, repo: *Repository, id: *const Oid) c_int;
pub extern fn git_commit_free(commit: *Commit) void;
pub extern fn git_commit_id(commit: *const Commit) *const Oid;
pub extern fn git_commit_summary(commit: *Commit) ?[*:0]const u8;
pub extern fn git_commit_body(commit: *Commit) ?[*:0]const u8;
pub extern fn git_commit_time(commit: *const Commit) i64;
pub extern fn git_commit_author(commit: *const Commit) *const Signature;
pub extern fn git_commit_tree(tree_out: *?*Tree, commit: *const Commit) c_int;
pub extern fn git_commit_parentcount(commit: *const Commit) c_uint;
pub extern fn git_commit_parent(out: *?*Commit, commit: *const Commit, n: c_uint) c_int;
pub extern fn git_commit_parent_id(commit: *const Commit, n: c_uint) ?*const Oid;
pub extern fn git_commit_create(
    id: *Oid,
    repo: *Repository,
    update_ref: ?[*:0]const u8,
    author: *const Signature,
    committer: *const Signature,
    message_encoding: ?[*:0]const u8,
    message: [*:0]const u8,
    tree: *const Tree,
    parent_count: usize,
    parents: ?[*]const *const Commit,
) c_int;

pub extern fn git_tree_lookup(out: *?*Tree, repo: *Repository, id: *const Oid) c_int;
pub extern fn git_tree_free(tree: *Tree) void;
pub extern fn git_tree_entrycount(tree: *const Tree) usize;
pub extern fn git_tree_entry_byname(tree: *const Tree, filename: [*:0]const u8) ?*const TreeEntry;
pub extern fn git_tree_entry_byindex(tree: *const Tree, idx: usize) ?*const TreeEntry;
pub extern fn git_tree_entry_bypath(out: *?*TreeEntry, root: *const Tree, path: [*:0]const u8) c_int;
pub extern fn git_tree_entry_free(entry: *TreeEntry) void;
pub extern fn git_tree_entry_name(entry: *const TreeEntry) [*:0]const u8;
pub extern fn git_tree_entry_id(entry: *const TreeEntry) *const Oid;
pub extern fn git_tree_entry_type(entry: *const TreeEntry) c_int;
pub extern fn git_tree_entry_filemode(entry: *const TreeEntry) c_int;

pub extern fn git_treebuilder_new(
    out: *?*TreeBuilder,
    repo: *Repository,
    source: ?*const Tree,
) c_int;
pub extern fn git_treebuilder_entrycount(bld: *TreeBuilder) usize;
pub extern fn git_treebuilder_free(bld: *TreeBuilder) void;
pub extern fn git_treebuilder_get(bld: *TreeBuilder, filename: [*:0]const u8) ?*const TreeEntry;
pub extern fn git_treebuilder_insert(
    out: ?*?*const TreeEntry,
    bld: *TreeBuilder,
    filename: [*:0]const u8,
    id: *const Oid,
    filemode: c_int,
) c_int;
pub extern fn git_treebuilder_remove(bld: *TreeBuilder, filename: [*:0]const u8) c_int;
pub extern fn git_treebuilder_write(id: *Oid, bld: *TreeBuilder) c_int;

pub extern fn git_blob_lookup(blob: *?*Blob, repo: *Repository, id: *const Oid) c_int;
pub extern fn git_blob_free(blob: *Blob) void;
pub extern fn git_blob_rawcontent(blob: *const Blob) ?*const anyopaque;
pub extern fn git_blob_rawsize(blob: *const Blob) u64;
pub extern fn git_blob_create_from_buffer(
    id: *Oid,
    repo: *Repository,
    buffer: *const anyopaque,
    len: usize,
) c_int;

pub extern fn git_odb_free(db: *Odb) void;
pub extern fn git_odb_exists(db: *Odb, id: *const Oid) c_int;
pub extern fn git_odb_refresh(db: *Odb) c_int;
pub extern fn git_odb_read_header(
    len_out: *usize,
    type_out: *c_int,
    db: *Odb,
    id: *const Oid,
) c_int;

pub extern fn git_indexer_options_init(opts: *IndexerOptions, version: c_uint) c_int;
pub extern fn git_indexer_new(
    out: *?*Indexer,
    path: [*:0]const u8,
    mode: c_uint,
    odb: ?*Odb,
    opts: ?*IndexerOptions,
) c_int;
pub extern fn git_indexer_append(
    idx: *Indexer,
    data: *const anyopaque,
    size: usize,
    stats: *IndexerProgress,
) c_int;
pub extern fn git_indexer_commit(idx: *Indexer, stats: *IndexerProgress) c_int;
pub extern fn git_indexer_free(idx: *Indexer) void;

pub extern fn git_graph_ahead_behind(
    ahead: *usize,
    behind: *usize,
    repo: *Repository,
    local: *const Oid,
    upstream: *const Oid,
) c_int;
pub extern fn git_graph_descendant_of(
    repo: *Repository,
    commit: *const Oid,
    ancestor: *const Oid,
) c_int;
pub extern fn git_merge_base(
    out: *Oid,
    repo: *Repository,
    one: *const Oid,
    two: *const Oid,
) c_int;

pub extern fn git_signature_new(
    out: *?*Signature,
    name: [*:0]const u8,
    email: [*:0]const u8,
    time: i64,
    offset: c_int,
) c_int;
pub extern fn git_signature_now(
    out: *?*Signature,
    name: [*:0]const u8,
    email: [*:0]const u8,
) c_int;
pub extern fn git_signature_free(sig: *Signature) void;

pub extern fn git_revwalk_new(out: *?*Revwalk, repo: *Repository) c_int;
pub extern fn git_revwalk_sorting(walk: *Revwalk, sort_mode: c_uint) c_int;
pub extern fn git_revwalk_push(walk: *Revwalk, id: *const Oid) c_int;
pub extern fn git_revwalk_hide(walk: *Revwalk, id: *const Oid) c_int;
pub extern fn git_revwalk_next(out: *Oid, walk: *Revwalk) c_int;
pub extern fn git_revwalk_free(walk: *Revwalk) void;

pub extern fn git_packbuilder_new(out: *?*Packbuilder, repo: *Repository) c_int;
pub extern fn git_packbuilder_set_threads(pb: *Packbuilder, n: c_uint) c_uint;
pub extern fn git_packbuilder_insert(pb: *Packbuilder, id: *const Oid, name: ?[*:0]const u8) c_int;
pub extern fn git_packbuilder_insert_commit(pb: *Packbuilder, id: *const Oid) c_int;
pub extern fn git_packbuilder_insert_walk(pb: *Packbuilder, walk: *Revwalk) c_int;
pub extern fn git_packbuilder_foreach(pb: *Packbuilder, cb: PackbuilderForeachCb, payload: ?*anyopaque) c_int;
pub extern fn git_packbuilder_free(pb: *Packbuilder) void;

const InitState = enum(u8) { uninit = 0, initing = 1, ready = 2 };
var init_state: std.atomic.Value(u8) = .init(@backingInt(InitState.uninit));

pub const Error = error{Git2InitFailed};

/// Initializes libgit2 once per process and hardens global options (R2.3, R2.4).
pub fn ensureInit() Error!void {
    while (true) {
        const s: InitState = @fromBackingInt(@intCast(init_state.load(.acquire)));
        switch (s) {
            .ready => return,
            .initing => std.atomic.spinLoopHint(),
            .uninit => {
                if (init_state.cmpxchgWeak(
                    @backingInt(InitState.uninit),
                    @backingInt(InitState.initing),
                    .acq_rel,
                    .acquire,
                ) != null) continue;
                errdefer init_state.store(@backingInt(InitState.uninit), .release);

                if (git_libgit2_init() < 0) return error.Git2InitFailed;
                errdefer _ = git_libgit2_shutdown();

                if ((git_libgit2_features() & feature_threads) == 0) return error.Git2InitFailed;

                // Disable system/global/XDG/ProgramData gitconfig and attributes
                // so host configuration cannot affect server behavior (R2.4).
                for ([_]c_int{
                    config_programdata,
                    config_system,
                    config_xdg,
                    config_global,
                }) |level| {
                    if (git_libgit2_opts(opt_set_search_path, level, @as([*:0]const u8, "")) != ok) {
                        return error.Git2InitFailed;
                    }
                }
                if (git_libgit2_opts(opt_enable_strict_object_creation, @as(c_int, 1)) != ok) {
                    return error.Git2InitFailed;
                }
                if (git_libgit2_opts(opt_enable_strict_hash_verification, @as(c_int, 1)) != ok) {
                    return error.Git2InitFailed;
                }
                // Service owns bare repos under GITD_DATA; allow container/uid mismatch if any.
                if (git_libgit2_opts(opt_set_owner_validation, @as(c_int, 0)) != ok) {
                    return error.Git2InitFailed;
                }

                init_state.store(@backingInt(InitState.ready), .release);
                return;
            },
        }
    }
}

/// Explicit startup hook for `gitd serve`. Pairs with `deinit()`.
pub fn init() Error!void {
    return ensureInit();
}

/// Tears down global libgit2 state once workers have exited.
pub fn deinit() void {
    if (init_state.swap(@backingInt(InitState.uninit), .acq_rel) == @backingInt(InitState.ready)) {
        _ = git_libgit2_shutdown();
    }
}

/// Returns the last libgit2 error message on the calling thread.
pub fn lastErrorMessage() []const u8 {
    const err = git_error_last() orelse return "unknown libgit2 error";
    return std.mem.span(err.message);
}

/// Opens a bare repository at `path` (which must not contain NUL bytes).
pub fn openBare(path: []const u8) ?*Repository {
    ensureInit() catch return null;
    if (std.mem.findScalar(u8, path, 0) != null) return null;
    var buf: [4097]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var repo: ?*Repository = null;
    if (git_repository_open_bare(&repo, buf[0..path.len :0]) != ok) return null;
    return repo;
}

/// Parses a 40-char hex SHA-1 string into `Oid`.
pub fn parseOid(hex: []const u8) ?Oid {
    if (hex.len != oid_hex_len) return null;
    for (hex) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return null,
        }
    }
    var out: Oid = .{};
    if (git_oid_fromstr(&out, hex.ptr) != ok) return null;
    return out;
}

/// Formats `oid` into 40 lowercase hex bytes in `buf`.
pub fn formatOid(oid: *const Oid, buf: *[oid_hex_len]u8) []const u8 {
    _ = git_oid_fmt(buf, oid);
    return buf;
}

test "ensureInit configures options and parseOid / formatOid round-trip" {
    try ensureInit();
    const hex = "0123456789abcdef0123456789abcdef01234567";
    const parsed = parseOid(hex) orelse return error.TestUnexpectedResult;
    var out: [oid_hex_len]u8 = undefined;
    try std.testing.expectEqualStrings(hex, formatOid(&parsed, &out));
    try std.testing.expect(parseOid("short") == null);
    try std.testing.expect(parseOid("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz") == null);
    try std.testing.expect(openBare("/nonexistent/repo.git") == null);
    try std.testing.expect(lastErrorMessage().len > 0);
}
