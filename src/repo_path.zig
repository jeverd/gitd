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

/// Validates a path pattern: either an exact path (`README.md`, `src/a.zig`)
/// with no `*`, or `<dir>/*` (matches any file inside `<dir>` at any depth).
pub fn validatePattern(pattern: []const u8) Error!void {
    if (std.mem.endsWith(u8, pattern, "/*")) {
        const dir = pattern[0 .. pattern.len - 2];
        if (std.mem.findScalar(u8, dir, '*') != null) return error.InvalidPath;
        return validate(dir);
    }
    if (std.mem.findScalar(u8, pattern, '*') != null) return error.InvalidPath;
    return validate(pattern);
}

/// Whether `pattern` covers file `path`.
pub fn matchesPattern(pattern: []const u8, path: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "/*")) {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, path, prefix);
    }
    return std.mem.eql(u8, pattern, path);
}

/// Whether directory `dir` may be listed/traversed under `pattern` (either
/// `dir` is inside `pattern`, or `pattern` matches something inside `dir`).
pub fn allowsDir(pattern: []const u8, dir: []const u8) bool {
    if (matchesPattern(pattern, dir)) return true;
    return pattern.len > dir.len and std.mem.startsWith(u8, pattern, dir) and pattern[dir.len] == '/';
}

/// Whether every file under directory `dir` is covered by `pattern`.
pub fn coversWholeDir(pattern: []const u8, dir: []const u8) bool {
    if (!std.mem.endsWith(u8, pattern, "/*")) return false;
    const prefix = pattern[0 .. pattern.len - 2];
    if (std.mem.eql(u8, prefix, dir)) return true;
    return dir.len > prefix.len and std.mem.startsWith(u8, dir, prefix) and dir[prefix.len] == '/';
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

test "path patterns validate and match" {
    try validatePattern("README.md");
    try validatePattern("docs/*");
    try validatePattern("src/ui/*");
    for ([_][]const u8{ "", "*", "/*", "docs/", "docs/*", "a/*/b", "docs/**/*" }) |p| {
        if (std.mem.eql(u8, p, "docs/*")) continue;
        try testing.expectError(error.InvalidPath, validatePattern(p));
    }
    try testing.expect(matchesPattern("README.md", "README.md"));
    try testing.expect(!matchesPattern("README.md", "README.md.bak"));
    try testing.expect(matchesPattern("docs/*", "docs/a.md"));
    try testing.expect(matchesPattern("docs/*", "docs/sub/b.md"));
    try testing.expect(!matchesPattern("docs/*", "docs2/a.md"));
    try testing.expect(!matchesPattern("docs/*", "docs"));
    try testing.expect(allowsDir("docs/*", "docs"));
    try testing.expect(allowsDir("docs/*", "docs/sub"));
    try testing.expect(allowsDir("docs/a.md", "docs"));
    try testing.expect(!allowsDir("docs/*", "docs2"));
    try testing.expect(coversWholeDir("docs/*", "docs"));
    try testing.expect(coversWholeDir("docs/*", "docs/sub"));
    try testing.expect(!coversWholeDir("docs/sub/*", "docs"));
    try testing.expect(!coversWholeDir("docs/a.md", "docs"));
}

test "fuzz match path pattern" {
    try testing.fuzz({}, fuzzMatchPattern, .{ .corpus = &.{ "docs/*\x00docs/a.md", "README.md\x00README.md" } });
}

fn fuzzMatchPattern(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const sep = std.mem.findScalar(u8, input, 0) orelse return;
    const pat = input[0..sep];
    const path = input[sep + 1 ..];
    validatePattern(pat) catch return;
    validate(path) catch return;
    if (matchesPattern(pat, path)) {
        if (std.mem.endsWith(u8, pat, "/*")) {
            try testing.expect(std.mem.startsWith(u8, path, pat[0 .. pat.len - 1]));
        } else {
            try testing.expectEqualStrings(pat, path);
        }
    }
}
