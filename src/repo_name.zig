//! Repo names: `{namespace}/{repo}`, such as `acme/web`.
//!
//! Names become paths on disk and in URLs, so the rules are strict (R2.3):
//! each part is 1-64 bytes of `a-z`, `0-9`, `.`, `_`, `-`, starts with a
//! letter or digit, has no `..`, and does not end in `.git` or `.lock`.
//! That rules out path traversal, hidden files, percent-encoding, and
//! anything git treats specially.

const std = @import("std");

pub const max_part_len = 64;
pub const max_len = max_part_len * 2 + 1;

pub const Error = error{InvalidRepoName};

/// A validated repo name. The slices borrow from the input.
pub const Name = struct {
    full: []const u8,
    namespace: []const u8,
    repo: []const u8,
};

pub fn parse(text: []const u8) Error!Name {
    if (text.len == 0 or text.len > max_len) return error.InvalidRepoName;
    const slash = std.mem.findScalar(u8, text, '/') orelse return error.InvalidRepoName;
    const namespace = text[0..slash];
    const repo = text[slash + 1 ..];
    try validatePart(namespace);
    try validatePart(repo);
    return .{ .full = text, .namespace = namespace, .repo = repo };
}

fn validatePart(part: []const u8) Error!void {
    if (part.len == 0 or part.len > max_part_len) return error.InvalidRepoName;
    if (!isAlnum(part[0])) return error.InvalidRepoName;
    for (part) |c| {
        if (!(isAlnum(c) or c == '.' or c == '_' or c == '-')) return error.InvalidRepoName;
    }
    if (std.mem.find(u8, part, "..") != null) return error.InvalidRepoName;
    if (std.mem.endsWith(u8, part, ".git") or std.mem.endsWith(u8, part, ".lock")) {
        return error.InvalidRepoName;
    }
}

fn isAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

test "valid names" {
    const n = try parse("acme/web");
    try std.testing.expectEqualStrings("acme", n.namespace);
    try std.testing.expectEqualStrings("web", n.repo);
    _ = try parse("a/b");
    _ = try parse("team-1/my_repo.v2");
    _ = try parse(&repeat(max_part_len, 'x') ++ "/" ++ &repeat(max_part_len, 'y'));
}

fn repeat(comptime n: usize, comptime c: u8) [n]u8 {
    return @splat(c);
}

test "invalid names" {
    const bad = [_][]const u8{
        "",               "acme",            "acme/",                                "/web",
        "acme/web/extra", "../web",          "acme/..",                              "acme/.hidden",
        "Acme/web",       "acme/web.git",    "acme/web.lock",                        "acme/we b",
        "acme/web%2f",    "acme/-web",       "acme/_web",                            "acme//web",
        "acme/web\x00",   "acme/w\xc3\xa9b", &repeat(max_part_len + 1, 'x') ++ "/y", "eb..b/b",
    };
    for (bad) |name| {
        try std.testing.expectError(error.InvalidRepoName, parse(name));
    }
}

test "fuzz parse" {
    try std.testing.fuzz({}, fuzzParse, .{ .corpus = &.{ "acme/web", "../x", "a/b.git" } });
}

fn fuzzParse(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_len + 8]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    const name = parse(input) catch return;
    try std.testing.expect(std.mem.find(u8, name.full, "..") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.countScalar(u8, name.full, '/'));
    try std.testing.expect(name.full[0] != '.' and name.repo[0] != '.');
}
