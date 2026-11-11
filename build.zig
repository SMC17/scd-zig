const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("scd", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_tests = b.addTest(.{ .root_module = mod });
    const run_root_tests = b.addRunArtifact(root_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_root_tests.step);
    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/selfserve.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lib", .module = mod }},
        }),
    });
    b.installArtifact(demo);
    b.step("demo", "Run the self-contained synthetic acceptance task").dependOn(&b.addRunArtifact(demo).step);
}
