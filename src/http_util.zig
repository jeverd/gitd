//! HTTP helpers shared by the API and the git proxy.

const std = @import("std");
const http = std.http;
const Io = std.Io;

/// Whether the connection can serve another request after this response.
/// Pass the result as `keep_alive` to every `respond` and `respondStreaming`.
///
/// To reuse a connection, std reads and discards any unread request body,
/// with no size limit, and asserts it ended cleanly. gitd never lets it
/// (R3.4): a body that was not read, or only partly read, closes the
/// connection instead. An unread body's `Expect: 100-continue` is dropped,
/// so the client is not invited to send it.
pub fn keepAlive(request: *http.Server.Request) bool {
    switch (request.server.reader.state) {
        .ready => return true,
        .received_head => {
            if (!hasBody(request)) return true;
            request.head.expect = null;
            return false;
        },
        else => return false,
    }
}

/// Whether the request declares a body. Valid only before the body is read.
pub fn hasBody(request: *const http.Server.Request) bool {
    return request.head.transfer_encoding != .none or (request.head.content_length orelse 0) > 0;
}

/// Caps open connections per client IP, so one client cannot take every
/// slot (R3.4). All methods are safe to call from any connection task.
pub const PeerLimit = struct {
    mutex: Io.Mutex = .init,
    counts: std.AutoHashMapUnmanaged([16]u8, u32) = .empty,
    max_per_peer: u32,

    pub fn deinit(p: *PeerLimit, gpa: std.mem.Allocator) void {
        p.counts.deinit(gpa);
    }

    /// Returns false when `address` is already at the limit or memory ran
    /// out; the caller then drops the connection. Pair a true result with
    /// one `release`.
    pub fn acquire(p: *PeerLimit, io: Io, gpa: std.mem.Allocator, address: Io.net.IpAddress) bool {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        const entry = p.counts.getOrPut(gpa, key(address)) catch return false;
        if (!entry.found_existing) entry.value_ptr.* = 0;
        if (entry.value_ptr.* >= p.max_per_peer) return false;
        entry.value_ptr.* += 1;
        return true;
    }

    pub fn release(p: *PeerLimit, io: Io, address: Io.net.IpAddress) void {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        const k = key(address);
        const count = p.counts.getPtr(k) orelse return;
        count.* -= 1;
        if (count.* == 0) _ = p.counts.remove(k);
    }

    /// IPv4 addresses map into IPv6 (`::ffff:a.b.c.d`); ports are ignored.
    fn key(address: Io.net.IpAddress) [16]u8 {
        return switch (address) {
            .ip6 => |a| a.bytes,
            .ip4 => |a| [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff } ++ a.bytes,
        };
    }
};

test "PeerLimit caps each address and frees slots on release" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var limit: PeerLimit = .{ .max_per_peer = 2 };
    defer limit.deinit(gpa);
    const a: Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 1 }, .port = 1 } };
    const a_other_port: Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 1 }, .port = 2 } };
    const b: Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 2 }, .port = 1 } };

    try std.testing.expect(limit.acquire(io, gpa, a));
    try std.testing.expect(limit.acquire(io, gpa, a_other_port));
    try std.testing.expect(!limit.acquire(io, gpa, a));
    try std.testing.expect(limit.acquire(io, gpa, b));
    limit.release(io, a);
    try std.testing.expect(limit.acquire(io, gpa, a));
    limit.release(io, a);
    limit.release(io, a);
    limit.release(io, b);
    try std.testing.expectEqual(@as(u32, 0), limit.counts.count());
}
