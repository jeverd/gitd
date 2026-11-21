//! Native Git Smart HTTP ref discovery (`GET /info/refs`) and `git-upload-pack`
//! (protocol v0/v1 and v2 `ls-refs` / `fetch`, R1.1, R2.1, R2.3, R3.4, R5.2).

const std = @import("std");
const Io = std.Io;
const http = std.http;
const api = @import("api.zig");
const auth = @import("auth.zig");
const git2 = @import("git2.zig");
const git_http = @import("git_http.zig");
const http_util = @import("http_util.zig");
const pktline = @import("pktline.zig");
const receive_pack = @import("receive_pack.zig");
const repo_git = @import("repo_git.zig");
const repo_name = @import("repo_name.zig");
const server = @import("server.zig");

const zero_oid = "0000000000000000000000000000000000000000";
const upload_pack_v1_caps =
    "multi_ack thin-pack side-band side-band-64k ofs-delta shallow no-progress include-tag multi_ack_detailed no-done";
const receive_pack_v1_caps =
    "report-status report-status-v2 delete-refs side-band-64k quiet atomic ofs-delta object-format=sha1 agent=gitd";

/// Hard caps on untrusted upload-pack request bodies and parsed lists (R2.3, R3.4).
pub const max_request_bytes: usize = 16 * 1024 * 1024;
pub const max_wants: usize = 4096;
pub const max_haves: usize = 16384;
pub const max_ref_prefixes: usize = 256;
pub const max_shallow_commits: usize = 65536;

// ---- Ref discovery: GET /info/refs ----

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

    // Protocol v2 discovery is static and requires no ref scan. Because
    // POST /git-upload-pack is served natively, read_refs isolation is enforced
    // in both v1 and v2 (ls-refs + fetch reachability).
    if (service == .upload_pack and pktline.hasProtocolV2(git_protocol)) {
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

// ---- Pure Request Parsers (v1 and v2) ----

pub const ParseError = error{ InvalidRequest, UnsupportedCommand, TooManyItems, OutOfMemory };

pub const V1Request = struct {
    wants: std.ArrayList([40]u8) = .empty,
    haves: std.ArrayList([40]u8) = .empty,
    shallows: std.ArrayList([40]u8) = .empty,
    caps: []const u8 = "",
    deepen: ?u32 = null,
    done: bool = false,

    pub fn deinit(r: *V1Request, gpa: std.mem.Allocator) void {
        r.wants.deinit(gpa);
        r.haves.deinit(gpa);
        r.shallows.deinit(gpa);
    }
};

pub const V2LsRefsArgs = struct {
    peel: bool = false,
    symrefs: bool = false,
    unborn: bool = false,
    prefixes: std.ArrayList([]const u8) = .empty,

    pub fn deinit(a: *V2LsRefsArgs, gpa: std.mem.Allocator) void {
        a.prefixes.deinit(gpa);
    }
};

pub const V2FetchArgs = struct {
    wants: std.ArrayList([40]u8) = .empty,
    haves: std.ArrayList([40]u8) = .empty,
    shallows: std.ArrayList([40]u8) = .empty,
    deepen: ?u32 = null,
    done: bool = false,
    wait_for_done: bool = false,
    include_tag: bool = false,
    thin_pack: bool = false,
    ofs_delta: bool = false,
    no_progress: bool = false,

    pub fn deinit(a: *V2FetchArgs, gpa: std.mem.Allocator) void {
        a.wants.deinit(gpa);
        a.haves.deinit(gpa);
        a.shallows.deinit(gpa);
    }
};

pub const V2Request = union(enum) {
    ls_refs: V2LsRefsArgs,
    fetch: V2FetchArgs,

    pub fn deinit(r: *V2Request, gpa: std.mem.Allocator) void {
        switch (r.*) {
            .ls_refs => |*a| a.deinit(gpa),
            .fetch => |*a| a.deinit(gpa),
        }
    }
};

fn parseSha1Hex(text: []const u8) ?[40]u8 {
    if (text.len != 40) return null;
    var out: [40]u8 = undefined;
    for (text, 0..) |c, i| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
        out[i] = c;
    }
    return out;
}

fn trimLf(s: []const u8) []const u8 {
    return if (s.len > 0 and s[s.len - 1] == '\n') s[0 .. s.len - 1] else s;
}

pub fn parseV1Request(gpa: std.mem.Allocator, bytes: []const u8) ParseError!V1Request {
    var req: V1Request = .{};
    errdefer req.deinit(gpa);

    var r = pktline.Reader.init(bytes);
    var in_have_phase = false;
    while (true) {
        const packet = (r.next() catch return error.InvalidRequest) orelse break;
        switch (packet) {
            .delim, .response_end => return error.InvalidRequest,
            .flush => {
                if (!in_have_phase) {
                    in_have_phase = true;
                } else {
                    break;
                }
            },
            .data => |raw| {
                const line = trimLf(raw);
                if (!in_have_phase) {
                    if (std.mem.startsWith(u8, line, "want ")) {
                        const rest = line["want ".len..];
                        const sp = std.mem.findScalar(u8, rest, ' ');
                        const oid_str = if (sp) |idx| rest[0..idx] else rest;
                        const oid = parseSha1Hex(oid_str) orelse return error.InvalidRequest;
                        if (req.wants.items.len == 0) {
                            if (sp) |idx| req.caps = rest[idx + 1 ..];
                        } else if (sp != null) {
                            return error.InvalidRequest;
                        }
                        if (req.wants.items.len >= max_wants) return error.TooManyItems;
                        try req.wants.append(gpa, oid);
                    } else if (std.mem.startsWith(u8, line, "shallow ")) {
                        const oid = parseSha1Hex(line["shallow ".len..]) orelse return error.InvalidRequest;
                        if (req.shallows.items.len >= max_wants) return error.TooManyItems;
                        try req.shallows.append(gpa, oid);
                    } else if (std.mem.startsWith(u8, line, "deepen ")) {
                        const n = std.fmt.parseInt(u32, line["deepen ".len..], 10) catch return error.InvalidRequest;
                        if (n == 0) return error.InvalidRequest;
                        req.deepen = n;
                    } else {
                        return error.InvalidRequest;
                    }
                } else {
                    if (std.mem.startsWith(u8, line, "have ")) {
                        const oid = parseSha1Hex(line["have ".len..]) orelse return error.InvalidRequest;
                        if (req.haves.items.len >= max_haves) return error.TooManyItems;
                        try req.haves.append(gpa, oid);
                    } else if (std.mem.eql(u8, line, "done")) {
                        req.done = true;
                        break;
                    } else {
                        return error.InvalidRequest;
                    }
                }
            },
        }
    }
    return req;
}

pub fn parseV2Request(gpa: std.mem.Allocator, bytes: []const u8) ParseError!V2Request {
    var r = pktline.Reader.init(bytes);
    var cmd: ?enum { ls_refs, fetch } = null;
    var saw_delim = false;

    while (true) {
        const packet = (r.next() catch return error.InvalidRequest) orelse return error.InvalidRequest;
        switch (packet) {
            .flush => break,
            .delim => {
                saw_delim = true;
                break;
            },
            .response_end => return error.InvalidRequest,
            .data => |raw| {
                const line = trimLf(raw);
                if (std.mem.startsWith(u8, line, "command=")) {
                    if (cmd != null) return error.InvalidRequest;
                    const name = line["command=".len..];
                    if (std.mem.eql(u8, name, "ls-refs")) {
                        cmd = .ls_refs;
                    } else if (std.mem.eql(u8, name, "fetch")) {
                        cmd = .fetch;
                    } else {
                        return error.UnsupportedCommand;
                    }
                } else if (std.mem.startsWith(u8, line, "agent=") or std.mem.startsWith(u8, line, "object-format=")) {
                    if (std.mem.startsWith(u8, line, "object-format=") and !std.mem.eql(u8, line, "object-format=sha1")) {
                        return error.InvalidRequest;
                    }
                } else {
                    return error.InvalidRequest;
                }
            },
        }
    }

    const chosen = cmd orelse return error.InvalidRequest;
    switch (chosen) {
        .ls_refs => {
            var args: V2LsRefsArgs = .{};
            errdefer args.deinit(gpa);
            if (saw_delim) {
                while (true) {
                    const packet = (r.next() catch return error.InvalidRequest) orelse return error.InvalidRequest;
                    switch (packet) {
                        .flush => break,
                        .delim, .response_end => return error.InvalidRequest,
                        .data => |raw| {
                            const line = trimLf(raw);
                            if (std.mem.eql(u8, line, "peel")) {
                                args.peel = true;
                            } else if (std.mem.eql(u8, line, "symrefs")) {
                                args.symrefs = true;
                            } else if (std.mem.eql(u8, line, "unborn")) {
                                args.unborn = true;
                            } else if (std.mem.startsWith(u8, line, "ref-prefix ")) {
                                if (args.prefixes.items.len >= max_ref_prefixes) return error.TooManyItems;
                                try args.prefixes.append(gpa, line["ref-prefix ".len..]);
                            }
                        },
                    }
                }
            }
            return .{ .ls_refs = args };
        },
        .fetch => {
            var args: V2FetchArgs = .{};
            errdefer args.deinit(gpa);
            if (saw_delim) {
                while (true) {
                    const packet = (r.next() catch return error.InvalidRequest) orelse return error.InvalidRequest;
                    switch (packet) {
                        .flush => break,
                        .delim, .response_end => return error.InvalidRequest,
                        .data => |raw| {
                            const line = trimLf(raw);
                            if (std.mem.startsWith(u8, line, "want ")) {
                                const oid = parseSha1Hex(line["want ".len..]) orelse return error.InvalidRequest;
                                if (args.wants.items.len >= max_wants) return error.TooManyItems;
                                try args.wants.append(gpa, oid);
                            } else if (std.mem.startsWith(u8, line, "have ")) {
                                const oid = parseSha1Hex(line["have ".len..]) orelse return error.InvalidRequest;
                                if (args.haves.items.len >= max_haves) return error.TooManyItems;
                                try args.haves.append(gpa, oid);
                            } else if (std.mem.startsWith(u8, line, "shallow ")) {
                                const oid = parseSha1Hex(line["shallow ".len..]) orelse return error.InvalidRequest;
                                if (args.shallows.items.len >= max_wants) return error.TooManyItems;
                                try args.shallows.append(gpa, oid);
                            } else if (std.mem.startsWith(u8, line, "deepen ")) {
                                const n = std.fmt.parseInt(u32, line["deepen ".len..], 10) catch return error.InvalidRequest;
                                if (n == 0) return error.InvalidRequest;
                                args.deepen = n;
                            } else if (std.mem.eql(u8, line, "done")) {
                                args.done = true;
                            } else if (std.mem.eql(u8, line, "wait-for-done")) {
                                args.wait_for_done = true;
                            } else if (std.mem.eql(u8, line, "include-tag")) {
                                args.include_tag = true;
                            } else if (std.mem.eql(u8, line, "thin-pack")) {
                                args.thin_pack = true;
                            } else if (std.mem.eql(u8, line, "ofs-delta")) {
                                args.ofs_delta = true;
                            } else if (std.mem.eql(u8, line, "no-progress")) {
                                args.no_progress = true;
                            }
                        },
                    }
                }
            }
            return .{ .fetch = args };
        },
    }
}

// ---- Native POST /git-upload-pack Handler ----

const ReadBodyError = error{ BodyTooLarge, ClientGone, InvalidGzip, IoFailed, OutOfMemory };

fn readUploadBody(gpa: std.mem.Allocator, request: *http.Server.Request, is_gzip: bool) ReadBodyError![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);

    var read_buf: [64 * 1024]u8 = undefined;
    const body = request.readerExpectContinue(&read_buf) catch return error.IoFailed;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = body.readSliceShort(&chunk) catch return error.ClientGone;
        if (n == 0) break;
        if (raw.items.len + n > max_request_bytes) return error.BodyTooLarge;
        try raw.appendSlice(gpa, chunk[0..n]);
    }
    if (request.server.reader.state != .ready) return error.ClientGone;

    if (!is_gzip) return try raw.toOwnedSlice(gpa);

    var in_reader = std.Io.Reader.fixed(raw.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&in_reader, .gzip, &window);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        const n = decomp.reader.readSliceShort(&chunk) catch return error.InvalidGzip;
        if (n == 0) break;
        if (out.items.len + n > max_request_bytes) return error.BodyTooLarge;
        try out.appendSlice(gpa, chunk[0..n]);
    }
    return try out.toOwnedSlice(gpa);
}

pub fn serveRpc(
    app: *server.App,
    request: *http.Server.Request,
    name: repo_name.Name,
    git_protocol: []const u8,
    claims: *const auth.Claims,
) api.HandleError!http.Status {
    const is_gzip = switch (request.head.transfer_compression) {
        .identity => false,
        .gzip => true,
        else => return api.respondError(request, .unsupported_media_type, "unsupported_encoding", "only gzip request bodies are supported"),
    };
    const body = readUploadBody(app.gpa, request, is_gzip) catch |err| return switch (err) {
        error.ClientGone => error.ClientGone,
        error.BodyTooLarge => api.respondError(request, .payload_too_large, "too_large", "request body is too large"),
        error.InvalidGzip => api.respondError(request, .bad_request, "bad_git_request", "invalid gzip request body"),
        error.IoFailed, error.OutOfMemory => api.internal(request),
    };
    defer app.gpa.free(body);

    const repo = repo_git.Repo.open(app.io, app.gpa, app.store, name) catch return api.internal(request);
    if (pktline.hasProtocolV2(git_protocol)) {
        return serveV2(app, request, &repo, body, claims);
    }
    return serveV1(app, request, &repo, body, claims);
}

fn serveV2(
    app: *server.App,
    request: *http.Server.Request,
    repo: *const repo_git.Repo,
    body: []const u8,
    claims: *const auth.Claims,
) api.HandleError!http.Status {
    var req = parseV2Request(app.gpa, body) catch |err| return switch (err) {
        error.OutOfMemory => api.internal(request),
        error.InvalidRequest, error.UnsupportedCommand, error.TooManyItems => api.respondError(request, .bad_request, "bad_git_request", "invalid upload-pack v2 request"),
    };
    defer req.deinit(app.gpa);

    switch (req) {
        .ls_refs => |args| return handleV2LsRefs(app, request, repo, &args, claims),
        .fetch => |args| return handleV2Fetch(app, request, repo, &args, claims),
    }
}

fn handleV2LsRefs(
    app: *server.App,
    request: *http.Server.Request,
    repo: *const repo_git.Repo,
    args: *const V2LsRefsArgs,
    claims: *const auth.Claims,
) api.HandleError!http.Status {
    const refs = repo.listRefs(args.peel) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => api.internal(request),
    };
    defer refs.deinit(app.gpa);

    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();

    const want_head = matchesPrefixes(args.prefixes.items, "HEAD");
    if (want_head) {
        const head_visible = if (refs.head_symref) |sym|
            claims.allowsReadRef(sym)
        else
            !claims.isReadRefRestricted();
        if (head_visible) {
            var line_buf: [1024]u8 = undefined;
            if (refs.head_oid) |head_oid| {
                const line = if (args.symrefs and refs.head_symref != null)
                    std.mem.print(&line_buf, "{s} HEAD symref-target:{s}", .{ head_oid, refs.head_symref.? }) catch return api.internal(request)
                else
                    std.mem.print(&line_buf, "{s} HEAD", .{head_oid}) catch return api.internal(request);
                pktline.writeLine(&out.writer, line) catch return api.internal(request);
            } else if (args.unborn and refs.head_symref != null) {
                const line = if (args.symrefs)
                    std.mem.print(&line_buf, "unborn HEAD symref-target:{s}", .{refs.head_symref.?}) catch return api.internal(request)
                else
                    "unborn HEAD";
                pktline.writeLine(&out.writer, line) catch return api.internal(request);
            }
        }
    }

    for (refs.items) |ref| {
        if (!claims.allowsReadRef(ref.name)) continue;
        if (!matchesPrefixes(args.prefixes.items, ref.name)) continue;
        var line_buf: [1024]u8 = undefined;
        const line = if (args.peel and ref.peeled != null)
            std.mem.print(&line_buf, "{s} {s} peeled:{s}", .{ ref.oid, ref.name, ref.peeled.? }) catch return api.internal(request)
        else
            std.mem.print(&line_buf, "{s} {s}", .{ ref.oid, ref.name }) catch return api.internal(request);
        pktline.writeLine(&out.writer, line) catch return api.internal(request);
    }
    pktline.writeFlush(&out.writer) catch return api.internal(request);

    try request.respond(out.written(), .{
        .keep_alive = http_util.keepAlive(request),
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-git-upload-pack-result" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
    return .ok;
}

fn matchesPrefixes(prefixes: []const []const u8, name: []const u8) bool {
    if (prefixes.len == 0) return true;
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, name, p)) return true;
    }
    return false;
}

fn handleV2Fetch(
    app: *server.App,
    request: *http.Server.Request,
    repo: *const repo_git.Repo,
    args: *const V2FetchArgs,
    claims: *const auth.Claims,
) api.HandleError!http.Status {
    const git2_repo = git2.openBare(repo.gitDir()) orelse return api.internal(request);
    defer git2.git_repository_free(git2_repo);

    // Enforce read_refs reachability and object existence for every want (R2.1).
    if (!(checkWantsAllowed(app.gpa, repo, git2_repo, args.wants.items, claims) catch return api.internal(request))) {
        return respondUploadErr(app, request, "not our ref");
    }

    // Determine which `have`s exist locally.
    var common: std.ArrayList(git2.Oid) = .empty;
    defer common.deinit(app.gpa);
    try collectCommonHaves(app.gpa, git2_repo, args.haves.items, &common);

    const ready = args.done or (!args.wait_for_done and common.items.len > 0);
    if (!ready) {
        var out: std.Io.Writer.Allocating = .init(app.gpa);
        defer out.deinit();
        pktline.writeLine(&out.writer, "acknowledgments") catch return api.internal(request);
        if (common.items.len == 0) {
            pktline.writeLine(&out.writer, "NAK") catch return api.internal(request);
        } else {
            for (common.items) |h| {
                var hex: [40]u8 = undefined;
                _ = git2.formatOid(&h, &hex);
                var line_buf: [64]u8 = undefined;
                const line = std.mem.print(&line_buf, "ACK {s}", .{hex}) catch unreachable;
                pktline.writeLine(&out.writer, line) catch return api.internal(request);
            }
        }
        pktline.writeFlush(&out.writer) catch return api.internal(request);
        try request.respond(out.written(), .{
            .keep_alive = http_util.keepAlive(request),
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/x-git-upload-pack-result" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        });
        return .ok;
    }

    var shallow_info: ShallowPlan = .{};
    defer shallow_info.deinit(app.gpa);
    if (args.deepen) |depth| {
        computeShallow(app.gpa, git2_repo, args.wants.items, depth, &shallow_info) catch return api.internal(request);
    }

    var send_buf: [16 * 1024]u8 = undefined;
    var response = request.respondStreaming(&send_buf, .{
        .respond_options = .{
            .status = .ok,
            .keep_alive = http_util.keepAlive(request),
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/x-git-upload-pack-result" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        },
    }) catch return error.ResponseBroken;

    if (!args.done) {
        pktline.writeLine(&response.writer, "acknowledgments") catch return error.ResponseBroken;
        for (common.items) |h| {
            var hex: [40]u8 = undefined;
            _ = git2.formatOid(&h, &hex);
            var line_buf: [64]u8 = undefined;
            const line = std.mem.print(&line_buf, "ACK {s}", .{hex}) catch unreachable;
            pktline.writeLine(&response.writer, line) catch return error.ResponseBroken;
        }
        pktline.writeLine(&response.writer, "ready") catch return error.ResponseBroken;
        pktline.writeDelim(&response.writer) catch return error.ResponseBroken;
    }

    if (args.deepen != null and shallow_info.boundaries.items.len > 0) {
        pktline.writeLine(&response.writer, "shallow-info") catch return error.ResponseBroken;
        for (shallow_info.boundaries.items) |oid| {
            var hex: [40]u8 = undefined;
            _ = git2.formatOid(&oid, &hex);
            var line_buf: [64]u8 = undefined;
            const line = std.mem.print(&line_buf, "shallow {s}", .{hex}) catch unreachable;
            pktline.writeLine(&response.writer, line) catch return error.ResponseBroken;
        }
        pktline.writeDelim(&response.writer) catch return error.ResponseBroken;
    }

    pktline.writeLine(&response.writer, "packfile") catch return error.ResponseBroken;
    streamPack(
        app.gpa,
        repo,
        git2_repo,
        args.wants.items,
        common.items,
        args.shallows.items,
        if (args.deepen != null) shallow_info.included.items else null,
        args.include_tag,
        claims,
        &response.writer,
        pktline.sideband_64k_max,
    ) catch return error.ResponseBroken;
    pktline.writeFlush(&response.writer) catch return error.ResponseBroken;
    response.end() catch return error.ResponseBroken;
    return .ok;
}

fn serveV1(
    app: *server.App,
    request: *http.Server.Request,
    repo: *const repo_git.Repo,
    body: []const u8,
    claims: *const auth.Claims,
) api.HandleError!http.Status {
    var req = parseV1Request(app.gpa, body) catch |err| return switch (err) {
        error.OutOfMemory => api.internal(request),
        error.InvalidRequest, error.UnsupportedCommand, error.TooManyItems => api.respondError(request, .bad_request, "bad_git_request", "invalid upload-pack request"),
    };
    defer req.deinit(app.gpa);

    if (req.wants.items.len == 0) {
        try request.respond("", .{
            .keep_alive = http_util.keepAlive(request),
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/x-git-upload-pack-result" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        });
        return .ok;
    }

    const git2_repo = git2.openBare(repo.gitDir()) orelse return api.internal(request);
    defer git2.git_repository_free(git2_repo);

    if (!(checkWantsAllowed(app.gpa, repo, git2_repo, req.wants.items, claims) catch return api.internal(request))) {
        return respondUploadErr(app, request, "not our ref");
    }

    var common: std.ArrayList(git2.Oid) = .empty;
    defer common.deinit(app.gpa);
    try collectCommonHaves(app.gpa, git2_repo, req.haves.items, &common);

    const multi_ack_detailed = receive_pack.hasCapability(req.caps, "multi_ack_detailed");
    const multi_ack = receive_pack.hasCapability(req.caps, "multi_ack");
    const no_done = receive_pack.hasCapability(req.caps, "no-done");
    const include_tag = receive_pack.hasCapability(req.caps, "include-tag");
    const band_max: usize = if (receive_pack.hasCapability(req.caps, "side-band-64k"))
        pktline.sideband_64k_max
    else if (receive_pack.hasCapability(req.caps, "side-band"))
        pktline.sideband_max
    else
        0;

    const send_pack = req.done or
        (common.items.len > 0 and (no_done or (!multi_ack and !multi_ack_detailed)));

    var shallow_info: ShallowPlan = .{};
    defer shallow_info.deinit(app.gpa);
    if (req.deepen) |depth| {
        computeShallow(app.gpa, git2_repo, req.wants.items, depth, &shallow_info) catch return api.internal(request);
    }

    var send_buf: [16 * 1024]u8 = undefined;
    var response = request.respondStreaming(&send_buf, .{
        .respond_options = .{
            .status = .ok,
            .keep_alive = http_util.keepAlive(request),
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/x-git-upload-pack-result" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        },
    }) catch return error.ResponseBroken;

    if (req.deepen != null) {
        for (shallow_info.boundaries.items) |oid| {
            var hex: [40]u8 = undefined;
            _ = git2.formatOid(&oid, &hex);
            var line_buf: [64]u8 = undefined;
            const line = std.mem.print(&line_buf, "shallow {s}", .{hex}) catch unreachable;
            pktline.writeLine(&response.writer, line) catch return error.ResponseBroken;
        }
        pktline.writeFlush(&response.writer) catch return error.ResponseBroken;
        if (!req.done) {
            response.end() catch return error.ResponseBroken;
            return .ok;
        }
    }

    if (multi_ack_detailed or multi_ack) {
        const suffix = if (multi_ack_detailed) "common" else "continue";
        for (common.items) |h| {
            var hex: [40]u8 = undefined;
            _ = git2.formatOid(&h, &hex);
            var line_buf: [80]u8 = undefined;
            const line = std.mem.print(&line_buf, "ACK {s} {s}", .{ hex, suffix }) catch unreachable;
            pktline.writeLine(&response.writer, line) catch return error.ResponseBroken;
        }
        if (send_pack) {
            if (common.items.len > 0) {
                var hex: [40]u8 = undefined;
                _ = git2.formatOid(&common.items[common.items.len - 1], &hex);
                var line_buf: [64]u8 = undefined;
                if (multi_ack_detailed and !req.done) {
                    const ready_line = std.mem.print(&line_buf, "ACK {s} ready", .{hex}) catch unreachable;
                    pktline.writeLine(&response.writer, ready_line) catch return error.ResponseBroken;
                }
                const ack_line = std.mem.print(&line_buf, "ACK {s}", .{hex}) catch unreachable;
                pktline.writeLine(&response.writer, ack_line) catch return error.ResponseBroken;
            } else {
                pktline.writeLine(&response.writer, "NAK") catch return error.ResponseBroken;
            }
        } else {
            pktline.writeLine(&response.writer, "NAK") catch return error.ResponseBroken;
            response.end() catch return error.ResponseBroken;
            return .ok;
        }
    } else {
        if (common.items.len > 0) {
            var hex: [40]u8 = undefined;
            _ = git2.formatOid(&common.items[0], &hex);
            var line_buf: [64]u8 = undefined;
            const ack_line = std.mem.print(&line_buf, "ACK {s}", .{hex}) catch unreachable;
            pktline.writeLine(&response.writer, ack_line) catch return error.ResponseBroken;
        } else {
            pktline.writeLine(&response.writer, "NAK") catch return error.ResponseBroken;
            if (!send_pack) {
                response.end() catch return error.ResponseBroken;
                return .ok;
            }
        }
    }

    streamPack(
        app.gpa,
        repo,
        git2_repo,
        req.wants.items,
        common.items,
        req.shallows.items,
        if (req.deepen != null) shallow_info.included.items else null,
        include_tag,
        claims,
        &response.writer,
        band_max,
    ) catch return error.ResponseBroken;
    if (band_max > 0) {
        pktline.writeFlush(&response.writer) catch return error.ResponseBroken;
    }
    response.end() catch return error.ResponseBroken;
    return .ok;
}

fn respondUploadErr(app: *server.App, request: *http.Server.Request, msg: []const u8) api.HandleError!http.Status {
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    var line_buf: [256]u8 = undefined;
    const line = std.mem.print(&line_buf, "ERR {s}", .{msg}) catch "ERR forbidden";
    pktline.writeLine(&out.writer, line) catch return api.internal(request);
    try request.respond(out.written(), .{
        .keep_alive = http_util.keepAlive(request),
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-git-upload-pack-result" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
    return .ok;
}

// ---- Reachability, Negotiation, Shallow & Pack Streaming ----

fn checkWantsAllowed(
    gpa: std.mem.Allocator,
    repo: *const repo_git.Repo,
    git2_repo: *git2.Repository,
    wants: []const [40]u8,
    claims: *const auth.Claims,
) !bool {
    var odb: ?*git2.Odb = null;
    if (git2.git_repository_odb(&odb, git2_repo) != git2.ok) return false;
    defer git2.git_odb_free(odb.?);

    if (!claims.isReadRefRestricted()) {
        for (wants) |w_hex| {
            const oid = git2.parseOid(&w_hex) orelse return false;
            if (git2.git_odb_exists(odb.?, &oid) != 1) return false;
        }
        return true;
    }

    // Restricted read_refs: every want must be an advertised visible tip (or its peeled target)
    // or an ancestor commit of an advertised visible commit (R2.1).
    const refs = try repo.listRefs(true);
    defer refs.deinit(gpa);

    var visible_oids: std.ArrayList(git2.Oid) = .empty;
    defer visible_oids.deinit(gpa);

    if (refs.head_oid) |head_oid| {
        const head_visible = if (refs.head_symref) |sym| claims.allowsReadRef(sym) else false;
        if (head_visible) {
            if (git2.parseOid(&head_oid)) |o| try visible_oids.append(gpa, o);
        }
    }
    for (refs.items) |ref| {
        if (!claims.allowsReadRef(ref.name)) continue;
        if (git2.parseOid(&ref.oid)) |o| try visible_oids.append(gpa, o);
        if (ref.peeled) |p| {
            if (git2.parseOid(&p)) |o| try visible_oids.append(gpa, o);
        }
    }

    for (wants) |w_hex| {
        const want_oid = git2.parseOid(&w_hex) orelse return false;
        if (git2.git_odb_exists(odb.?, &want_oid) != 1) return false;

        var allowed = false;
        for (visible_oids.items) |vis| {
            if (std.mem.eql(u8, &want_oid.id, &vis.id)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) {
            for (visible_oids.items) |vis| {
                if (git2.git_graph_descendant_of(git2_repo, &vis, &want_oid) == 1) {
                    allowed = true;
                    break;
                }
            }
        }
        if (!allowed) return false;
    }
    return true;
}

fn collectCommonHaves(
    gpa: std.mem.Allocator,
    git2_repo: *git2.Repository,
    haves: []const [40]u8,
    common: *std.ArrayList(git2.Oid),
) api.HandleError!void {
    if (haves.len == 0) return;
    var odb: ?*git2.Odb = null;
    if (git2.git_repository_odb(&odb, git2_repo) != git2.ok) return;
    defer git2.git_odb_free(odb.?);

    for (haves) |h_hex| {
        const oid = git2.parseOid(&h_hex) orelse continue;
        if (git2.git_odb_exists(odb.?, &oid) == 1) {
            common.append(gpa, oid) catch return;
        }
    }
}

const ShallowPlan = struct {
    included: std.ArrayList(git2.Oid) = .empty,
    boundaries: std.ArrayList(git2.Oid) = .empty,

    fn deinit(p: *ShallowPlan, gpa: std.mem.Allocator) void {
        p.included.deinit(gpa);
        p.boundaries.deinit(gpa);
    }
};

fn computeShallow(
    gpa: std.mem.Allocator,
    git2_repo: *git2.Repository,
    wants: []const [40]u8,
    depth: u32,
    plan: *ShallowPlan,
) !void {
    const QueueItem = struct { oid: git2.Oid, d: u32 };
    var queue: std.ArrayList(QueueItem) = .empty;
    defer queue.deinit(gpa);
    var seen: std.array_hash_map.Auto([20]u8, u32) = .empty;
    defer seen.deinit(gpa);

    for (wants) |w_hex| {
        const oid = git2.parseOid(&w_hex) orelse continue;
        const commit_oid = peelToCommitOid(git2_repo, &oid) orelse continue;
        if (!seen.contains(commit_oid.id)) {
            try seen.put(gpa, commit_oid.id, 1);
            try queue.append(gpa, .{ .oid = commit_oid, .d = 1 });
        }
    }

    var head: usize = 0;
    while (head < queue.items.len and plan.included.items.len < max_shallow_commits) : (head += 1) {
        const cur = queue.items[head];
        try plan.included.append(gpa, cur.oid);

        var commit: ?*git2.Commit = null;
        if (git2.git_commit_lookup(&commit, git2_repo, &cur.oid) != git2.ok) continue;
        defer git2.git_commit_free(commit.?);

        const pcount = git2.git_commit_parentcount(commit.?);
        if (cur.d >= depth) {
            if (pcount > 0) try plan.boundaries.append(gpa, cur.oid);
            continue;
        }
        for (0..pcount) |pi| {
            const p_oid = git2.git_commit_parent_id(commit.?, @intCast(pi)) orelse continue;
            if (!seen.contains(p_oid.id)) {
                try seen.put(gpa, p_oid.id, cur.d + 1);
                try queue.append(gpa, .{ .oid = p_oid.*, .d = cur.d + 1 });
            }
        }
    }
}

fn peelToCommitOid(git2_repo: *git2.Repository, oid: *const git2.Oid) ?git2.Oid {
    var obj: ?*git2.Object = null;
    if (git2.git_object_lookup(&obj, git2_repo, oid, git2.obj_any) != git2.ok) return null;
    defer git2.git_object_free(obj.?);
    if (git2.git_object_type(obj.?) == git2.obj_commit) return oid.*;
    var peeled: ?*git2.Object = null;
    if (git2.git_object_peel(&peeled, obj.?, git2.obj_commit) != git2.ok) return null;
    defer git2.git_object_free(peeled.?);
    return git2.git_object_id(peeled.?).*;
}

const StreamCtx = struct {
    writer: *std.Io.Writer,
    band_max: usize,
    failed: bool = false,
};

fn packForeachCb(buf: ?*anyopaque, size: usize, payload: ?*anyopaque) callconv(.c) c_int {
    const ctx: *StreamCtx = @ptrCast(@alignCast(payload.?));
    if (ctx.failed) return -1;
    if (size == 0) return 0;
    const data: [*]const u8 = @ptrCast(buf orelse return -1);
    // Write in bounded 16 KiB chunks so TimedWriter checks the per-write
    // idle timeout before each chunk instead of blocking inside one large send (R3.4).
    var rest = data[0..size];
    while (rest.len > 0) {
        const n = @min(rest.len, 16 * 1024);
        const chunk = rest[0..n];
        if (ctx.band_max > 0) {
            pktline.writeSideband(ctx.writer, .pack, chunk, ctx.band_max) catch {
                ctx.failed = true;
                return -1;
            };
        } else {
            ctx.writer.writeAll(chunk) catch {
                ctx.failed = true;
                return -1;
            };
        }
        ctx.writer.flush() catch {
            ctx.failed = true;
            return -1;
        };
        rest = rest[n..];
    }
    return 0;
}

fn streamPack(
    gpa: std.mem.Allocator,
    repo: *const repo_git.Repo,
    git2_repo: *git2.Repository,
    wants: []const [40]u8,
    common_haves: []const git2.Oid,
    client_shallows: []const [40]u8,
    shallow_commits: ?[]const git2.Oid,
    include_tag: bool,
    claims: *const auth.Claims,
    writer: *std.Io.Writer,
    band_max: usize,
) error{ PackFailed, OutOfMemory }!void {
    var pb: ?*git2.Packbuilder = null;
    if (git2.git_packbuilder_new(&pb, git2_repo) != git2.ok) return error.PackFailed;
    defer git2.git_packbuilder_free(pb.?);
    // Single-threaded per request to keep worker CPU and memory predictable (R3.4).
    _ = git2.git_packbuilder_set_threads(pb.?, 1);

    // Track included commits when include-tag is requested.
    var packed_commits: std.array_hash_map.Auto([20]u8, void) = .empty;
    defer packed_commits.deinit(gpa);

    if (shallow_commits) |commits| {
        for (commits) |c_oid| {
            if (git2.git_packbuilder_insert_commit(pb.?, &c_oid) != git2.ok) return error.PackFailed;
            if (include_tag) try packed_commits.put(gpa, c_oid.id, {});
        }
        // Also insert any wanted annotated tag objects directly.
        for (wants) |w_hex| {
            const oid = git2.parseOid(&w_hex) orelse continue;
            var obj: ?*git2.Object = null;
            if (git2.git_object_lookup(&obj, git2_repo, &oid, git2.obj_any) == git2.ok) {
                defer git2.git_object_free(obj.?);
                if (git2.git_object_type(obj.?) != git2.obj_commit) {
                    _ = git2.git_packbuilder_insert(pb.?, &oid, null);
                }
            }
        }
    } else {
        var walk: ?*git2.Revwalk = null;
        if (git2.git_revwalk_new(&walk, git2_repo) != git2.ok) return error.PackFailed;
        defer git2.git_revwalk_free(walk.?);
        _ = git2.git_revwalk_sorting(walk.?, git2.sort_topological | git2.sort_time);

        for (wants) |w_hex| {
            const oid = git2.parseOid(&w_hex) orelse continue;
            var obj: ?*git2.Object = null;
            if (git2.git_object_lookup(&obj, git2_repo, &oid, git2.obj_any) != git2.ok) continue;
            defer git2.git_object_free(obj.?);
            const kind = git2.git_object_type(obj.?);
            if (kind == git2.obj_commit) {
                _ = git2.git_revwalk_push(walk.?, &oid);
            } else {
                _ = git2.git_packbuilder_insert(pb.?, &oid, null);
                if (kind == git2.obj_tag) {
                    var peeled: ?*git2.Object = null;
                    if (git2.git_object_peel(&peeled, obj.?, git2.obj_commit) == git2.ok) {
                        defer git2.git_object_free(peeled.?);
                        _ = git2.git_revwalk_push(walk.?, git2.git_object_id(peeled.?));
                    }
                }
            }
        }
        for (common_haves) |h| {
            _ = git2.git_revwalk_hide(walk.?, &h);
        }
        // Respect client's existing shallow boundary parents by hiding parents of shallow commits.
        for (client_shallows) |s_hex| {
            const s_oid = git2.parseOid(&s_hex) orelse continue;
            var sc: ?*git2.Commit = null;
            if (git2.git_commit_lookup(&sc, git2_repo, &s_oid) == git2.ok) {
                defer git2.git_commit_free(sc.?);
                const pcount = git2.git_commit_parentcount(sc.?);
                for (0..pcount) |pi| {
                    if (git2.git_commit_parent_id(sc.?, @intCast(pi))) |p_oid| {
                        _ = git2.git_revwalk_hide(walk.?, p_oid);
                    }
                }
            }
        }

        if (include_tag) {
            var cur_oid: git2.Oid = .{};
            while (git2.git_revwalk_next(&cur_oid, walk.?) == git2.ok) {
                if (git2.git_packbuilder_insert_commit(pb.?, &cur_oid) != git2.ok) return error.PackFailed;
                try packed_commits.put(gpa, cur_oid.id, {});
            }
        } else {
            if (git2.git_packbuilder_insert_walk(pb.?, walk.?) != git2.ok) return error.PackFailed;
        }
    }

    if (include_tag and packed_commits.count() > 0) {
        if (repo.listRefs(true)) |refs| {
            defer refs.deinit(gpa);
            for (refs.items) |ref| {
                if (!std.mem.startsWith(u8, ref.name, "refs/tags/")) continue;
                if (!claims.allowsReadRef(ref.name)) continue;
                const peeled_hex = ref.peeled orelse continue;
                const peeled_oid = git2.parseOid(&peeled_hex) orelse continue;
                if (packed_commits.contains(peeled_oid.id)) {
                    if (git2.parseOid(&ref.oid)) |tag_oid| {
                        _ = git2.git_packbuilder_insert(pb.?, &tag_oid, null);
                    }
                }
            }
        } else |_| {}
    }

    var ctx: StreamCtx = .{ .writer = writer, .band_max = band_max };
    if (git2.git_packbuilder_foreach(pb.?, packForeachCb, &ctx) != git2.ok or ctx.failed) {
        return error.PackFailed;
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

test "parseV1Request and parseV2Request handle valid and malformed inputs" {
    const sha1 = "1111111111111111111111111111111111111111";
    const sha2 = "2222222222222222222222222222222222222222";

    var v1_buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer v1_buf.deinit();
    try pktline.writeLine(&v1_buf.writer, "want " ++ sha1 ++ " side-band-64k multi_ack_detailed");
    try pktline.writeLine(&v1_buf.writer, "deepen 2");
    try pktline.writeFlush(&v1_buf.writer);
    try pktline.writeLine(&v1_buf.writer, "have " ++ sha2);
    try pktline.writeLine(&v1_buf.writer, "done");

    var v1 = try parseV1Request(testing.allocator, v1_buf.written());
    defer v1.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), v1.wants.items.len);
    try testing.expectEqualStrings(sha1, &v1.wants.items[0]);
    try testing.expectEqual(@as(usize, 1), v1.haves.items.len);
    try testing.expectEqual(@as(?u32, 2), v1.deepen);
    try testing.expect(v1.done);
    try testing.expect(receive_pack.hasCapability(v1.caps, "side-band-64k"));

    var v2_buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer v2_buf.deinit();
    try pktline.writeLine(&v2_buf.writer, "command=fetch");
    try pktline.writeLine(&v2_buf.writer, "agent=git/2.50");
    try pktline.writeDelim(&v2_buf.writer);
    try pktline.writeLine(&v2_buf.writer, "want " ++ sha1);
    try pktline.writeLine(&v2_buf.writer, "deepen 1");
    try pktline.writeLine(&v2_buf.writer, "done");
    try pktline.writeFlush(&v2_buf.writer);

    var v2 = try parseV2Request(testing.allocator, v2_buf.written());
    defer v2.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), v2.fetch.wants.items.len);
    try testing.expectEqual(@as(?u32, 1), v2.fetch.deepen);
    try testing.expect(v2.fetch.done);
}

test "fuzz upload-pack" {
    try testing.fuzz({}, fuzzUploadPack, .{
        .corpus = &.{
            "0032want 1111111111111111111111111111111111111111\n00000009done\n",
            "0014command=ls-refs\n00010009peel\n0000",
            "0012command=fetch\n00010009done\n0000",
            "0000",
        },
    });
}

fn fuzzUploadPack(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    if (parseV1Request(testing.allocator, input)) |*r1| {
        var mut = r1.*;
        mut.deinit(testing.allocator);
    } else |_| {}
    if (parseV2Request(testing.allocator, input)) |*r2| {
        var mut = r2.*;
        mut.deinit(testing.allocator);
    } else |_| {}
}
