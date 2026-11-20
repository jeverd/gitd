//! Helpers shared by every HTTP handler: JSON bodies, error responses,
//! headers, and the clock.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const http_util = @import("http_util.zig");
const keepAlive = http_util.keepAlive;

pub const HandleError = error{ WriteFailed, ResponseBroken, ClientGone, HttpExpectationFailed } || Io.Cancelable;

pub const max_json_body = 64 * 1024;

pub const BodyError = error{ BodyTooLarge, InvalidJson, ReadFailed, OutOfMemory };

pub fn readJson(comptime T: type, gpa: std.mem.Allocator, request: *http.Server.Request) BodyError!std.json.Parsed(T) {
    return readJsonLimit(T, gpa, request, max_json_body);
}

/// Like `readJson` with a caller-chosen body limit, for bodies that carry
/// file contents.
pub fn readJsonLimit(comptime T: type, gpa: std.mem.Allocator, request: *http.Server.Request, limit: usize) BodyError!std.json.Parsed(T) {
    if (request.head.transfer_compression != .identity) return error.InvalidJson;
    var buf: [4096]u8 = undefined;
    const reader = request.readerExpectContinue(&buf) catch return error.ReadFailed;
    const bytes = reader.allocRemaining(gpa, .limited(limit)) catch |err| return switch (err) {
        error.StreamTooLong => error.BodyTooLarge,
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => error.ReadFailed,
    };
    defer gpa.free(bytes);
    // A connection closed mid-body also ends the read; only a body read to
    // its declared end counts.
    if (request.server.reader.state != .ready) return error.ReadFailed;
    return std.json.parseFromSlice(T, gpa, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

pub fn respondBodyError(request: *http.Server.Request, err: BodyError) HandleError!http.Status {
    return switch (err) {
        error.BodyTooLarge => respondError(request, .payload_too_large, "too_large", "the JSON body is too large"),
        error.InvalidJson => respondError(request, .bad_request, "invalid_json", "the body does not match the expected JSON"),
        error.ReadFailed => error.WriteFailed,
        error.OutOfMemory => internal(request),
    };
}

pub fn respondJson(gpa: std.mem.Allocator, request: *http.Server.Request, status: http.Status, value: anytype) HandleError!http.Status {
    const body = gpa.print("{f}\n", .{std.json.fmt(value, .{})}) catch return internal(request);
    defer gpa.free(body);
    try request.respond(body, .{ .status = status, .keep_alive = keepAlive(request), .extra_headers = &json_headers });
    return status;
}

pub const json_headers = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};

pub fn respondError(request: *http.Server.Request, status: http.Status, code: []const u8, message: []const u8) HandleError!http.Status {
    var buf: [512]u8 = undefined;
    const Err = struct { code: []const u8, message: []const u8 };
    // Codes and messages are short constants, so this always fits.
    const body = std.mem.print(&buf, "{f}\n", .{std.json.fmt(.{ .@"error" = Err{ .code = code, .message = message } }, .{})}) catch unreachable;
    try request.respond(body, .{ .status = status, .keep_alive = keepAlive(request), .extra_headers = &json_headers });
    return status;
}

pub fn internal(request: *http.Server.Request) HandleError!http.Status {
    return respondError(request, .internal_server_error, "internal", "internal error; see server logs");
}

pub fn findHeader(request: *http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

pub fn copyBounded(buf: []u8, text: []const u8) ?[]const u8 {
    if (text.len > buf.len) return null;
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

pub fn pathOf(target: []const u8) []const u8 {
    return target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
}

pub fn copyTruncated(buf: []u8, text: []const u8) []const u8 {
    const n = @min(buf.len, text.len);
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

pub fn unixNow(io: Io) i64 {
    const ns = Io.Clock.real.now(io).nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}

/// Decodes `%XX` escapes (and `+` as space in query values) into `out`.
/// Returns null for a malformed escape or when `out` is too small.
pub fn percentDecode(out: []u8, text: []const u8, plus_is_space: bool) ?[]const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < text.len) : (n += 1) {
        if (n == out.len) return null;
        switch (text[i]) {
            '%' => {
                if (i + 2 >= text.len) return null;
                const hi = std.fmt.charToDigit(text[i + 1], 16) catch return null;
                const lo = std.fmt.charToDigit(text[i + 2], 16) catch return null;
                out[n] = hi * 16 + lo;
                i += 3;
            },
            '+' => {
                out[n] = if (plus_is_space) ' ' else '+';
                i += 1;
            },
            else => |c| {
                out[n] = c;
                i += 1;
            },
        }
    }
    return out[0..n];
}

/// Finds `name=` in a query string and decodes its value into `out`.
pub fn queryValue(out: []u8, query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return percentDecode(out, pair[eq + 1 ..], true);
    }
    return null;
}

test percentDecode {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("agent/3/work", percentDecode(&buf, "agent%2F3%2fwork", true).?);
    try std.testing.expectEqualStrings("a b+c", percentDecode(&buf, "a+b%2Bc", true).?);
    try std.testing.expectEqualStrings("a+b", percentDecode(&buf, "a+b", false).?);
    try std.testing.expectEqual(null, percentDecode(&buf, "a%2", true));
    try std.testing.expectEqual(null, percentDecode(&buf, "a%", true));
    try std.testing.expectEqual(null, percentDecode(&buf, "%zz", true));
    try std.testing.expectEqual(null, percentDecode(buf[0..2], "abc", true));
    try std.testing.expectEqualStrings("main", queryValue(&buf, "x=1&ref=main", "ref").?);
    try std.testing.expectEqual(null, queryValue(&buf, "x=1", "ref"));
}
