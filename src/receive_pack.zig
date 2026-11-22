//! Native Git Smart HTTP `git-receive-pack` (R1.1, R2.1, R2.2, R2.3, R3.2, R3.4).
//!
//! Parses pkt-line ref update commands, enforces token ref ACLs, branch locks,
//! declarative branch rules, and quotas *before* indexing any packfile bytes,
//! verifies & indexes the pack in-process via libgit2 `git_indexer`, enforces
//! `allow_force_push` via `git_graph_descendant_of`, and applies atomic/CAS
//! ref updates via `repo_git.Repo.updateRef`.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const api = @import("api.zig");
const auth = @import("auth.zig");
const Db = @import("db.zig").Db;
const events = @import("events.zig");
const http_util = @import("http_util.zig");
const maintenance = @import("maintenance.zig");
const pktline = @import("pktline.zig");
const ref_name = @import("ref_name.zig");
const repo_git = @import("repo_git.zig");
const repo_name = @import("repo_name.zig");
const rules_mod = @import("rules.zig");
const server = @import("server.zig");
const store_mod = @import("store.zig");

pub const max_commands = 512;
/// Commands must fit in this many leading bytes of the body.
pub const max_commands_bytes = 1024 * 1024;
const in_mem_body_limit: usize = 4 * 1024 * 1024;
/// Hard cap on a single push body (R3.4).
pub const max_body_bytes: u64 = 2 * 1024 * 1024 * 1024;

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

pub const Parsed = struct {
    commands: []Command,
    caps: []const u8,
    /// Byte offset immediately after the flush packet (`0000`), where pack data begins.
    pack_offset: usize,
};

/// Parses commands from `bytes`, which holds the start of the body (up to
/// `max_commands_bytes`). Writes them into `out` and returns the used part.
/// `caps` receives the client's capability list (borrowing `bytes`).
pub fn parse(bytes: []const u8, out: *[max_commands]Command, caps: *[]const u8) ParseError![]Command {
    const res = try parseWithOffset(bytes, out);
    caps.* = res.caps;
    return res.commands;
}

pub fn parseWithOffset(bytes: []const u8, out: *[max_commands]Command) ParseError!Parsed {
    var caps: []const u8 = "";
    var r = pktline.Reader.init(bytes);
    var count: usize = 0;
    var saw_shallow_done = false;
    while (true) {
        const packet = (r.next() catch return error.InvalidPush) orelse return error.InvalidPush;
        switch (packet) {
            .flush => return .{
                .commands = out[0..count],
                .caps = caps,
                .pack_offset = r.pos,
            },
            .delim, .response_end => return error.InvalidPush,
            .data => |raw_line| {
                if (raw_line.len == 0) return error.InvalidPush;
                var line = raw_line;
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
                    if (std.mem.findScalar(u8, line, 0)) |nul| {
                        caps = line[nul + 1 ..];
                        line = line[0..nul];
                    }
                } else if (std.mem.findScalar(u8, line, 0) != null) return error.InvalidPush;

                if (count == max_commands) return error.TooManyCommands;
                out[count] = try parseCommand(line);
                count += 1;
            },
        }
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

pub fn hasCapability(caps: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, caps, " \n");
    while (it.next()) |cap| if (std.mem.eql(u8, cap, name)) return true;
    return false;
}

pub const RefResult = union(enum) {
    ok,
    ng: []const u8,
};

/// Writes a `git-receive-pack` status report (`unpack ...`, `ok`/`ng` per ref),
/// wrapped in side-band channel 1 (plus optional channel 2 progress banner)
/// when the client negotiated `side-band` or `side-band-64k`.
pub fn writeReport(
    w: *std.Io.Writer,
    caps: []const u8,
    unpack_status: []const u8,
    commands: []const Command,
    results: []const RefResult,
    progress_message: ?[]const u8,
) std.Io.Writer.Error!void {
    var report_buf: [64 * 1024]u8 = undefined;
    var report: std.Io.Writer = .fixed(&report_buf);
    var unpack_buf: [256]u8 = undefined;
    const unpack_line = std.mem.print(&unpack_buf, "unpack {s}\n", .{unpack_status}) catch "unpack error\n";
    pktline.write(&report, unpack_line) catch {};
    for (commands, results) |cmd, res| {
        var line_buf: [1024]u8 = undefined;
        const line = switch (res) {
            .ok => std.mem.print(&line_buf, "ok {s}\n", .{cmd.ref}) catch continue,
            .ng => |reason| std.mem.print(&line_buf, "ng {s} {s}\n", .{ cmd.ref, reason }) catch continue,
        };
        pktline.write(&report, line) catch break;
    }
    pktline.writeFlush(&report) catch {};
    const body = report.buffered();

    const band_max: usize = if (hasCapability(caps, "side-band-64k")) pktline.sideband_64k_max else if (hasCapability(caps, "side-band")) pktline.sideband_max else 0;
    if (band_max == 0) return w.writeAll(body);
    if (progress_message) |msg| {
        if (msg.len > 0) {
            var msg_buf: [1024]u8 = undefined;
            const progress = std.mem.print(&msg_buf, "{s}\n", .{msg}) catch "";
            if (progress.len > 0 and progress.len + 5 <= band_max) {
                try pktline.writeSideband(w, .progress, progress, band_max);
            }
        }
    }
    try pktline.writeSideband(w, .pack, body, band_max);
    try pktline.writeFlush(w);
}

/// Writes git's answer to a push that gitd refuses before indexing: every
/// command marked `ng` with `reason`.
pub fn writeRejection(w: *std.Io.Writer, caps: []const u8, commands: []const Command, reasons: []const []const u8, message: []const u8) std.Io.Writer.Error!void {
    var results: [max_commands]RefResult = undefined;
    for (reasons, 0..) |reason, i| results[i] = .{ .ng = reason };
    return writeReport(w, caps, "ok", commands, results[0..commands.len], message);
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

const PushBody = struct {
    mem: std.ArrayList(u8) = .empty,
    file: ?Io.File = null,
    total_len: u64 = 0,

    fn deinit(b: *PushBody, io: Io, gpa: std.mem.Allocator) void {
        if (b.file) |f| f.close(io);
        b.mem.deinit(gpa);
    }

    const ReadError = error{ BodyTooLarge, ClientGone, IoFailed, OutOfMemory } || Io.Cancelable;

    fn readFrom(io: Io, gpa: std.mem.Allocator, store: *const store_mod.Store, request: *http.Server.Request) ReadError!PushBody {
        var b: PushBody = .{};
        errdefer b.deinit(io, gpa);

        var read_buf: [64 * 1024]u8 = undefined;
        const body = request.readerExpectContinue(&read_buf) catch return error.IoFailed;

        var chunk: [64 * 1024]u8 = undefined;
        var file_write_buf: [64 * 1024]u8 = undefined;
        var file_writer: ?Io.File.Writer = null;

        while (true) {
            const n = body.readSliceShort(&chunk) catch |err| switch (err) {
                error.ReadFailed => return error.ClientGone,
            };
            if (n == 0) break;

            b.total_len += n;
            if (b.total_len > max_body_bytes) return error.BodyTooLarge;

            if (b.file == null and b.mem.items.len + n <= in_mem_body_limit) {
                try b.mem.appendSlice(gpa, chunk[0..n]);
            } else {
                if (b.file == null) {
                    const f = try createUnlinkedTmp(io, store);
                    b.file = f;
                    file_writer = f.writer(io, &file_write_buf);
                    if (b.mem.items.len > 0) {
                        file_writer.?.interface.writeAll(b.mem.items) catch return error.IoFailed;
                        b.mem.clearAndFree(gpa);
                    }
                }
                file_writer.?.interface.writeAll(chunk[0..n]) catch return error.IoFailed;
            }
        }
        // Only a body read cleanly to its declared end leaves the server ready
        // for the next request; cut-off uploads must never touch the repo (R3.4).
        if (request.server.reader.state != .ready) return error.ClientGone;
        if (file_writer) |*fw| {
            fw.interface.flush() catch return error.IoFailed;
        }
        return b;
    }

    fn headSlice(b: *const PushBody, io: Io, scratch: []u8) error{IoFailed}![]const u8 {
        if (b.file) |f| {
            const want: usize = @intCast(@min(b.total_len, scratch.len));
            const n = f.readPositionalAll(io, scratch[0..want], 0) catch return error.IoFailed;
            return scratch[0..n];
        }
        return b.mem.items[0..@min(b.mem.items.len, max_commands_bytes)];
    }
};

fn createUnlinkedTmp(io: Io, store: *const store_mod.Store) error{ IoFailed, Canceled }!Io.File {
    var random: [8]u8 = undefined;
    io.random(&random);
    var path_buf: [store_mod.Store.max_path_len]u8 = undefined;
    const path = std.mem.print(&path_buf, "{s}/{x}.push", .{ store.tmp, random }) catch return error.IoFailed;
    const cwd = Io.Dir.cwd();
    const file = cwd.createFile(io, path, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.IoFailed,
    };
    cwd.deleteFile(io, path) catch |err| {
        file.close(io);
        return if (err == error.Canceled) error.Canceled else error.IoFailed;
    };
    return file;
}

/// Serves `POST /{ns}/{repo}.git/git-receive-pack` completely in-process.
pub fn serveRpc(
    app: *server.App,
    request: *http.Server.Request,
    name: repo_name.Name,
    claims: *const auth.Claims,
) api.HandleError!http.Status {
    var body = PushBody.readFrom(app.io, app.gpa, app.store, request) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.ClientGone => error.ClientGone,
        error.BodyTooLarge => api.respondError(request, .payload_too_large, "too_large", "request body is too large"),
        error.IoFailed, error.OutOfMemory => api.internal(request),
    };
    defer body.deinit(app.io, app.gpa);

    var file_head_buf: ?[]u8 = null;
    defer if (file_head_buf) |b| app.gpa.free(b);
    const head_bytes = if (body.file != null) blk: {
        const buf = app.gpa.alloc(u8, max_commands_bytes) catch return api.internal(request);
        file_head_buf = buf;
        break :blk body.headSlice(app.io, buf) catch return api.internal(request);
    } else body.headSlice(app.io, &.{}) catch return api.internal(request);

    const commands_buf = app.gpa.create([max_commands]Command) catch return api.internal(request);
    defer app.gpa.destroy(commands_buf);
    const parsed = parseWithOffset(head_bytes, commands_buf) catch |err| return switch (err) {
        error.InvalidPush, error.TooManyCommands => api.respondError(request, .bad_request, "bad_git_request", "could not read the push commands"),
    };
    const commands = parsed.commands;
    const caps = parsed.caps;

    if (commands.len == 0) {
        try request.respond("", .{
            .keep_alive = http_util.keepAlive(request),
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/x-git-receive-pack-result" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        });
        return .ok;
    }

    for (commands) |cmd| {
        if (!claims.allowsRef(cmd.ref)) {
            return rejectRefAcl(app, request, commands, caps, claims, name);
        }
    }
    for (commands) |cmd| {
        const locked = app.db.isBranchLocked(app.io, name.full, cmd.ref) catch return api.internal(request);
        if (locked) return rejectLocked(app, request, commands, caps, name);
    }
    const repo_rules = app.db.listBranchRules(app.io, app.gpa, name.full) catch return api.internal(request);
    defer Db.freeBranchRules(app.gpa, repo_rules);
    for (commands) |cmd| {
        const eff = rules_mod.evaluate(repo_rules, cmd.ref);
        if (cmd.isDelete() and !eff.allow_delete) return rejectRule(app, request, commands, caps, repo_rules, name);
        if (!cmd.isDelete() and !eff.allow_direct_push) return rejectRule(app, request, commands, caps, repo_rules, name);
    }

    const git_repo = repo_git.Repo.open(app.io, app.gpa, app.store, name) catch return api.internal(request);

    var new_branches: u64 = 0;
    for (commands) |cmd| {
        if (cmd.isCreate() and std.mem.startsWith(u8, cmd.ref, "refs/heads/")) new_branches += 1;
    }
    if (new_branches > 0) {
        const bq = maintenance.checkBranchQuota(app, &git_repo, name, new_branches, commands[0].ref) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            else => api.internal(request),
        };
        if (bq == .exceeded) {
            return rejectQuota(app, request, commands, caps, .too_many_requests, "branch quota exceeded");
        }
    }
    if (body.total_len > 0) {
        const dq = maintenance.checkDiskQuota(app, name, body.total_len, commands[0].ref) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            else => api.internal(request),
        };
        if (dq == .exceeded) {
            return rejectQuota(app, request, commands, caps, .payload_too_large, "disk quota exceeded");
        }
    }

    const has_pack = body.total_len > parsed.pack_offset;
    if (has_pack) {
        const index_res = if (body.file) |f|
            git_repo.indexPackFile(f, parsed.pack_offset, body.total_len)
        else
            git_repo.indexPackSlice(body.mem.items[parsed.pack_offset..]);
        index_res catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.InvalidPack => return respondUnpackFailure(app, request, commands, caps, "invalid packfile"),
            error.PackTooManyObjects => return respondUnpackFailure(app, request, commands, caps, "pack has too many objects"),
            error.GitFailed, error.OutOfMemory => return api.internal(request),
        };
    }

    const is_atomic = hasCapability(caps, "atomic");
    const now = api.unixNow(app.io);
    var results: [max_commands]RefResult = undefined;
    for (0..commands.len) |i| results[i] = .ok;

    var any_pre_error = false;
    for (commands, 0..) |cmd, i| {
        if (!cmd.isDelete()) {
            const must_be_commit = std.mem.startsWith(u8, cmd.ref, "refs/heads/");
            const valid_obj = git_repo.verifyPushedTarget(cmd.new, must_be_commit) catch |err| return switch (err) {
                error.Canceled => error.Canceled,
                else => api.internal(request),
            };
            if (!valid_obj) {
                results[i] = .{ .ng = if (must_be_commit) "object is not a commit" else "missing object" };
                any_pre_error = true;
                continue;
            }
        }
        var cur_buf: [64]u8 = undefined;
        const current = git_repo.refValue(cmd.ref, &cur_buf) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            else => api.internal(request),
        };
        if (cmd.isCreate()) {
            if (current != null) {
                results[i] = .{ .ng = "already exists" };
                any_pre_error = true;
                continue;
            }
        } else {
            if (current == null or !std.mem.eql(u8, current.?, cmd.old)) {
                results[i] = .{ .ng = "stale info" };
                any_pre_error = true;
                continue;
            }
        }
        if (!cmd.isCreate() and !cmd.isDelete()) {
            const eff = rules_mod.evaluate(repo_rules, cmd.ref);
            if (!eff.allow_force_push) {
                const is_ff = git_repo.isAncestor(cmd.old, cmd.new) catch |err| return switch (err) {
                    error.Canceled => error.Canceled,
                    else => api.internal(request),
                };
                if (!is_ff) {
                    results[i] = .{ .ng = "non-fast-forward" };
                    any_pre_error = true;
                    events.record(app, .{
                        .repo = name.full,
                        .kind = "push_rejected",
                        .ref = cmd.ref,
                        .old = cmd.old,
                        .new = cmd.new,
                        .detail = "branch rule forbids force push",
                        .created_at = now,
                    });
                    continue;
                }
            }
        }
    }

    if (is_atomic and any_pre_error) {
        for (0..commands.len) |i| {
            if (results[i] == .ok) results[i] = .{ .ng = "atomic push failed" };
        }
        return respondReport(app, request, commands, caps, "ok", results[0..commands.len], null);
    }

    var applied: [max_commands]bool = @splat(false);
    var atomic_aborted = false;
    for (commands, 0..) |cmd, i| {
        if (results[i] != .ok) continue;
        const new_opt: ?[]const u8 = if (cmd.isDelete()) null else cmd.new;
        const old_opt: ?[]const u8 = if (cmd.isCreate()) null else cmd.old;
        const outcome = git_repo.updateRef(cmd.ref, new_opt, old_opt) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => blk: {
                results[i] = .{ .ng = "ref update failed" };
                if (is_atomic) atomic_aborted = true;
                break :blk repo_git.Repo.RefUpdate.stale;
            },
        };
        if (outcome == .updated) {
            applied[i] = true;
        } else {
            if (results[i] == .ok) results[i] = .{ .ng = "stale info" };
            if (is_atomic) {
                atomic_aborted = true;
                break;
            }
        }
    }

    if (atomic_aborted) {
        var j: usize = commands.len;
        while (j > 0) {
            j -= 1;
            if (!applied[j]) continue;
            const cmd = commands[j];
            const restore_new: ?[]const u8 = if (cmd.isCreate()) null else cmd.old;
            const restore_old: ?[]const u8 = if (cmd.isDelete()) null else cmd.new;
            const rollback = git_repo.updateRef(cmd.ref, restore_new, restore_old) catch |err| {
                std.log.warn("atomic push rollback failed for {s}: {t}", .{ cmd.ref, err });
                applied[j] = false;
                continue;
            };
            if (rollback == .stale) {
                std.log.warn("atomic push rollback stale for {s}", .{cmd.ref});
            }
            applied[j] = false;
        }
        for (0..commands.len) |i| {
            if (results[i] == .ok) results[i] = .{ .ng = "atomic push failed" };
        }
        return respondReport(app, request, commands, caps, "ok", results[0..commands.len], null);
    }

    for (commands, 0..) |cmd, i| {
        if (!applied[i]) continue;
        const detail = if (cmd.isCreate()) "created" else if (cmd.isDelete()) "deleted" else "updated";
        events.record(app, .{
            .repo = name.full,
            .kind = "push",
            .ref = cmd.ref,
            .old = cmd.old,
            .new = cmd.new,
            .detail = detail,
            .created_at = now,
        });
        if (cmd.isDelete()) {
            app.db.clearBranchTtl(app.io, name.full, cmd.ref) catch |err|
                std.log.err("clearing expiry of {s}: {t}", .{ cmd.ref, err });
        } else if (cmd.isCreate() and claims.branch_ttl > 0 and std.mem.startsWith(u8, cmd.ref, "refs/heads/")) {
            app.db.setBranchTtl(app.io, name.full, &claims.repo_id, cmd.ref, now + claims.branch_ttl) catch |err|
                std.log.err("setting expiry of {s}: {t}", .{ cmd.ref, err });
        }
    }

    return respondReport(app, request, commands, caps, "ok", results[0..commands.len], null);
}

fn wantsReportStatus(caps: []const u8) bool {
    return hasCapability(caps, "report-status") or hasCapability(caps, "report-status-v2");
}

fn respondReport(
    app: *server.App,
    request: *http.Server.Request,
    commands: []const Command,
    caps: []const u8,
    unpack_status: []const u8,
    results: []const RefResult,
    progress_message: ?[]const u8,
) api.HandleError!http.Status {
    if (!wantsReportStatus(caps)) {
        try request.respond("", .{
            .keep_alive = http_util.keepAlive(request),
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/x-git-receive-pack-result" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        });
        return .ok;
    }
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    writeReport(&out.writer, caps, unpack_status, commands, results, progress_message) catch return api.internal(request);
    try request.respond(out.written(), .{
        .keep_alive = http_util.keepAlive(request),
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-git-receive-pack-result" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
    return .ok;
}

fn respondUnpackFailure(
    app: *server.App,
    request: *http.Server.Request,
    commands: []const Command,
    caps: []const u8,
    reason: []const u8,
) api.HandleError!http.Status {
    if (!wantsReportStatus(caps)) {
        return api.respondError(request, .bad_request, "invalid_pack", reason);
    }
    var results: [max_commands]RefResult = undefined;
    for (0..commands.len) |i| results[i] = .{ .ng = "unpack failed" };
    return respondReport(app, request, commands, caps, reason, results[0..commands.len], reason);
}

fn rejectRefAcl(
    app: *server.App,
    request: *http.Server.Request,
    commands: []const Command,
    caps: []const u8,
    claims: *const auth.Claims,
    name: repo_name.Name,
) api.HandleError!http.Status {
    var allowed_buf: [auth.max_ref_patterns_bytes + 16]u8 = undefined;
    var allowed: std.Io.Writer = .fixed(&allowed_buf);
    for (0..claims.refs_count) |i| {
        if (i > 0) allowed.writeAll(", ") catch {};
        allowed.writeAll(claims.refPattern(i)) catch {};
    }
    var reason_buf: [auth.max_ref_patterns_bytes + 64]u8 = undefined;
    const reason = std.mem.print(&reason_buf, "token may only push to {s}", .{allowed.buffered()}) catch "token may not push here";
    const other = "push refused: another ref in it is not allowed";

    var results: [max_commands]RefResult = undefined;
    const now = api.unixNow(app.io);
    for (commands, 0..) |cmd, i| {
        const ok = claims.allowsRef(cmd.ref);
        results[i] = .{ .ng = if (ok) other else reason };
        if (!ok) events.record(app, .{ .repo = name.full, .kind = "push_rejected", .ref = cmd.ref, .old = cmd.old, .new = cmd.new, .detail = reason, .created_at = now });
    }
    if (!wantsReportStatus(caps)) {
        return api.respondError(request, .forbidden, "forbidden", reason);
    }
    var msg_buf: [auth.max_ref_patterns_bytes + 96]u8 = undefined;
    const message = std.mem.print(&msg_buf, "gitd: push rejected: {s}", .{reason}) catch "gitd: push rejected";
    return respondReport(app, request, commands, caps, "ok", results[0..commands.len], message);
}

fn rejectLocked(
    app: *server.App,
    request: *http.Server.Request,
    commands: []const Command,
    caps: []const u8,
    name: repo_name.Name,
) api.HandleError!http.Status {
    const locked_reason = "branch is locked";
    const other = "push refused: another ref in it is locked";
    var results: [max_commands]RefResult = undefined;
    const now = api.unixNow(app.io);
    for (commands, 0..) |cmd, i| {
        const is_locked = app.db.isBranchLocked(app.io, name.full, cmd.ref) catch false;
        results[i] = .{ .ng = if (is_locked) locked_reason else other };
        if (is_locked) events.record(app, .{ .repo = name.full, .kind = "push_rejected", .ref = cmd.ref, .old = cmd.old, .new = cmd.new, .detail = locked_reason, .created_at = now });
    }
    if (!wantsReportStatus(caps)) {
        return api.respondError(request, .locked, "branch_locked", "branch is locked");
    }
    return respondReport(app, request, commands, caps, "ok", results[0..commands.len], "gitd: push rejected: branch is locked");
}

fn rejectRule(
    app: *server.App,
    request: *http.Server.Request,
    commands: []const Command,
    caps: []const u8,
    repo_rules: []const Db.BranchRule,
    name: repo_name.Name,
) api.HandleError!http.Status {
    const no_delete = "branch rule forbids deleting this branch";
    const no_direct = "branch rule forbids direct push to this branch";
    const other = "push refused: another ref in it violates a branch rule";
    var results: [max_commands]RefResult = undefined;
    const now = api.unixNow(app.io);
    for (commands, 0..) |cmd, i| {
        const eff = rules_mod.evaluate(repo_rules, cmd.ref);
        const bad_delete = cmd.isDelete() and !eff.allow_delete;
        const bad_direct = !cmd.isDelete() and !eff.allow_direct_push;
        const reason = if (bad_delete) no_delete else if (bad_direct) no_direct else other;
        results[i] = .{ .ng = reason };
        if (bad_delete or bad_direct) {
            events.record(app, .{
                .repo = name.full,
                .kind = "push_rejected",
                .ref = cmd.ref,
                .old = cmd.old,
                .new = cmd.new,
                .detail = reason,
                .created_at = now,
            });
        }
    }
    if (!wantsReportStatus(caps)) {
        return api.respondError(request, .forbidden, "rule_violation", "branch rule rejected push");
    }
    return respondReport(app, request, commands, caps, "ok", results[0..commands.len], "gitd: push rejected: branch rule violation");
}

fn rejectQuota(
    app: *server.App,
    request: *http.Server.Request,
    commands: []const Command,
    caps: []const u8,
    http_status: http.Status,
    reason: []const u8,
) api.HandleError!http.Status {
    if (!wantsReportStatus(caps)) {
        return api.respondError(request, http_status, "quota_exceeded", reason);
    }
    var results: [max_commands]RefResult = undefined;
    for (0..commands.len) |i| results[i] = .{ .ng = reason };
    var msg_buf: [128]u8 = undefined;
    const banner = std.mem.print(&msg_buf, "gitd: push rejected: {s}", .{reason}) catch "gitd: quota exceeded";
    return respondReport(app, request, commands, caps, "ok", results[0..commands.len], banner);
}

const testing = std.testing;
const zero = "0000000000000000000000000000000000000000";
const oid_a = "1111111111111111111111111111111111111111";
const oid_b = "2222222222222222222222222222222222222222";

inline fn testPkt(comptime payload: []const u8) []const u8 {
    return comptime std.fmt.comptimePrint("{x:0>4}", .{payload.len + 4}) ++ payload;
}

test "parses commands, capabilities, pack offset, and shallow lines" {
    var out: [max_commands]Command = undefined;
    const body = testPkt("shallow " ++ oid_a ++ "\n") ++
        testPkt(zero ++ " " ++ oid_a ++ " refs/heads/agent/1\x00report-status side-band-64k\n") ++
        testPkt(oid_a ++ " " ++ zero ++ " refs/heads/old") ++
        "0000PACK...";
    const res = try parseWithOffset(body, &out);
    try testing.expectEqualStrings("report-status side-band-64k", res.caps);
    try testing.expectEqual(@as(usize, 2), res.commands.len);
    try testing.expectEqualStrings("refs/heads/agent/1", res.commands[0].ref);
    try testing.expect(res.commands[0].isCreate());
    try testing.expect(res.commands[1].isDelete());
    try testing.expectEqualStrings("PACK...", body[res.pack_offset..]);
}

test "an empty probe push has no commands" {
    var out: [max_commands]Command = undefined;
    var caps: []const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), (try parse("0000", &out, &caps)).len);
}

test "rejects malformed pushes" {
    var out: [max_commands]Command = undefined;
    const bad = [_][]const u8{
        "",
        "00",
        "zzzz",
        "0003",
        testPkt(oid_a ++ " " ++ oid_b ++ " refs/heads/main"),
        testPkt(oid_a ++ " " ++ oid_b ++ " main") ++ "0000",
        testPkt(oid_a ++ " " ++ oid_b ++ " refs/heads/../x") ++ "0000",
        testPkt(oid_a ++ " " ++ oid_b[0..39] ++ " refs/heads/x") ++ "0000",
        testPkt("push-cert\x00caps") ++ "0000",
        testPkt(oid_a ++ " " ++ oid_b ++ " refs/heads/x\x00caps") ++ testPkt(oid_a ++ " " ++ oid_b ++ " refs/heads/y\x00more") ++ "0000",
        testPkt(oid_a ++ " " ++ oid_b ++ " refs/heads/x") ++ testPkt("shallow " ++ oid_a) ++ "0000",
        "00ff" ++ oid_a,
    };
    var caps: []const u8 = undefined;
    for (bad) |body| try testing.expectError(error.InvalidPush, parse(body, &out, &caps));
}

test "rejection report, plain and side-band" {
    var out: [max_commands]Command = undefined;
    var caps: []const u8 = undefined;
    const cmds = try parse(testPkt(oid_a ++ " " ++ oid_b ++ " refs/heads/main\x00report-status") ++ "0000", &out, &caps);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRejection(&w, caps, cmds, &.{"not allowed"}, "gitd: no");
    try testing.expectEqualStrings("000eunpack ok\n0023ng refs/heads/main not allowed\n0000", w.buffered());

    var w2: std.Io.Writer = .fixed(&buf);
    try writeRejection(&w2, "report-status side-band-64k", cmds, &.{"not allowed"}, "gitd: no");
    const got = w2.buffered();
    try testing.expectEqualStrings("000e\x02gitd: no\n", got[0..14]);
    try testing.expectEqualStrings("003a\x01000eunpack ok\n0023ng refs/heads/main not allowed\n0000", got[14 .. got.len - 4]);
    try testing.expectEqualStrings("0000", got[got.len - 4 ..]);
}

test "fuzz parse commands" {
    try testing.fuzz({}, fuzzParse, .{ .corpus = &.{ "0000", testPkt(zero ++ " " ++ oid_a ++ " refs/heads/x\x00caps") ++ "0000" } });
}

fn fuzzParse(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const input = buf[0..smith.slice(&buf)];
    var out: [max_commands]Command = undefined;
    const res = parseWithOffset(input, &out) catch return;
    try testing.expect(res.pack_offset <= input.len);
    for (res.commands) |c| {
        try ref_name.validate(c.ref);
        try testing.expect(isOid(c.old) and isOid(c.new));
    }
}
