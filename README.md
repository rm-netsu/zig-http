# http

High-performance, allocation-conscious HTTP/1.1 and HTTP/2 protocol primitives for Zig 0.16.0.

## Design

- Transport-agnostic: sockets, TLS and event loops stay outside the protocol core.
- Slice-oriented parsers with caller-owned bounded storage.
- Zero-copy fast paths when a complete HTTP/1 head or HTTP/2 frame is already contiguous in the transport buffer.
- Small process-wide byte-class tables and SIMD validation trade about 512 bytes of read-only data for faster field parsing without increasing per-connection state.
- Incremental fallbacks preserve streaming operation across arbitrarily fragmented reads.
- HTTP/2 connection state is split from caller-owned stream storage: connection-wide invariants stay allocation-free while applications choose their own stream slab/hash layout.
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

`parseRequest` and `parseResponse` now scan a contiguous head only once: start-line parsing, field validation, and body framing advance together until the terminating empty line. Malformed complete lines can therefore fail early before the final delimiter arrives. When the head spans reads, `HeadParser.feedRequest` / `feedResponse` keep the smallest persistent parser state. For transports that fragment heads frequently, `FramedHeadParser` spends 48 bytes instead of 24 bytes on x86_64 to validate complete lines and accumulate body-framing state as they arrive, avoiding the final field traversal. Both parsers copy only head bytes into caller-owned scratch storage.

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

When a TLS/TCP read contains several complete frames, `CompleteFrameIterator` repeatedly applies the same validated zero-copy complete-frame path while retaining the unconsumed remainder:

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

## HTTP/2 connection state

`ConnectionDecoder` layers connection-wide receive rules over the existing frame
parsers without owning a stream table. Its persistent state is 28 bytes on
x86_64: a 20-byte `FrameDecoder` plus 8 bytes for CONTINUATION sequencing and the
connection receive flow-control window. These mutable connection contexts are
intended for one ordered owner at a time; applications that move a connection
between worker threads should transfer ownership rather than process its frames
concurrently.

Drain complete frames first:

```zig
var connection = http.http2.ConnectionDecoder.init(
    http.http2.frame.default_max_frame_size,
);

var frames = try connection.complete(input);
while (try frames.next()) |complete| {
    // complete.payload aliases input
    _ = complete;
}
const consumed = frames.consumed();
```

If the remaining tail crosses a transport-read boundary, use the embedded frame
decoder. Header events are already frame-validated; `checkHeader` adds the
connection-wide rules and returns a compact violation enum that maps naturally
to HTTP/2 connection error handling:

```zig
const result = try connection.frames.next(fragment);
if (result.event) |event| switch (event) {
    .header => |header| switch (connection.checkHeader(header)) {
        .none => {},
        .protocol => return error.Protocol,
        .flow_control => return error.FlowControl,
    },
    .payload => |chunk| {
        // chunk.bytes aliases fragment
        _ = chunk;
    },
};
```

`PeerState` tracks the constraints advertised by the remote endpoint: SETTINGS,
connection send credit, and monotonic GOAWAY last-stream-id state. SETTINGS are
surfaced as ordered effects so a caller can apply every
`SETTINGS_INITIAL_WINDOW_SIZE` delta to its own active-stream table before
processing the next setting. Drain the returned SETTINGS effects before
processing any subsequent frame; SETTINGS values take effect in wire order.
`settings.StreamDecoder` handles SETTINGS values
that themselves cross transport reads using only seven bytes of state.

`stream.Windows` is an 8-byte caller-owned pair of send/receive stream windows.
This keeps the library allocation-free at the connection layer: applications can
embed `stream.Tracked` records in a slab, hash table, intrusive map, or another
layout appropriate for their event loop.

Before writing an outbound frame, `PeerState.sendHeader` can enforce the peer's
`SETTINGS_MAX_FRAME_SIZE`, server-push permission, and connection DATA send
credit. Stream-level state and flow checks remain explicit and caller-owned.

## HTTP/2 caller-owned stream manager

`StreamManager` adds stream-ID ordering, initiator parity, concurrent-stream
limits, per-stream state transitions, stream flow control, PUSH_PROMISE
reservation, and GOAWAY cutoffs without owning the surrounding stream table. A
store only needs `get(id)` and `insert(id, Tracked)` methods; slab, fixed-array,
hash-table, or intrusive storage remains an application choice.

```zig
var manager = http.http2.StreamManager.init(.client, .{});
var peer = http.http2.PeerState.init(.client);

try manager.openLocal(&store, &peer, 1, true);
const stream = manager.existing(&store, 1).?;
if (stream.receiveHeaders(false) != .accepted) return error.Protocol;
if (stream.receiveData(data_frame_length, true) != .accepted) return error.Protocol;
try stream.creditReceive(data_frame_length);
```

`Tracked` remains 12 bytes. `StreamManager` is 36 bytes on x86_64 and does not
allocate. `StreamCursor` (`streams.Existing`) is a temporary 24-byte cursor for
callers that already hold a stable stream record. Use it only while both the
manager and caller-owned record remain stable; the lookup API remains available
for containers that can move records.

After a locally sent GOAWAY, peer-initiated stream IDs above its last-stream-id
return `.ignored_after_goaway`. HPACK and connection-level flow-control minimal
processing still belong to the connection layer and must happen before the
stream result is discarded. Conversely, `unprocessedByPeer()` identifies local
streams above a received GOAWAY last-stream-id so application code can decide
whether its request semantics permit retry.

`LocalLimits.enable_push` is the effective inbound push policy. A client that
sends `SETTINGS_ENABLE_PUSH=0` should switch this flag only after that SETTINGS
value has been acknowledged.

## Modules

- `http1/head.zig` — contiguous and incremental request/response head parsing with body framing.
- `http1/body.zig` — fixed-length and streaming chunked-body decoding.
- `http1/write.zig` — request/response and chunk serialization.
- `http2/frame.zig` — contiguous, batched, and incremental zero-copy frame parsing plus frame serialization.
- `http2/connection.zig` — allocation-free connection receive state and complete/fragmented frame integration.
- `http2/peer.zig` — peer SETTINGS, send-window, outbound constraints, and GOAWAY state.
- `http2/settings.zig`, `flow.zig`, `stream.zig` — streaming SETTINGS and caller-owned flow/stream state primitives.
- `http2/streams.zig` — allocation-free stream-ID/concurrency/lifecycle manager over caller-owned storage.
- `http2/payload.zig` — typed DATA/HEADERS/PUSH_PROMISE/etc. payload helpers.
- `http2/continuation.zig`, `header_block.zig` — bounded field-block assembly rules.
- `hpack` 0.4.1 dependency — standalone RFC 7541 codec with real-world-benchmarked encoder lookup and short-literal Huffman fast paths plus bounded decoding.

## Dependency

HPACK is fetched from `https://github.com/rm-netsu/zig-hpack` and pinned by both Git commit and Zig package hash in `build.zig.zon`.

## Build

```sh
zig build test
zig build test -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSafe -Dsanitize-thread=true
zig build bench -Doptimize=ReleaseFast
zig build bench-real -Doptimize=ReleaseFast
zig build bench-real-frames -Doptimize=ReleaseFast
zig build bench-real-streams -Doptimize=ReleaseFast
```

The package exports module `http`. Benchmark methodology and current results are documented in `BENCHMARKS.md`.

## Scope

This package is the protocol engine rather than a batteries-included HTTP client/server. It intentionally does not own TCP/TLS connections, DNS, thread pools, an event loop, or application routing. Those layers can be built on top without forcing an I/O architecture on users of the parsers.
