//! Webhooks (feature 8): each event in a repo is POSTed to the repo's
//! webhook URLs.
//!
//!   POST   /v1/repos/{ns}/{repo}/webhooks            {"url"}   admin key only
//!   GET    /v1/repos/{ns}/{repo}/webhooks
//!   DELETE /v1/repos/{ns}/{repo}/webhooks/{id}
//!   GET    /v1/repos/{ns}/{repo}/webhooks/deliveries
//!
//! Deliveries are queued in the database in the same transaction as their
//! event, so none are lost on a crash. A worker sends them oldest first:
//!   POST <url>   content-type: application/json
//!   x-gitd-event: <kind>   x-gitd-delivery: <id>
//!   x-gitd-signature: sha256=<hex HMAC-SHA256 of the body with the secret>
//!   {"delivery": <id>, "event": {...}}
//! A 2xx answer marks it delivered. Anything else, or no answer within the
//! timeout, is retried after 1, 2, 4, then 8 backoff units; after 5 tries
//! it is marked failed. The secret is shown once, when the webhook is made.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const api = @import("api.zig");
const server = @import("server.zig");
const repo_name = @import("repo_name.zig");
const content = @import("content.zig");
const Db = @import("db.zig").Db;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
pub const max_attempts = 5;
const max_url_len = 2048;
const batch = 16;

// ---- API ----

pub fn serveApi(app: *server.App, request: *http.Server.Request, name: repo_name.Name, rest: []const u8, query: []const u8, access: content.Access) api.HandleError!http.Status {
    if (access.claims != null or access.read_only) return api.respondError(request, .forbidden, "forbidden", "webhooks need the admin key");
    const method = request.head.method;
    if (std.mem.eql(u8, rest, "webhooks")) {
        return switch (method) {
            .POST => create(app, request, name),
            .GET => list(app, request, name),
            else => api.respondError(request, .method_not_allowed, "method_not_allowed", "use GET or POST"),
        };
    }
    if (std.mem.eql(u8, rest, "webhooks/deliveries") and method == .GET) {
        const limit = @import("ui.zig").queryInt(query, "limit") orelse 50;
        if (limit < 1 or limit > 500) return api.respondError(request, .bad_request, "invalid_limit", "limit must be 1-500");
        return recent(app, request, name.full, @intCast(limit));
    }
    if (std.mem.startsWith(u8, rest, "webhooks/") and method == .DELETE) {
        const id = std.fmt.parseInt(i64, rest["webhooks/".len..], 10) catch
            return api.respondError(request, .bad_request, "invalid_id", "webhook ids are numbers");
        if (id <= 0) return api.respondError(request, .bad_request, "invalid_id", "webhook ids are positive");
        const deleted = app.db.deleteWebhooks(app.io, name.full, id) catch return api.internal(request);
        if (!deleted) return api.respondError(request, .not_found, "not_found", "no such webhook");
        try request.respond("", .{ .status = .no_content, .keep_alive = @import("http_util.zig").keepAlive(request) });
        return .no_content;
    }
    return api.respondError(request, .not_found, "not_found", "no such webhook route");
}

/// Accepts absolute http and https URLs with a host.
pub fn validUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > max_url_len) return false;
    for (url) |c| if (c <= 0x20 or c == 0x7f) return false;
    const uri = std.Uri.parse(url) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return false;
    const host = uri.host orelse return false;
    return switch (host) {
        .raw, .percent_encoded => |h| h.len > 0,
    };
}

fn create(app: *server.App, request: *http.Server.Request, name: repo_name.Name) api.HandleError!http.Status {
    const Body = struct { url: []const u8 };
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    if (!validUrl(parsed.value.url)) return api.respondError(request, .bad_request, "invalid_url", "url must be an absolute http or https URL");

    var random: [24]u8 = undefined;
    app.io.randomSecure(&random) catch return api.internal(request);
    var secret_buf: [6 + 48]u8 = undefined;
    @memcpy(secret_buf[0..6], "whsec_");
    const hex = std.fmt.bytesToHex(random, .lower);
    @memcpy(secret_buf[6..], &hex);
    const secret: []const u8 = &secret_buf;

    const now = api.unixNow(app.io);
    const id = app.db.insertWebhook(app.io, name.full, parsed.value.url, secret, now) catch return api.internal(request);
    return api.respondJson(app.gpa, request, .created, .{ .id = id, .url = parsed.value.url, .secret = secret, .created_at = now });
}

fn list(app: *server.App, request: *http.Server.Request, name: repo_name.Name) api.HandleError!http.Status {
    const hooks = app.db.listWebhooks(app.io, app.gpa, name.full) catch return api.internal(request);
    defer Db.freeWebhooks(app.gpa, hooks);
    return api.respondJson(app.gpa, request, .ok, .{ .webhooks = hooks });
}

const DeliveryJson = struct {
    id: i64,
    webhook_id: i64,
    url: []const u8,
    status: []const u8,
    attempts: i64,
    last_status: i64,
    last_error: []const u8,
    updated_at: i64,
    event: Db.Event,
};

/// Recent deliveries without secrets, newest first. An empty `repo`
/// means every repo (for the UI).
pub fn recent(app: *server.App, request: *http.Server.Request, repo: []const u8, limit: u32) api.HandleError!http.Status {
    const rows = app.db.recentDeliveries(app.io, app.gpa, repo, limit) catch return api.internal(request);
    defer Db.freeDeliveries(app.gpa, rows);
    const items = app.gpa.alloc(DeliveryJson, rows.len) catch return api.internal(request);
    defer app.gpa.free(items);
    for (rows, items) |d, *i| i.* = .{
        .id = d.id,
        .webhook_id = d.webhook_id,
        .url = d.url,
        .status = d.status,
        .attempts = d.attempts,
        .last_status = d.last_status,
        .last_error = d.last_error,
        .updated_at = d.updated_at,
        .event = d.event,
    };
    return api.respondJson(app.gpa, request, .ok, .{ .deliveries = items });
}

// ---- Delivery worker ----

/// Deliveries in flight at once. A slow endpoint holds one slot, never
/// the whole queue.
const max_in_flight = 16;

/// Sends due deliveries until canceled. Each runs as its own task, so a
/// slow or hanging endpoint does not delay the others.
pub fn run(app: *server.App) Io.Cancelable!void {
    const io = app.io;
    app.db.requeueSending(io) catch |err| std.log.err("requeueing deliveries: {t}", .{err});
    var group: Io.Group = .init;
    defer group.cancel(io);
    var in_flight: std.atomic.Value(u32) = .init(0);
    while (true) {
        const free = max_in_flight - in_flight.load(.acquire);
        if (free > 0) {
            const due = app.db.claimDueDeliveries(io, app.gpa, nowMs(io), @min(free, batch)) catch |err| blk: {
                std.log.err("listing due deliveries: {t}", .{err});
                break :blk &.{};
            };
            defer app.gpa.free(due);
            for (due) |d| {
                _ = in_flight.fetchAdd(1, .acq_rel);
                group.concurrent(io, deliverTask, .{ app, d, &in_flight }) catch |err| {
                    std.log.err("starting webhook delivery: {t}", .{err});
                    _ = in_flight.fetchSub(1, .acq_rel);
                    // Leave it pending for the next round.
                    app.db.updateDelivery(io, d.id, "pending", d.attempts, nowMs(io) + app.webhook_backoff_ms, d.last_status, d.last_error, api.unixNow(io)) catch |db_err| {
                        std.log.err("requeueing delivery {d}: {t}", .{ d.id, db_err });
                    };
                    d.deinit(app.gpa);
                };
            }
        }
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

/// Owns `d`; counts itself out of `in_flight` when done.
fn deliverTask(app: *server.App, d: Db.Delivery, in_flight: *std.atomic.Value(u32)) Io.Cancelable!void {
    defer _ = in_flight.fetchSub(1, .acq_rel);
    defer d.deinit(app.gpa);
    var client: http.Client = .{ .allocator = app.gpa, .io = app.io };
    defer client.deinit();
    try deliverOne(app, &client, d);
}

/// The body sent for a delivery. The caller frees it.
pub fn payload(gpa: std.mem.Allocator, d: Db.Delivery) std.mem.Allocator.Error![]u8 {
    return gpa.print("{f}", .{std.json.fmt(.{ .delivery = d.id, .event = d.event }, .{})});
}

/// `sha256=<hex>` over `body` with `secret`.
pub fn signature(secret: []const u8, body: []const u8) [7 + 64]u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, secret);
    var out: [7 + 64]u8 = undefined;
    @memcpy(out[0..7], "sha256=");
    const hex = std.fmt.bytesToHex(mac, .lower);
    @memcpy(out[7..], &hex);
    return out;
}

const Outcome = union(enum) {
    sent: anyerror!http.Status,
    timeout: Io.Cancelable!void,
};

fn deliverOne(app: *server.App, client: *http.Client, d: Db.Delivery) Io.Cancelable!void {
    const io = app.io;
    const body = payload(app.gpa, d) catch return;
    defer app.gpa.free(body);
    const sig = signature(d.secret, body);
    var id_buf: [24]u8 = undefined;
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-gitd-event", .value = d.event.kind },
        .{ .name = "x-gitd-delivery", .value = std.mem.print(&id_buf, "{d}", .{d.id}) catch unreachable },
        .{ .name = "x-gitd-signature", .value = &sig },
    };

    // fetch has no deadline of its own, so race it against a timer and
    // cancel whichever loses.
    var buf: [2]Outcome = undefined;
    var select: Io.Select(Outcome) = .init(io, &buf);
    defer select.cancelDiscard();
    select.concurrent(.sent, post, .{ client, d.url, body, &headers }) catch |err| {
        std.log.err("starting webhook delivery: {t}", .{err});
        return;
    };
    select.concurrent(.timeout, Io.sleep, .{ io, .fromMilliseconds(app.webhook_timeout_ms), .awake }) catch |err| {
        std.log.err("starting webhook timer: {t}", .{err});
        return;
    };
    const outcome = try select.await();

    var status: i64 = 0;
    var err_text: []const u8 = "";
    var err_buf: [96]u8 = undefined;
    switch (outcome) {
        .sent => |result| if (result) |s| {
            status = @backingInt(s);
            if (status < 200 or status > 299) err_text = std.mem.print(&err_buf, "HTTP {d}", .{status}) catch "HTTP error";
        } else |e| {
            err_text = std.mem.print(&err_buf, "{t}", .{e}) catch "request failed";
        },
        .timeout => err_text = "timed out",
    }
    const attempts = d.attempts + 1;
    const ok = err_text.len == 0;
    const final = ok or attempts >= max_attempts;
    const next = nowMs(io) + app.webhook_backoff_ms * (@as(i64, 1) << @intCast(attempts - 1));
    const new_status = if (ok) "delivered" else if (final) "failed" else "pending";
    app.db.updateDelivery(io, d.id, new_status, attempts, if (final) 0 else next, status, err_text, api.unixNow(io)) catch |err| {
        std.log.err("recording delivery {d}: {t}", .{ d.id, err });
    };
    if (!ok and final) std.log.info("webhook delivery {d} to {s} failed after {d} attempts: {s}", .{ d.id, d.url, attempts, err_text });
}

fn post(client: *http.Client, url: []const u8, body: []const u8, headers: []const http.Header) anyerror!http.Status {
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = headers,
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    });
    return result.status;
}

test validUrl {
    try std.testing.expect(validUrl("http://127.0.0.1:9000/hook"));
    try std.testing.expect(validUrl("https://example.com/x?y=1"));
    for ([_][]const u8{ "", "ftp://x/y", "http://", "/relative", "http://a b/", "javascript:alert(1)", "http:///x" }) |u| {
        try std.testing.expect(!validUrl(u));
    }
}

test signature {
    const sig = signature("whsec_x", "{}");
    try std.testing.expectEqualStrings("sha256=", sig[0..7]);
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, "{}", "whsec_x");
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(mac, .lower), sig[7..]);
}
