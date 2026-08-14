# http

High-performance, allocation-conscious HTTP/1.1 and HTTP/2 protocol primitives for Zig 0.16.0.

## Design

- Transport-agnostic: sockets, TLS and event loops stay outside the protocol core.
- Slice-oriented parsers with caller-owned bounded storage.
- HTTP/1 bodies and HTTP/2 frame payloads are streamed without whole-message buffering.
- Strict HTTP/1 framing checks reject ambiguous `Transfer-Encoding` / `Content-Length` input.
- HPACK is provided by the standalone `hpack` package, with explicit memory and decode limits.
- `std.Io.Writer` is used by serialization APIs from Zig 0.16.0.

## Modules

- `http1/head.zig` — incremental request/response head parsing and body framing.
- `http1/body.zig` — fixed-length and streaming chunked-body decoding.
- `http1/write.zig` — request/response and chunk serialization.
- `http2/frame.zig` — zero-copy frame payload decoder and frame writer.
- `http2/settings.zig`, `flow.zig`, `stream.zig` — protocol state primitives.
- `http2/payload.zig` — typed DATA/HEADERS/PUSH_PROMISE/etc. payload helpers.
- `http2/continuation.zig`, `header_block.zig` — bounded field-block assembly rules.
- `hpack` dependency — standalone RFC 7541 codec with Huffman and dynamic-table support.

## Dependency

HPACK is fetched from `https://github.com/rm-netsu/zig-hpack` and pinned by both Git commit and Zig package hash in `build.zig.zon`.

## Build

```sh
zig build test
zig build test -Doptimize=ReleaseFast
```

The package exports module `http`.

## Scope

This package is the protocol engine rather than a batteries-included HTTP client/server. It intentionally does not own TCP/TLS connections, DNS, thread pools, an event loop, or application routing. Those layers can be built on top without forcing an I/O architecture on users of the parsers.
