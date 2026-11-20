//! The activity log. Every change gitd makes or refuses is recorded here:
//! pushes, rejected pushes, commits, merges, expiries. The UI reads it, and
//! webhooks deliver it.

const std = @import("std");
const server = @import("server.zig");
const Db = @import("db.zig").Db;

pub const Event = Db.Event;

/// Records `event`. A failure is logged and otherwise ignored: the change
/// itself already happened, and losing its log entry must not undo it or
/// fail the request.
pub fn record(app: *server.App, event: Event) void {
    _ = app.db.insertEvent(app.io, event) catch |err| {
        std.log.err("recording {s} event for {s}: {t}", .{ event.kind, event.repo, err });
    };
}
