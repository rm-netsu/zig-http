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

## Current property targets

The fuzz artifact currently contains seven independent targets:

1. HTTP/2 `FlowWindow` operations against a signed reference model.
2. HTTP/1 request parsing: contiguous `parseRequest` versus one-byte-fragmented `FramedHeadParser`.
3. HTTP/1 response parsing: contiguous `parseResponse` versus one-byte-fragmented parsing with GET/HEAD/CONNECT context.
4. HTTP/2 complete-frame parsing versus `FrameDecoder` under generated transport fragmentation.
5. HTTP/1 `ChunkDecoder` contiguous versus one-byte-fragmented decoding, including generated chunk extensions and trailers.
6. HTTP/2 `streams.Manager` mixed client/server lifecycle sequences with caller-owned storage, checking active-stream aggregate invariants after every generated transition.
7. HTTP/2 `Session` versus the fragmented-frame receive path over generated HEADERS/CONTINUATION/DATA/SETTINGS/PING/WINDOW_UPDATE/PRIORITY/RST_STREAM/GOAWAY/extension sequences, checking event and persistent-state equivalence after every frame.

The deterministic replay path is intentionally part of `zig build check`. Coverage-guided runs can be longer-lived and are not required for ordinary consumers or every local build. New protocol bugs found by conformance/interoperability testing should be reduced into deterministic unit/property regressions rather than relying only on a transient fuzz corpus.
