//! File paths inside a repo, as the API takes them (R2.3).
//!
//! A path is 1-4096 bytes of slash-separated segments, with no empty, `.`,
//! or `..` segment, no `.git` segment in any case, and no NUL or other
//! control bytes. Leading and trailing slashes are not allowed. These rules
//! keep paths meaning the same thing to gitd, git, and every client.

const std = @import("std");

pub const max_len = 4096;
pub const Error = error{InvalidPath};

pub fn validate(path: []const u8) Error!void {
    if (path.len == 0 or path.len > max_len) return error.InvalidPath;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPath;
        if (std.ascii.eqlIgnoreCase(segment, ".git")) return error.InvalidPath;
        for (segment) |c| if (c < 0x20 or c == 0x7f) return error.InvalidPath;
    }
}

const testing = std.testing;

test "valid and invalid paths" {
    for ([_][]const u8{ "a", "src/main.zig", "a b/c.txt", ".github/x.yml", "dir/.env", "caf\xc3\xa9.md" }) |p| try validate(p);
    for ([_][]const u8{
        "",       "/a",    "a/",   "a//b",          ".",      "..",
        "a/../b", "a/./b", ".git", "x/.GIT/config", "a\x00b", "a\nb",
        "a\x7fb",
    }) |p| try testing.expectError(error.InvalidPath, validate(p));
}

test "fuzz validate path" {
    try testing.fuzz({}, fuzzValidate, .{ .corpus = &.{ "src/main.zig", "a/../b" } });
}

fn fuzzValidate(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    validate(input) catch return;
    var it = std.mem.splitScalar(u8, input, '/');
    while (it.next()) |segment| {
        try testing.expect(segment.len > 0);
        try testing.expect(!std.mem.eql(u8, segment, ".."));
        try testing.expect(!std.ascii.eqlIgnoreCase(segment, ".git"));
    }
}
