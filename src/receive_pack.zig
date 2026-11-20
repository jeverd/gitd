//! Reads the ref update commands at the start of a `git-receive-pack`
//! request body, before git sees it (R2.2, R2.3).
//!
//! The body is pkt-lines: optional `shallow <oid>` lines, then one command
//! per ref, `<old-oid> <new-oid> <refname>`, the first followed by NUL and
//! capabilities, then a flush packet (`0000`). The pack data that follows
//! is not read. Push certificates are refused: gitd does not advertise
//! them, and their commands sit inside a signed block.

const std = @import("std");
const ref_name = @import("ref_name.zig");

pub const max_commands = 512;
/// Commands must fit in this many leading bytes of the body.
pub const max_commands_bytes = 1024 * 1024;

pub const Command = struct {
    /// Slices borrow the parsed bytes.
    old: []const u8,
    new: []const u8,
    ref: []const u8,

    pub fn isDelete(c: Command) bool {
        return isZero(c.new);
    }
    pub fn isCreate(c: Command) bool {
        return isZero(c.old);
    }
};

pub const ParseError = error{ InvalidPush, TooManyCommands };

/// Parses commands from `bytes`, which holds the start of the body (up to
/// `max_commands_bytes`). Writes them into `out` and returns the used part.
pub fn parse(bytes: []const u8, out: *[max_commands]Command) ParseError![]Command {
    var pos: usize = 0;
    var count: usize = 0;
    var saw_shallow_done = false;
    while (true) {
        if (bytes.len - pos < 4) return error.InvalidPush;
        const len = std.fmt.parseInt(u16, bytes[pos..][0..4], 16) catch return error.InvalidPush;
        if (len == 0) {
            // The flush that ends the command list. A push with no commands
            // (git's probe request) is just a flush.
            return out[0..count];
        }
        if (len < 5 or len > bytes.len - pos) return error.InvalidPush;
        var line = bytes[pos + 4 .. pos + len];
        pos += len;
        if (line[line.len - 1] == '\n') line = line[0 .. line.len - 1];

        if (std.mem.startsWith(u8, line, "shallow ")) {
            if (saw_shallow_done) return error.InvalidPush;
            if (!isOid(line["shallow ".len..])) return error.InvalidPush;
            continue;
        }
        saw_shallow_done = true;
        if (std.mem.startsWith(u8, line, "push-cert")) return error.InvalidPush;
        if (count == 0) {
            // Capabilities follow a NUL on the first command only.
            if (std.mem.findScalar(u8, line, 0)) |nul| line = line[0..nul];
        } else if (std.mem.findScalar(u8, line, 0) != null) return error.InvalidPush;

        if (count == max_commands) return error.TooManyCommands;
        out[count] = try parseCommand(line);
        count += 1;
    }
}

fn parseCommand(line: []const u8) ParseError!Command {
    const first = std.mem.findScalar(u8, line, ' ') orelse return error.InvalidPush;
    const old = line[0..first];
    const rest = line[first + 1 ..];
    const second = std.mem.findScalar(u8, rest, ' ') orelse return error.InvalidPush;
    const new = rest[0..second];
    const ref = rest[second + 1 ..];
    if (!isOid(old) or !isOid(new) or old.len != new.len) return error.InvalidPush;
    ref_name.validate(ref) catch return error.InvalidPush;
    return .{ .old = old, .new = new, .ref = ref };
}

pub fn isOid(text: []const u8) bool {
    if (text.len != 40 and text.len != 64) return false;
    for (text) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

pub fn isZero(oid: []const u8) bool {
    for (oid) |c| if (c != '0') return false;
    return true;
}

const testing = std.testing;
const zero = "0000000000000000000000000000000000000000";
const a = "1111111111111111111111111111111111111111";
const b = "2222222222222222222222222222222222222222";

inline fn pkt(comptime payload: []const u8) []const u8 {
    return comptime std.fmt.comptimePrint("{x:0>4}", .{payload.len + 4}) ++ payload;
}

test "parses commands, capabilities, and shallow lines" {
    var out: [max_commands]Command = undefined;
    const body = pkt("shallow " ++ a ++ "\n") ++
        pkt(zero ++ " " ++ a ++ " refs/heads/agent/1\x00report-status side-band-64k\n") ++
        pkt(a ++ " " ++ zero ++ " refs/heads/old") ++
        "0000PACK...";
    const cmds = try parse(body, &out);
    try testing.expectEqual(@as(usize, 2), cmds.len);
    try testing.expectEqualStrings("refs/heads/agent/1", cmds[0].ref);
    try testing.expect(cmds[0].isCreate());
    try testing.expect(cmds[1].isDelete());
}

test "an empty probe push has no commands" {
    var out: [max_commands]Command = undefined;
    try testing.expectEqual(@as(usize, 0), (try parse("0000", &out)).len);
}

test "rejects malformed pushes" {
    var out: [max_commands]Command = undefined;
    const bad = [_][]const u8{
        "",
        "00",
        "zzzz",
        "0003",
        pkt(a ++ " " ++ b ++ " refs/heads/main"), // no flush
        pkt(a ++ " " ++ b ++ " main") ++ "0000", // not under refs/
        pkt(a ++ " " ++ b ++ " refs/heads/../x") ++ "0000",
        pkt(a ++ " " ++ b[0..39] ++ " refs/heads/x") ++ "0000",
        pkt("push-cert\x00caps") ++ "0000",
        pkt(a ++ " " ++ b ++ " refs/heads/x\x00caps") ++ pkt(a ++ " " ++ b ++ " refs/heads/y\x00more") ++ "0000",
        pkt(a ++ " " ++ b ++ " refs/heads/x") ++ pkt("shallow " ++ a) ++ "0000",
        "00ff" ++ a,
    };
    for (bad) |body| try testing.expectError(error.InvalidPush, parse(body, &out));
}

test "fuzz parse commands" {
    try testing.fuzz({}, fuzzParse, .{ .corpus = &.{ "0000", pkt(zero ++ " " ++ a ++ " refs/heads/x\x00caps") ++ "0000" } });
}

fn fuzzParse(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var out: [max_commands]Command = undefined;
    const cmds = parse(input, &out) catch return;
    for (cmds) |c| {
        try ref_name.validate(c.ref);
        try testing.expect(isOid(c.old) and isOid(c.new));
    }
}
