const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer instrumentation") orelse false;

    const hpack_dep = b.dependency("hpack", .{
        .target = target,
        .optimize = optimize,
    });

    const hpack_mod = hpack_dep.module("hpack");
    hpack_mod.sanitize_thread = sanitize_thread;

    const mod = b.addModule("http", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{.{ .name = "hpack", .module = hpack_mod }},
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
            .{ .name = "hpack", .module = hpack_mod },
        },
    });
    const real_bench_exe = b.addExecutable(.{ .name = "http-real-bench", .root_module = real_bench_mod });
    const run_real_bench = b.addRunArtifact(real_bench_exe);
    if (b.args) |args| run_real_bench.addArgs(args);
    const real_bench_step = b.step("bench-real", "Run real-world HTTP protocol benchmarks");
    real_bench_step.dependOn(&run_real_bench.step);

    const frame_real_step = b.step("bench-real-frames", "Run isolated real-world HTTP/2 frame benchmarks");
    const frame_cases = [_][]const u8{
        "raw_complete",
        "connection_complete",
        "raw_fragmented",
        "connection_fragmented",
    };
    var previous_frame_run: ?*std.Build.Step = null;
    for (frame_cases) |case| {
        const source = b.fmt("bench/frame_real_{s}.zig", .{case});
        const frame_mod = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const exe = b.addExecutable(.{ .name = b.fmt("http-frame-real-{s}", .{case}), .root_module = frame_mod });
        const run = b.addRunArtifact(exe);
        run.stdio = .inherit;
        if (b.args) |args| run.addArgs(args);
        if (previous_frame_run) |previous| run.step.dependOn(previous);
        previous_frame_run = &run.step;
    }
    frame_real_step.dependOn(previous_frame_run.?);

    const stream_real_step = b.step("bench-real-streams", "Run isolated real-world HTTP/2 stream lifecycle benchmarks");
    const stream_cases = [_][]const u8{ "raw", "managed", "raw_tracked", "managed_tracked", "detached_tracked", "raw_multiplex", "managed_multiplex" };
    var previous_stream_run: ?*std.Build.Step = null;
    for (stream_cases) |case| {
        const source = b.fmt("bench/stream_real_{s}.zig", .{case});
        const stream_mod = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const exe = b.addExecutable(.{ .name = b.fmt("http-stream-real-{s}", .{case}), .root_module = stream_mod });
        const run = b.addRunArtifact(exe);
        run.stdio = .inherit;
        if (b.args) |args| run.addArgs(args);
        if (previous_stream_run) |previous| run.step.dependOn(previous);
        previous_stream_run = &run.step;
    }
    stream_real_step.dependOn(previous_stream_run.?);

    const session_real_step = b.step("bench-real-session", "Run isolated real-world HTTP/2 session composition benchmarks");
    const session_cases = [_][]const u8{ "manual", "managed" };
    var previous_session_run: ?*std.Build.Step = null;
    for (session_cases) |case| {
        const source = b.fmt("bench/session_real_{s}.zig", .{case});
        const session_mod = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const exe = b.addExecutable(.{ .name = b.fmt("http-session-real-{s}", .{case}), .root_module = session_mod });
        const run = b.addRunArtifact(exe);
        run.stdio = .inherit;
        if (b.args) |args| run.addArgs(args);
        if (previous_session_run) |previous| run.step.dependOn(previous);
        previous_session_run = &run.step;
    }
    session_real_step.dependOn(previous_session_run.?);

    const scheduler_step = b.step("bench-real-scheduler", "Run caller-driven HTTP/2 DATA scheduler benchmarks");
    const scheduler_cases = [_][]const u8{ "manual", "managed" };
    var previous_scheduler_run: ?*std.Build.Step = null;
    for (scheduler_cases) |case| {
        const source = b.fmt("bench/scheduler_real_{s}.zig", .{case});
        const scheduler_mod = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const exe = b.addExecutable(.{ .name = b.fmt("http-scheduler-real-{s}", .{case}), .root_module = scheduler_mod });
        const run = b.addRunArtifact(exe);
        run.stdio = .inherit;
        // Keep both isolated executables on the exact same runtime-derived
        // workload shape while still preventing compile-time folding.
        run.addArg("2654435761");
        if (b.args) |args| run.addArgs(args);
        if (previous_scheduler_run) |previous| run.step.dependOn(previous);
        previous_scheduler_run = &run.step;
    }
    scheduler_step.dependOn(previous_scheduler_run.?);

    const dispatch_step = b.step("bench-real-dispatch", "Run HTTP/2 ordered-dispatch stream handoff benchmarks");
    const dispatch_cases = [_][]const u8{ "manual", "handoff", "managed", "typed", "prechecked" };
    var previous_dispatch_run: ?*std.Build.Step = null;
    for (dispatch_cases) |case| {
        const source = b.fmt("bench/dispatch_real_{s}.zig", .{case});
        const dispatch_mod = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const exe = b.addExecutable(.{ .name = b.fmt("http-dispatch-real-{s}", .{case}), .root_module = dispatch_mod });
        const run = b.addRunArtifact(exe);
        run.stdio = .inherit;
        if (b.args) |args| run.addArgs(args);
        if (previous_dispatch_run) |previous| run.step.dependOn(previous);
        previous_dispatch_run = &run.step;
    }
    dispatch_step.dependOn(previous_dispatch_run.?);

    const settings_mod = b.createModule(.{
        .root_source_file = b.path("bench/settings_real.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = mod }},
    });
    const settings_exe = b.addExecutable(.{ .name = "http-settings-real", .root_module = settings_mod });
    const run_settings = b.addRunArtifact(settings_exe);
    run_settings.stdio = .inherit;
    const settings_step = b.step("bench-real-settings", "Run HTTP/2 SETTINGS stream-window scalability benchmark");
    settings_step.dependOn(&run_settings.step);

    const send_offer_step = b.step("bench-real-send-offer", "Run sharded HTTP/2 DATA offer/grant benchmarks");
    const send_offer_cases = [_][]const u8{ "manual", "managed" };
    var previous_send_offer_run: ?*std.Build.Step = null;
    for (send_offer_cases) |case| {
        const source = b.fmt("bench/send_offer_real_{s}.zig", .{case});
        const send_offer_mod = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const exe = b.addExecutable(.{ .name = b.fmt("http-send-offer-real-{s}", .{case}), .root_module = send_offer_mod });
        const run = b.addRunArtifact(exe);
        run.stdio = .inherit;
        if (b.args) |args| run.addArgs(args);
        if (previous_send_offer_run) |previous| run.step.dependOn(previous);
        previous_send_offer_run = &run.step;
    }
    send_offer_step.dependOn(previous_send_offer_run.?);

    const send_session_step = b.step("bench-real-send-session", "Run isolated real-world HTTP/2 send-session benchmarks");
    const send_session_cases = [_][]const u8{ "manual", "managed", "managed_tracked" };
    var previous_send_session_run: ?*std.Build.Step = null;
    for (send_session_cases) |case| {
        const source = b.fmt("bench/send_session_real_{s}.zig", .{case});
        const send_session_mod = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const exe = b.addExecutable(.{ .name = b.fmt("http-send-session-real-{s}", .{case}), .root_module = send_session_mod });
        const run = b.addRunArtifact(exe);
        run.stdio = .inherit;
        if (b.args) |args| run.addArgs(args);
        if (previous_send_session_run) |previous| run.step.dependOn(previous);
        previous_send_session_run = &run.step;
    }
    send_session_step.dependOn(previous_send_session_run.?);
}
