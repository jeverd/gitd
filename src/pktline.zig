//! Git smart protocol pkt-line framing and side-band multiplexing (R1.1, R2.3, R3.1).
//!
//! Format: 4 lowercase ASCII hex digits giving the total packet length
//! (including the 4-byte header), followed by `len - 4` payload bytes:
//!   0000  flush-pkt
//!   0001  delim-pkt (protocol v2)
//!   0002  response-end-pkt (protocol v2)
//!   0003  invalid
//!   0004  empty data-pkt
//!   0005..fff0  data-pkt (max 65516 payload bytes)

const std = @import("std");

pub const max_pkt_len: usize = 65520;
pub const max_payload_len: usize = max_pkt_len - 4;
pub const sideband_max: usize = 995;
pub const sideband_64k_max: usize = 65515;

pub const Channel = enum(u8) {
    pack = 1,
    progress = 2,
    fatal = 3,
};

pub const Packet = union(enum) {
    flush,
    delim,
    response_end,
    data: []const u8,
};

pub const ParseError = error{
    InvalidPacket,
    Truncated,
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn remaining(r: *const Reader) []const u8 {
        return r.buf[r.pos..];
    }

    /// Reads the next pkt-line, or returns null at exact end-of-buffer.
    pub fn next(r: *Reader) ParseError!?Packet {
        if (r.pos == r.buf.len) return null;
        if (r.buf.len - r.pos < 4) return error.Truncated;
        const len = parseHex4(r.buf[r.pos..][0..4]) orelse return error.InvalidPacket;
        switch (len) {
            0 => {
                r.pos += 4;
                return .flush;
            },
            1 => {
                r.pos += 4;
                return .delim;
            },
            2 => {
                r.pos += 4;
                return .response_end;
            },
            3 => return error.InvalidPacket,
            else => {
                if (len > max_pkt_len) return error.InvalidPacket;
                if (len > r.buf.len - r.pos) return error.Truncated;
                const payload = r.buf[r.pos + 4 .. r.pos + len];
                r.pos += len;
                return .{ .data = payload };
            },
        }
    }
};

fn parseHex4(hdr: *const [4]u8) ?usize {
    var val: usize = 0;
    for (hdr) |c| {
        const d: usize = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        val = (val << 4) | d;
    }
    return val;
}

pub fn write(w: *std.Io.Writer, payload: []const u8) std.Io.Writer.Error!void {
    std.debug.assert(payload.len <= max_payload_len);
    try w.print("{x:0>4}", .{payload.len + 4});
    try w.writeAll(payload);
}

pub fn writeLine(w: *std.Io.Writer, line: []const u8) std.Io.Writer.Error!void {
    std.debug.assert(line.len + 1 <= max_payload_len);
    try w.print("{x:0>4}", .{line.len + 5});
    try w.writeAll(line);
    try w.writeByte('\n');
}

pub fn writeFlush(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("0000");
}

pub fn writeDelim(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("0001");
}

pub fn writeResponseEnd(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("0002");
}

/// Writes `data` on side-band `channel`, splitting into packets of at most
/// `band_max` payload bytes (including the 1-byte channel prefix).
pub fn writeSideband(
    w: *std.Io.Writer,
    channel: Channel,
    data: []const u8,
    band_max: usize,
) std.Io.Writer.Error!void {
    std.debug.assert(band_max >= 2 and band_max <= max_payload_len);
    const max_chunk = band_max - 1;
    var rest = data;
    while (rest.len > 0) {
        const n = @min(rest.len, max_chunk);
        try w.print("{x:0>4}", .{n + 5});
        try w.writeByte(@backingInt(channel));
        try w.writeAll(rest[0..n]);
        rest = rest[n..];
    }
}

/// Returns whether a `Git-Protocol` header requests wire protocol version 2.
/// Header values are colon-separated key=value tokens, e.g. `version=2`.
pub fn hasProtocolV2(header: []const u8) bool {
    var it = std.mem.splitScalar(u8, header, ':');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "version=2")) return true;
    }
    return false;
}

const testing = std.testing;

test "reader parses flush, delim, response_end, empty, and data packets" {
    const stream = "000eversion 2\n000100040009hello00020000PACK";
    var r = Reader.init(stream);
    const p1 = (try r.next()).?;
    try testing.expectEqualStrings("version 2\n", p1.data);
    try testing.expectEqual(Packet.delim, (try r.next()).?);
    try testing.expectEqualStrings("", (try r.next()).?.data);
    try testing.expectEqualStrings("hello", (try r.next()).?.data);
    try testing.expectEqual(Packet.response_end, (try r.next()).?);
    try testing.expectEqual(Packet.flush, (try r.next()).?);
    try testing.expectEqualStrings("PACK", r.remaining());
}

test "reader rejects invalid and truncated packets" {
    const invalid = [_][]const u8{ "0003", "zzzz", "fff1aaaa", "ffff" };
    for (invalid) |in| {
        var r = Reader.init(in);
        try testing.expectError(error.InvalidPacket, r.next());
    }
    const truncated = [_][]const u8{ "0", "00", "000", "000aabc" };
    for (truncated) |in| {
        var r = Reader.init(in);
        try testing.expectError(error.Truncated, r.next());
    }
}

test "writers and side-band chunking round-trip through reader" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeLine(&out.writer, "# service=git-upload-pack");
    try writeFlush(&out.writer);
    try writeSideband(&out.writer, .pack, "abcdefghij", 5);
    try writeFlush(&out.writer);

    var r = Reader.init(out.written());
    try testing.expectEqualStrings("# service=git-upload-pack\n", (try r.next()).?.data);
    try testing.expectEqual(Packet.flush, (try r.next()).?);
    try testing.expectEqualStrings("\x01abcd", (try r.next()).?.data);
    try testing.expectEqualStrings("\x01efgh", (try r.next()).?.data);
    try testing.expectEqualStrings("\x01ij", (try r.next()).?.data);
    try testing.expectEqual(Packet.flush, (try r.next()).?);
    try testing.expect((try r.next()) == null);
}

test "hasProtocolV2 parses colon-delimited tokens" {
    try testing.expect(hasProtocolV2("version=2"));
    try testing.expect(hasProtocolV2("foo=1:version=2:bar=3"));
    try testing.expect(!hasProtocolV2(""));
    try testing.expect(!hasProtocolV2("version=1"));
    try testing.expect(!hasProtocolV2("version=20"));
}

test "fuzz pktline" {
    try testing.fuzz({}, fuzzPktline, .{
        .corpus = &.{
            "0000",
            "0001",
            "0002",
            "0003",
            "0004",
            "000eversion 2\n0000",
            "000aabc",
            "fff0",
        },
    });
}

fn fuzzPktline(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var r = Reader.init(input);
    var count: usize = 0;
    while (count < 2048) : (count += 1) {
        const pkt = (r.next() catch break) orelse break;
        switch (pkt) {
            .data => |d| try testing.expect(d.len <= max_payload_len),
            else => {},
        }
    }
    try testing.expect(r.pos <= input.len);
    _ = hasProtocolV2(input);
}
