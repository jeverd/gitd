//! Ref names and ref patterns (R2.3).
//!
//! gitd accepts a strict subset of git's ref names: `refs/` then segments of
//! `A-Z a-z 0-9 . _ -`, separated by single slashes. No segment starts with
//! `.` or ends with `.lock`, there is no `..` or `@{`, and the whole name is
//! at most 255 bytes. Anything git would reject, gitd rejects first.
//!
//! A pattern is an exact ref name, or a ref name prefix ending in `/*`
//! that matches every ref under it: `refs/heads/agent/7/*`. `refs/*`
//! matches everything.

const std = @import("std");

pub const max_len = 255;
pub const Error = error{InvalidRefName};

pub fn validate(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_len) return error.InvalidRefName;
    if (!std.mem.startsWith(u8, name, "refs/")) return error.InvalidRefName;
    var it = std.mem.splitScalar(u8, name, '/');
    var count: usize = 0;
    while (it.next()) |segment| : (count += 1) try validateSegment(segment);
    if (count < 2) return error.InvalidRefName;
}

/// A branch name without `refs/heads/`, as the API takes it.
pub fn validateBranch(branch: []const u8, buf: *[max_len]u8) Error![]const u8 {
    const prefix = "refs/heads/";
    if (branch.len + prefix.len > max_len) return error.InvalidRefName;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..branch.len], branch);
    const full = buf[0 .. prefix.len + branch.len];
    try validate(full);
    if (std.mem.eql(u8, full, prefix[0 .. prefix.len - 1])) return error.InvalidRefName;
    return full;
}

fn validateSegment(segment: []const u8) Error!void {
    if (segment.len == 0 or segment[0] == '.' or segment[segment.len - 1] == '.') return error.InvalidRefName;
    if (std.mem.endsWith(u8, segment, ".lock")) return error.InvalidRefName;
    if (std.mem.find(u8, segment, "..") != null) return error.InvalidRefName;
    for (segment) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
        if (!ok) return error.InvalidRefName;
    }
}

pub fn validatePattern(pattern: []const u8) Error!void {
    if (std.mem.endsWith(u8, pattern, "/*")) {
        const prefix = pattern[0 .. pattern.len - 2];
        if (std.mem.eql(u8, prefix, "refs")) return;
        return validate(prefix);
    }
    return validate(pattern);
}

/// Whether `ref` matches `pattern`. Both must already be valid.
pub fn matches(pattern: []const u8, ref: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "/*")) {
        const prefix = pattern[0 .. pattern.len - 1];
        return ref.len > prefix.len and std.mem.startsWith(u8, ref, prefix);
    }
    return std.mem.eql(u8, pattern, ref);
}

const testing = std.testing;

test "valid and invalid ref names" {
    for ([_][]const u8{ "refs/heads/main", "refs/heads/agent/7/try-1", "refs/tags/v1.0", "refs/heads/A_b.c" }) |n| try validate(n);
    for ([_][]const u8{
        "",                  "main",             "refs",            "refs/",
        "refs/heads/",       "refs//heads",      "refs/heads/../x", "refs/heads/.x",
        "refs/heads/x.lock", "refs/heads/a b",   "refs/heads/a~1",  "refs/heads/a^",
        "refs/heads/a:b",    "refs/heads/a@{1}", "refs/heads/a\\b", "refs/heads/\x00",
        "refs/heads/x/",     "refs/heads/x.",    "refs/heads/a./b",
    }) |n| try testing.expectError(error.InvalidRefName, validate(n));
}

test "patterns match exact refs and subtrees" {
    try validatePattern("refs/*");
    try validatePattern("refs/heads/agent/7/*");
    try validatePattern("refs/heads/main");
    try testing.expectError(error.InvalidRefName, validatePattern("refs/heads/a*"));
    try testing.expectError(error.InvalidRefName, validatePattern("*"));
    try testing.expectError(error.InvalidRefName, validatePattern("refs/heads/../*"));

    try testing.expect(matches("refs/*", "refs/heads/main"));
    try testing.expect(matches("refs/heads/agent/7/*", "refs/heads/agent/7/try"));
    try testing.expect(!matches("refs/heads/agent/7/*", "refs/heads/agent/7"));
    try testing.expect(!matches("refs/heads/agent/7/*", "refs/heads/agent/70/x"));
    try testing.expect(!matches("refs/heads/agent/7/*", "refs/heads/main"));
    try testing.expect(matches("refs/heads/main", "refs/heads/main"));
    try testing.expect(!matches("refs/heads/main", "refs/heads/main2"));
}

test "branch names" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("refs/heads/agent/1", try validateBranch("agent/1", &buf));
    try testing.expectError(error.InvalidRefName, validateBranch("", &buf));
    try testing.expectError(error.InvalidRefName, validateBranch("../main", &buf));
}

test "fuzz validate and matches" {
    try testing.fuzz({}, fuzzRefs, .{ .corpus = &.{ "refs/heads/main", "refs/heads/agent/*" } });
}

fn fuzzRefs(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_len + 8]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    if (validate(input)) |_| {
        try testing.expect(std.mem.find(u8, input, "..") == null);
        try testing.expect(std.mem.find(u8, input, "//") == null);
        try testing.expect(matches("refs/*", input));
    } else |_| {}
    if (validatePattern(input)) |_| {
        try testing.expect(!matches(input, "HEAD"));
    } else |_| {}
}
