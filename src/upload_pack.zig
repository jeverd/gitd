//! Native Git Smart HTTP ref discovery (`GET /info/refs`) and upload-pack
//! (R1.1, R2.1, R2.3, R3.4).

const std = @import("std");
const http = std.http;
const api = @import("api.zig");
const auth = @import("auth.zig");
const git_http = @import("git_http.zig");
const http_util = @import("http_util.zig");
const pktline = @import("pktline.zig");
const repo_git = @import("repo_git.zig");
const repo_name = @import("repo_name.zig");
const server = @import("server.zig");

const zero_oid = "0000000000000000000000000000000000000000";
const upload_pack_v1_caps =
    "multi_ack thin-pack side-band side-band-64k ofs-delta shallow no-progress include-tag multi_ack_detailed no-done";
const receive_pack_v1_caps =
    "report-status report-status-v2 delete-refs side-band-64k quiet atomic ofs-delta object-format=sha1 agent=gitd";

/// Serves `GET /{ns}/{repo}.git/info/refs?service=git-upload-pack|git-receive-pack`
/// directly in-process using libgit2 ref enumeration and pkt-line framing.
pub fn serveInfoRefs(
    app: *server.App,
    request: *http.Server.Request,
    name: repo_name.Name,
    service: git_http.Service,
    git_protocol: []const u8,
    claims: *const auth.Claims,
) api.HandleError!http.Status {
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();

    // Protocol v2 upload-pack discovery is static and requires no ref scan.
    // Keep read_refs-restricted tokens on v1 until POST /git-upload-pack is
    // served natively so git http-backend cannot serve hidden SHAs under v2 (R2.1).
    if (service == .upload_pack and pktline.hasProtocolV2(git_protocol) and !claims.isReadRefRestricted()) {
        writeUploadPackV2Advertisement(&out.writer) catch return api.internal(request);
    } else {
        const repo = repo_git.Repo.open(app.io, app.gpa, app.store, name) catch return api.internal(request);
        const refs = repo.listRefs(service == .upload_pack) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            else => api.internal(request),
        };
        defer refs.deinit(app.gpa);
        writeV1Advertisement(&out.writer, service, &refs, claims) catch return api.internal(request);
    }

    const content_type = switch (service) {
        .upload_pack => "application/x-git-upload-pack-advertisement",
        .receive_pack => "application/x-git-receive-pack-advertisement",
    };
    try request.respond(out.written(), .{
        .keep_alive = http_util.keepAlive(request),
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
    return .ok;
}

pub fn writeUploadPackV2Advertisement(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try pktline.writeLine(w, "# service=git-upload-pack");
    try pktline.writeFlush(w);
    try pktline.writeLine(w, "version 2");
    try pktline.writeLine(w, "agent=gitd");
    try pktline.writeLine(w, "ls-refs=unborn");
    try pktline.writeLine(w, "fetch=shallow wait-for-done");
    try pktline.writeLine(w, "object-format=sha1");
    try pktline.writeFlush(w);
}

pub fn writeV1Advertisement(
    w: *std.Io.Writer,
    service: git_http.Service,
    refs: *const repo_git.Repo.Refs,
    claims: *const auth.Claims,
) std.Io.Writer.Error!void {
    var svc_buf: [64]u8 = undefined;
    const svc_line = std.mem.print(&svc_buf, "# service={s}", .{service.programName()}) catch unreachable;
    try pktline.writeLine(w, svc_line);
    try pktline.writeFlush(w);

    var caps_buf: [512]u8 = undefined;
    const caps = switch (service) {
        .receive_pack => receive_pack_v1_caps,
        .upload_pack => formatUploadPackCaps(&caps_buf, refs, claims),
    };

    var sent_first = false;
    if (service == .upload_pack) {
        if (refs.head_oid) |head_oid| {
            const head_visible = if (refs.head_symref) |sym|
                claims.allowsReadRef(sym)
            else
                !claims.isReadRefRestricted();
            if (head_visible) {
                try writeRefLine(w, &head_oid, "HEAD", caps);
                sent_first = true;
            }
        }
    }

    for (refs.items) |ref| {
        if (!claims.allowsReadRef(ref.name)) continue;
        if (!sent_first) {
            try writeRefLine(w, &ref.oid, ref.name, caps);
            sent_first = true;
        } else {
            try writeRefLine(w, &ref.oid, ref.name, null);
        }
        if (service == .upload_pack) {
            if (ref.peeled) |peeled| {
                var peeled_buf: [1024]u8 = undefined;
                if (std.mem.print(&peeled_buf, "{s} {s}^{{}}\n", .{ peeled, ref.name })) |line| {
                    try pktline.write(w, line);
                } else |_| {}
            }
        }
    }

    if (!sent_first) {
        try writeRefLine(w, zero_oid, "capabilities^{}", caps);
    }
    try pktline.writeFlush(w);
}

fn formatUploadPackCaps(buf: *[512]u8, refs: *const repo_git.Repo.Refs, claims: *const auth.Claims) []const u8 {
    if (refs.head_oid != null) {
        if (refs.head_symref) |sym| {
            if (claims.allowsReadRef(sym)) {
                return std.mem.print(
                    buf,
                    "{s} symref=HEAD:{s} object-format=sha1 agent=gitd",
                    .{ upload_pack_v1_caps, sym },
                ) catch upload_pack_v1_caps ++ " object-format=sha1 agent=gitd";
            }
        }
    }
    return upload_pack_v1_caps ++ " object-format=sha1 agent=gitd";
}

fn writeRefLine(w: *std.Io.Writer, oid: []const u8, name: []const u8, caps: ?[]const u8) std.Io.Writer.Error!void {
    if (caps) |c| {
        const payload_len = oid.len + 1 + name.len + 1 + c.len + 1;
        try w.print("{x:0>4}", .{payload_len + 4});
        try w.writeAll(oid);
        try w.writeByte(' ');
        try w.writeAll(name);
        try w.writeByte(0);
        try w.writeAll(c);
        try w.writeByte('\n');
    } else {
        const payload_len = oid.len + 1 + name.len + 1;
        try w.print("{x:0>4}", .{payload_len + 4});
        try w.writeAll(oid);
        try w.writeByte(' ');
        try w.writeAll(name);
        try w.writeByte('\n');
    }
}

const testing = std.testing;

test "v2 upload-pack advertisement format" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeUploadPackV2Advertisement(&out.writer);

    var r = pktline.Reader.init(out.written());
    try testing.expectEqualStrings("# service=git-upload-pack\n", (try r.next()).?.data);
    try testing.expectEqual(pktline.Packet.flush, (try r.next()).?);
    try testing.expectEqualStrings("version 2\n", (try r.next()).?.data);
    try testing.expectEqualStrings("agent=gitd\n", (try r.next()).?.data);
    try testing.expectEqualStrings("ls-refs=unborn\n", (try r.next()).?.data);
    try testing.expectEqualStrings("fetch=shallow wait-for-done\n", (try r.next()).?.data);
    try testing.expectEqualStrings("object-format=sha1\n", (try r.next()).?.data);
    try testing.expectEqual(pktline.Packet.flush, (try r.next()).?);
    try testing.expect((try r.next()) == null);
}

test "v1 upload-pack and receive-pack advertisements respect empty repos, tags, and read_refs" {
    var claims: auth.Claims = .{
        .repo_id = @splat('a'),
        .scopes = .{ .git_read = true, .git_write = true },
        .expires_at = 999999,
    };

    // Empty repo -> capabilities^{}
    const empty_refs: repo_git.Repo.Refs = .{ .raw = &.{}, .items = &.{} };
    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try writeV1Advertisement(&out.writer, .upload_pack, &empty_refs, &claims);
        var r = pktline.Reader.init(out.written());
        try testing.expectEqualStrings("# service=git-upload-pack\n", (try r.next()).?.data);
        try testing.expectEqual(pktline.Packet.flush, (try r.next()).?);
        const line = (try r.next()).?.data;
        try testing.expect(std.mem.startsWith(u8, line, zero_oid ++ " capabilities^{}\x00"));
        try testing.expect(std.mem.find(u8, line, "symref=HEAD:") == null);
        try testing.expectEqual(pktline.Packet.flush, (try r.next()).?);
    }

    // Populated repo with HEAD, secret branch, agent branch, and annotated tag.
    const oid1 = "1111111111111111111111111111111111111111".*;
    const oid2 = "2222222222222222222222222222222222222222".*;
    const tag_oid = "3333333333333333333333333333333333333333".*;
    var items = [_]repo_git.Repo.RefInfo{
        .{ .name = "refs/heads/agent/1", .oid = oid2 },
        .{ .name = "refs/heads/main", .oid = oid1 },
        .{ .name = "refs/tags/v1", .oid = tag_oid, .peeled = oid1 },
    };
    const refs: repo_git.Repo.Refs = .{
        .raw = &.{},
        .head_symref = "refs/heads/main",
        .head_oid = oid1,
        .items = &items,
    };

    // Unrestricted upload-pack includes HEAD + symref + all refs + peeled tag.
    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try writeV1Advertisement(&out.writer, .upload_pack, &refs, &claims);
        var r = pktline.Reader.init(out.written());
        try testing.expectEqualStrings("# service=git-upload-pack\n", (try r.next()).?.data);
        try testing.expectEqual(pktline.Packet.flush, (try r.next()).?);
        const l1 = (try r.next()).?.data;
        try testing.expect(std.mem.startsWith(u8, l1, &oid1 ++ " HEAD\x00"));
        try testing.expect(std.mem.find(u8, l1, "symref=HEAD:refs/heads/main") != null);
        try testing.expectEqualStrings(&oid2 ++ " refs/heads/agent/1\n", (try r.next()).?.data);
        try testing.expectEqualStrings(&oid1 ++ " refs/heads/main\n", (try r.next()).?.data);
        try testing.expectEqualStrings(&tag_oid ++ " refs/tags/v1\n", (try r.next()).?.data);
        try testing.expectEqualStrings(&oid1 ++ " refs/tags/v1^{}\n", (try r.next()).?.data);
        try testing.expectEqual(pktline.Packet.flush, (try r.next()).?);
    }

    // Receive-pack omits HEAD and peeled tags.
    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try writeV1Advertisement(&out.writer, .receive_pack, &refs, &claims);
        var r = pktline.Reader.init(out.written());
        try testing.expectEqualStrings("# service=git-receive-pack\n", (try r.next()).?.data);
        try testing.expectEqual(pktline.Packet.flush, (try r.next()).?);
        const l1 = (try r.next()).?.data;
        try testing.expect(std.mem.startsWith(u8, l1, &oid2 ++ " refs/heads/agent/1\x00report-status"));
        try testing.expectEqualStrings(&oid1 ++ " refs/heads/main\n", (try r.next()).?.data);
        try testing.expectEqualStrings(&tag_oid ++ " refs/tags/v1\n", (try r.next()).?.data);
        try testing.expectEqual(pktline.Packet.flush, (try r.next()).?);
    }

    // Restricted read_refs hides HEAD, main, and tags.
    try claims.addReadRefPattern("refs/heads/agent/*");
    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try writeV1Advertisement(&out.writer, .upload_pack, &refs, &claims);
        var r = pktline.Reader.init(out.written());
        try testing.expectEqualStrings("# service=git-upload-pack\n", (try r.next()).?.data);
        try testing.expectEqual(pktline.Packet.flush, (try r.next()).?);
        const l1 = (try r.next()).?.data;
        try testing.expect(std.mem.startsWith(u8, l1, &oid2 ++ " refs/heads/agent/1\x00"));
        try testing.expect(std.mem.find(u8, l1, "symref=HEAD:") == null);
        try testing.expectEqual(pktline.Packet.flush, (try r.next()).?);
    }
}
