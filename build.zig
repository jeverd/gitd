const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "gitd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Build and run gitd").dependOn(&run_cmd.step);

    // `zig build test --fuzz` fuzzes only the first fuzz test it finds, so
    // scripts/verify.sh picks each target with -Dtest-filter.
    const test_filters = b.option([]const []const u8, "test-filter", "Run only tests whose name contains this") orelse &.{};
    const unit_tests = b.addTest(.{ .root_module = exe.root_module, .filters = test_filters });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    const fmt_paths: []const std.Build.LazyPath = &.{ b.path("src"), b.path("build.zig"), b.path("build.zig.zon") };
    b.step("fmt", "Format Zig source").dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);
    b.step("fmt-check", "Fail if Zig source is not formatted")
        .dependOn(&b.addFmt(.{ .paths = fmt_paths, .check = true }).step);
}
