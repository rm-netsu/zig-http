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

    const conformance_mod = b.createModule(.{
        .root_source_file = b.path("test/conformance/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = mod }},
    });
    const conformance_exe = b.addExecutable(.{ .name = "http2-conformance-server", .root_module = conformance_mod });
    const install_conformance = b.addInstallArtifact(conformance_exe, .{});
    const conformance_server_step = b.step("conformance-server", "Build the cleartext HTTP/2 conformance fixture server");
    conformance_server_step.dependOn(&install_conformance.step);

    const conformance_client_mod = b.createModule(.{
        .root_source_file = b.path("test/conformance/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = mod }},
    });
    const conformance_client_exe = b.addExecutable(.{ .name = "http2-conformance-client", .root_module = conformance_client_mod });
    const install_conformance_client = b.addInstallArtifact(conformance_client_exe, .{});
    const conformance_client_step = b.step("conformance-client", "Build the cleartext HTTP/2 interoperability fixture client");
    conformance_client_step.dependOn(&install_conformance_client.step);

    const http1_conformance_mod = b.createModule(.{
        .root_source_file = b.path("test/conformance/http1_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = mod }},
    });
    const http1_conformance_exe = b.addExecutable(.{ .name = "http1-conformance-server", .root_module = http1_conformance_mod });
    const install_http1_conformance = b.addInstallArtifact(http1_conformance_exe, .{});
    const http1_conformance_step = b.step("http1-conformance-server", "Build the cleartext HTTP/1 interoperability fixture server");
    http1_conformance_step.dependOn(&install_http1_conformance.step);

    const http1_client_mod = b.createModule(.{
        .root_source_file = b.path("test/conformance/http1_client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = mod }},
    });
    const http1_client_exe = b.addExecutable(.{ .name = "http1-conformance-client", .root_module = http1_client_mod });
    const install_http1_client = b.addInstallArtifact(http1_client_exe, .{});
    const http1_client_step = b.step("http1-conformance-client", "Build the cleartext HTTP/1 interoperability fixture client");
    http1_client_step.dependOn(&install_http1_client.step);

    // Generate declaration-level API documentation from the public root module.
    // Guides remain hand-written because ownership and composition rules are
    // broader than declaration signatures.
    const docs_lib = b.addLibrary(.{ .name = "http-docs", .root_module = mod });
    const install_api_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/api",
    });
    const docs_step = b.step("docs", "Generate and install the HTTP API reference");
    docs_step.dependOn(&install_api_docs.step);

    const examples_step = b.step("examples", "Build and run HTTP usage examples");
    const example_sources = [_][]const u8{
        "http1_client_core",
        "http1_high_level",
        "http1_tcp_client_server",
        "http1_expect_upgrade",
        "http1_server_core",
        "http1_trailers",
        "http2_client_core",
        "http2_high_level",
        "http2_tcp_client_server",
        "http2_server_core",
        "http2_trailers",
        "http2_priority",
        "http2_scheduler",
        "error_handling",
    };
    for (example_sources) |name| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "http", .module = mod }},
        });
        const example_exe = b.addExecutable(.{
            .name = b.fmt("http-example-{s}", .{name}),
            .root_module = example_mod,
        });
        const run_example = b.addRunArtifact(example_exe);
        examples_step.dependOn(&run_example.step);
        if (std.mem.eql(u8, name, "http1_tcp_client_server")) {
            const step = b.step("example-http1-tcp", "Run the loopback TCP HTTP/1 client/server example");
            step.dependOn(&run_example.step);
        } else if (std.mem.eql(u8, name, "http2_tcp_client_server")) {
            const step = b.step("example-http2-tcp", "Run the loopback TCP HTTP/2 prior-knowledge client/server example");
            step.dependOn(&run_example.step);
        }
    }

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the HTTP library tests");
    test_step.dependOn(&run_tests.step);

    // Zig 0.16.0's stock test runner has a fuzz-only StackTrace type mismatch.
    // Keep normal tests on the stock runner; fuzzing uses the narrowly patched
    // vendored runner and ReleaseSafe for reproducibility.
    const fuzz_hpack_dep = b.dependency("hpack", .{
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const fuzz_hpack_mod = fuzz_hpack_dep.module("hpack");
    const fuzz_http_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "hpack", .module = fuzz_hpack_mod }},
    });
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("test/fuzz/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "http", .module = fuzz_http_mod }},
    });
    const fuzz_tests = b.addTest(.{
        .name = "http-fuzz",
        .root_module = fuzz_mod,
        .test_runner = .{
            .path = b.path("build_support/zig-0.16.0-fuzz-test-runner.zig"),
            .mode = .server,
        },
    });
    const fuzz_step = b.step("fuzz", "Run HTTP property tests and Zig builtin fuzzing");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    const fixtures_step = b.step("conformance-fixtures", "Compile HTTP/1 and HTTP/2 external-test fixtures");
    fixtures_step.dependOn(&install_conformance.step);
    fixtures_step.dependOn(&install_conformance_client.step);
    fixtures_step.dependOn(&install_http1_conformance.step);
    fixtures_step.dependOn(&install_http1_client.step);

    // Dependency-free merge gate: unit/property tests plus compilation of every
    // test-only transport fixture. Full external stacks and h2spec remain shell
    // commands because they intentionally depend on tools outside Zig.
    const check_step = b.step("check", "Run unit/property tests and compile conformance fixtures");
    check_step.dependOn(test_step);
    check_step.dependOn(fuzz_step);
    check_step.dependOn(fixtures_step);
    check_step.dependOn(examples_step);

    // External protocol verification is intentionally separated from `check`:
    // these steps depend on system tools such as Python and curl. The ordinary
    // conformance aggregate stays reproducible without h2spec, while the strict
    // h2spec target keeps a missing upstream binary as an explicit failure.
    const run_conformance = b.addSystemCommand(&.{ "sh", "test/conformance/run-conformance.sh" });
    run_conformance.setCwd(b.path("."));
    run_conformance.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    const conformance_step = b.step("conformance", "Run HTTP/1 and HTTP/2 external interoperability plus RFC smoke tests");
    conformance_step.dependOn(&run_conformance.step);

    const run_h2spec = b.addSystemCommand(&.{ "sh", "test/conformance/run-h2spec.sh" });
    run_h2spec.setCwd(b.path("."));
    run_h2spec.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    const h2spec_step = b.step("conformance-h2spec", "Run the strict upstream h2spec suite (requires h2spec)");
    h2spec_step.dependOn(&run_h2spec.step);

    const all_checks_step = b.step("all-checks", "Run merge checks, API docs, and reproducible external conformance");
    all_checks_step.dependOn(check_step);
    all_checks_step.dependOn(docs_step);
    all_checks_step.dependOn(conformance_step);

    // Release gate: run the reproducible aggregate first, then upstream h2spec
    // on the same fixture port. A separate command instance gives the build
    // graph an explicit ordering edge and avoids racing two fixture servers.
    const run_release_h2spec = b.addSystemCommand(&.{ "sh", "test/conformance/run-h2spec.sh" });
    run_release_h2spec.setCwd(b.path("."));
    run_release_h2spec.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    run_release_h2spec.step.dependOn(all_checks_step);
    const release_checks_step = b.step("release-checks", "Run all release gates including strict upstream h2spec");
    release_checks_step.dependOn(&run_release_h2spec.step);

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
