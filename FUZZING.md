# Fuzzing

`zig build fuzz` replays the checked-in smoke corpus. `zig build fuzz --fuzz=N`
enables Zig's coverage-guided fuzzer; omit `=N` for an unbounded run.

The fuzz artifact is deliberately built in `ReleaseSafe` and uses
`build_support/zig-0.16.0-fuzz-test-runner.zig`. Zig 0.16.0's stock fuzz-only
runner passes `@errorReturnTrace()` to `std.debug.writeStackTrace`, whose trace
type is incompatible. The vendored runner changes that single call to
`std.debug.writeErrorReturnTrace`. Ordinary `zig build test` continues to use
the stock runner.

When upgrading Zig, diff the vendored file against `lib/compiler/test_runner.zig`.
If the stock fuzz path already uses `writeErrorReturnTrace`, remove the vendored
runner and the `test_runner` override from `build.zig`.
