//! Pure in-memory surgical edit and unified-diff application (R1.1, R2.3, R3.3, R5.1).

const std = @import("std");

pub const max_edits_per_file = 64;
pub const max_hunks_per_patch = 256;
pub const max_patch_line_num = 1_000_000;

pub const Edit = struct {
    old: []const u8,
    new: []const u8,
    replace_all: bool = false,
};

pub const ApplyError = error{
    TooManyEdits,
    EmptyOld,
    EditNotFound,
    EditAmbiguous,
    InvalidPatch,
    HunkMismatch,
    OutputTooLarge,
    OutOfMemory,
};

pub fn applyEdits(
    gpa: std.mem.Allocator,
    base: []const u8,
    edits: []const Edit,
    max_output_bytes: usize,
) ApplyError![]u8 {
    if (base.len > max_output_bytes) return error.OutputTooLarge;
    if (edits.len > max_edits_per_file) return error.TooManyEdits;

    var cur = try gpa.dupe(u8, base);
    errdefer gpa.free(cur);

    for (edits) |e| {
        if (e.old.len == 0) return error.EmptyOld;
        if (!e.replace_all) {
            const pos = std.mem.find(u8, cur, e.old) orelse return error.EditNotFound;
            if (std.mem.findPos(u8, cur, pos + 1, e.old) != null) return error.EditAmbiguous;
            const out_len = checkedSingleReplaceLen(cur.len, e.old.len, e.new.len, max_output_bytes) orelse
                return error.OutputTooLarge;
            const next = try gpa.alloc(u8, out_len);
            @memcpy(next[0..pos], cur[0..pos]);
            @memcpy(next[pos .. pos + e.new.len], e.new);
            @memcpy(next[pos + e.new.len ..], cur[pos + e.old.len ..]);
            gpa.free(cur);
            cur = next;
        } else {
            var count: usize = 0;
            var scan: usize = 0;
            while (std.mem.findPos(u8, cur, scan, e.old)) |idx| {
                count += 1;
                scan = idx + e.old.len;
            }
            if (count == 0) return error.EditNotFound;
            const out_len = checkedMultiReplaceLen(cur.len, count, e.old.len, e.new.len, max_output_bytes) orelse
                return error.OutputTooLarge;
            const next = try gpa.alloc(u8, out_len);
            var src: usize = 0;
            var dst: usize = 0;
            while (std.mem.findPos(u8, cur, src, e.old)) |idx| {
                const prefix = idx - src;
                @memcpy(next[dst .. dst + prefix], cur[src..idx]);
                dst += prefix;
                @memcpy(next[dst .. dst + e.new.len], e.new);
                dst += e.new.len;
                src = idx + e.old.len;
            }
            const rem = cur.len - src;
            @memcpy(next[dst .. dst + rem], cur[src..]);
            gpa.free(cur);
            cur = next;
        }
    }
    return cur;
}

fn checkedSingleReplaceLen(cur_len: usize, old_len: usize, new_len: usize, limit: usize) ?usize {
    const shrunk = cur_len - old_len;
    const total = std.math.add(usize, shrunk, new_len) catch return null;
    if (total > limit) return null;
    return total;
}

fn checkedMultiReplaceLen(cur_len: usize, count: usize, old_len: usize, new_len: usize, limit: usize) ?usize {
    const old_total = std.math.mul(usize, count, old_len) catch return null;
    const new_total = std.math.mul(usize, count, new_len) catch return null;
    const shrunk = cur_len - old_total;
    const total = std.math.add(usize, shrunk, new_total) catch return null;
    if (total > limit) return null;
    return total;
}

const SplitResult = struct {
    lines: [][]const u8,
    trailing_nl: bool,
};

fn splitLinesPreservingEof(gpa: std.mem.Allocator, text: []const u8) !SplitResult {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    if (text.len == 0) {
        return .{ .lines = try list.toOwnedSlice(gpa), .trailing_nl = false };
    }
    const trailing_nl = text[text.len - 1] == '\n';
    const body = if (trailing_nl) text[0 .. text.len - 1] else text;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| try list.append(gpa, line);
    return .{ .lines = try list.toOwnedSlice(gpa), .trailing_nl = trailing_nl };
}

const HunkHeader = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
};

fn parseHunkRange(part: []const u8, prefix: u8) ?struct { start: usize, count: usize } {
    if (part.len < 2 or part[0] != prefix) return null;
    const rest = part[1..];
    if (std.mem.findScalar(u8, rest, ',')) |comma| {
        const s = std.fmt.parseInt(usize, rest[0..comma], 10) catch return null;
        const c = std.fmt.parseInt(usize, rest[comma + 1 ..], 10) catch return null;
        if (s > max_patch_line_num or c > max_patch_line_num) return null;
        return .{ .start = s, .count = c };
    }
    const s = std.fmt.parseInt(usize, rest, 10) catch return null;
    if (s > max_patch_line_num) return null;
    return .{ .start = s, .count = 1 };
}

fn parseHunkHeader(line: []const u8) ?HunkHeader {
    if (!std.mem.startsWith(u8, line, "@@ -")) return null;
    const after_open = line["@@ ".len..];
    const close_rel = std.mem.find(u8, after_open, " @@") orelse return null;
    const range_str = after_open[0..close_rel];
    const space = std.mem.findScalar(u8, range_str, ' ') orelse return null;
    const old_part = range_str[0..space];
    const new_part = range_str[space + 1 ..];
    const old_r = parseHunkRange(old_part, '-') orelse return null;
    const new_r = parseHunkRange(new_part, '+') orelse return null;
    return .{
        .old_start = old_r.start,
        .old_count = old_r.count,
        .new_start = new_r.start,
        .new_count = new_r.count,
    };
}

fn isNoNewlineMarker(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "\\ No newline");
}

fn isDiffMetaLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "diff ") or
        std.mem.startsWith(u8, line, "index ") or
        std.mem.startsWith(u8, line, "new file") or
        std.mem.startsWith(u8, line, "deleted file") or
        std.mem.startsWith(u8, line, "old mode") or
        std.mem.startsWith(u8, line, "new mode") or
        std.mem.startsWith(u8, line, "--- ") or
        std.mem.startsWith(u8, line, "+++ ");
}

/// Applies a unified diff string (`@@ -a,b +c,d @@`) to `base`.
/// Strict context matching rejects stale/ambiguous patches with `HunkMismatch`.
pub fn applyUnifiedPatch(
    gpa: std.mem.Allocator,
    base: []const u8,
    diff: []const u8,
    max_output_bytes: usize,
) ApplyError![]u8 {
    if (base.len > max_output_bytes) return error.OutputTooLarge;
    if (diff.len == 0) return error.InvalidPatch;

    const base_split = try splitLinesPreservingEof(gpa, base);
    defer gpa.free(base_split.lines);
    const diff_split = try splitLinesPreservingEof(gpa, diff);
    defer gpa.free(diff_split.lines);

    const base_lines = base_split.lines;
    const diff_lines = diff_split.lines;

    var out_lines: std.ArrayList([]const u8) = .empty;
    defer out_lines.deinit(gpa);

    var di: usize = 0;
    while (di < diff_lines.len and isDiffMetaLine(diff_lines[di])) : (di += 1) {}
    if (di >= diff_lines.len) return error.InvalidPatch;

    var base_cursor: usize = 0;
    var hunks: usize = 0;
    var out_trailing_nl = if (base.len == 0) true else base_split.trailing_nl;

    while (di < diff_lines.len) {
        if (diff_lines[di].len == 0 and hunks > 0 and di + 1 == diff_lines.len) break;
        const hdr = parseHunkHeader(diff_lines[di]) orelse return error.InvalidPatch;
        di += 1;
        hunks += 1;
        if (hunks > max_hunks_per_patch) return error.InvalidPatch;

        if (hdr.old_count > 0 and hdr.old_start == 0) return error.InvalidPatch;
        if (hdr.new_count > 0 and hdr.new_start == 0) return error.InvalidPatch;
        const target_idx = if (hdr.old_count == 0) hdr.old_start else hdr.old_start - 1;
        if (target_idx < base_cursor or target_idx > base_lines.len) return error.HunkMismatch;

        while (base_cursor < target_idx) : (base_cursor += 1) {
            try out_lines.append(gpa, base_lines[base_cursor]);
        }

        const expected_out_idx = if (hdr.new_count == 0) hdr.new_start else hdr.new_start - 1;
        if (out_lines.items.len != expected_out_idx) return error.HunkMismatch;

        var old_seen: usize = 0;
        var new_seen: usize = 0;
        const LastOp = enum { none, ctx, del, add };
        var last_op: LastOp = .none;

        while (old_seen < hdr.old_count or new_seen < hdr.new_count) {
            if (di >= diff_lines.len) return error.InvalidPatch;
            const dline = diff_lines[di];
            di += 1;
            if (dline.len == 0) return error.InvalidPatch;
            switch (dline[0]) {
                ' ' => {
                    if (old_seen >= hdr.old_count or new_seen >= hdr.new_count) return error.InvalidPatch;
                    if (base_cursor >= base_lines.len or !std.mem.eql(u8, base_lines[base_cursor], dline[1..])) {
                        return error.HunkMismatch;
                    }
                    try out_lines.append(gpa, base_lines[base_cursor]);
                    base_cursor += 1;
                    old_seen += 1;
                    new_seen += 1;
                    last_op = .ctx;
                },
                '-' => {
                    if (old_seen >= hdr.old_count) return error.InvalidPatch;
                    if (base_cursor >= base_lines.len or !std.mem.eql(u8, base_lines[base_cursor], dline[1..])) {
                        return error.HunkMismatch;
                    }
                    base_cursor += 1;
                    old_seen += 1;
                    last_op = .del;
                    if (di < diff_lines.len and isNoNewlineMarker(diff_lines[di])) {
                        di += 1;
                        if (base_cursor != base_lines.len or base_split.trailing_nl) return error.HunkMismatch;
                        out_trailing_nl = true;
                    }
                },
                '+' => {
                    if (new_seen >= hdr.new_count) return error.InvalidPatch;
                    try out_lines.append(gpa, dline[1..]);
                    new_seen += 1;
                    last_op = .add;
                    if (base_cursor == base_lines.len) out_trailing_nl = true;
                    if (di < diff_lines.len and isNoNewlineMarker(diff_lines[di])) {
                        di += 1;
                        out_trailing_nl = false;
                    }
                },
                else => return error.InvalidPatch,
            }
            if (last_op == .ctx and di < diff_lines.len and isNoNewlineMarker(diff_lines[di])) {
                di += 1;
                if (base_cursor != base_lines.len or base_split.trailing_nl) return error.HunkMismatch;
                out_trailing_nl = false;
            }
        }
    }
    if (hunks == 0) return error.InvalidPatch;

    while (base_cursor < base_lines.len) : (base_cursor += 1) {
        try out_lines.append(gpa, base_lines[base_cursor]);
    }
    if (out_lines.items.len == 0) return try gpa.alloc(u8, 0);

    var total: usize = 0;
    for (out_lines.items, 0..) |line, i| {
        total = std.math.add(usize, total, line.len) catch return error.OutputTooLarge;
        if (i + 1 < out_lines.items.len or out_trailing_nl) {
            total = std.math.add(usize, total, 1) catch return error.OutputTooLarge;
        }
        if (total > max_output_bytes) return error.OutputTooLarge;
    }

    const out = try gpa.alloc(u8, total);
    var pos: usize = 0;
    for (out_lines.items, 0..) |line, i| {
        @memcpy(out[pos .. pos + line.len], line);
        pos += line.len;
        if (i + 1 < out_lines.items.len or out_trailing_nl) {
            out[pos] = '\n';
            pos += 1;
        }
    }
    return out;
}

const testing = std.testing;

test "applyEdits handles single, sequential, replace_all, and error cases" {
    const base = "line 1\nalpha = 1\nbeta = 2\nline 4\n";
    const out = try applyEdits(testing.allocator, base, &.{
        .{ .old = "alpha = 1", .new = "alpha = 42" },
        .{ .old = "beta = 2", .new = "beta = 99" },
    }, 1024);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("line 1\nalpha = 42\nbeta = 99\nline 4\n", out);

    const all = try applyEdits(testing.allocator, "foo bar foo baz foo", &.{
        .{ .old = "foo", .new = "qux", .replace_all = true },
    }, 1024);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("qux bar qux baz qux", all);

    try testing.expectError(error.EditNotFound, applyEdits(testing.allocator, base, &.{.{ .old = "missing", .new = "x" }}, 1024));
    try testing.expectError(error.EditAmbiguous, applyEdits(testing.allocator, "aa", &.{.{ .old = "a", .new = "b" }}, 1024));
    try testing.expectError(error.EditAmbiguous, applyEdits(testing.allocator, "aaa", &.{.{ .old = "aa", .new = "b" }}, 1024));
    try testing.expectError(error.EmptyOld, applyEdits(testing.allocator, base, &.{.{ .old = "", .new = "x" }}, 1024));
    try testing.expectError(error.OutputTooLarge, applyEdits(testing.allocator, "ab", &.{.{ .old = "ab", .new = "12345" }}, 4));
}

test "applyUnifiedPatch handles multi-hunk, EOF newline, and mismatches" {
    const base = "a\nb\nc\nd\ne\nf\n";
    const diff =
        \\--- a/f.txt
        \\+++ b/f.txt
        \\@@ -1,3 +1,3 @@
        \\ a
        \\-b
        \\+B_NEW
        \\ c
        \\@@ -5,2 +5,3 @@
        \\ e
        \\ f
        \\+g
        \\
    ;
    const out = try applyUnifiedPatch(testing.allocator, base, diff, 1024);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\nB_NEW\nc\nd\ne\nf\ng\n", out);

    const added = try applyUnifiedPatch(testing.allocator, "", "@@ -0,0 +1,2 @@\n+hello\n+world\n", 1024);
    defer testing.allocator.free(added);
    try testing.expectEqualStrings("hello\nworld\n", added);

    const no_nl = try applyUnifiedPatch(testing.allocator, "a\nb", "@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+B\n\\ No newline at end of file\n", 1024);
    defer testing.allocator.free(no_nl);
    try testing.expectEqualStrings("a\nB", no_nl);

    try testing.expectError(error.HunkMismatch, applyUnifiedPatch(testing.allocator, base, "@@ -1,2 +1,2 @@\n a\n-WRONG\n+b\n", 1024));
    try testing.expectError(error.InvalidPatch, applyUnifiedPatch(testing.allocator, "", "@@ -0,0 +0,1 @@\n+bad\n", 1024));
    try testing.expectError(error.InvalidPatch, applyUnifiedPatch(testing.allocator, base, "not a patch", 1024));
    try testing.expectError(error.OutputTooLarge, applyUnifiedPatch(testing.allocator, "a\n", "@@ -1 +1,2 @@\n a\n+12345\n", 4));
}

test "fuzz apply patch" {
    try testing.fuzz({}, fuzzApplyPatch, .{
        .corpus = &.{
            "a\nb\n\x00@@ -1,2 +1,2 @@\n a\n-b\n+c\n",
            "hello world\x00world\x00zig",
        },
    });
}

fn fuzzApplyPatch(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const raw = buf[0..smith.slice(&buf)];
    const sep = std.mem.findScalar(u8, raw, 0) orelse return;
    const base = raw[0..sep];
    const rest = raw[sep + 1 ..];

    if (applyUnifiedPatch(testing.allocator, base, rest, 4096)) |out| {
        try testing.expect(out.len <= 4096);
        testing.allocator.free(out);
    } else |_| {}

    if (std.mem.findScalar(u8, rest, 0)) |sep2| {
        const old = rest[0..sep2];
        const new = rest[sep2 + 1 ..];
        if (applyEdits(testing.allocator, base, &.{.{ .old = old, .new = new }}, 4096)) |out| {
            try testing.expect(out.len <= 4096);
            testing.allocator.free(out);
        } else |_| {}
    }
}
