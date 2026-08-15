# Changelog

## Unreleased

- Add an offline real-world protocol benchmark covering diverse captured HTTP headers, fragmented reads, body framing, HTTP/2 field validation, and realistic HEADERS/DATA frame traces.
- Fix HTTP/2 frame serialization for payload lengths above 255 bytes by encoding all three 24-bit length octets correctly.

## 0.4.0

- Parse contiguous HTTP/1 heads line-by-line without a preliminary CRLF-CRLF scan.
- Use process-wide byte-class tables, four-byte token validation, and short SIMD blocks for HTTP field validation.
- Keep the validation tables to 512 bytes of read-only process state; persistent per-connection parser sizes are unchanged.
- Collapse HTTP/2 frame stream/length validation into one frame-type dispatch.
- Add `CompleteFrameIterator` for zero-copy traversal of multiple complete frames in one transport buffer.
- Accelerate HTTP/2 field validation with direct pseudo-header classification, one-pass lowercase token checks, and SIMD value checks.
- Enforce the RFC 9113 prohibition on leading/trailing SP or HTAB in HTTP/2 field values.
- Extend the regression benchmark with batched HTTP/2 frame traversal and field validation.

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
