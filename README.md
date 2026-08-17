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
- HTTP/2 ordered dispatch can materialize DATA/RST_STREAM/stream WINDOW_UPDATE as temporary caller-routable work after connection-wide invariants are committed, so stream shards do not need the full connection/session object.
- Protocol objects contain no process-global mutable state. Independent connections are naturally shardable across threads; one HTTP/2 connection still has ordered connection/HPACK state and therefore has one logical mutator at a time unless the caller supplies equivalent synchronization.
- An optional 128-byte `Session` composes complete-frame parsing, HPACK decode, field semantics, stream transitions, peer SETTINGS/GOAWAY, flow accounting, and state-aware outbound control frames without owning either HPACK allocators or the stream table.
- HTTP/1 bodies and HTTP/2 frame payloads are streamed without whole-message buffering.
- An optional allocation-free HTTP/1 `ConnectionDecoder` composes head parsing, strict request semantics, message framing, informational/final response sequencing, HEAD/CONNECT handling, trailers, persistence, and close-delimited EOF without owning I/O or a client pipeline queue.
- Strict HTTP/1 framing checks reject ambiguous `Transfer-Encoding` / `Content-Length` input.
- HPACK is provided by the standalone `hpack` package, with explicit memory and decode limits.
- `std.Io.Writer` is used by serialization APIs from Zig 0.16.0.

## Choosing a composition level

The package does not require one architecture. Pick the highest level that owns
only state you actually want the HTTP engine to manage:

- HTTP/1 messages on an existing byte stream: `http1.ConnectionDecoder` is the
  recommended receive coordinator and `http1.MessageWriter` is the recommended
  send coordinator. Use `http1.head.parseRequest` / `parseResponse`,
  `http1.head.FramedHeadParser`, `http1.body.ChunkDecoder`, and `http1.write`
  directly when an existing runtime already owns more of the message state machine.
- HTTP/2 connection engine: `http2.Session` is the recommended composed path
  over caller-owned HPACK objects and stream storage.
  `Session.init(.{ ... })` uses named configuration and caller-owned state.
- HTTP/2 custom/sharded runtimes: compose `connection`, `peer`, `streams`,
  `dispatch`, `send`, frame, flow, and field primitives independently. No
  scheduler, storage layout, queue, or synchronization strategy is mandatory.

None of these levels opens sockets, performs TLS/DNS, registers timers, or owns
an event loop.

## Compile-tested examples

The `examples/` directory contains executable, transport-neutral reference
compositions. They are built and run by `zig build examples`, and the normal
`zig build check` merge gate depends on that step so examples cannot silently
fall behind the public API.

Start with:

- `examples/http1_client_core.zig` and `http1_server_core.zig` for the symmetric
  `ConnectionDecoder` / `MessageWriter` message lifecycle;
- `examples/http2_client_core.zig` for the minimum client `Session` setup;
- `examples/http2_server_core.zig` for an in-memory client/server Session
  round-trip including the caller-owned store and synchronous field sink;
- `examples/http2_priority.zig` for policy-free RFC 9218 parsing and
  PRIORITY_UPDATE serialization.

The support files are deliberately simple reference implementations rather than
core-owned storage policy. `support/fixed_stream_store.zig` shows the complete
Session store surface (`get`, `insert`, and `maxActiveSendAdjustment`) while
`support/counting_field_sink.zig` demonstrates the synchronous `field` callback
without retaining borrowed HPACK slices. Production applications can substitute
slabs, hash tables, shards, or direct projection into application state.

Public names intentionally follow one path per abstraction level. Composed entry
points are `http1.ConnectionDecoder`, `http1.MessageWriter`, and `http2.Session`; lower-level types live
under their owning namespaces (`http1.head`, `http1.body`, `http2.frame`,
`http2.connection`, `http2.streams`, and so on). Pre-1.0 flat aliases and
positional compatibility initializers are not retained, so API discovery mirrors
the protocol architecture instead of accumulating duplicate spellings.

## HTTP/1 connection/message coordination

`ConnectionDecoder` connects the HTTP/1 protocol pieces without becoming a
transport abstraction. Scratch storage is caller-owned and events borrow input
or scratch bytes:

```zig
var decoder = http.http1.ConnectionDecoder.initRequest(
    &head_storage,
    &chunk_line_storage,
    .{},
);

var remaining = input;
while (remaining.len != 0) {
    const result = try decoder.feed(remaining);
    remaining = remaining[result.consumed..];
    if (result.event) |event| {
        // HEAD, body DATA, trailers, or message completion.
        _ = event;
    }
    if (result.consumed == 0 and result.event == null) break;
}
```

Request mode applies RFC 9112 request-target and Host semantics by default.
Callers implementing diagnostics, proxies with specialized policy, or other
low-level tooling can use `.{ .validate_requests = false }` and apply their
own semantics; the syntax/framing parsers remain independently usable.

Response mode deliberately does not own a request queue. Bind the next response
to caller-owned request context with `beginResponse(method)`. Informational 1xx
responses retain that context, HEAD and successful CONNECT use the correct body
semantics, `101`/successful CONNECT expose the protocol-switch boundary without
consuming tunnel bytes, and close-delimited completion is reported by
`finish()` when the caller observes transport EOF.

### HTTP/1 send-side message coordination

`MessageWriter` provides the symmetric send-side state machine without owning a
transport. It validates the complete head, request semantics, framing, and
persistence before emitting the first byte; fixed-length overruns are rejected
before body output, chunk termination/trailers are serialized consistently, and
partial writer failures poison only this protocol coordinator. Close-delimited
messages and `Connection: close` transition to `mustClose()` so the same HTTP
connection cannot be reused accidentally.

```zig
var message = http.http1.MessageWriter.init();
const started = try message.beginResponse(
    out,
    .http_1_1,
    200,
    "OK",
    "GET", // request method supplies HEAD/CONNECT response context
    &.{.{ .name = "content-length", .value = "5" }},
);

if (!started.message_done) {
    const sent = try message.writeData(out, "hello");
    _ = sent.message_done; // true after exactly five bytes
}
```

For streaming output use `Transfer-Encoding: chunked`; each `writeData` call is
serialized as one chunk and `finish(out, trailers)` emits the terminal chunk.
Framing fields are rejected in trailers. Responses whose framing is close-delimited
require `finish(out, &.{})`, after which the caller must close the transport.
Successful CONNECT and `101` responses transition to `protocolSwitched()`; tunnel
bytes intentionally remain outside the HTTP writer.

## HTTP/1 fast paths

For a transport buffer that may already contain a complete request head:

```zig
if (try http.http1.head.parseRequest(input)) |parsed| {
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
if (try http.http2.frame.parseComplete(input, http.http2.frame.default_max_frame_size)) |parsed| {
    const header = parsed.frame.header;
    const payload = parsed.frame.payload;
    _ = header;
    _ = payload;
}
```

The payload slice aliases caller input. Use `http2.frame.FrameDecoder` for fragmented frame headers or payloads.

When a TLS/TCP read contains several complete frames, `http2.frame.CompleteIterator` repeatedly applies the same validated zero-copy complete-frame path while retaining the unconsumed remainder:

```zig
var frames = http.http2.frame.CompleteIterator.init(
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

`http2.connection.Decoder` layers connection-wide receive rules over the existing frame
parsers without owning a stream table. Its persistent state is 28 bytes on
x86_64: a 20-byte `FrameDecoder` plus 8 bytes for CONTINUATION sequencing and the
connection receive flow-control window. These mutable connection contexts are
intended for one ordered owner at a time; applications that move a connection
between worker threads should transfer ownership rather than process its frames
concurrently.

Drain complete frames first:

```zig
var connection = http.http2.connection.Decoder.init(
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

RFC 8441 Extended CONNECT is handled as HTTP/2 protocol state rather than as a
WebSocket abstraction. `SETTINGS_ENABLE_CONNECT_PROTOCOL` is tracked per
connection, `:protocol` is validated as part of request pseudo-header semantics,
and Session gates Extended CONNECT on negotiated capability. The selected
application protocol and tunnel bytes remain entirely caller-owned.

Request pseudo-header validation also checks the URI semantics that are safe to
resolve inside the HTTP core. `:scheme` follows RFC 3986 syntax and remains open
to non-HTTP schemes; `:path` validates path/query syntax and applies the stricter
non-empty absolute-path rule only to HTTP/HTTPS; HTTP/HTTPS `:authority` rejects
empty hosts and deprecated userinfo. Asterisk-form `:path = "*"` is accepted only
for server-wide OPTIONS without `:authority`, and traditional CONNECT requires
`:authority` in host:port form. The ephemeral `http2.fields.RequestTarget` state
is public for consumers composing field validation below `Session`.

### HTTP/2 extension composition

`Session` does not force consumers to abandon the composed path when they add an
HTTP/2 extension. Unknown/unsupported frame types are returned as a zero-copy
`.extension` event containing the raw type, flags, stream identifier, and
caller-owned payload slice. The base Session deliberately performs no
extension-specific stream mutation. Applications that do not support the frame
can simply ignore that event.

The `.settings` event likewise retains the already validated raw SETTINGS
payload. `settings_event.iterator()` lets an application inspect extension
setting identifiers while Session continues to apply the settings it natively
understands in wire order. This preserves the HTTP/2 requirement that unknown
settings remain harmless without making composed Session a closed extension
surface.

`http2.priority` provides policy-free RFC 9218 support for
`SETTINGS_NO_RFC7540_PRIORITIES`, HTTP/2 `PRIORITY_UPDATE`, and the Priority
Structured Field Dictionary. `priority.parseFieldValue()` preserves omission of
`u`/`i`, ignores unknown or type/range-invalid parameters after validating the
complete dictionary, and `Parameters.effective()` applies the standard `u=3,
i=false` defaults when appropriate. `writeFieldValue()`, `writeUpdate()`, and
`writeUpdateParameters()` provide allocation-free canonical outbound paths.
Scheduling, buffering priority for future streams, and merging request/response
signals remain caller-owned policy.

### Structural contracts and error model

HTTP/2 caller-owned storage remains structurally typed. `http2.contracts`
provides `hasStreamStore`, `hasSessionStore`, and `hasFieldSink` predicates plus
`assert*` helpers. The composed `Session` invokes these at its public generic
boundary so a missing `get`, `insert`, `maxActiveSendAdjustment`, or `field`
operation fails with a short zig-http-specific compile error rather than a deep
instantiation trace. These helpers intentionally preflight operation presence;
ordinary Zig method resolution remains the authority for exact signatures. No
vtable, allocator, or concrete store type is introduced.

Protocol failures received from the peer are values (`SessionEvent.fault`) so a
caller can serialize the required RST_STREAM/GOAWAY through its own transport
policy. Local invalid operations remain Zig errors. A writer/HPACK failure after
outbound state may have advanced poisons only the Session send side; callers
should abandon that HTTP/2 transport rather than retrying against a potentially
desynchronized wire/compression state. Transport closure, retry policy, logging,
and timers remain outside core.

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

## HTTP/2 ordered dispatch and shard handoff

`http2.dispatch` exposes the receive-side ownership boundary explicitly. A
connection owner first commits only connection-wide HTTP/2 state (CONTINUATION
adjacency and the connection receive window), then DATA, RST_STREAM, and stream
WINDOW_UPDATE can be handed to the owner of one `Tracked` record. HEADERS/HPACK,
SETTINGS, GOAWAY, connection WINDOW_UPDATE, PING, and extension handling remain
on the ordered path. No worker queue or synchronization primitive is part of
core.

When `ConnectionCompleteIterator` or `ConnectionDecoder` already observed the
frame header, use `prepareAssumeConnectionChecked()` or the typed
`prepareDataAssumeConnectionChecked()` / `prepareResetAssumeConnectionChecked()` /
`prepareStreamWindowUpdateAssumeConnectionChecked()` paths. This avoids checking
connection state twice:

```zig
var frames = http.http2.connection.CompleteIterator.init(
    &session.connection,
    input,
    receiver_max_frame_size,
);

while (try frames.next()) |complete| {
    const prepared = http.http2.dispatch.prepareAssumeConnectionChecked(
        session.peer.settings.initial_window_size,
        complete,
    );
    switch (prepared) {
        .data, .reset, .window_update => {
            // Convert only when the runtime really needs a tagged queue item.
            const work = prepared.streamWork().?;
            enqueueStreamWork(work.streamId(), work);
        },
        .ordered => {
            const event = try session.receiveCompleteAssumeConnectionChecked(
                &store,
                complete,
                scratch,
                &field_sink,
            );
            _ = event;
        },
        .ignored => {},
        .fault => |code| return connectionError(code),
    }
}
```

`Prepared` is 32 bytes and flat (there is no nested stream-work union).
`StreamWork` is also 32 bytes when a generic queue item is actually required;
typed DATA work is 24 bytes. Stream WINDOW_UPDATE work captures the exact peer
`SETTINGS_INITIAL_WINDOW_SIZE` ordered before that frame, so a delayed shard does
not read a newer connection setting accidentally. If the target shard reports
that the stream record is absent, `StreamWork.absent()` /
`StreamManager.receiveAbsent()` resolve the high-water and GOAWAY semantics
without repeating the caller-store lookup.

DATA work keeps a zero-copy slice into the original frame payload. A runtime that
queues it across threads must therefore keep the backing transport/read buffer
alive until the work item is consumed. The core deliberately does not choose a
buffer ownership or reference-counting scheme.

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
var manager = http.http2.streams.Manager.init(.client, .{});
var peer = http.http2.peer.State.init(.client);

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

For runtimes that shard stream records away from the ordered connection owner,
`Existing.detached()` drops the `Manager` pointer entirely. The resulting
16-byte `DetachedStreamCursor` can apply the common stream-local DATA,
RST_STREAM, and stream WINDOW_UPDATE transitions directly to one caller-owned
`Tracked` record and returns a 1-byte `StreamEffect` containing only aggregate
bookkeeping that belongs back on the connection owner:

```zig
const existing = manager.existing(&store, stream_id).?;
const local = existing.detached();

// This can run where the caller owns `local.tracked`. Connection-level DATA
// flow accounting must already have happened in wire order.
const applied = local.receiveData(frame_length, end_stream);
if (applied.result != .accepted) return mapStreamResult(applied.result);

// Hand only the compact aggregate effect back to the ordered connection owner.
if (!applied.effect.empty()) {
    manager.commitStreamEffect(stream_id, applied.effect);
}
```

The detached cursor deliberately does **not** re-check manager-owned routing
invariants such as GOAWAY cutoffs or missing-record classification; use the
lookup-based `StreamManager` path when those checks have not already been
resolved. A `Tracked` record still has one logical mutator at a time. Core does
not make it atomic and does not prescribe how a runtime transfers ownership.

`StreamEffect.ordersConcurrency()` identifies active-count changes that should
be committed before a later concurrent-stream-limit decision needs an exact
count. `ordersSettings()` identifies the rarer positive stream WINDOW_UPDATE
effect that must be visible before a later `SETTINGS_INITIAL_WINDOW_SIZE`
increase is validated. These ordering hints expose the HTTP/2 dependency without
requiring a particular queue, lock, or worker topology.

The same split is available on the send side. The fully manual
`dataSendCredit()` / `localDataAssumeCredit()` pair remains available, while a
sharded runtime can instead capture a 12-byte `DataSendOffer`:

```zig
// Stream owner / shard:
const offer = try detached.dataSendOffer(peer_initial_window_snapshot);

// Ordered connection owner:
const grant = try http.http2.dispatch.grantDataSend(&peer, offer);
const amount = @min(bytes.len, grant.max_payload);
// Write DATA here. Only after the wire write succeeds:
try peer.consumeSend(@intCast(amount));

// Stream owner / shard:
const effect = offer.commit(detached, @intCast(amount), end_stream);
```

`grantDataSend()` combines stream credit with the current connection send window
and peer MAX_FRAME_SIZE. If `SETTINGS_INITIAL_WINDOW_SIZE` decreased after the
offer was made, it returns `error.StaleStreamCredit` so the shard can probe again;
a later increase leaves the older offer conservatively valid. The post-write
commit needs no `PeerState`. Per-stream work must still remain ordered by the
caller, and the connection owner must not reorder a SETTINGS transition between
accepting a grant and the corresponding wire write.

This preserves the existing Session preflight/write/commit semantics while
allowing a lower-level runtime to keep stream storage on a separate shard. The
ordinary `Session` and `StreamCursor` APIs remain fused for convenience and use
specialized hot paths rather than paying handoff-token overhead internally.

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

var session = http.http2.Session.init(.{
    .role = .client,
    .decoder = &decoder,
    .encoder = &encoder,
    .header_storage = &continuation_storage,
});

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
`StreamManager`. Ordinary peer `SETTINGS_INITIAL_WINDOW_SIZE` changes are now
O(1) because each stream send window is represented relative to the current peer
initial window. Only a rare increase that could overflow an active stream asks
the store for `maxActiveSendAdjustment() i32`; the store can satisfy that query
with a scan, a maintained aggregate, or shard coordination. Received
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
var settings_sync: http.http2.session.SettingsSync = .{};
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
var connection_credit = try http.http2.flow.ReceiveCredit.init(65_535, 32_767);
var stream_credit = try http.http2.flow.ReceiveCredit.init(65_535, 32_767);

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
var drain: http.http2.session.GracefulGoAway = .{};
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
var scheduler: http.http2.scheduler.RoundRobin = .{};
const candidates = [_]http.http2.scheduler.Candidate{
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
- `http1/semantics.zig` — opt-out request-target/Host and persistence semantics.
- `http1/connection.zig` — allocation-free receive-side message/connection coordinator over caller-owned buffers and request context.
- `http1/body.zig` — fixed-length and streaming chunked-body decoding with strict chunk-extension grammar.
- `http1/write.zig` — HTTP/1.0/1.1 raw serialization plus allocation-free `MessageWriter` send-side framing/state coordination.
- `http2/frame.zig` — contiguous, batched, and incremental zero-copy frame parsing plus frame serialization.
- `http2/connection.zig` — allocation-free connection receive state and complete/fragmented frame integration.
- `http2/peer.zig` — peer SETTINGS, send-window, outbound constraints, and GOAWAY state.
- `http2/settings.zig`, `flow.zig`, `stream.zig` — streaming SETTINGS, caller-owned flow/stream state, and optional receive-credit policy primitives.
- `http2/streams.zig` — allocation-free stream-ID/concurrency/lifecycle manager over caller-owned storage.
- `http2/session.zig` — optional 128-byte receive/send session composition with HPACK/field/stream/control dispatch over caller-owned storage.
- `http2/scheduler.zig` — one-word caller-driven round-robin DATA selector over Session flow credit.
- `http2/dispatch.zig` — ordered receive-to-stream handoff plus cross-owner DATA credit snapshots, with typed fast paths for already classified frames.
- `http2/send.zig` — bounded streaming HPACK field-block framing plus allocation-free SETTINGS/PING/RST_STREAM/WINDOW_UPDATE/GOAWAY serialization.
- `http2/payload.zig` — typed DATA/HEADERS/PUSH_PROMISE/etc. payload helpers.
- `http2/continuation.zig`, `header_block.zig` — bounded field-block assembly rules.
- `hpack` 0.4.1 dependency — standalone RFC 7541 codec with real-world-benchmarked encoder lookup and short-literal Huffman fast paths plus bounded decoding.

## Dependency

HPACK is fetched from `https://github.com/rm-netsu/zig-hpack` and pinned by both Git commit and Zig package hash in `build.zig.zon`.

## Build

```sh
zig build test
zig build check
zig build examples
zig build test -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSafe -Dsanitize-thread=true
zig build conformance-fixtures
./test/conformance/run-http1-interop.sh
./test/conformance/run-rfc-smoke.sh
./test/conformance/run-external-interop.sh
H2SPEC_BIN=/path/to/h2spec ./test/conformance/run-h2spec.sh
zig build bench -Doptimize=ReleaseFast
zig build bench-real -Doptimize=ReleaseFast
zig build bench-real-frames -Doptimize=ReleaseFast
zig build bench-real-streams -Doptimize=ReleaseFast
zig build bench-real-session -Doptimize=ReleaseFast
zig build bench-real-send-session -Doptimize=ReleaseFast
zig build bench-real-scheduler -Doptimize=ReleaseFast
zig build bench-real-settings -Doptimize=ReleaseFast
zig build bench-real-dispatch -Doptimize=ReleaseFast
zig build bench-real-send-offer -Doptimize=ReleaseFast
```

The package exports module `http`. Benchmark methodology and current results are documented in `BENCHMARKS.md`. HTTP/1/HTTP/2 conformance and bidirectional external interoperability setup is documented in `test/conformance/README.md`.

## Scope

This package is the protocol engine rather than a batteries-included HTTP client/server. HTTP-only composition remains part of the core even when it is more convenient than raw wire primitives. The core intentionally does not own TCP/TLS connections, DNS, timers, thread pools, event loops, socket lifetimes, or application routing/work queues. Concrete adapters that coordinate those external layers belong in an optional `high_level` namespace/package and must remain wrappers over independently usable core APIs.
