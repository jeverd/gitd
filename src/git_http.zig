//! Git's smart HTTP protocol, served by handing each request to
//! `git http-backend` (a CGI program).
//!
//! This file has the pure parts: matching git URLs and parsing the CGI
//! response head. `git_proxy.zig` runs the process.
//!
//! Only the smart protocol is served. Dumb-protocol paths such as
//! `/objects/...` and `/HEAD` are rejected, so clients cannot read repo
//! files directly.

const std = @import("std");
const repo_name = @import("repo_name.zig");

pub const Service = enum {
    upload_pack,
    receive_pack,

    pub fn programName(s: Service) []const u8 {
        return switch (s) {
            .upload_pack => "git-upload-pack",
            .receive_pack => "git-receive-pack",
        };
    }

    fn fromProgramName(name: []const u8) ?Service {
        if (std.mem.eql(u8, name, "git-upload-pack")) return .upload_pack;
        if (std.mem.eql(u8, name, "git-receive-pack")) return .receive_pack;
        return null;
    }
};

pub const Kind = enum {
    /// `GET .../info/refs?service=...`: the ref advertisement.
    info_refs,
    /// `POST .../git-upload-pack` or `.../git-receive-pack`.
    rpc,
};

pub const Route = struct {
    repo: repo_name.Name,
    service: Service,
    kind: Kind,
    /// `/{ns}/{repo}.git/...`, passed to the CGI as PATH_INFO.
    /// Like `repo`, it borrows the request target, which reading the
    /// request body overwrites: copy it first.
    path_info: []const u8,
};

pub const MatchError = error{
    /// Looks like a git URL but is malformed or uses the dumb protocol.
    BadGitRequest,
    /// The method does not fit the endpoint.
    MethodNotAllowed,
};

/// Returns null when `path` is not a git URL at all (no `.git/` segment),
/// so other routes can try it. `path` excludes the query string.
pub fn match(method: std.http.Method, path: []const u8, query: []const u8) MatchError!?Route {
    const marker = ".git/";
    const end = std.mem.find(u8, path, marker) orelse return null;
    if (path.len == 0 or path[0] != '/') return error.BadGitRequest;
    const name = repo_name.parse(path[1..end]) catch return error.BadGitRequest;
    const rest = path[end + marker.len ..];

    if (std.mem.eql(u8, rest, "info/refs")) {
        if (method != .GET) return error.MethodNotAllowed;
        const service = serviceFromQuery(query) orelse return error.BadGitRequest;
        return .{ .repo = name, .service = service, .kind = .info_refs, .path_info = path };
    }
    if (Service.fromProgramName(rest)) |service| {
        if (method != .POST) return error.MethodNotAllowed;
        if (query.len != 0) return error.BadGitRequest;
        return .{ .repo = name, .service = service, .kind = .rpc, .path_info = path };
    }
    return error.BadGitRequest;
}

/// The query must be exactly `service=<name>`; anything else is rejected so
/// nothing unexpected reaches the CGI's QUERY_STRING.
fn serviceFromQuery(query: []const u8) ?Service {
    const prefix = "service=";
    if (!std.mem.startsWith(u8, query, prefix)) return null;
    return Service.fromProgramName(query[prefix.len..]);
}

/// Response headers from the CGI that gitd forwards to the client.
pub const forwarded_headers = [_][]const u8{ "Content-Type", "Cache-Control", "Expires", "Pragma" };

pub const max_cgi_head_len = 8 * 1024;
pub const max_cgi_headers = 16;

pub const CgiHead = struct {
    status: std.http.Status = .ok,
    headers: [max_cgi_headers]std.http.Header = undefined,
    header_count: usize = 0,
    /// Bytes after the blank line, which start the body.
    body_start: usize,

    pub fn forwarded(h: *const CgiHead) []const std.http.Header {
        return h.headers[0..h.header_count];
    }
};

pub const CgiParseError = error{ CgiHeadIncomplete, CgiHeadInvalid };

/// Parses the CGI response head in `bytes`. Header slices borrow `bytes`.
/// Accepts `\n` or `\r\n` line endings, as CGI allows both.
pub fn parseCgiHead(bytes: []const u8) CgiParseError!CgiHead {
    var head: CgiHead = .{ .body_start = 0 };
    var pos: usize = 0;
    while (true) {
        const nl = std.mem.findScalarPos(u8, bytes, pos, '\n') orelse return error.CgiHeadIncomplete;
        var line = bytes[pos..nl];
        pos = nl + 1;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) {
            head.body_start = pos;
            return head;
        }
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.CgiHeadInvalid;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (name.len == 0) return error.CgiHeadInvalid;

        if (std.ascii.eqlIgnoreCase(name, "Status")) {
            const code_end = std.mem.findScalar(u8, value, ' ') orelse value.len;
            const code = std.fmt.parseInt(u10, value[0..code_end], 10) catch return error.CgiHeadInvalid;
            if (code < 200 or code > 599) return error.CgiHeadInvalid;
            head.status = @fromBackingInt(code);
            continue;
        }
        for (forwarded_headers) |allowed| {
            if (!std.ascii.eqlIgnoreCase(name, allowed)) continue;
            if (head.header_count == max_cgi_headers) return error.CgiHeadInvalid;
            head.headers[head.header_count] = .{ .name = allowed, .value = value };
            head.header_count += 1;
        }
    }
}

const testing = std.testing;

test "matches smart protocol URLs" {
    const refs = (try match(.GET, "/acme/web.git/info/refs", "service=git-upload-pack")).?;
    try testing.expectEqualStrings("acme/web", refs.repo.full);
    try testing.expectEqual(Service.upload_pack, refs.service);
    try testing.expectEqual(Kind.info_refs, refs.kind);
    try testing.expectEqualStrings("/acme/web.git/info/refs", refs.path_info);

    const push = (try match(.POST, "/acme/web.git/git-receive-pack", "")).?;
    try testing.expectEqual(Service.receive_pack, push.service);
    try testing.expectEqual(Kind.rpc, push.kind);
}

test "rejects dumb protocol, traversal, and wrong methods" {
    try testing.expectEqual(null, try match(.GET, "/v1/repos", ""));
    const bad = [_][]const u8{
        "/acme/web.git/HEAD",
        "/acme/web.git/objects/info/packs",
        "/acme/web.git/info/refs/../../x",
        "/../web.git/info/refs",
        "/acme/../web.git/info/refs",
        "/acme/web.git/git-upload-pack/",
        "acme/web.git/info/refs",
        "/Acme/web.git/info/refs",
    };
    for (bad) |path| {
        try testing.expectError(error.BadGitRequest, match(.GET, path, "service=git-upload-pack"));
    }
    try testing.expectError(error.BadGitRequest, match(.GET, "/acme/web.git/info/refs", ""));
    try testing.expectError(error.BadGitRequest, match(.GET, "/acme/web.git/info/refs", "service=git-upload-pack&x=1"));
    try testing.expectError(error.BadGitRequest, match(.POST, "/acme/web.git/git-upload-pack", "x=1"));
    try testing.expectError(error.MethodNotAllowed, match(.POST, "/acme/web.git/info/refs", "service=git-upload-pack"));
    try testing.expectError(error.MethodNotAllowed, match(.GET, "/acme/web.git/git-receive-pack", ""));
}

test "parses CGI heads" {
    const crlf = try parseCgiHead("Status: 403 Forbidden\r\nContent-Type: text/plain\r\nX-Other: no\r\n\r\nbody");
    try testing.expectEqual(std.http.Status.forbidden, crlf.status);
    try testing.expectEqual(@as(usize, 1), crlf.forwarded().len);
    try testing.expectEqualStrings("text/plain", crlf.forwarded()[0].value);

    const bytes = "Content-Type: application/x-git-upload-pack-advertisement\nCache-Control: no-cache\n\nPACK";
    const lf = try parseCgiHead(bytes);
    try testing.expectEqual(std.http.Status.ok, lf.status);
    try testing.expectEqualStrings("PACK", bytes[lf.body_start..]);

    try testing.expectError(error.CgiHeadIncomplete, parseCgiHead("Content-Type: x\r\n"));
    try testing.expectError(error.CgiHeadInvalid, parseCgiHead("garbage\r\n\r\n"));
    try testing.expectError(error.CgiHeadInvalid, parseCgiHead("Status: 99 Low\r\n\r\n"));
    try testing.expectError(error.CgiHeadInvalid, parseCgiHead("Status: abc\r\n\r\n"));
}

test "fuzz match and parseCgiHead" {
    try testing.fuzz({}, fuzzParsers, .{ .corpus = &.{ "/acme/web.git/info/refs", "Status: 200 OK\r\n\r\n" } });
}

fn fuzzParsers(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    if (match(.GET, input, "service=git-upload-pack") catch null) |route| {
        try testing.expect(std.mem.find(u8, route.path_info, "..") == null);
    }
    if (parseCgiHead(input)) |head| {
        try testing.expect(head.body_start <= input.len);
        try testing.expect(head.header_count <= max_cgi_headers);
    } else |_| {}
}
