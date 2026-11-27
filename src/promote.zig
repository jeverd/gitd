//! Per-branch promote fences and the atomic compare-and-swap promote.
//!
//! Under /v1/repos/{ns}/{repo}/:
//!   GET  branches/{name}/fence  {repo, branch, paused, policy_epoch, reason}  git:read
//!   POST branches/{name}/fence  {"paused", "bump_epoch", "reason"}            admin key
//!   POST refs/promote           {"target", "candidate_sha", "expected_base_sha",
//!                                "expected_policy_epoch", "operation_id"}     git:write on the target
//!
//! A fence is `{paused, policy_epoch, reason}` per branch, unpaused at
//! epoch 0 until first set. Changing `paused`, or asking for `bump_epoch`,
//! raises the epoch, so a promote planned under the old policy fails.
//!
//! A promote moves `refs/heads/{target}` to `candidate_sha` only if, at one
//! instant, the fence is unpaused, its epoch is `expected_policy_epoch`, and
//! the branch is at `expected_base_sha`. `App.promote_lock` makes the fence
//! check and the ref move one step against fence updates; the ref move is
//! also a compare-and-swap against every other writer, pushes included
//! (R3.2). A promote that succeeded leaves a receipt under its
//! `operation_id`, and a retry gets that receipt back instead of a 409.
//! Modeled in tests/tla/promote_fence/PromoteFence.tla (`NoStalePromote`).

const std = @import("std");
const http = std.http;
const api = @import("api.zig");
const server = @import("server.zig");
const repo_name = @import("repo_name.zig");
const ref_name = @import("ref_name.zig");
const repo_git = @import("repo_git.zig");
const receive_pack = @import("receive_pack.zig");
const events = @import("events.zig");
const rules = @import("rules.zig");
const content = @import("content.zig");
const Db = @import("db.zig").Db;

const Error = api.HandleError;

pub const max_reason_len = 200;
pub const max_operation_id_len = 128;

/// Routes `branches/{name}/fence`; `raw_branch` is the still-encoded name.
pub fn serveFence(
    app: *server.App,
    request: *http.Server.Request,
    name: repo_name.Name,
    raw_branch: []const u8,
    access: content.Access,
) Error!http.Status {
    var decoded: [ref_name.max_len]u8 = undefined;
    const branch = api.percentDecode(&decoded, raw_branch, false) orelse
        return api.respondError(request, .bad_request, "invalid_branch", "the branch name is not valid");
    var ref_buf: [ref_name.max_len]u8 = undefined;
    const ref = ref_name.validateBranch(branch, &ref_buf) catch
        return api.respondError(request, .bad_request, "invalid_branch", "the branch name is not valid");

    switch (request.head.method) {
        .GET => {
            if (!access.canRead()) return api.respondError(request, .forbidden, "forbidden", "this token lacks git:read");
            if (!try content.checkReadableRev(request, ref, access)) return .forbidden;
            const fence = app.db.getFence(app.io, app.gpa, name.full, ref) catch return api.internal(request);
            defer fence.deinit(app.gpa);
            return respondFence(app, request, name, branch, fence);
        },
        .POST => return updateFence(app, request, name, branch, ref, access),
        else => return api.respondError(request, .method_not_allowed, "method_not_allowed", "use GET or POST"),
    }
}

fn updateFence(
    app: *server.App,
    request: *http.Server.Request,
    name: repo_name.Name,
    branch: []const u8,
    ref: []const u8,
    access: content.Access,
) Error!http.Status {
    if (access.claims != null or access.read_only) {
        return api.respondError(request, .forbidden, "forbidden", "branch fences need the admin key");
    }
    const Body = struct {
        paused: ?bool = null,
        bump_epoch: ?bool = null,
        reason: ?[]const u8 = null,
    };
    // `branch` and `ref` point into the handler's copy of the target, not
    // the request head, so reading the body leaves them intact (R3.5).
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    const body = parsed.value;
    if (body.reason) |r| if (r.len > max_reason_len) {
        return api.respondError(request, .bad_request, "invalid_reason", "reason must be at most 200 bytes");
    };

    const io = app.io;
    const now = api.unixNow(io);
    const fence = blk: {
        try app.promote_lock.lock(io);
        defer app.promote_lock.unlock(io);
        break :blk app.db.updateFence(io, app.gpa, name.full, ref, .{
            .paused = body.paused,
            .bump_epoch = body.bump_epoch orelse false,
            .reason = body.reason,
        }, now) catch return api.internal(request);
    };
    defer fence.deinit(app.gpa);

    var detail_buf: [max_reason_len + 64]u8 = undefined;
    const detail = std.mem.print(&detail_buf, "paused={} epoch={d}{s}{s}", .{
        fence.paused,
        fence.policy_epoch,
        if (fence.reason.len > 0) ": " else "",
        fence.reason,
    }) catch "fence updated";
    events.record(app, .{ .repo = name.full, .kind = "fence_updated", .ref = ref, .detail = detail, .created_at = now });
    return respondFence(app, request, name, branch, fence);
}

fn respondFence(app: *server.App, request: *http.Server.Request, name: repo_name.Name, branch: []const u8, fence: Db.Fence) Error!http.Status {
    return api.respondJson(app.gpa, request, .ok, .{
        .repo = name.full,
        .branch = branch,
        .paused = fence.paused,
        .policy_epoch = fence.policy_epoch,
        .reason = if (fence.reason.len == 0) null else fence.reason,
    });
}

/// Whether `text` may be an operation id: 1-128 bytes of
/// `A-Z a-z 0-9 . _ - :`.
pub fn validOperationId(text: []const u8) bool {
    if (text.len == 0 or text.len > max_operation_id_len) return false;
    for (text) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-', ':' => {},
        else => return false,
    };
    return true;
}

pub fn servePromote(
    app: *server.App,
    request: *http.Server.Request,
    repo: *const repo_git.Repo,
    name: repo_name.Name,
    access: content.Access,
) Error!http.Status {
    if (request.head.method != .POST) return api.respondError(request, .method_not_allowed, "method_not_allowed", "use POST");
    const Body = struct {
        target: []const u8,
        candidate_sha: []const u8,
        expected_base_sha: []const u8,
        expected_policy_epoch: u64,
        operation_id: []const u8,
    };
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    const body = parsed.value;

    var ref_buf: [ref_name.max_len]u8 = undefined;
    const target_ref = ref_name.validateBranch(body.target, &ref_buf) catch
        return api.respondError(request, .bad_request, "invalid_branch", "target must be a branch name");
    if (!receive_pack.isOid(body.candidate_sha) or !receive_pack.isOid(body.expected_base_sha)) {
        return api.respondError(request, .bad_request, "invalid_sha", "candidate_sha and expected_base_sha must be full lowercase commit oids");
    }
    if (!validOperationId(body.operation_id)) {
        return api.respondError(request, .bad_request, "invalid_operation_id", "operation_id is 1-128 characters of A-Z a-z 0-9 . _ - :");
    }
    if (!access.canWrite(target_ref)) {
        var msg_buf: [ref_name.max_len + 64]u8 = undefined;
        const msg = std.mem.print(&msg_buf, "this token may not write {s}", .{target_ref}) catch "this token may not write that branch";
        return api.respondError(request, .forbidden, "forbidden", msg);
    }
    // A promote can land any commit, so it would let a path-scoped token
    // change files outside its paths.
    if (access.isPathRestricted()) {
        return api.respondError(request, .forbidden, "forbidden", "path-scoped tokens may not promote");
    }
    if (!try content.checkReadableRev(request, target_ref, access)) return .forbidden;

    const io = app.io;
    try app.promote_lock.lock(io);
    defer app.promote_lock.unlock(io);

    // Inside the lock, so two retries of one operation cannot both move
    // the branch.
    const prior = app.db.getPromoteReceipt(io, app.gpa, name.full, body.operation_id) catch return api.internal(request);
    if (prior) |receipt| {
        defer receipt.deinit(app.gpa);
        const same = std.mem.eql(u8, receipt.target, body.target) and
            std.mem.eql(u8, receipt.sha, body.candidate_sha) and
            std.mem.eql(u8, receipt.base_sha, body.expected_base_sha);
        if (!same) {
            return api.respondError(request, .conflict, "operation_id_conflict", "this operation_id already promoted a different target or commit");
        }
        return respondReceipt(app, request, receipt, body.operation_id);
    }

    if (app.db.isBranchLocked(io, name.full, target_ref) catch return api.internal(request)) {
        return api.respondError(request, .locked, "branch_locked", "this branch is locked");
    }

    const fence = app.db.getFence(io, app.gpa, name.full, target_ref) catch return api.internal(request);
    defer fence.deinit(app.gpa);
    var current_buf: [64]u8 = undefined;
    const current = repo.refValue(target_ref, &current_buf) catch |err| return content.gitError(request, err);

    if (fence.paused) {
        return respondConflict(app, request, "fence_paused", "promotes to this branch are paused", fence, current);
    }
    if (fence.policy_epoch != body.expected_policy_epoch) {
        return respondConflict(app, request, "policy_epoch_mismatch", "the branch's policy epoch changed; re-plan against the current epoch", fence, current);
    }
    if (current == null or !std.mem.eql(u8, current.?, body.expected_base_sha)) {
        return respondConflict(app, request, "base_sha_mismatch", "the branch is not at expected_base_sha", fence, current);
    }

    var cand_buf: [64]u8 = undefined;
    const candidate = (repo.resolveCommit(body.candidate_sha, &cand_buf) catch |err| return content.gitError(request, err)) orelse
        return api.respondError(request, .not_found, "not_found", "candidate_sha names no commit");
    const fast_forward = std.mem.eql(u8, candidate, body.expected_base_sha) or
        (repo.isAncestor(body.expected_base_sha, candidate) catch |err| return content.gitError(request, err));
    if (!fast_forward) {
        const repo_rules = app.db.listBranchRules(io, app.gpa, name.full) catch return api.internal(request);
        defer Db.freeBranchRules(app.gpa, repo_rules);
        if (!rules.evaluate(repo_rules, target_ref).allow_force_push) {
            return api.respondError(request, .forbidden, "rule_violation", "branch rule forbids a promote that is not a fast-forward");
        }
    }

    const outcome = repo.updateRef(target_ref, candidate, body.expected_base_sha) catch |err| return content.gitError(request, err);
    if (outcome == .stale) {
        const now_at = repo.refValue(target_ref, &current_buf) catch |err| return content.gitError(request, err);
        return respondConflict(app, request, "base_sha_mismatch", "the branch moved while promoting", fence, now_at);
    }

    const now = api.unixNow(io);
    const receipt: Db.PromoteReceipt = .{
        .target = body.target,
        .base_sha = body.expected_base_sha,
        .sha = candidate,
        .policy_epoch = fence.policy_epoch,
    };
    // The branch already moved; a lost receipt only means a retry of this
    // operation gets base_sha_mismatch instead of the receipt.
    app.db.insertPromoteReceipt(io, name.full, body.operation_id, receipt, now) catch |err|
        std.log.err("storing promote receipt for {s}: {t}", .{ name.full, err });

    var detail_buf: [max_operation_id_len + 64]u8 = undefined;
    const detail = std.mem.print(&detail_buf, "operation {s} at epoch {d}", .{ body.operation_id, fence.policy_epoch }) catch "promote";
    events.record(app, events.withActor(.{
        .repo = name.full,
        .kind = "promote",
        .ref = target_ref,
        .old = body.expected_base_sha,
        .new = candidate,
        .detail = detail,
        .created_at = now,
    }, access.claims));
    return respondReceipt(app, request, receipt, body.operation_id);
}

fn respondReceipt(app: *server.App, request: *http.Server.Request, receipt: Db.PromoteReceipt, operation_id: []const u8) Error!http.Status {
    return api.respondJson(app.gpa, request, .ok, .{
        .target = receipt.target,
        .base_sha = receipt.base_sha,
        .sha = receipt.sha,
        .policy_epoch = receipt.policy_epoch,
        .operation_id = operation_id,
    });
}

fn respondConflict(
    app: *server.App,
    request: *http.Server.Request,
    code: []const u8,
    message: []const u8,
    fence: Db.Fence,
    current_base_sha: ?[]const u8,
) Error!http.Status {
    const Err = struct { code: []const u8, message: []const u8 };
    return api.respondJson(app.gpa, request, .conflict, .{
        .@"error" = Err{ .code = code, .message = message },
        .paused = fence.paused,
        .policy_epoch = fence.policy_epoch,
        .current_base_sha = current_base_sha,
    });
}

test validOperationId {
    try std.testing.expect(validOperationId("op-1"));
    try std.testing.expect(validOperationId("queue:main:42.retry_1"));
    try std.testing.expect(!validOperationId(""));
    try std.testing.expect(!validOperationId("has space"));
    try std.testing.expect(!validOperationId("a/b"));
    try std.testing.expect(!validOperationId(&@as([max_operation_id_len + 1]u8, @splat('a'))));
}
