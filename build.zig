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
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Build and run gitd").dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    const fmt_paths: []const std.Build.LazyPath = &.{ b.path("src"), b.path("build.zig"), b.path("build.zig.zon") };
    b.step("fmt", "Format Zig source").dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);
    b.step("fmt-check", "Fail if Zig source is not formatted")
        .dependOn(&b.addFmt(.{ .paths = fmt_paths, .check = true }).step);
}
