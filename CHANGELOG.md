# Changelog

## 0.3.0

- Add zero-copy contiguous HTTP/1 request and response head parsing.
- Add single-pass request/response framing APIs that avoid a second field traversal.
- Add incremental single-pass framing methods to `HeadParser`.
- Parse complete chunk-size and trailer lines directly from transport input, buffering only fragmented lines.
- Add checked chunk-size and content-length arithmetic and stricter control-byte validation.
- Add a stateless zero-copy HTTP/2 complete-frame parser for contiguous transport buffers.
- Compact HTTP/1 and HTTP/2 parser state, including 32-bit flow-control windows and sentinel-based continuation state.
- Avoid copying HPACK field blocks completed in a single HEADERS or PUSH_PROMISE frame.
- Tighten flag-dependent HTTP/2 frame length validation.
- Ensure the root test target executes all nested protocol tests under Zig 0.16.0 lazy analysis.
- Add reproducible ReleaseFast parser microbenchmarks with `zig build bench`.

## 0.2.2

- Update the standalone `hpack` dependency to 0.3.0.

## 0.2.1

- Update the standalone `hpack` dependency to 0.2.0.

## 0.2.0

- Extract HPACK into the standalone `hpack` package.

## 0.1.0

- Initial HTTP/1.1 and HTTP/2 protocol core with streaming parsers, framing, flow control, and HPACK support.
