# Changelog

## 0.6.0

- Add allocation-free HTTP/2 `ConnectionState` / `ConnectionDecoder` primitives that enforce CONTINUATION adjacency and connection receive flow control across complete and fragmented transport reads.
- Add a compact `ConnectionViolation` fast path so event loops can map protocol and flow-control failures directly to HTTP/2 connection errors without forcing an error-union wrapper into the fragmented hot path.
- Add `PeerState` for ordered peer SETTINGS application, connection send credit, outbound maximum-frame/push checks, stream WINDOW_UPDATE routing, and monotonic GOAWAY tracking.
- Add a seven-byte streaming SETTINGS decoder for setting values split across transport boundaries.
- Add 8-byte caller-owned per-stream flow windows and a 12-byte `Tracked` stream record, leaving stream-table allocation/layout entirely to the application.
- Correct zero WINDOW_UPDATE increments to surface a protocol violation; flow-window overflow remains a flow-control violation.
- Add `bench-real-frames`, which compiles raw/connection and complete/fragmented HTTP/2 cases as separate executables to avoid Zig 0.16 code-layout/inlining cross-contamination between benchmark cases.
- Keep the broad `bench-real` corpus unchanged from 0.5.0 so historical HTTP/1, field-validation, and raw frame baselines remain comparable.

## 0.5.0

- Add an offline real-world protocol benchmark covering diverse captured HTTP headers, fragmented reads, body framing, HTTP/2 field validation, and realistic HEADERS/DATA frame traces.
- Fix HTTP/2 frame serialization for payload lengths above 255 bytes by encoding all three 24-bit length octets correctly.
- Update the standalone `hpack` dependency to 0.4.1.
- Add `FramedHeadParser`, an opt-in incremental HTTP/1 parser that spends a small amount of extra state to accumulate framing while lines arrive and avoid the final header-field traversal.
- Split common HTTP/2 DATA/HEADERS validation from uncommon frame validation and inline the incremental decoder hot path without increasing its 20-byte state.
- Refine `CompleteFrameIterator` to retain a shrinking input remainder and reuse the validated complete-frame parser.
- Extend the real-world benchmark so HTTP/1 compact versus streaming framed parsing and HTTP/2 direct complete parsing versus iteration are measured on identical corpus data.

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
