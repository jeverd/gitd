//! Deletes branches whose time is up (feature 7).
//!
//! A branch gets an expiry when it is created through the API with
//! `ttl_seconds`, or by a push whose token has `branch_ttl_seconds`. The
//! expiry is a lifetime from creation: later pushes do not extend it.
//! Expiries live in the database, so they survive restarts.
//!
//! Once a second the reaper deletes due branches, whatever they point at
//! now, and logs `branch_expired`. It holds `repo_lock` while it works, so
//! a repo is never deleted or recreated under it.

const std = @import("std");
const Io = std.Io;
const server = @import("server.zig");
const repo_name = @import("repo_name.zig");
const repo_git = @import("repo_git.zig");
const events = @import("events.zig");
const api = @import("api.zig");
const Db = @import("db.zig").Db;

pub const max_ttl_seconds = 7 * 24 * 60 * 60;
const batch = 100;

/// Runs until canceled.
pub fn run(app: *server.App) Io.Cancelable!void {
    while (true) {
        try reapDue(app);
        try app.io.sleep(.fromMilliseconds(app.reaper_interval_ms), .awake);
    }
}

/// Deletes every branch due now. Errors are logged; the next round
/// retries anything left.
pub fn reapDue(app: *server.App) Io.Cancelable!void {
    const io = app.io;
    const now = api.unixNow(io);
    app.db.pruneRevokedTokens(io, now) catch |err| std.log.err("pruning revoked tokens: {t}", .{err});
    const due = app.db.listBranchTtls(io, app.gpa, "", now, batch) catch |err| {
        std.log.err("listing due branches: {t}", .{err});
        return;
    };
    defer Db.freeBranchTtls(app.gpa, due);
    for (due) |ttl| try reapOne(app, ttl, now);
}

fn reapOne(app: *server.App, ttl: Db.BranchTtl, now: i64) Io.Cancelable!void {
    const io = app.io;
    try app.repo_lock.lock(io);
    defer app.repo_lock.unlock(io);

    const forget = struct {
        fn f(a: *server.App, t: Db.BranchTtl) void {
            a.db.clearBranchTtl(a.io, t.repo, t.ref) catch |err| std.log.err("clearing expiry of {s} {s}: {t}", .{ t.repo, t.ref, err });
        }
    }.f;

    // The repo may have been deleted since the expiry was set.
    const name = repo_name.parse(ttl.repo) catch return forget(app, ttl);
    const exists = (app.db.getRepo(io, app.gpa, ttl.repo) catch |err| {
        std.log.err("checking repo {s}: {t}", .{ ttl.repo, err });
        return;
    }) orelse return forget(app, ttl);
    const same = std.mem.eql(u8, exists.id, ttl.repo_id);
    exists.deinit(app.gpa);
    // The expiry belongs to a deleted repo that has since been made again.
    if (!same) return forget(app, ttl);

    const repo = repo_git.Repo.open(io, app.gpa, app.store, name) catch return forget(app, ttl);
    var buf: [64]u8 = undefined;
    const current = repo.refValue(ttl.ref, &buf) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.err("reading {s} {s}: {t}", .{ ttl.repo, ttl.ref, err });
            return;
        },
    };
    if (current) |oid| {
        const outcome = repo.updateRef(ttl.ref, null, oid) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                std.log.err("expiring {s} {s}: {t}", .{ ttl.repo, ttl.ref, err });
                return;
            },
        };
        // A push moved it in between: keep the expiry and try next round.
        if (outcome == .stale) return;
        events.record(app, .{ .repo = ttl.repo, .kind = "branch_expired", .ref = ttl.ref, .old = oid, .detail = "lifetime ended", .created_at = now });
        app.db.recordBranchExpired(io, ttl.repo) catch |err| std.log.err("recording expired count of {s}: {t}", .{ ttl.repo, err });
    }
    forget(app, ttl);
}
