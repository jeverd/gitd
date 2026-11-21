//! Admin API keys and signed repo tokens (R2.1).
//!
//! A repo token is `gitd_t_<payload>.<mac>`: base64url JSON claims, then an
//! HMAC-SHA256 over `gitd_t_<payload>`. The server keeps no token state, so
//! a token cannot be revoked early; keep expiries short. Claims name the
//! repo's random id as well as its name, so deleting a repo ends its tokens.
//!
//! An admin key is `gitd_k_` plus 32 random bytes in hex. The database
//! stores only its SHA-256, so a leaked database does not leak keys.

const std = @import("std");
const repo_name = @import("repo_name.zig");
const ref_name = @import("ref_name.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.url_safe_no_pad;

pub const secret_len = 32;
pub const Secret = [secret_len]u8;

pub const token_prefix = "gitd_t_";
pub const key_prefix = "gitd_k_";
/// Longer tokens are rejected before decoding (R2.3).
pub const max_token_len = 4096;
/// A token can limit writes to at most this many ref patterns (R2.2).
pub const max_ref_patterns = 4;
/// Total bytes of all ref patterns in one token.
pub const max_ref_patterns_bytes = 600;
/// Upper bound on a token's lifetime, in seconds.
pub const max_ttl_seconds = 24 * 60 * 60;
pub const default_ttl_seconds = 15 * 60;

pub const Scopes = packed struct(u8) {
    git_read: bool = false,
    git_write: bool = false,
    _: u6 = 0,

    pub const Name = enum { @"git:read", @"git:write" };

    pub fn fromName(name: []const u8) ?Scopes {
        const tag = std.meta.stringToEnum(Name, name) orelse return null;
        return switch (tag) {
            .@"git:read" => .{ .git_read = true },
            .@"git:write" => .{ .git_write = true },
        };
    }

    pub fn merge(a: Scopes, b: Scopes) Scopes {
        return .{ .git_read = a.git_read or b.git_read, .git_write = a.git_write or b.git_write };
    }

    pub fn isEmpty(s: Scopes) bool {
        return !s.git_read and !s.git_write;
    }
};

pub const repo_id_len = 32;
pub const RepoId = [repo_id_len]u8;

/// A new random repo id: 32 lowercase hex characters.
pub fn newRepoId(io: std.Io) std.Io.RandomSecureError!RepoId {
    var bytes: [repo_id_len / 2]u8 = undefined;
    try io.randomSecure(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn isRepoId(text: []const u8) bool {
    if (text.len != repo_id_len) return false;
    for (text) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

pub const Claims = struct {
    repo_buf: [repo_name.max_len]u8 = undefined,
    repo_len: usize = 0,
    repo_id: RepoId,
    scopes: Scopes,
    /// Unix seconds.
    expires_at: i64,
    /// Ref patterns this token may write (see ref_name). None means any.
    refs_buf: [max_ref_patterns_bytes]u8 = undefined,
    refs_ends: [max_ref_patterns]u16 = undefined,
    refs_count: usize = 0,
    /// Ref patterns this token may read (see ref_name). None means any.
    read_refs_buf: [max_ref_patterns_bytes]u8 = undefined,
    read_refs_ends: [max_ref_patterns]u16 = undefined,
    read_refs_count: usize = 0,
    /// Seconds a branch created by a push with this token lives before
    /// gitd deletes it. Zero means such branches do not expire.
    branch_ttl: u32 = 0,

    pub fn repo(c: *const Claims) []const u8 {
        return c.repo_buf[0..c.repo_len];
    }

    pub fn refPattern(c: *const Claims, i: usize) []const u8 {
        const start = if (i == 0) 0 else c.refs_ends[i - 1];
        return c.refs_buf[start..c.refs_ends[i]];
    }

    pub fn readRefPattern(c: *const Claims, i: usize) []const u8 {
        const start = if (i == 0) 0 else c.read_refs_ends[i - 1];
        return c.read_refs_buf[start..c.read_refs_ends[i]];
    }

    /// Adds a write limit. Fails if the pattern is invalid or the limits
    /// on count and size are reached.
    pub fn addRefPattern(c: *Claims, pattern: []const u8) error{ InvalidRefPattern, TooManyRefPatterns }!void {
        ref_name.validatePattern(pattern) catch return error.InvalidRefPattern;
        const start: usize = if (c.refs_count == 0) 0 else c.refs_ends[c.refs_count - 1];
        if (c.refs_count == max_ref_patterns or start + pattern.len > max_ref_patterns_bytes) return error.TooManyRefPatterns;
        @memcpy(c.refs_buf[start..][0..pattern.len], pattern);
        c.refs_ends[c.refs_count] = @intCast(start + pattern.len);
        c.refs_count += 1;
    }

    /// Adds a read limit. Fails if the pattern is invalid or the limits
    /// on count and size are reached.
    pub fn addReadRefPattern(c: *Claims, pattern: []const u8) error{ InvalidRefPattern, TooManyRefPatterns }!void {
        ref_name.validatePattern(pattern) catch return error.InvalidRefPattern;
        const start: usize = if (c.read_refs_count == 0) 0 else c.read_refs_ends[c.read_refs_count - 1];
        if (c.read_refs_count == max_ref_patterns or start + pattern.len > max_ref_patterns_bytes) return error.TooManyRefPatterns;
        @memcpy(c.read_refs_buf[start..][0..pattern.len], pattern);
        c.read_refs_ends[c.read_refs_count] = @intCast(start + pattern.len);
        c.read_refs_count += 1;
    }

    /// Whether this token may create, move, or delete `ref`.
    pub fn allowsRef(c: *const Claims, ref: []const u8) bool {
        if (c.refs_count == 0) return true;
        for (0..c.refs_count) |i| if (ref_name.matches(c.refPattern(i), ref)) return true;
        return false;
    }

    /// Whether this token may read `ref`.
    pub fn allowsReadRef(c: *const Claims, ref: []const u8) bool {
        if (c.read_refs_count == 0) return true;
        for (0..c.read_refs_count) |i| if (ref_name.matches(c.readRefPattern(i), ref)) return true;
        return false;
    }

    pub fn isReadRefRestricted(c: *const Claims) bool {
        return c.read_refs_count > 0;
    }

    pub fn init(name: []const u8, repo_id: []const u8, scopes: Scopes, expires_at: i64) error{InvalidRepoName}!Claims {
        _ = try repo_name.parse(name);
        if (!isRepoId(repo_id)) return error.InvalidRepoName;
        var c: Claims = .{ .repo_id = repo_id[0..repo_id_len].*, .scopes = scopes, .expires_at = expires_at };
        @memcpy(c.repo_buf[0..name.len], name);
        c.repo_len = name.len;
        return c;
    }
};

/// The JSON shape inside a token.
const Payload = struct {
    v: u8,
    repo: []const u8,
    rid: []const u8,
    scopes: []const []const u8,
    exp: i64,
    refs: []const []const u8 = &.{},
    rrefs: []const []const u8 = &.{},
    bttl: u32 = 0,
};

pub const VerifyError = error{ InvalidToken, ExpiredToken };

/// Writes a token for `claims` into `out` and returns the used part.
pub fn mint(secret: *const Secret, claims: *const Claims, out: *[max_token_len]u8) error{TokenTooLong}![]const u8 {
    var names: [2][]const u8 = undefined;
    var count: usize = 0;
    if (claims.scopes.git_read) {
        names[count] = "git:read";
        count += 1;
    }
    if (claims.scopes.git_write) {
        names[count] = "git:write";
        count += 1;
    }
    var refs: [max_ref_patterns][]const u8 = undefined;
    for (0..claims.refs_count) |i| refs[i] = claims.refPattern(i);
    var rrefs: [max_ref_patterns][]const u8 = undefined;
    for (0..claims.read_refs_count) |i| rrefs[i] = claims.readRefPattern(i);
    const payload: Payload = .{
        .v = 1,
        .repo = claims.repo(),
        .rid = &claims.repo_id,
        .scopes = names[0..count],
        .exp = claims.expires_at,
        .refs = refs[0..claims.refs_count],
        .rrefs = rrefs[0..claims.read_refs_count],
        .bttl = claims.branch_ttl,
    };

    var json_buf: [2800]u8 = undefined;
    const json = std.mem.print(&json_buf, "{f}", .{std.json.fmt(payload, .{})}) catch return error.TokenTooLong;

    const encoded_len = b64.Encoder.calcSize(json.len);
    const signed_len = token_prefix.len + encoded_len;
    const total = signed_len + 1 + b64.Encoder.calcSize(HmacSha256.mac_length);
    if (total > out.len) return error.TokenTooLong;

    @memcpy(out[0..token_prefix.len], token_prefix);
    _ = b64.Encoder.encode(out[token_prefix.len..signed_len], json);
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, out[0..signed_len], secret);
    out[signed_len] = '.';
    _ = b64.Encoder.encode(out[signed_len + 1 .. total], &mac);
    return out[0..total];
}

/// Checks the signature and expiry. Never trusts anything in the token
/// before the MAC matches.
pub fn verify(secret: *const Secret, token: []const u8, now: i64) VerifyError!Claims {
    if (token.len > max_token_len or !std.mem.startsWith(u8, token, token_prefix)) return error.InvalidToken;
    const dot = std.mem.findScalarLast(u8, token, '.') orelse return error.InvalidToken;
    if (dot < token_prefix.len) return error.InvalidToken;
    const signed = token[0..dot];
    const mac_text = token[dot + 1 ..];

    var given_mac: [HmacSha256.mac_length]u8 = undefined;
    const mac_len = b64.Decoder.calcSizeForSlice(mac_text) catch return error.InvalidToken;
    if (mac_len != given_mac.len) return error.InvalidToken;
    b64.Decoder.decode(&given_mac, mac_text) catch return error.InvalidToken;

    var want_mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&want_mac, signed, secret);
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, given_mac, want_mac)) return error.InvalidToken;

    // Signed by us from here on, but still parsed defensively.
    const payload_text = signed[token_prefix.len..];
    var json_buf: [max_token_len]u8 = undefined;
    const json_len = b64.Decoder.calcSizeForSlice(payload_text) catch return error.InvalidToken;
    if (json_len > json_buf.len) return error.InvalidToken;
    b64.Decoder.decode(json_buf[0..json_len], payload_text) catch return error.InvalidToken;

    var arena_buf: [8192]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&arena_buf);
    const payload = std.json.parseFromSliceLeaky(Payload, fba.allocator(), json_buf[0..json_len], .{}) catch
        return error.InvalidToken;
    if (payload.v != 1) return error.InvalidToken;

    var scopes: Scopes = .{};
    for (payload.scopes) |name| {
        scopes = scopes.merge(Scopes.fromName(name) orelse return error.InvalidToken);
    }
    var claims = Claims.init(payload.repo, payload.rid, scopes, payload.exp) catch return error.InvalidToken;
    for (payload.refs) |pattern| claims.addRefPattern(pattern) catch return error.InvalidToken;
    for (payload.rrefs) |pattern| claims.addReadRefPattern(pattern) catch return error.InvalidToken;
    claims.branch_ttl = payload.bttl;
    if (now >= claims.expires_at) return error.ExpiredToken;
    return claims;
}

pub const key_len = key_prefix.len + 64;

/// A fresh admin key from `random_bytes`, which must be secure randomness.
pub fn formatKey(random_bytes: *const [32]u8) [key_len]u8 {
    var out: [key_len]u8 = undefined;
    @memcpy(out[0..key_prefix.len], key_prefix);
    const hex = std.fmt.bytesToHex(random_bytes.*, .lower);
    @memcpy(out[key_prefix.len..], &hex);
    return out;
}

/// Whether `text` has the shape of an admin key: the prefix, then 64
/// lowercase hex digits (what `formatKey` makes).
pub fn isKey(text: []const u8) bool {
    if (text.len != key_len or !std.mem.startsWith(u8, text, key_prefix)) return false;
    for (text[key_prefix.len..]) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// The value stored in the database for an admin key.
pub fn hashKey(key: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(key, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Pulls the password out of `Authorization: Basic base64(user:password)`.
/// Git sends the token as the password; the user name is ignored.
pub fn basicPassword(header_value: []const u8, scratch: *[max_token_len + 256]u8) ?[]const u8 {
    const prefix = "Basic ";
    if (header_value.len < prefix.len or !std.ascii.eqlIgnoreCase(header_value[0..prefix.len], prefix)) return null;
    const encoded = std.mem.trim(u8, header_value[prefix.len..], " ");
    const std_b64 = std.base64.standard;
    const len = std_b64.Decoder.calcSizeForSlice(encoded) catch return null;
    if (len > scratch.len) return null;
    std_b64.Decoder.decode(scratch[0..len], encoded) catch return null;
    const decoded = scratch[0..len];
    const colon = std.mem.findScalar(u8, decoded, ':') orelse return null;
    return decoded[colon + 1 ..];
}

/// Pulls the key out of `Authorization: Bearer <key>`.
pub fn bearer(header_value: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (header_value.len < prefix.len or !std.ascii.eqlIgnoreCase(header_value[0..prefix.len], prefix)) return null;
    const value = std.mem.trim(u8, header_value[prefix.len..], " ");
    return if (value.len == 0) null else value;
}

/// Reads the token signing secret at `path`, creating it on first start.
/// The file holds 64 hex characters and only its owner can read it. It is
/// written to a temp file and renamed, so a crash never leaves a short one.
pub fn loadSecret(io: std.Io, path: []const u8) !Secret {
    const cwd = std.Io.Dir.cwd();
    var hex: [secret_len * 2]u8 = undefined;
    var secret: Secret = undefined;
    if (cwd.openFile(io, path, .{})) |file| {
        defer file.close(io);
        const n = try file.readPositionalAll(io, &hex, 0);
        if (n != hex.len) return error.InvalidSecretFile;
        _ = std.fmt.hexToBytes(&secret, &hex) catch return error.InvalidSecretFile;
        return secret;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try io.randomSecure(&secret);
    hex = std.fmt.bytesToHex(secret, .lower);
    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = try std.mem.print(&tmp_buf, "{s}.tmp", .{path});
    cwd.deleteFile(io, tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try cwd.writeFile(io, .{
        .sub_path = tmp_path,
        .data = &hex,
        .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) },
    });
    try cwd.rename(tmp_path, cwd, path, io);
    return secret;
}

const test_secret: Secret = @splat(7);
const test_rid = "0123456789abcdef0123456789abcdef";

test "mint then verify round-trips" {
    const claims = try Claims.init("acme/web", test_rid, .{ .git_read = true, .git_write = true }, 1000);
    var buf: [max_token_len]u8 = undefined;
    const token = try mint(&test_secret, &claims, &buf);
    try std.testing.expect(std.mem.startsWith(u8, token, token_prefix));

    const got = try verify(&test_secret, token, 999);
    try std.testing.expectEqualStrings("acme/web", got.repo());
    try std.testing.expectEqualStrings(test_rid, &got.repo_id);
    try std.testing.expect(got.scopes.git_read and got.scopes.git_write);
    try std.testing.expectEqual(@as(i64, 1000), got.expires_at);
}

test "expired, tampered, and foreign tokens are rejected" {
    const claims = try Claims.init("acme/web", test_rid, .{ .git_read = true }, 1000);
    var buf: [max_token_len]u8 = undefined;
    const token = try mint(&test_secret, &claims, &buf);

    try std.testing.expectError(error.ExpiredToken, verify(&test_secret, token, 1000));

    const other_secret: Secret = @splat(8);
    try std.testing.expectError(error.InvalidToken, verify(&other_secret, token, 0));

    // Flip one byte in the payload, the separator, and the MAC.
    for ([_]usize{ token_prefix.len + 2, std.mem.findScalarLast(u8, token, '.').?, token.len - 2 }) |i| {
        var copy: [max_token_len]u8 = undefined;
        @memcpy(copy[0..token.len], token);
        copy[i] ^= 1;
        try std.testing.expectError(error.InvalidToken, verify(&test_secret, copy[0..token.len], 0));
    }

    try std.testing.expectError(error.InvalidToken, verify(&test_secret, "", 0));
    try std.testing.expectError(error.InvalidToken, verify(&test_secret, token_prefix, 0));
    try std.testing.expectError(error.InvalidToken, verify(&test_secret, "gitd_t_.", 0));
}

test "a validly signed payload with bad claims is rejected" {
    const rid = "\"rid\":\"0123456789abcdef0123456789abcdef\"";
    const bad_payloads = [_][]const u8{
        "{\"v\":1,\"repo\":\"../x\"," ++ rid ++ ",\"scopes\":[],\"exp\":10}",
        "{\"v\":1,\"repo\":\"a/b\"," ++ rid ++ ",\"scopes\":[\"admin\"],\"exp\":10}",
        "{\"v\":2,\"repo\":\"a/b\"," ++ rid ++ ",\"scopes\":[],\"exp\":10}",
        "{\"v\":1,\"repo\":\"a/b\",\"rid\":\"short\",\"scopes\":[],\"exp\":10}",
        "{\"v\":1,\"repo\":\"a/b\",\"rid\":\"0123456789ABCDEF0123456789ABCDEF\",\"scopes\":[],\"exp\":10}",
        "{\"v\":1,\"repo\":\"a/b\",\"scopes\":[],\"exp\":10}",
        "not json",
    };
    for (bad_payloads) |json| {
        var buf: [max_token_len]u8 = undefined;
        @memcpy(buf[0..token_prefix.len], token_prefix);
        const end = token_prefix.len + b64.Encoder.calcSize(json.len);
        _ = b64.Encoder.encode(buf[token_prefix.len..end], json);
        var mac: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&mac, buf[0..end], &test_secret);
        buf[end] = '.';
        const total = end + 1 + b64.Encoder.calcSize(mac.len);
        _ = b64.Encoder.encode(buf[end + 1 .. total], &mac);
        try std.testing.expectError(error.InvalidToken, verify(&test_secret, buf[0..total], 0));
    }
}

test "ref patterns survive mint and verify, and limit writes" {
    var claims = try Claims.init("acme/web", test_rid, .{ .git_write = true }, 1000);
    try std.testing.expect(claims.allowsRef("refs/heads/main"));
    try claims.addRefPattern("refs/heads/agent/7/*");
    try claims.addRefPattern("refs/tags/v1");
    var buf: [max_token_len]u8 = undefined;
    const got = try verify(&test_secret, try mint(&test_secret, &claims, &buf), 0);
    try std.testing.expectEqual(@as(usize, 2), got.refs_count);
    try std.testing.expect(got.allowsRef("refs/heads/agent/7/try"));
    try std.testing.expect(got.allowsRef("refs/tags/v1"));
    try std.testing.expect(!got.allowsRef("refs/heads/main"));
    try std.testing.expect(!got.allowsRef("refs/heads/agent/70/x"));
    try std.testing.expectEqual(@as(u32, 0), got.branch_ttl);
    var with_ttl = claims;
    with_ttl.branch_ttl = 90;
    try std.testing.expectEqual(@as(u32, 90), (try verify(&test_secret, try mint(&test_secret, &with_ttl, &buf), 0)).branch_ttl);

    try std.testing.expectError(error.InvalidRefPattern, claims.addRefPattern("main"));
    try claims.addRefPattern("refs/heads/a");
    try claims.addRefPattern("refs/heads/b");
    try std.testing.expectError(error.TooManyRefPatterns, claims.addRefPattern("refs/heads/c"));

    var big = try Claims.init("acme/web", test_rid, .{ .git_write = true }, 1000);
    const long = "refs/heads/" ++ @as([240]u8, @splat('a'));
    try big.addRefPattern(long);
    try big.addRefPattern(long);
    try std.testing.expectError(error.TooManyRefPatterns, big.addRefPattern(long));
    // The largest allowed token still fits.
    _ = try mint(&test_secret, &big, &buf);
}

test "read_refs patterns survive mint and verify, and limit reads" {
    var claims = try Claims.init("acme/web", test_rid, .{ .git_read = true }, 1000);
    try std.testing.expect(!claims.isReadRefRestricted());
    try std.testing.expect(claims.allowsReadRef("refs/heads/secret"));
    try claims.addReadRefPattern("refs/heads/main");
    try claims.addReadRefPattern("refs/heads/agent/7/*");
    var buf: [max_token_len]u8 = undefined;
    const got = try verify(&test_secret, try mint(&test_secret, &claims, &buf), 0);
    try std.testing.expect(got.isReadRefRestricted());
    try std.testing.expectEqual(@as(usize, 2), got.read_refs_count);
    try std.testing.expect(got.allowsReadRef("refs/heads/main"));
    try std.testing.expect(got.allowsReadRef("refs/heads/agent/7/work"));
    try std.testing.expect(!got.allowsReadRef("refs/heads/secret"));
    try std.testing.expect(!got.allowsReadRef("refs/heads/agent/8/work"));
}

test "admin keys hash stably and differ from the key" {
    const random_bytes: [32]u8 = @splat(1);
    const key = formatKey(&random_bytes);
    try std.testing.expect(std.mem.startsWith(u8, &key, key_prefix));
    try std.testing.expect(isKey(&key));
    try std.testing.expect(!isKey(key[0 .. key.len - 1]));
    var upper = key;
    upper[key_prefix.len] = 'A';
    try std.testing.expect(!isKey(&upper));
    try std.testing.expect(!isKey("gitd_t_" ++ key[key_prefix.len..]));
    const h1 = hashKey(&key);
    const h2 = hashKey(&key);
    try std.testing.expectEqualStrings(&h1, &h2);
    try std.testing.expect(std.mem.find(u8, &h1, key[key_prefix.len..]) == null);
}

test "authorization header parsing" {
    var scratch: [max_token_len + 256]u8 = undefined;
    // base64("t:secret-token")
    try std.testing.expectEqualStrings("secret-token", basicPassword("Basic dDpzZWNyZXQtdG9rZW4=", &scratch).?);
    try std.testing.expectEqual(null, basicPassword("Basic !!!", &scratch));
    try std.testing.expectEqual(null, basicPassword("Bearer x", &scratch));
    try std.testing.expectEqual(null, basicPassword("Basic dXNlcg==", &scratch)); // "user", no colon
    try std.testing.expectEqualStrings("abc", bearer("Bearer abc").?);
    try std.testing.expectEqual(null, bearer("Bearer "));
    try std.testing.expectEqual(null, bearer("Basic abc"));
}

test "fuzz verify" {
    try std.testing.fuzz({}, fuzzVerify, .{ .corpus = &.{ "gitd_t_e30.AAAA", "gitd_t_." } });
}

fn fuzzVerify(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_token_len + 16]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    // Without the secret, no input may verify.
    _ = verify(&test_secret, input, 0) catch return;
    return error.ForgedTokenAccepted;
}
