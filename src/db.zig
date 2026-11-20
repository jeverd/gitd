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
extern fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;

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
    \\CREATE TABLE IF NOT EXISTS branch_ttls (
    \\  repo TEXT NOT NULL,
    \\  repo_id TEXT NOT NULL,
    \\  ref TEXT NOT NULL,
    \\  expires_at INTEGER NOT NULL,
    \\  PRIMARY KEY (repo, ref)
    \\) STRICT;
    \\CREATE INDEX IF NOT EXISTS branch_ttls_due ON branch_ttls (expires_at);
    \\CREATE TABLE IF NOT EXISTS webhooks (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  repo TEXT NOT NULL,
    \\  url TEXT NOT NULL,
    \\  secret TEXT NOT NULL,
    \\  created_at INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS deliveries (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  webhook_id INTEGER NOT NULL,
    \\  event_id INTEGER NOT NULL,
    \\  status TEXT NOT NULL,
    \\  attempts INTEGER NOT NULL,
    \\  next_attempt_ms INTEGER NOT NULL,
    \\  last_status INTEGER NOT NULL,
    \\  last_error TEXT NOT NULL,
    \\  updated_at INTEGER NOT NULL
    \\) STRICT;
    \\CREATE INDEX IF NOT EXISTS deliveries_due ON deliveries (status, next_attempt_ms);
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

    /// Records `event` (its `id` is ignored), queues a delivery for each of
    /// the repo's webhooks in the same transaction, and returns the id.
    pub fn insertEvent(db: *Db, io: Io, event: Event) Error!i64 {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        try db.exec("BEGIN IMMEDIATE");
        errdefer db.exec("ROLLBACK") catch {}; // the original error is what matters
        const stmt = try db.prepare("INSERT INTO events (repo, kind, ref, old, new, detail, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)");
        defer _ = sqlite3_finalize(stmt);
        for ([_][]const u8{ event.repo, event.kind, event.ref, event.old, event.new, event.detail }, 1..) |text, i| {
            try db.bindText(stmt, @intCast(i), text);
        }
        try db.check(sqlite3_bind_int64(stmt, 7, event.created_at));
        if (sqlite3_step(stmt) != SQLITE_DONE) return db.fail("insert event");
        const id = sqlite3_last_insert_rowid(db.handle);

        const queue = try db.prepare(
            \\INSERT INTO deliveries (webhook_id, event_id, status, attempts, next_attempt_ms, last_status, last_error, updated_at)
            \\SELECT id, ?1, 'pending', 0, 0, 0, '', ?2 FROM webhooks WHERE repo = ?3
        );
        defer _ = sqlite3_finalize(queue);
        try db.check(sqlite3_bind_int64(queue, 1, id));
        try db.check(sqlite3_bind_int64(queue, 2, event.created_at));
        try db.bindText(queue, 3, event.repo);
        if (sqlite3_step(queue) != SQLITE_DONE) return db.fail("queue deliveries");
        try db.exec("COMMIT");
        return id;
    }

    fn exec(db: *Db, sql: [:0]const u8) Error!void {
        if (sqlite3_exec(db.handle, sql, null, null, null) != SQLITE_OK) return db.fail(sql);
    }

    pub fn insertWebhook(db: *Db, io: Io, repo: []const u8, url: []const u8, secret: []const u8, created_at: i64) Error!i64 {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("INSERT INTO webhooks (repo, url, secret, created_at) VALUES (?1, ?2, ?3, ?4)");
        defer _ = sqlite3_finalize(stmt);
        try db.bindText(stmt, 1, repo);
        try db.bindText(stmt, 2, url);
        try db.bindText(stmt, 3, secret);
        try db.check(sqlite3_bind_int64(stmt, 4, created_at));
        if (sqlite3_step(stmt) != SQLITE_DONE) return db.fail("insert webhook");
        return sqlite3_last_insert_rowid(db.handle);
    }

    /// Deletes one webhook (or, with `id` 0, all of a repo's) and their
    /// queued deliveries. Returns whether any webhook was deleted.
    pub fn deleteWebhooks(db: *Db, io: Io, repo: []const u8, id: i64) Error!bool {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        try db.exec("BEGIN IMMEDIATE");
        errdefer db.exec("ROLLBACK") catch {}; // the original error is what matters
        const del = try db.prepare("DELETE FROM deliveries WHERE webhook_id IN (SELECT id FROM webhooks WHERE repo = ?1 AND (?2 = 0 OR id = ?2))");
        defer _ = sqlite3_finalize(del);
        try db.bindText(del, 1, repo);
        try db.check(sqlite3_bind_int64(del, 2, id));
        if (sqlite3_step(del) != SQLITE_DONE) return db.fail("delete deliveries");
        const stmt = try db.prepare("DELETE FROM webhooks WHERE repo = ?1 AND (?2 = 0 OR id = ?2)");
        defer _ = sqlite3_finalize(stmt);
        try db.bindText(stmt, 1, repo);
        try db.check(sqlite3_bind_int64(stmt, 2, id));
        if (sqlite3_step(stmt) != SQLITE_DONE) return db.fail("delete webhook");
        const deleted = sqlite3_changes(db.handle) > 0;
        try db.exec("COMMIT");
        return deleted;
    }

    pub const Webhook = struct {
        id: i64,
        url: []const u8,
        created_at: i64,
    };

    /// A repo's webhooks, without secrets. The caller frees each `url` and
    /// the slice.
    pub fn listWebhooks(db: *Db, io: Io, gpa: std.mem.Allocator, repo: []const u8) Error![]Webhook {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("SELECT id, url, created_at FROM webhooks WHERE repo = ?1 ORDER BY id");
        defer _ = sqlite3_finalize(stmt);
        try db.bindText(stmt, 1, repo);
        var list: std.ArrayList(Webhook) = .empty;
        errdefer {
            for (list.items) |w| gpa.free(w.url);
            list.deinit(gpa);
        }
        while (true) switch (sqlite3_step(stmt)) {
            SQLITE_ROW => {
                const url = try columnText(stmt, 1, gpa);
                errdefer gpa.free(url);
                try list.append(gpa, .{ .id = sqlite3_column_int64(stmt, 0), .url = url, .created_at = sqlite3_column_int64(stmt, 2) });
            },
            SQLITE_DONE => break,
            else => return db.fail("list webhooks"),
        };
        return list.toOwnedSlice(gpa);
    }

    pub fn freeWebhooks(gpa: std.mem.Allocator, hooks: []const Webhook) void {
        for (hooks) |w| gpa.free(w.url);
        gpa.free(hooks);
    }

    /// One queued or finished delivery, joined with its webhook and event.
    pub const Delivery = struct {
        id: i64,
        webhook_id: i64,
        status: []const u8,
        attempts: i64,
        last_status: i64,
        last_error: []const u8,
        updated_at: i64,
        url: []const u8,
        /// Empty except from `dueDeliveries`.
        secret: []const u8,
        event: Event,

        pub fn deinit(d: Delivery, gpa: std.mem.Allocator) void {
            for ([_][]const u8{ d.status, d.last_error, d.url, d.secret }) |t| gpa.free(t);
            d.event.deinit(gpa);
        }
    };

    const delivery_columns =
        \\d.id, d.webhook_id, d.status, d.attempts, d.last_status, d.last_error, d.updated_at, w.url,
        \\e.id, e.repo, e.kind, e.ref, e.old, e.new, e.detail, e.created_at
    ;

    /// Pending deliveries whose next attempt is due at `now_ms`, with the
    /// webhook secret. Free with `freeDeliveries`.
    pub fn dueDeliveries(db: *Db, io: Io, gpa: std.mem.Allocator, now_ms: i64, limit: u32) Error![]Delivery {
        return db.queryDeliveries(io, gpa, "SELECT " ++ delivery_columns ++ ", w.secret FROM deliveries d JOIN webhooks w ON w.id = d.webhook_id JOIN events e ON e.id = d.event_id WHERE d.status = 'pending' AND d.next_attempt_ms <= ?1 ORDER BY d.id LIMIT ?2", "", now_ms, limit);
    }

    /// Like `dueDeliveries`, but also marks them `sending`, so no other
    /// round picks them up while they are in flight.
    pub fn claimDueDeliveries(db: *Db, io: Io, gpa: std.mem.Allocator, now_ms: i64, limit: u32) Error![]Delivery {
        const due = try db.dueDeliveries(io, gpa, now_ms, limit);
        errdefer freeDeliveries(gpa, due);
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("UPDATE deliveries SET status = 'sending' WHERE id = ?1");
        defer _ = sqlite3_finalize(stmt);
        for (due) |d| {
            _ = sqlite3_reset(stmt);
            try db.check(sqlite3_bind_int64(stmt, 1, d.id));
            if (sqlite3_step(stmt) != SQLITE_DONE) return db.fail("claim delivery");
        }
        return due;
    }

    /// Puts deliveries a stopped server left `sending` back in the queue.
    pub fn requeueSending(db: *Db, io: Io) Error!void {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        try db.exec("UPDATE deliveries SET status = 'pending' WHERE status = 'sending'");
    }

    /// The newest deliveries, for one repo or (empty `repo`) all, without
    /// secrets. Free with `freeDeliveries`.
    pub fn recentDeliveries(db: *Db, io: Io, gpa: std.mem.Allocator, repo: []const u8, limit: u32) Error![]Delivery {
        return db.queryDeliveries(io, gpa, "SELECT " ++ delivery_columns ++ ", '' FROM deliveries d JOIN webhooks w ON w.id = d.webhook_id JOIN events e ON e.id = d.event_id WHERE (?3 = '' OR w.repo = ?3) AND ?1 >= 0 ORDER BY d.id DESC LIMIT ?2", repo, 0, limit);
    }

    fn queryDeliveries(db: *Db, io: Io, gpa: std.mem.Allocator, sql: []const u8, repo: []const u8, num: i64, limit: u32) Error![]Delivery {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare(sql);
        defer _ = sqlite3_finalize(stmt);
        try db.check(sqlite3_bind_int64(stmt, 1, num));
        try db.check(sqlite3_bind_int64(stmt, 2, limit));
        if (std.mem.find(u8, sql, "?3") != null) try db.bindText(stmt, 3, repo);
        var list: std.ArrayList(Delivery) = .empty;
        errdefer {
            for (list.items) |d| d.deinit(gpa);
            list.deinit(gpa);
        }
        while (true) switch (sqlite3_step(stmt)) {
            SQLITE_ROW => {
                const d = try readDelivery(stmt, gpa);
                list.append(gpa, d) catch |err| {
                    d.deinit(gpa);
                    return err;
                };
            },
            SQLITE_DONE => break,
            else => return db.fail("list deliveries"),
        };
        return list.toOwnedSlice(gpa);
    }

    fn readDelivery(stmt: *sqlite3_stmt, gpa: std.mem.Allocator) Error!Delivery {
        // Text columns: 2 status, 5 last_error, 7 url, 9-14 event, 16 secret.
        const cols = [_]c_int{ 2, 5, 7, 9, 10, 11, 12, 13, 14, 16 };
        var texts: [cols.len][]const u8 = undefined;
        var done: usize = 0;
        errdefer for (texts[0..done]) |t| gpa.free(t);
        while (done < cols.len) : (done += 1) texts[done] = try columnText(stmt, cols[done], gpa);
        return .{
            .id = sqlite3_column_int64(stmt, 0),
            .webhook_id = sqlite3_column_int64(stmt, 1),
            .status = texts[0],
            .attempts = sqlite3_column_int64(stmt, 3),
            .last_status = sqlite3_column_int64(stmt, 4),
            .last_error = texts[1],
            .updated_at = sqlite3_column_int64(stmt, 6),
            .url = texts[2],
            .event = .{
                .id = sqlite3_column_int64(stmt, 8),
                .repo = texts[3],
                .kind = texts[4],
                .ref = texts[5],
                .old = texts[6],
                .new = texts[7],
                .detail = texts[8],
                .created_at = sqlite3_column_int64(stmt, 15),
            },
            .secret = texts[9],
        };
    }

    pub fn freeDeliveries(gpa: std.mem.Allocator, list: []const Delivery) void {
        for (list) |d| d.deinit(gpa);
        gpa.free(list);
    }

    /// Records the outcome of one attempt.
    pub fn updateDelivery(db: *Db, io: Io, id: i64, status: []const u8, attempts: i64, next_attempt_ms: i64, last_status: i64, last_error: []const u8, now: i64) Error!void {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("UPDATE deliveries SET status = ?2, attempts = ?3, next_attempt_ms = ?4, last_status = ?5, last_error = ?6, updated_at = ?7 WHERE id = ?1");
        defer _ = sqlite3_finalize(stmt);
        try db.check(sqlite3_bind_int64(stmt, 1, id));
        try db.bindText(stmt, 2, status);
        try db.check(sqlite3_bind_int64(stmt, 3, attempts));
        try db.check(sqlite3_bind_int64(stmt, 4, next_attempt_ms));
        try db.check(sqlite3_bind_int64(stmt, 5, last_status));
        try db.bindText(stmt, 6, last_error);
        try db.check(sqlite3_bind_int64(stmt, 7, now));
        if (sqlite3_step(stmt) != SQLITE_DONE) return db.fail("update delivery");
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

    /// Sets (or replaces) when a branch expires. `repo_id` ties the expiry
    /// to this incarnation of the repo: the reaper ignores it if the repo
    /// was deleted and made again under the same name.
    pub fn setBranchTtl(db: *Db, io: Io, repo: []const u8, repo_id: []const u8, ref: []const u8, expires_at: i64) Error!void {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("INSERT INTO branch_ttls (repo, repo_id, ref, expires_at) VALUES (?1, ?4, ?2, ?3) ON CONFLICT (repo, ref) DO UPDATE SET expires_at = excluded.expires_at, repo_id = excluded.repo_id");
        defer _ = sqlite3_finalize(stmt);
        try db.bindText(stmt, 1, repo);
        try db.bindText(stmt, 2, ref);
        try db.check(sqlite3_bind_int64(stmt, 3, expires_at));
        try db.bindText(stmt, 4, repo_id);
        if (sqlite3_step(stmt) != SQLITE_DONE) return db.fail("set branch ttl");
    }

    /// Forgets a branch's expiry. An empty `ref` clears every branch in
    /// the repo.
    pub fn clearBranchTtl(db: *Db, io: Io, repo: []const u8, ref: []const u8) Error!void {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare("DELETE FROM branch_ttls WHERE repo = ?1 AND (?2 = '' OR ref = ?2)");
        defer _ = sqlite3_finalize(stmt);
        try db.bindText(stmt, 1, repo);
        try db.bindText(stmt, 2, ref);
        if (sqlite3_step(stmt) != SQLITE_DONE) return db.fail("clear branch ttl");
    }

    pub const BranchTtl = struct {
        repo: []const u8,
        repo_id: []const u8,
        ref: []const u8,
        expires_at: i64,

        pub fn deinit(t: BranchTtl, gpa: std.mem.Allocator) void {
            gpa.free(t.repo);
            gpa.free(t.repo_id);
            gpa.free(t.ref);
        }
    };

    /// Branch expiries, soonest first: those due by `due_by` (all repos),
    /// or every one in `repo` when `repo` is not empty. Free with
    /// `freeBranchTtls`.
    pub fn listBranchTtls(db: *Db, io: Io, gpa: std.mem.Allocator, repo: []const u8, due_by: i64, limit: u32) Error![]BranchTtl {
        db.mutex.lockUncancelable(io);
        defer db.mutex.unlock(io);
        const stmt = try db.prepare(
            \\SELECT repo, ref, expires_at, repo_id FROM branch_ttls
            \\WHERE (?1 != '' AND repo = ?1) OR (?1 = '' AND expires_at <= ?2)
            \\ORDER BY expires_at LIMIT ?3
        );
        defer _ = sqlite3_finalize(stmt);
        try db.bindText(stmt, 1, repo);
        try db.check(sqlite3_bind_int64(stmt, 2, due_by));
        try db.check(sqlite3_bind_int64(stmt, 3, limit));
        var list: std.ArrayList(BranchTtl) = .empty;
        errdefer {
            for (list.items) |t| t.deinit(gpa);
            list.deinit(gpa);
        }
        while (true) switch (sqlite3_step(stmt)) {
            SQLITE_ROW => {
                const r = try columnText(stmt, 0, gpa);
                errdefer gpa.free(r);
                const ref = try columnText(stmt, 1, gpa);
                errdefer gpa.free(ref);
                const rid = try columnText(stmt, 3, gpa);
                errdefer gpa.free(rid);
                try list.append(gpa, .{ .repo = r, .repo_id = rid, .ref = ref, .expires_at = sqlite3_column_int64(stmt, 2) });
            },
            SQLITE_DONE => break,
            else => return db.fail("list branch ttls"),
        };
        return list.toOwnedSlice(gpa);
    }

    pub fn freeBranchTtls(gpa: std.mem.Allocator, ttls: []const BranchTtl) void {
        for (ttls) |t| t.deinit(gpa);
        gpa.free(ttls);
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

test "webhooks queue a delivery per event, and deleting cleans up" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var db: Db = try .open(":memory:");
    defer db.close();
    const hook = try db.insertWebhook(io, "a/b", "http://x/hook", "whsec_1", 1);
    _ = try db.insertWebhook(io, "a/c", "http://y/hook", "whsec_2", 1);
    _ = try db.insertEvent(io, .{ .repo = "a/b", .kind = "push", .ref = "refs/heads/main", .created_at = 5 });
    _ = try db.insertEvent(io, .{ .repo = "a/z", .kind = "push", .created_at = 6 }); // no webhook

    const due = try db.dueDeliveries(io, gpa, 0, 10);
    defer Db.freeDeliveries(gpa, due);
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqualStrings("whsec_1", due[0].secret);
    try std.testing.expectEqualStrings("push", due[0].event.kind);
    try std.testing.expectEqualStrings("http://x/hook", due[0].url);

    const claimed = try db.claimDueDeliveries(io, gpa, 0, 10);
    defer Db.freeDeliveries(gpa, claimed);
    try std.testing.expectEqual(@as(usize, 1), claimed.len);
    const again = try db.claimDueDeliveries(io, gpa, 0, 10);
    defer Db.freeDeliveries(gpa, again);
    try std.testing.expectEqual(@as(usize, 0), again.len); // in flight
    try db.requeueSending(io);
    try db.updateDelivery(io, due[0].id, "pending", 1, 5000, 500, "HTTP 500", 7);
    const later = try db.dueDeliveries(io, gpa, 4999, 10);
    defer Db.freeDeliveries(gpa, later);
    try std.testing.expectEqual(@as(usize, 0), later.len);

    const recent = try db.recentDeliveries(io, gpa, "a/b", 10);
    defer Db.freeDeliveries(gpa, recent);
    try std.testing.expectEqual(@as(usize, 1), recent.len);
    try std.testing.expectEqualStrings("", recent[0].secret);
    try std.testing.expectEqual(@as(i64, 500), recent[0].last_status);

    const hooks = try db.listWebhooks(io, gpa, "a/b");
    defer Db.freeWebhooks(gpa, hooks);
    try std.testing.expectEqual(@as(usize, 1), hooks.len);

    try std.testing.expect(try db.deleteWebhooks(io, "a/b", hook));
    try std.testing.expect(!try db.deleteWebhooks(io, "a/b", hook));
    const none = try db.recentDeliveries(io, gpa, "", 10);
    defer Db.freeDeliveries(gpa, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    try std.testing.checkAllAllocationFailures(gpa, dueAndFree, .{ &db, io });
}

fn dueAndFree(gpa: std.mem.Allocator, db: *Db, io: Io) !void {
    Db.freeDeliveries(gpa, try db.recentDeliveries(io, gpa, "", 10));
}

test "branch expiries" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var db: Db = try .open(":memory:");
    defer db.close();
    try db.setBranchTtl(io, "a/b", "id1", "refs/heads/x", 100);
    try db.setBranchTtl(io, "a/b", "id1", "refs/heads/y", 50);
    try db.setBranchTtl(io, "a/c", "id2", "refs/heads/z", 300);
    try db.setBranchTtl(io, "a/b", "id1", "refs/heads/x", 200); // replaces

    const due = try db.listBranchTtls(io, gpa, "", 200, 10);
    defer Db.freeBranchTtls(gpa, due);
    try std.testing.expectEqual(@as(usize, 2), due.len);
    try std.testing.expectEqualStrings("refs/heads/y", due[0].ref);
    try std.testing.expectEqual(@as(i64, 200), due[1].expires_at);
    try std.testing.expectEqualStrings("id1", due[1].repo_id);

    const in_repo = try db.listBranchTtls(io, gpa, "a/c", 0, 10);
    defer Db.freeBranchTtls(gpa, in_repo);
    try std.testing.expectEqual(@as(usize, 1), in_repo.len);

    try db.clearBranchTtl(io, "a/b", "refs/heads/y");
    try db.clearBranchTtl(io, "a/c", "");
    const left = try db.listBranchTtls(io, gpa, "", 1000, 10);
    defer Db.freeBranchTtls(gpa, left);
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.checkAllAllocationFailures(gpa, listTtlsAndFree, .{ &db, io });
}

fn listTtlsAndFree(gpa: std.mem.Allocator, db: *Db, io: Io) !void {
    Db.freeBranchTtls(gpa, try db.listBranchTtls(io, gpa, "", 1000, 10));
}

fn listEventsAndFree(gpa: std.mem.Allocator, db: *Db, io: Io) !void {
    Db.freeEvents(gpa, try db.listEvents(io, gpa, "", 0, 10));
}

fn listAndFree(gpa: std.mem.Allocator, db: *Db, io: Io) !void {
    const repos = try db.listRepos(io, gpa);
    Db.freeRepos(gpa, repos);
}
