//! Declarative branch protection rules (R1.1, R2.1, R2.2).
//!
//!   POST   /v1/repos/{ns}/{repo}/rules       admin key only
//!   GET    /v1/repos/{ns}/{repo}/rules       admin key only
//!   DELETE /v1/repos/{ns}/{repo}/rules/{id}  admin key only
//!
//! Rules use `ref_name` patterns (`refs/heads/main`, `refs/heads/release/*`)
//! and combine with deny-wins semantics across all matching rules for a ref.

const std = @import("std");
const http = std.http;
const api = @import("api.zig");
const server = @import("server.zig");
const repo_name = @import("repo_name.zig");
const ref_name = @import("ref_name.zig");
const content = @import("content.zig");
const http_util = @import("http_util.zig");
const events = @import("events.zig");
const checks = @import("checks.zig");
const Db = @import("db.zig").Db;

pub const max_rules_per_repo = 64;

pub const Effective = struct {
    allow_direct_push: bool = true,
    allow_force_push: bool = true,
    allow_delete: bool = true,
    /// Borrowed from the matching `Db.BranchRule` slice.
    required_merge_strategy: ?[]const u8 = null,
    /// Two matching rules require different merge strategies.
    strategy_conflict: bool = false,
};

/// Combines all rules whose pattern matches `ref`. Deny wins on boolean
/// flags; distinct required merge strategies mark `strategy_conflict`.
pub fn evaluate(rules: []const Db.BranchRule, ref: []const u8) Effective {
    var eff: Effective = .{};
    for (rules) |r| {
        if (!ref_name.matches(r.pattern, ref)) continue;
        if (!r.allow_direct_push) eff.allow_direct_push = false;
        if (!r.allow_force_push) eff.allow_force_push = false;
        if (!r.allow_delete) eff.allow_delete = false;
        if (r.required_merge_strategy.len > 0) {
            if (eff.required_merge_strategy) |prev| {
                if (!std.mem.eql(u8, prev, r.required_merge_strategy)) eff.strategy_conflict = true;
            } else {
                eff.required_merge_strategy = r.required_merge_strategy;
            }
        }
    }
    return eff;
}

pub fn mergeAllowed(eff: Effective, strategy_name: []const u8) bool {
    if (eff.strategy_conflict) return false;
    const req = eff.required_merge_strategy orelse return true;
    return std.mem.eql(u8, req, strategy_name);
}

/// Deduplicated union of required check names across all rules matching `ref`.
/// Slices borrow `rules`; caller frees the returned slice.
pub fn collectRequiredChecks(gpa: std.mem.Allocator, rules_list: []const Db.BranchRule, ref: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (rules_list) |r| {
        if (r.required_checks.len == 0 or !ref_name.matches(r.pattern, ref)) continue;
        var it = std.mem.splitScalar(u8, r.required_checks, ',');
        while (it.next()) |name| {
            if (name.len == 0) continue;
            var seen = false;
            for (out.items) |prev| {
                if (std.mem.eql(u8, prev, name)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try out.append(gpa, name);
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn validStrategy(text: []const u8) bool {
    return std.mem.eql(u8, text, "merge") or
        std.mem.eql(u8, text, "squash") or
        std.mem.eql(u8, text, "fast-forward");
}

const RuleJson = struct {
    id: i64,
    pattern: []const u8,
    allow_direct_push: bool,
    allow_force_push: bool,
    allow_delete: bool,
    required_merge_strategy: ?[]const u8,
    required_checks: []const []const u8,
    created_at: i64,
};

fn toJson(gpa: std.mem.Allocator, r: Db.BranchRule) !RuleJson {
    return .{
        .id = r.id,
        .pattern = r.pattern,
        .allow_direct_push = r.allow_direct_push,
        .allow_force_push = r.allow_force_push,
        .allow_delete = r.allow_delete,
        .required_merge_strategy = if (r.required_merge_strategy.len > 0) r.required_merge_strategy else null,
        .required_checks = try checks.splitRequired(gpa, r.required_checks),
        .created_at = r.created_at,
    };
}

pub fn serveApi(
    app: *server.App,
    request: *http.Server.Request,
    name: repo_name.Name,
    rest: []const u8,
    access: content.Access,
) api.HandleError!http.Status {
    if (access.claims != null or access.read_only) {
        return api.respondError(request, .forbidden, "forbidden", "branch rules need the admin key");
    }
    const method = request.head.method;
    if (std.mem.eql(u8, rest, "rules")) {
        return switch (method) {
            .POST => create(app, request, name),
            .GET => list(app, request, name),
            else => api.respondError(request, .method_not_allowed, "method_not_allowed", "use GET or POST"),
        };
    }
    if (std.mem.startsWith(u8, rest, "rules/") and method == .DELETE) {
        const id = std.fmt.parseInt(i64, rest["rules/".len..], 10) catch
            return api.respondError(request, .bad_request, "invalid_id", "rule ids are numbers");
        if (id <= 0) return api.respondError(request, .bad_request, "invalid_id", "rule ids are positive");
        const deleted = app.db.deleteBranchRule(app.io, name.full, id) catch return api.internal(request);
        if (!deleted) return api.respondError(request, .not_found, "not_found", "no such rule");
        var detail_buf: [32]u8 = undefined;
        const detail = std.mem.print(&detail_buf, "rule #{d}", .{id}) catch "rule";
        events.record(app, .{
            .repo = name.full,
            .kind = "rule_deleted",
            .detail = detail,
            .created_at = api.unixNow(app.io),
        });
        try request.respond("", .{ .status = .no_content, .keep_alive = http_util.keepAlive(request) });
        return .no_content;
    }
    return api.respondError(request, .not_found, "not_found", "no such rule route");
}

fn create(app: *server.App, request: *http.Server.Request, name: repo_name.Name) api.HandleError!http.Status {
    const Body = struct {
        pattern: []const u8,
        allow_direct_push: bool = true,
        allow_force_push: bool = true,
        allow_delete: bool = true,
        required_merge_strategy: ?[]const u8 = null,
        required_checks: []const []const u8 = &.{},
    };
    var parsed = api.readJson(Body, app.gpa, request) catch |err| return api.respondBodyError(request, err);
    defer parsed.deinit();
    const body = parsed.value;

    ref_name.validatePattern(body.pattern) catch
        return api.respondError(request, .bad_request, "invalid_ref_pattern", "pattern must be a full ref name optionally ending in /*, like refs/heads/main");
    const strategy = body.required_merge_strategy orelse "";
    if (strategy.len > 0 and !validStrategy(strategy)) {
        return api.respondError(request, .bad_request, "invalid_strategy", "required_merge_strategy must be merge, squash, or fast-forward");
    }
    const req_checks_csv = checks.joinRequired(app.gpa, body.required_checks) catch |err| return switch (err) {
        error.TooManyChecks => api.respondError(request, .bad_request, "invalid_checks", "at most 16 required_checks per rule"),
        error.DuplicateCheck => api.respondError(request, .bad_request, "invalid_checks", "required_checks must not contain duplicates"),
        error.InvalidCheckName => api.respondError(request, .bad_request, "invalid_checks", "each check name must be 1-64 characters from [A-Za-z0-9._/-]"),
        error.OutOfMemory => api.internal(request),
    };
    defer app.gpa.free(req_checks_csv);

    const existing = app.db.listBranchRules(app.io, app.gpa, name.full) catch return api.internal(request);
    defer Db.freeBranchRules(app.gpa, existing);
    if (existing.len >= max_rules_per_repo) {
        return api.respondError(request, .bad_request, "too_many_rules", "a repo may have at most 64 branch rules");
    }

    const now = api.unixNow(app.io);
    const id = app.db.insertBranchRule(
        app.io,
        name.full,
        body.pattern,
        body.allow_direct_push,
        body.allow_force_push,
        body.allow_delete,
        strategy,
        req_checks_csv,
        now,
    ) catch return api.internal(request);
    events.record(app, .{
        .repo = name.full,
        .kind = "rule_created",
        .ref = body.pattern,
        .detail = if (strategy.len > 0) strategy else if (req_checks_csv.len > 0) req_checks_csv else "protection rule",
        .created_at = now,
    });
    return api.respondJson(app.gpa, request, .created, RuleJson{
        .id = id,
        .pattern = body.pattern,
        .allow_direct_push = body.allow_direct_push,
        .allow_force_push = body.allow_force_push,
        .allow_delete = body.allow_delete,
        .required_merge_strategy = if (strategy.len > 0) strategy else null,
        .required_checks = body.required_checks,
        .created_at = now,
    });
}

fn list(app: *server.App, request: *http.Server.Request, name: repo_name.Name) api.HandleError!http.Status {
    const rows = app.db.listBranchRules(app.io, app.gpa, name.full) catch return api.internal(request);
    defer Db.freeBranchRules(app.gpa, rows);
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = arena.alloc(RuleJson, rows.len) catch return api.internal(request);
    for (rows, items) |r, *out| out.* = toJson(arena, r) catch return api.internal(request);
    return api.respondJson(app.gpa, request, .ok, .{ .rules = items });
}

const testing = std.testing;

test "evaluate combines matching rules with deny-wins and strategy checks" {
    const rules = [_]Db.BranchRule{
        .{
            .id = 1,
            .pattern = "refs/heads/*",
            .allow_direct_push = true,
            .allow_force_push = false,
            .allow_delete = true,
            .required_merge_strategy = "",
            .created_at = 1,
        },
        .{
            .id = 2,
            .pattern = "refs/heads/main",
            .allow_direct_push = false,
            .allow_force_push = true,
            .allow_delete = false,
            .required_merge_strategy = "squash",
            .created_at = 2,
        },
        .{
            .id = 3,
            .pattern = "refs/heads/release/*",
            .allow_direct_push = true,
            .allow_force_push = false,
            .allow_delete = false,
            .required_merge_strategy = "fast-forward",
            .created_at = 3,
        },
    };

    const main = evaluate(&rules, "refs/heads/main");
    try testing.expect(!main.allow_direct_push);
    try testing.expect(!main.allow_force_push);
    try testing.expect(!main.allow_delete);
    try testing.expectEqualStrings("squash", main.required_merge_strategy.?);
    try testing.expect(!main.strategy_conflict);
    try testing.expect(mergeAllowed(main, "squash"));
    try testing.expect(!mergeAllowed(main, "merge"));

    const work = evaluate(&rules, "refs/heads/agent/1");
    try testing.expect(work.allow_direct_push);
    try testing.expect(!work.allow_force_push);
    try testing.expect(work.allow_delete);
    try testing.expectEqual(null, work.required_merge_strategy);
    try testing.expect(mergeAllowed(work, "merge"));

    const conflict_rules = [_]Db.BranchRule{
        .{ .id = 1, .pattern = "refs/heads/*", .allow_direct_push = true, .allow_force_push = true, .allow_delete = true, .required_merge_strategy = "squash", .created_at = 1 },
        .{ .id = 2, .pattern = "refs/heads/main", .allow_direct_push = true, .allow_force_push = true, .allow_delete = true, .required_merge_strategy = "merge", .created_at = 2 },
    };
    const both = evaluate(&conflict_rules, "refs/heads/main");
    try testing.expect(both.strategy_conflict);
    try testing.expect(!mergeAllowed(both, "squash"));
    try testing.expect(!mergeAllowed(both, "merge"));

    const check_rules = [_]Db.BranchRule{
        .{ .id = 1, .pattern = "refs/heads/*", .allow_direct_push = true, .allow_force_push = true, .allow_delete = true, .required_merge_strategy = "", .required_checks = "lint", .created_at = 1 },
        .{ .id = 2, .pattern = "refs/heads/main", .allow_direct_push = true, .allow_force_push = true, .allow_delete = true, .required_merge_strategy = "", .required_checks = "tests,lint", .created_at = 2 },
    };
    const req = try collectRequiredChecks(testing.allocator, &check_rules, "refs/heads/main");
    defer testing.allocator.free(req);
    try testing.expectEqual(@as(usize, 2), req.len);
    try testing.expectEqualStrings("lint", req[0]);
    try testing.expectEqualStrings("tests", req[1]);
}

test "fuzz evaluate rules" {
    try testing.fuzz({}, fuzzEvaluate, .{
        .corpus = &.{
            "refs/heads/main\x001\x001\x001\x00squash\x00refs/heads/main",
            "refs/heads/*\x000\x000\x000\x00\x00refs/heads/a",
        },
    });
}

fn fuzzEvaluate(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const raw = buf[0..smith.slice(&buf)];
    if (raw.len < 6) return;
    const pat_len = @min(@as(usize, raw[0]), raw.len - 5);
    const pat = raw[1 .. 1 + pat_len];
    const flags = raw[1 + pat_len];
    const ref = raw[2 + pat_len ..];
    ref_name.validatePattern(pat) catch return;
    ref_name.validate(ref) catch return;

    const strat: []const u8 = switch (flags & 3) {
        1 => "merge",
        2 => "squash",
        3 => "fast-forward",
        else => "",
    };
    const rule: Db.BranchRule = .{
        .id = 1,
        .pattern = pat,
        .allow_direct_push = (flags & 4) != 0,
        .allow_force_push = (flags & 8) != 0,
        .allow_delete = (flags & 16) != 0,
        .required_merge_strategy = strat,
        .created_at = 1,
    };
    const eff = evaluate(&.{rule}, ref);
    if (!ref_name.matches(pat, ref)) {
        try testing.expect(eff.allow_direct_push and eff.allow_force_push and eff.allow_delete);
        try testing.expectEqual(null, eff.required_merge_strategy);
    } else if (strat.len > 0) {
        try testing.expect(!mergeAllowed(eff, "invalid"));
        try testing.expect(mergeAllowed(eff, strat));
    }
}
