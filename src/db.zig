//! SQLite metadata store (R1.3): repos and admin keys.
//!
//! The sqlite3 functions are declared by hand instead of translating
//! `sqlite3.h`, so gitd needs no translate-c package (R4.1). Only what gitd
//! calls is declared.
//!
//! One connection is shared by all requests. `mutex` guards every use of it,
//! because statements and `sqlite3_errmsg` belong to the connection.

const std = @import("std");
const Io = std.Io;

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close_v2(db: *sqlite3) c_int;
extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, len: c_int, stmt: *?*sqlite3_stmt, tail: ?*?[*]const u8) c_int;
extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, index: c_int, text: [*]const u8, len: c_int, destructor: ?*const anyopaque) c_int;
extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, index: c_int, value: i64) c_int;
extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_column_text(stmt: *sqlite3_stmt, col: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, col: c_int) c_int;
extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, col: c_int) i64;
extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
extern fn sqlite3_busy_timeout(db: *sqlite3, ms: c_int) c_int;
extern fn sqlite3_changes(db: *sqlite3) c_int;
extern fn sqlite3_last_insert_rowid(db: *sqlite3) i64;

const SQLITE_OK = 0;
const SQLITE_CONSTRAINT = 19;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_OPEN_READWRITE = 0x00000002;
const SQLITE_OPEN_CREATE = 0x00000004;
const SQLITE_OPEN_FULLMUTEX = 0x00010000;
/// Binding with a null destructor (SQLITE_STATIC) means sqlite does not copy
/// the text. Every bound slice outlives the `step` that reads it.
const SQLITE_STATIC: ?*const anyopaque = null;

pub const Error = error{ DatabaseError, OutOfMemory };

const schema =
    \\PRAGMA journal_mode = WAL;
    \\PRAGMA synchronous = NORMAL;
    \\CREATE TABLE IF NOT EXISTS repos (
    \\  name TEXT PRIMARY KEY,
    \\  id TEXT NOT NULL UNIQUE,
    \\  created_at INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS events (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  repo TEXT NOT NULL,
    \\  kind TEXT NOT NULL,
    \\  ref TEXT NOT NULL DEFAULT '',
    \\  old TEXT NOT NULL DEFAULT '',
    \\  new TEXT NOT NULL DEFAULT '',
    \\  detail TEXT NOT NULL DEFAULT '',
    \\  created_at INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS api_keys (
    \\  id INTEGER PRIMARY KEY,
    \\  key_hash TEXT NOT NULL UNIQUE,
    \\  created_at INTEGER NOT NULL
    \\) STRICT;
;

pub const Db = struct {
    handle: *sqlite3,
    mutex: Io.Mutex = .init,

    /// Opens or creates the database at `path` and applies the schema.
    pub fn open(path: [:0]const u8) Error!Db {
        var handle: ?*sqlite3 = null;
        const flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
        if (sqlite3_open_v2(path.ptr, &handle, flags, null) != SQLITE_OK) {
            if (handle) |h| {
                std.log.err("sqlite open {s}: {s}", .{ path, sqlite3_errmsg(h) });
                _ = sqlite3_close_v2(h);
            }
            return error.DatabaseError;
        }
        var db: Db = .{ .handle = handle.? };
        errdefer db.close();
        _ = sqlite3_busy_timeout(db.handle, 5000);
        var errmsg: ?[*:0]u8 = null;
        if (sqlite3_exec(db.handle, schema, null, null, &errmsg) != SQLITE_OK) {
            std.log.err("sqlite schema: {s}", .{errmsg orelse "unknown error"});
            return error.DatabaseError;
        }
        return db;
    }

    pub fn close(db: *Db) void {
        _ = sqlite3_close_v2(db.handle);
        db.* = undefined;
    }

    pub const InsertRepoError = Error || error{AlreadyExists};

    /// `id` is random and never reused, so tokens for a deleted repo do not
    /// work on a new repo with the same name.
    pub fn insertRepo(db: *Db, io: Io, name: []const u8, id: []const u8, created_at: i64) InsertRepoError!void {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("INSERT INTO repos (name, id, created_at) VALUES (?1, ?2, ?3)");
        defer _ = sqlite3_finalize(stmt);
        try db.bindText(stmt, 1, name);
        try db.bindText(stmt, 2, id);
        try db.check(sqlite3_bind_int64(stmt, 3, created_at));
        switch (sqlite3_step(stmt)) {
            SQLITE_DONE => {},
            SQLITE_CONSTRAINT => return error.AlreadyExists,
            else => return db.fail("insert repo"),
        }
    }

    /// Returns whether a row was deleted.
    pub fn deleteRepo(db: *Db, io: Io, name: []const u8) Error!bool {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("DELETE FROM repos WHERE name = ?1");
        defer _ = sqlite3_finalize(stmt);
        try db.bindText(stmt, 1, name);
        if (sqlite3_step(stmt) != SQLITE_DONE) return db.fail("delete repo");
        return sqlite3_changes(db.handle) > 0;
    }

    pub const Repo = struct {
        /// `name` and `id` are owned by the allocator passed to the query;
        /// free them with `deinit`.
        name: []const u8,
        id: []const u8,
        created_at: i64,

        pub fn deinit(r: Repo, gpa: std.mem.Allocator) void {
            gpa.free(r.name);
            gpa.free(r.id);
        }
    };

    /// Returns the repo or null. The caller frees it with `Repo.deinit`.
    pub fn getRepo(db: *Db, io: Io, gpa: std.mem.Allocator, name: []const u8) Error!?Repo {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("SELECT name, id, created_at FROM repos WHERE name = ?1");
        defer _ = sqlite3_finalize(stmt);
        try db.bindText(stmt, 1, name);
        return switch (sqlite3_step(stmt)) {
            SQLITE_ROW => try readRepo(stmt, gpa),
            SQLITE_DONE => null,
            else => db.fail("get repo"),
        };
    }

    /// Returns every repo ordered by name. Free with `freeRepos`.
    pub fn listRepos(db: *Db, io: Io, gpa: std.mem.Allocator) Error![]Repo {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("SELECT name, id, created_at FROM repos ORDER BY name");
        defer _ = sqlite3_finalize(stmt);
        var list: std.ArrayList(Repo) = .empty;
        errdefer {
            for (list.items) |repo| repo.deinit(gpa);
            list.deinit(gpa);
        }
        while (true) switch (sqlite3_step(stmt)) {
            SQLITE_ROW => {
                const repo = try readRepo(stmt, gpa);
                list.append(gpa, repo) catch |err| {
                    repo.deinit(gpa);
                    return err;
                };
            },
            SQLITE_DONE => break,
            else => return db.fail("list repos"),
        };
        return list.toOwnedSlice(gpa);
    }

    pub fn freeRepos(gpa: std.mem.Allocator, repos: []const Repo) void {
        for (repos) |repo| repo.deinit(gpa);
        gpa.free(repos);
    }

    pub fn insertApiKey(db: *Db, io: Io, key_hash: []const u8, created_at: i64) Error!void {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("INSERT INTO api_keys (key_hash, created_at) VALUES (?1, ?2)");
        defer _ = sqlite3_finalize(stmt);
        try db.bindText(stmt, 1, key_hash);
        try db.check(sqlite3_bind_int64(stmt, 2, created_at));
        if (sqlite3_step(stmt) != SQLITE_DONE) return db.fail("insert api key");
    }

    pub fn apiKeyExists(db: *Db, io: Io, key_hash: []const u8) Error!bool {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("SELECT 1 FROM api_keys WHERE key_hash = ?1");
        defer _ = sqlite3_finalize(stmt);
        try db.bindText(stmt, 1, key_hash);
        return switch (sqlite3_step(stmt)) {
            SQLITE_ROW => true,
            SQLITE_DONE => false,
            else => db.fail("check api key"),
        };
    }

    /// One entry in the activity log: pushes, rejections, merges, and so
    /// on. The UI shows them and webhooks deliver them.
    pub const Event = struct {
        id: i64 = 0,
        repo: []const u8,
        kind: []const u8,
        ref: []const u8 = "",
        old: []const u8 = "",
        new: []const u8 = "",
        detail: []const u8 = "",
        created_at: i64,

        pub fn deinit(e: Event, gpa: std.mem.Allocator) void {
            for ([_][]const u8{ e.repo, e.kind, e.ref, e.old, e.new, e.detail }) |text| gpa.free(text);
        }
    };

    /// Records `event` (its `id` is ignored) and returns the new id.
    pub fn insertEvent(db: *Db, io: Io, event: Event) Error!i64 {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("INSERT INTO events (repo, kind, ref, old, new, detail, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)");
        defer _ = sqlite3_finalize(stmt);
        for ([_][]const u8{ event.repo, event.kind, event.ref, event.old, event.new, event.detail }, 1..) |text, i| {
            try db.bindText(stmt, @intCast(i), text);
        }
        try db.check(sqlite3_bind_int64(stmt, 7, event.created_at));
        if (sqlite3_step(stmt) != SQLITE_DONE) return db.fail("insert event");
        return sqlite3_last_insert_rowid(db.handle);
    }

    /// Events with an id above `after`, oldest first, at most `limit`.
    /// An empty `repo` means every repo. Free with `freeEvents`.
    pub fn listEvents(db: *Db, io: Io, gpa: std.mem.Allocator, repo: []const u8, after: i64, limit: u32) Error![]Event {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare(
            \\SELECT id, repo, kind, ref, old, new, detail, created_at FROM events
            \\WHERE id > ?1 AND (?2 = '' OR repo = ?2) ORDER BY id LIMIT ?3
        );
        defer _ = sqlite3_finalize(stmt);
        try db.check(sqlite3_bind_int64(stmt, 1, after));
        try db.bindText(stmt, 2, repo);
        try db.check(sqlite3_bind_int64(stmt, 3, limit));
        var list: std.ArrayList(Event) = .empty;
        errdefer {
            for (list.items) |e| e.deinit(gpa);
            list.deinit(gpa);
        }
        while (true) switch (sqlite3_step(stmt)) {
            SQLITE_ROW => {
                const event = try readEvent(stmt, gpa);
                list.append(gpa, event) catch |err| {
                    event.deinit(gpa);
                    return err;
                };
            },
            SQLITE_DONE => break,
            else => return db.fail("list events"),
        };
        return list.toOwnedSlice(gpa);
    }

    pub fn freeEvents(gpa: std.mem.Allocator, events: []const Event) void {
        for (events) |e| e.deinit(gpa);
        gpa.free(events);
    }

    fn readEvent(stmt: *sqlite3_stmt, gpa: std.mem.Allocator) Error!Event {
        var texts: [6][]const u8 = undefined;
        var done: usize = 0;
        errdefer for (texts[0..done]) |t| gpa.free(t);
        while (done < texts.len) : (done += 1) texts[done] = try columnText(stmt, @intCast(done + 1), gpa);
        return .{
            .id = sqlite3_column_int64(stmt, 0),
            .repo = texts[0],
            .kind = texts[1],
            .ref = texts[2],
            .old = texts[3],
            .new = texts[4],
            .detail = texts[5],
            .created_at = sqlite3_column_int64(stmt, 7),
        };
    }

    fn readRepo(stmt: *sqlite3_stmt, gpa: std.mem.Allocator) Error!Repo {
        const name = try columnText(stmt, 0, gpa);
        errdefer gpa.free(name);
        return .{
            .name = name,
            .id = try columnText(stmt, 1, gpa),
            .created_at = sqlite3_column_int64(stmt, 2),
        };
    }

    fn columnText(stmt: *sqlite3_stmt, col: c_int, gpa: std.mem.Allocator) Error![]const u8 {
        const len: usize = @intCast(@max(0, sqlite3_column_bytes(stmt, col)));
        const ptr = sqlite3_column_text(stmt, col) orelse return error.DatabaseError;
        return gpa.dupe(u8, ptr[0..len]);
    }

    fn prepare(db: *Db, sql: []const u8) Error!*sqlite3_stmt {
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &stmt, null) != SQLITE_OK) {
            return db.fail("prepare");
        }
        return stmt orelse error.DatabaseError;
    }

    fn bindText(db: *Db, stmt: *sqlite3_stmt, index: c_int, text: []const u8) Error!void {
        const len = std.math.cast(c_int, text.len) orelse return error.DatabaseError;
        try db.check(sqlite3_bind_text(stmt, index, text.ptr, len, SQLITE_STATIC));
    }

    fn check(db: *Db, rc: c_int) Error!void {
        if (rc != SQLITE_OK) return db.fail("bind");
    }

    fn fail(db: *Db, what: []const u8) error{DatabaseError} {
        std.log.err("sqlite {s}: {s}", .{ what, sqlite3_errmsg(db.handle) });
        return error.DatabaseError;
    }
};

test "repos and keys round-trip" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var db: Db = try .open(":memory:");
    defer db.close();

    try db.insertRepo(io, "acme/web", "id1", 10);
    try db.insertRepo(io, "acme/api", "id2", 11);
    try std.testing.expectError(error.AlreadyExists, db.insertRepo(io, "acme/web", "id3", 12));
    try std.testing.expectError(error.AlreadyExists, db.insertRepo(io, "acme/new", "id1", 12));

    const got = (try db.getRepo(io, gpa, "acme/web")).?;
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings("acme/web", got.name);
    try std.testing.expectEqualStrings("id1", got.id);
    try std.testing.expectEqual(@as(i64, 10), got.created_at);
    try std.testing.expectEqual(null, try db.getRepo(io, gpa, "acme/none"));

    const all = try db.listRepos(io, gpa);
    defer Db.freeRepos(gpa, all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("acme/api", all[0].name);

    try std.testing.expect(try db.deleteRepo(io, "acme/web"));
    try std.testing.expect(!try db.deleteRepo(io, "acme/web"));

    try db.insertApiKey(io, "hash1", 1);
    try std.testing.expect(try db.apiKeyExists(io, "hash1"));
    try std.testing.expect(!try db.apiKeyExists(io, "hash2"));
}

test "listRepos frees everything when allocation fails" {
    const io = std.testing.io;
    var db: Db = try .open(":memory:");
    defer db.close();
    try db.insertRepo(io, "a/one", "i1", 1);
    try db.insertRepo(io, "a/two", "i2", 2);
    try db.insertRepo(io, "a/three", "i3", 3);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, listAndFree, .{ &db, io });
}

test "events round-trip and filter by repo" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var db: Db = try .open(":memory:");
    defer db.close();
    const first = try db.insertEvent(io, .{ .repo = "a/b", .kind = "push", .ref = "refs/heads/main", .new = "abc", .created_at = 5 });
    _ = try db.insertEvent(io, .{ .repo = "a/c", .kind = "repo_created", .created_at = 6 });
    const all = try db.listEvents(io, gpa, "", 0, 10);
    defer Db.freeEvents(gpa, all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("push", all[0].kind);
    try std.testing.expectEqualStrings("", all[0].old);
    const later = try db.listEvents(io, gpa, "", first, 10);
    defer Db.freeEvents(gpa, later);
    try std.testing.expectEqual(@as(usize, 1), later.len);
    const only_ab = try db.listEvents(io, gpa, "a/b", 0, 10);
    defer Db.freeEvents(gpa, only_ab);
    try std.testing.expectEqual(@as(usize, 1), only_ab.len);
    try std.testing.checkAllAllocationFailures(gpa, listEventsAndFree, .{ &db, io });
}

fn listEventsAndFree(gpa: std.mem.Allocator, db: *Db, io: Io) !void {
    Db.freeEvents(gpa, try db.listEvents(io, gpa, "", 0, 10));
}

fn listAndFree(gpa: std.mem.Allocator, db: *Db, io: Io) !void {
    const repos = try db.listRepos(io, gpa);
    Db.freeRepos(gpa, repos);
}
