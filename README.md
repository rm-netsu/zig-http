# http

High-performance, allocation-conscious HTTP/1.1 and HTTP/2 protocol primitives for Zig 0.16.0.

## Design

- Protocol-core boundary: anything whose state and decisions are purely HTTP remains under `http1` / `http2`, including optional HTTP flow-control and scheduling helpers. Sockets, TLS, DNS, timers, event loops, thread pools, and cross-subsystem queues stay outside the core.
- A future `high_level` layer is reserved for concrete integration wrappers that cross that boundary; the core APIs remain usable independently and never require those wrappers.
- Slice-oriented parsers with caller-owned bounded storage.
- Zero-copy fast paths when a complete HTTP/1 head or HTTP/2 frame is already contiguous in the transport buffer.
- Small process-wide byte-class tables and SIMD validation trade about 512 bytes of read-only data for faster field parsing without increasing per-connection state.
- Incremental fallbacks preserve streaming operation across arbitrarily fragmented reads.
- HTTP/2 connection state is split from caller-owned stream storage: connection-wide invariants stay allocation-free while applications choose their own stream slab/hash/sharded layout.
- Protocol objects contain no process-global mutable state. Independent connections are naturally shardable across threads; one HTTP/2 connection still has ordered connection/HPACK state and therefore has one logical mutator at a time unless the caller supplies equivalent synchronization.
- An optional 128-byte `Session` composes complete-frame parsing, HPACK decode, field semantics, stream transitions, peer SETTINGS/GOAWAY, flow accounting, and state-aware outbound control frames without owning either HPACK allocators or the stream table.
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
surfaced as ordered effects and take effect in wire order. Stream send windows
store only their signed adjustment relative to the peer's current
`SETTINGS_INITIAL_WINDOW_SIZE`, so normal initial-window changes do not mutate
every stream record. `settings.StreamDecoder` handles SETTINGS values that
themselves cross transport reads using only seven bytes of state.

`stream.Windows` is an 8-byte caller-owned pair of send/receive stream windows.
This keeps the library allocation-free at the connection layer: applications can
embed `stream.Tracked` records in a slab, hash table, intrusive map, sharded
store, or another layout appropriate for their runtime.

Before writing an outbound frame, `PeerState.sendHeader` can enforce the peer's
`SETTINGS_MAX_FRAME_SIZE`, server-push permission, and connection DATA send
credit. Stream-level state and flow checks remain explicit and caller-owned.

### Concurrency model

The core deliberately defines protocol ownership rather than a locking model.
Parsers, validators, frame writers, flow windows, stream records, and independent
connection/session objects do not share mutable global state, so callers can run
unrelated connections concurrently without library-side serialization. A single
HTTP/2 connection has ordered SETTINGS, HPACK, connection flow-control, stream-ID,
and GOAWAY state; mutate that ordered context from one logical owner at a time, or
provide equivalent external synchronization when handing it between workers.

The stream table remains caller-owned and may be partitioned or sharded. In
particular, `SETTINGS_INITIAL_WINDOW_SIZE` no longer forces Session to mutate every
live stream. Normal SETTINGS changes are O(1) in connection state. On an increase
that could overflow an active stream, Session asks the store for
`maxActiveSendAdjustment()`. The store may answer by scanning, using a maintained
aggregate, or coordinating shards; core does not prescribe atomics, mutexes, or a
storage topology.

The relative-window representation is a choice made by the composed Session, not a
restriction on lower-level composition. Consumers that know an eager per-stream
SETTINGS update is preferable for their own storage topology can use the standalone
`FlowWindow`, `StreamSendWindow`, `stream.Stream`, and frame/state primitives directly
and own that policy themselves.

## HTTP/2 caller-owned stream manager

`StreamManager` adds stream-ID ordering, initiator parity, concurrent-stream
limits, per-stream state transitions, stream flow control, PUSH_PROMISE
reservation, and GOAWAY cutoffs without owning the surrounding stream table. Its
low-level lookup API needs only `get(id)` and `insert(id, Tracked)`; slab,
fixed-array, hash-table, intrusive, or sharded storage remains an application
choice. The composed `Session` additionally asks for
`maxActiveSendAdjustment()` only on the rare SETTINGS initial-window
overflow-validation path.

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

`Session` is the optional composed receive path for applications that want the
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

The same 128-byte `Session` also provides streaming outbound HEADERS, DATA,
PUSH_PROMISE, and the HTTP/2 control plane without owning an output queue or
complete HPACK-block buffer. Fields are validated before HPACK encoding starts,
then encoded directly into a caller-owned staging buffer that is flushed as
HEADERS/PUSH_PROMISE plus CONTINUATION frames:

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

Server push uses the same bounded field-block framer. The four-byte promised
stream identifier consumes payload space only in the initial PUSH_PROMISE frame;
CONTINUATION frames use the full staging/frame limit. The promised stream is
reserved in caller storage before encoding and becomes active only when its
response HEADERS are sent:

```zig
_ = try session.sendPushPromise(
    &store,
    transport_writer,
    request_stream_id,
    promised_stream_id,
    &frame_staging,
    &promised_request_fields,
);
```

For an event loop that already owns a stable `StreamCursor`,
`sendHeadersExisting()` and `sendDataExisting()` avoid another caller-store
lookup. The fixed-array benchmark does not universally favor this cursor, so it
is intended for stores where retaining a stable pointer is already natural.

Control frames use the same send-poison rule while keeping state changes
transactional with respect to the writer. `sendSettingsAck()` and
`sendPingAck()` cover response paths. `sendWindowUpdate()` credits the local
connection or retained stream receive window only after the frame is
successfully written; `sendReset()` closes stream state after the RST_STREAM
commit; and `sendGoAway()` enforces a non-increasing local last-stream-id before
recording graceful shutdown state. Stable-cursor variants are available for
stream WINDOW_UPDATE and RST_STREAM as well.

New SETTINGS frames can now be sent through Session while synchronization stays
caller-owned. `SettingsSync` is only eight bytes and records wire order; the
application can attach any policy snapshot to the returned ticket and commit it
when the corresponding ACK event arrives:

```zig
var settings_sync: http.http2.SessionSettingsSync = .{};
const ticket = try session.sendSettings(
    &settings_sync,
    transport_writer,
    &.{.{ .id = .enable_push, .value = 0 }},
);
_ = ticket; // associate with caller-owned local policy if needed

// In the receive loop:
switch (event) {
    .settings => |applied| if (applied.acknowledge(&settings_sync)) |acked_ticket| {
        _ = acked_ticket; // commit the matching caller-owned policy snapshot
    },
    else => {},
}
```

This keeps transport receive limits, stream-store policy, and SETTINGS snapshot
storage outside Session while still giving ACKs an unambiguous FIFO ticket. A
failed preflight or writer call does not register a ticket.

### Caller-driven receive credit

HTTP/2 receive-window replenishment is also available as a protocol-only helper.
`ReceiveCredit` owns only a target window, a low watermark, and the number of
flow-controlled bytes whose receive capacity the caller has released. It never
assumes when application buffers are reusable. `proposal()` is non-mutating and
Session commits both the WINDOW_UPDATE and the accumulator only after a
successful writer call:

```zig
var connection_credit = try http.http2.ReceiveCredit.init(65_535, 32_767);
var stream_credit = try http.http2.ReceiveCredit.init(65_535, 32_767);

// After the application has consumed/copied/discarded this DATA event:
connection_credit.release(data.flowControlledBytes());
stream_credit.release(data.flowControlledBytes());

_ = try session.replenishConnectionReceive(transport_writer, &connection_credit);
_ = try session.replenishStreamReceive(
    &store,
    transport_writer,
    data.stream_id,
    &stream_credit,
);
```

For padded DATA, `flowControlledBytes()` intentionally returns the complete DATA
payload length rather than `data.bytes.len`, because HTTP/2 flow control charges
pad length and padding as well. Separate caller-owned connection and stream
accumulators allow different memory/capacity policies without growing `Session`
or `stream.Tracked`. `ReceiveCredit` is 12 bytes on x86_64.

### Graceful GOAWAY without timer ownership

`GracefulGoAway` implements only the HTTP/2 two-phase server drain. The first
call sends `GOAWAY(2^31-1, NO_ERROR)`; after a grace interval chosen by the
caller, `finish()` sends the final non-increasing last-stream-id. The helper does
not start a timer and deliberately does not infer "processed" from frame receipt,
because that depends on whether data reached a higher application layer:

```zig
var drain: http.http2.GracefulGoAway = .{};
try drain.announce(&session, transport_writer, "maintenance");

// Caller waits according to its own runtime/RTT policy, then supplies the
// highest peer-initiated stream that might actually have been processed.
try drain.finish(&session, transport_writer, last_processed_stream_id, "");
```

If an implementation needs socket shutdown, timer registration, event-loop
wakeups, or task-queue coordination around these calls, that integration belongs
above the protocol core rather than in `http2`.

### Caller-driven DATA scheduler

`DataScheduler` is an optional one-word round-robin selector over a caller-owned
list of DATA candidates. It combines connection credit, per-stream credit, and
peer MAX_FRAME_SIZE without owning buffers, priorities, wakeups, or queues:

```zig
var scheduler: http.http2.DataScheduler = .{};
const candidates = [_]http.http2.DataSchedulerCandidate{
    .{ .stream_id = 1, .remaining = body1.len, .end_stream = true },
    .{ .stream_id = 3, .remaining = body2.len, .end_stream = true },
};

switch (try scheduler.next(&session, &store, &candidates)) {
    .ready => |ready| {
        // ready.index maps back to caller-owned queue/buffer state.
        // ready.amount is already bounded by current HTTP/2 send credit.
        _ = ready;
    },
    .blocked => {}, // wait for WINDOW_UPDATE / policy wakeup
    .idle => {},
}
```

`nextAssumeValid()` is the lower-overhead path for event loops whose runnable set
already contains only live sendable streams; it returns `null` when nothing can
currently make progress. Scheduling policy remains application-controlled: the
caller can rebuild or reorder the candidate slice before each round, while the
helper retains only the next scan index.

HTTP/2 local field-section phase is tracked in existing `Tracked` padding, so
`Tracked` remains 12 bytes. `Session` remains 128 bytes, `SettingsSync` is 8
bytes, and `DataScheduler` is one native `usize` (8 bytes on x86_64). Field
syntax/semantics and store preconditions fail before HPACK/wire mutation; a later
HPACK allocation/codec or writer failure marks only the send side poisoned
because the connection compression or wire state may already be partially
advanced.

## Modules

- `http1/head.zig` — contiguous and incremental request/response head parsing with body framing.
- `http1/body.zig` — fixed-length and streaming chunked-body decoding.
- `http1/write.zig` — request/response and chunk serialization.
- `http2/frame.zig` — contiguous, batched, and incremental zero-copy frame parsing plus frame serialization.
- `http2/connection.zig` — allocation-free connection receive state and complete/fragmented frame integration.
- `http2/peer.zig` — peer SETTINGS, send-window, outbound constraints, and GOAWAY state.
- `http2/settings.zig`, `flow.zig`, `stream.zig` — streaming SETTINGS, caller-owned flow/stream state, and optional receive-credit policy primitives.
- `http2/streams.zig` — allocation-free stream-ID/concurrency/lifecycle manager over caller-owned storage.
- `http2/session.zig` — optional 128-byte receive/send session composition with HPACK/field/stream/control dispatch over caller-owned storage.
- `http2/scheduler.zig` — one-word caller-driven round-robin DATA selector over Session flow credit.
- `http2/send.zig` — bounded streaming HPACK field-block framing plus allocation-free SETTINGS/PING/RST_STREAM/WINDOW_UPDATE/GOAWAY serialization.
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
zig build bench-real-scheduler -Doptimize=ReleaseFast
zig build bench-real-settings -Doptimize=ReleaseFast
```

The package exports module `http`. Benchmark methodology and current results are documented in `BENCHMARKS.md`.

## Scope

This package is the protocol engine rather than a batteries-included HTTP client/server. HTTP-only composition remains part of the core even when it is more convenient than raw wire primitives. The core intentionally does not own TCP/TLS connections, DNS, timers, thread pools, event loops, socket lifetimes, or application routing/work queues. Concrete adapters that coordinate those external layers belong in an optional `high_level` namespace/package and must remain wrappers over independently usable core APIs.
