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
    if (request.head.transfer_compression != .identity) return error.InvalidJson;
    var buf: [4096]u8 = undefined;
    const reader = request.readerExpectContinue(&buf) catch return error.ReadFailed;
    const bytes = reader.allocRemaining(gpa, .limited(max_json_body)) catch |err| return switch (err) {
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
        error.BodyTooLarge => respondError(request, .payload_too_large, "too_large", "JSON bodies are limited to 64 KiB"),
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
