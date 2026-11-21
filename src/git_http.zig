//! Git smart HTTP URL matching (pure).
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

test "fuzz match" {
    try testing.fuzz({}, fuzzMatch, .{ .corpus = &.{ "/acme/web.git/info/refs", "/acme/web.git/git-upload-pack" } });
}

fn fuzzMatch(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    if (match(.GET, input, "service=git-upload-pack") catch null) |route| {
        try testing.expect(std.mem.find(u8, route.path_info, "..") == null);
    }
}
