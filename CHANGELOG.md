# Changelog

## 0.12.0

- Define the library boundary explicitly: HTTP-only state, scheduling, flow-control, and shutdown orchestration stay in the `http1`/`http2` core; sockets, TLS, timers, event loops, thread pools, and cross-subsystem queues belong only in optional higher-level wrappers.
- Add a 12-byte caller-owned `http2.ReceiveCredit` low-watermark policy with two-phase proposal/commit semantics so freed receive capacity is never lost when WINDOW_UPDATE serialization fails.
- Add `Session.replenishConnectionReceive()`, `replenishStreamReceive()`, and stable-cursor replenishment without growing the 128-byte Session or 12-byte `stream.Tracked`.
- Expose the complete 24-bit flow-controlled DATA payload charge through `Data.flowControlledBytes()`, including padding, while packing it into existing event padding so `Data` remains 24 bytes and `Event` remains 32 bytes.
- Add caller-owned `GracefulGoAway` for the RFC 9113 two-phase server shutdown sequence; timing and the final application-processed stream cutoff remain explicit caller decisions.
- Re-run isolated receive/send Session benchmarks against 0.11.0 after the layout-sensitive additions; compact DATA accounting avoids the regression seen with an initially tested 32-byte Data event and keeps both hot paths in their established range.

## 0.11.0

- Add streaming outbound HTTP/2 `PUSH_PROMISE` support to Session, including bounded first-frame prefix handling, CONTINUATION framing, server/push-policy preflight, and reserved(local) promised-stream state.
- Add `Session.sendSettings()` plus an 8-byte caller-owned `SettingsSync` ticket tracker so received ACKs can be matched to sent SETTINGS in wire order without Session owning a policy queue.
- Validate locally generated SETTINGS before wire mutation, including ENABLE_PUSH role/value rules, INITIAL_WINDOW_SIZE bounds, and MAX_FRAME_SIZE bounds; failed writes do not create synchronization tickets.
- Add non-mutating Session DATA credit probes and a one-word caller-driven round-robin DATA scheduler that combines connection, stream, and peer frame-size credit while leaving buffers, priorities, wakeups, and queues to the application.
- Add a lower-overhead `nextAssumeValid()` scheduler path for event loops that already maintain a valid active-stream set, while retaining a checked `idle` / `blocked` / `ready` API.
- Add an isolated 64-stream scheduler benchmark using captured response body sizes and mixed stream/connection blocking; document its convenience overhead instead of presenting the helper as a scan-speed optimization.
- Keep `Session` at 128 bytes and `stream.Tracked` at 12 bytes; the new synchronization and scheduling state is caller-owned (8 bytes each on x86_64).
- Re-run the real send-session benchmark after the additions; HEADERS/DATA throughput remains in the established range with identical wire bytes per transaction.

## 0.10.0

- Add allocation-free HTTP/2 control-frame writers for SETTINGS, SETTINGS ACK, PING, RST_STREAM, WINDOW_UPDATE, and GOAWAY.
- Add state-aware `Session.sendSettingsAck()`, `sendPing()` / `sendPingAck()`, `sendWindowUpdate()`, `sendReset()`, and `sendGoAway()` paths while keeping Session at 128 bytes and `stream.Tracked` at 12 bytes.
- Commit local receive-window credit, stream reset state, and GOAWAY cutoffs only after the corresponding frame is successfully written; protocol/size preflight failures remain retry-safe while partial writer failures poison only the send side.
- Add stable-cursor WINDOW_UPDATE and RST_STREAM send variants for applications with expensive caller-owned stream lookup.
- Keep outbound SETTINGS value application caller-owned: `http2.send.writeSettings()` serializes ordered values without a whole-frame buffer while the application controls ACK-synchronized local policy changes.
- Re-run the isolated real send-session benchmark after the control-send additions; existing HEADERS/DATA throughput remains within run-to-run noise with identical wire bytes per transaction.

## 0.9.0

- Add streaming send-side HTTP/2 Session support for HPACK field blocks, emitting HEADERS plus CONTINUATION frames without buffering the complete encoded block.
- Bound outbound field-block memory by caller-owned staging storage; one lookahead byte preserves correct END_HEADERS placement when an encoded block exactly fills a frame payload.
- Add `Session.sendHeaders()` and `sendHeadersExisting()` with HTTP/2 field validation, request/response/informational/trailer phase tracking, stream lifecycle integration, and peer GOAWAY checks.
- Add `Session.sendData()` and `sendDataExisting()` with one-frame caller-driven backpressure constrained by peer MAX_FRAME_SIZE plus connection and stream send windows.
- Keep `Session` at 128 bytes and `stream.Tracked` at 12 bytes by storing the local field-section phase in existing per-stream padding and the send-poison bit in an impossible stream-id bit.
- Poison only the Session send side after HPACK/allocator or writer failures that may have partially advanced the connection compression/wire state; semantic and store preflight failures remain retry-safe.
- Add isolated `bench-real-send-session` cases over the real response corpus with production-like HPACK indexing and captured body sizes. Nine direct pinned runs measured the lookup Session about 1.7% below manual composition with identical wire bytes per transaction.

## 0.8.0

- Add a 128-byte allocation-free `Session` that composes complete-frame receive handling with connection rules, HPACK decoding, HTTP/2 field semantics, caller-owned stream transitions, peer SETTINGS/GOAWAY state, and DATA/window accounting.
- Add `Session.receiveBytes()` for validated zero-copy parse-and-dispatch from a contiguous transport buffer and `receiveComplete()` for callers that already parsed a complete frame.
- Track incoming request/response/trailer phase inside existing `stream.Tracked` padding, keeping the per-stream record at 12 bytes while supporting repeated informational responses, final responses, and trailers.
- Drain semantically malformed field sections through HPACK before returning a stream protocol fault, preserving connection compression state; drain HPACK header-list-limit failures through the supported iterator finish path as well.
- Apply peer SETTINGS in wire order through the session, including outbound HPACK table limits and caller-store `SETTINGS_INITIAL_WINDOW_SIZE` propagation.
- Remove the continuation-storage size requirement for single-frame HEADERS/PUSH_PROMISE blocks; caller storage is now required only when CONTINUATION assembly is actually needed.
- Add isolated `bench-real-session` manual-versus-managed composition cases over real response fields/body sizes; the 128-byte session is about 2.7% below equivalent manual composition in the pinned median.

## 0.7.0

- Add allocation-free `StreamManager` over caller-owned stream storage, enforcing stream initiator parity, monotonically increasing stream IDs, concurrent-stream limits, stream state transitions, and per-stream flow control.
- Add a short-lived `StreamCursor` / `streams.Existing` fast path for event loops that already hold a stable `Tracked` pointer, avoiding repeated slab/hash lookups across HEADERS, DATA, WINDOW_UPDATE, and local send handling.
- Add local GOAWAY tracking and `ignored_after_goaway` receive results while keeping HPACK and connection-flow minimal processing explicit at the connection layer.
- Add `unprocessedByPeer()` so callers can identify locally initiated streams that a received GOAWAY proves were not processed.
- Keep the stream table fully caller-owned: the required store contract is only `get` plus `insert`, with removal policy left to the application.
- Add isolated `bench-real-streams` cases for lookup-heavy, stable-pointer, and 64-stream multiplexed lifecycles using captured response body sizes.
- Add `-Dsanitize-thread=true` build support and propagate ThreadSanitizer instrumentation through both `http` and the pinned `hpack` dependency.
- Keep zero WINDOW_UPDATE increments as stream PROTOCOL_ERROR even on a closed stream, while valid late WINDOW_UPDATE remains accepted.

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
