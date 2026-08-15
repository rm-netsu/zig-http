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

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = mod }},
    });
    const bench_exe = b.addExecutable(.{ .name = "http-bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run HTTP parser microbenchmarks");
    bench_step.dependOn(&run_bench.step);

    const real_bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/real.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http", .module = mod },
            .{ .name = "hpack", .module = hpack_dep.module("hpack") },
        },
    });
    const real_bench_exe = b.addExecutable(.{ .name = "http-real-bench", .root_module = real_bench_mod });
    const run_real_bench = b.addRunArtifact(real_bench_exe);
    if (b.args) |args| run_real_bench.addArgs(args);
    const real_bench_step = b.step("bench-real", "Run real-world HTTP protocol benchmarks");
    real_bench_step.dependOn(&run_real_bench.step);
}
