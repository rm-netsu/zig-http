# http

High-performance, allocation-conscious HTTP/1.1 and HTTP/2 protocol primitives for Zig 0.16.0.

## Design

- Transport-agnostic: sockets, TLS and event loops stay outside the protocol core.
- Slice-oriented parsers with caller-owned bounded storage.
- Zero-copy fast paths when a complete HTTP/1 head or HTTP/2 frame is already contiguous in the transport buffer.
- Small process-wide byte-class tables and SIMD validation trade about 512 bytes of read-only data for faster field parsing without increasing per-connection state.
- Incremental fallbacks preserve streaming operation across arbitrarily fragmented reads.
- HTTP/2 connection state is split from caller-owned stream storage: connection-wide invariants stay allocation-free while applications choose their own stream slab/hash layout.
- An optional 128-byte `Session` composes complete-frame parsing, HPACK decode, field semantics, stream transitions, peer SETTINGS/GOAWAY, and flow accounting without owning either HPACK allocators or the stream table.
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

## HTTP/2 composable session layer

`Session` is the optional high-level receive path for applications that want the
existing connection, stream, peer, HPACK, and field-validation primitives wired
together without adopting a networking or allocation model. The session itself
is 128 bytes on x86_64. It owns no heap memory: HPACK encoder/decoder dynamic
tables and the continuation buffer remain caller-owned.

```zig
var decoder = http.http2.hpack.Decoder.init(allocator, 4096);
defer decoder.deinit();
var encoder = http.http2.hpack.Encoder.init(allocator, 4096);
defer encoder.deinit();
var continuation_storage: [16 * 1024]u8 = undefined;

var session = http.http2.Session.init(
    .client,
    .{},
    &decoder,
    &encoder,
    &continuation_storage,
);

if (try session.receiveBytes(
    &store,
    input,
    http.http2.frame.default_max_frame_size,
    scratch,
    &field_sink,
)) |received| {
    input = input[received.consumed..];
    switch (received.event) {
        .headers => |section| _ = section,
        .data => |data| _ = data.bytes, // aliases input
        .fault => |fault| _ = fault,
        else => {},
    }
}
```

For callers that already parsed a frame, `receiveComplete()` skips the frame
parser and accepts an already validated `CompleteFrame` directly. Single-frame
HEADERS/PUSH_PROMISE blocks are decoded zero-copy and no longer need to fit the
continuation scratch; the scratch storage is touched only when CONTINUATION
assembly is actually required. Configure `Decoder.max_encoded_block_size` when
a hard compressed-field-section limit is required; continuation storage is no
longer that limit for contiguous blocks.

The session tracks request/response/trailer phase inside existing padding in
`stream.Tracked`, so the record stays 12 bytes. It supports repeated 1xx response
sections, rejects HTTP/2 status 101, requires `END_STREAM` on trailers, and drains
a malformed field section through the HPACK decoder before returning a stream
protocol fault so the connection compression context remains synchronized.
Once Session is used for a stream, keep inbound field-section transitions on
that path rather than mixing manual `StreamManager` HEADERS transitions with
Session on the same stream.

The field sink is synchronous because HPACK field slices may be invalidated by
the next decoder step. Treat sink callbacks as provisional and commit application
side effects only after `receiveComplete()` / `receiveBytes()` returns a successful
`.headers` or `.push_promise` event. HPACK codec failures are returned directly.
Except for header-list overflow, which Session drains through `Iterator.finish()`,
callers should treat an undecodable HPACK block as connection-fatal because the
compression context cannot in general be resumed safely.

A Session store uses the same caller-owned `get`/`insert` contract as
`StreamManager` and additionally provides
`applyPeerInitialWindow(change) bool`. That operation applies ordered peer
`SETTINGS_INITIAL_WINDOW_SIZE` changes to live stream send windows; returning
false is surfaced as a connection flow-control fault. Received
`SETTINGS_HEADER_TABLE_SIZE` updates the caller-owned outbound HPACK encoder's
allowed table size automatically.

## HTTP/2 send-side Session

The same 128-byte `Session` also provides streaming outbound HEADERS and DATA
without owning an output queue or complete HPACK-block buffer. Fields are
validated before HPACK encoding starts, then encoded directly into a caller-owned
staging buffer that is flushed as HEADERS/CONTINUATION frames:

```zig
const fields = [_]http.http2.hpack.EncodedField{
    .{ .field = .{ .name = ":status", .value = "200" } },
    .{ .field = .{ .name = "content-type", .value = "application/json" }, .indexing = .incremental },
};

var frame_staging: [4097]u8 = undefined; // <= 4096 bytes per field-block frame
_ = try session.sendHeaders(
    &store,
    transport_writer,
    stream_id,
    false,
    &frame_staging,
    &fields,
);
```

The staging buffer needs one lookahead byte, so `4097` bytes caps generated
HEADERS/CONTINUATION payloads at 4096 bytes even when the peer advertises a much
larger `SETTINGS_MAX_FRAME_SIZE`. Memory therefore stays bounded independently
of field-block size. `END_STREAM` is carried only on the initial HEADERS frame;
`END_HEADERS` is placed on the final HEADERS or CONTINUATION frame, including
the exact-frame-size boundary case.

DATA is intentionally one frame per call so backpressure stays caller-driven:

```zig
const sent = try session.sendData(
    &store,
    transport_writer,
    stream_id,
    body,
    true,
);
body = body[sent.consumed..];
if (sent.blocked) {
    // Wait for connection/stream WINDOW_UPDATE before trying again.
}
```

The amount sent is the minimum of available input, peer
`SETTINGS_MAX_FRAME_SIZE`, the peer-advertised connection send window, and the
stream send window. A zero-length DATA frame can still carry END_STREAM when
both flow-control windows are exhausted because it consumes no credit.

For an event loop that already owns a stable `StreamCursor`,
`sendHeadersExisting()` and `sendDataExisting()` avoid another caller-store
lookup. The fixed-array benchmark does not show a speedup from this cursor, so it
is an API for expensive real stores rather than a claimed universal fast path.

HTTP/2 local field-section phase is tracked in existing `Tracked` padding, so
`Tracked` remains 12 bytes. `Session` also remains 128 bytes: a send-side poison
flag uses the otherwise impossible high bit of its pending stream identifier.
Field syntax/semantics and store preconditions fail before HPACK/wire mutation;
a later HPACK allocation/codec or writer failure marks only the send side
poisoned because the connection compression or wire state may already be
partially advanced.

## Modules

- `http1/head.zig` — contiguous and incremental request/response head parsing with body framing.
- `http1/body.zig` — fixed-length and streaming chunked-body decoding.
- `http1/write.zig` — request/response and chunk serialization.
- `http2/frame.zig` — contiguous, batched, and incremental zero-copy frame parsing plus frame serialization.
- `http2/connection.zig` — allocation-free connection receive state and complete/fragmented frame integration.
- `http2/peer.zig` — peer SETTINGS, send-window, outbound constraints, and GOAWAY state.
- `http2/settings.zig`, `flow.zig`, `stream.zig` — streaming SETTINGS and caller-owned flow/stream state primitives.
- `http2/streams.zig` — allocation-free stream-ID/concurrency/lifecycle manager over caller-owned storage.
- `http2/session.zig` — optional 128-byte receive/send session composition with HPACK/field/stream/control dispatch over caller-owned storage.
- `http2/send.zig` — bounded streaming HPACK field-block framing into HEADERS/CONTINUATION frames.
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
zig build bench-real-session -Doptimize=ReleaseFast
zig build bench-real-send-session -Doptimize=ReleaseFast
```

The package exports module `http`. Benchmark methodology and current results are documented in `BENCHMARKS.md`.

## Scope

This package is the protocol engine rather than a batteries-included HTTP client/server. It intentionally does not own TCP/TLS connections, DNS, thread pools, an event loop, or application routing. Those layers can be built on top without forcing an I/O architecture on users of the parsers.
