const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const hpack_dep = b.dependency("hpack", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("http", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "hpack", .module = hpack_dep.module("hpack") }},
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the HTTP library tests");
    test_step.dependOn(&run_tests.step);
}
