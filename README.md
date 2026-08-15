# http

High-performance, allocation-conscious HTTP/1.1 and HTTP/2 protocol primitives for Zig 0.16.0.

## Design

- Transport-agnostic: sockets, TLS and event loops stay outside the protocol core.
- Slice-oriented parsers with caller-owned bounded storage.
- Zero-copy fast paths when a complete HTTP/1 head or HTTP/2 frame is already contiguous in the transport buffer.
- Small process-wide byte-class tables and SIMD validation trade about 512 bytes of read-only data for faster field parsing without increasing per-connection state.
- Incremental fallbacks preserve streaming operation across arbitrarily fragmented reads.
- HTTP/1 bodies and HTTP/2 frame payloads are streamed without whole-message buffering.
- Strict HTTP/1 framing checks reject ambiguous `Transfer-Encoding` / `Content-Length` input.
- HPACK is provided by the standalone `hpack` package, with explicit memory and decode limits.
- `std.Io.Writer` is used by serialization APIs from Zig 0.16.0.

## HTTP/1 fast paths

For a transport buffer that may already contain a complete request head:

```zig
if (try http.http1.parseRequest(input)) |parsed| {
    const head = parsed.head;
    const framing = parsed.framing;
    const body_bytes = input[parsed.consumed..];
    _ = head;
    _ = framing;
    _ = body_bytes;
}
```

`parseRequest` and `parseResponse` now scan a contiguous head only once: start-line parsing, field validation, and body framing advance together until the terminating empty line. Malformed complete lines can therefore fail early before the final delimiter arrives. When the head spans reads, use `HeadParser.feedRequest` or `HeadParser.feedResponse`; only head bytes are copied to caller-owned scratch storage.

## HTTP/2 fast path

When a complete frame is already available:

```zig
if (try http.http2.parseCompleteFrame(input, http.http2.frame.default_max_frame_size)) |parsed| {
    const header = parsed.frame.header;
    const payload = parsed.frame.payload;
    _ = header;
    _ = payload;
}
```

The payload slice aliases caller input. Use `FrameDecoder` for fragmented frame headers or payloads.

When a TLS/TCP read contains several complete frames, use the batch iterator to avoid rebuilding a remainder slice and parse-result wrapper for every frame:

```zig
var frames = http.http2.CompleteFrameIterator.init(
    input,
    http.http2.frame.default_max_frame_size,
);
while (try frames.next()) |frame| {
    _ = frame.header;
    _ = frame.payload;
}
const consumed = frames.consumed();
_ = consumed; // retain input[consumed..] if it contains an incomplete frame
```

The iterator itself is 32 bytes on x86_64 and does not become part of persistent connection state unless the application chooses to store it.

## Modules

- `http1/head.zig` — contiguous and incremental request/response head parsing with body framing.
- `http1/body.zig` — fixed-length and streaming chunked-body decoding.
- `http1/write.zig` — request/response and chunk serialization.
- `http2/frame.zig` — contiguous, batched, and incremental zero-copy frame parsing plus frame serialization.
- `http2/settings.zig`, `flow.zig`, `stream.zig` — protocol state primitives.
- `http2/payload.zig` — typed DATA/HEADERS/PUSH_PROMISE/etc. payload helpers.
- `http2/continuation.zig`, `header_block.zig` — bounded field-block assembly rules.
- `hpack` 0.3.0 dependency — standalone RFC 7541 codec with compact connection state, combined encoder lookup, staged Huffman decoding, and bounded decoding.

## Dependency

HPACK is fetched from `https://github.com/rm-netsu/zig-hpack` and pinned by both Git commit and Zig package hash in `build.zig.zon`.

## Build

```sh
zig build test
zig build test -Doptimize=ReleaseFast
zig build bench -Doptimize=ReleaseFast
zig build bench-real -Doptimize=ReleaseFast
```

The package exports module `http`. Benchmark methodology and current results are documented in `BENCHMARKS.md`.

## Scope

This package is the protocol engine rather than a batteries-included HTTP client/server. It intentionally does not own TCP/TLS connections, DNS, thread pools, an event loop, or application routing. Those layers can be built on top without forcing an I/O architecture on users of the parsers.
