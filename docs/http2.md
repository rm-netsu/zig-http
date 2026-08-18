# HTTP/2 composition guide

## Optional high-level connection

For applications that want bounded defaults rather than custom storage,
`http.high_level.http2.Connection(config)` owns the repetitive HTTP-specific
connection wiring while leaving the transport outside the library:

```zig
const Conn = http.high_level.http2.Connection(.{});
var client = try Conn.initClient(allocator);
defer client.deinit();

_ = try client.start(out, &.{});
const sent = try client.sendRequest(
    out,
    http.http2.message.RequestFields.init("GET", "https", "example.com", "/"),
    &.{http.http2.message.header("accept", "application/json")},
    true,
);
```

The wrapper bundles HPACK encoder/decoder contexts, `Bootstrap`, `Session`,
`SettingsSync`, `http2.storage.FixedStreamStore`, a copying transactional
`FixedFieldCollector`, and bounded scratch/staging buffers. It performs one
connection-state allocation so its public handle is safely movable despite
Session holding internal pointers. Sockets, TLS, transport buffers, timers, and
application scheduling remain caller-owned. `core()`, `store()`, `collector()`,
and `bootstrap()` expose the underlying components when an integration needs to
drop down a level.

The convenience defaults favor a practical standalone integration rather than
minimum bytes per connection. `Connection(config).state_bytes` exposes the fixed
allocation size at comptime; tune the bounds or use `Session` directly for very
high connection counts or custom storage topologies.

`receive()` returns copied header fields alongside HEADERS/PUSH_PROMISE events.
If the configured collector capacity is insufficient, `overflowed` is reported
without publishing a partial field list; the HTTP/2 decoder stays synchronized.
Closed entries are retained until the application explicitly calls
`reclaimClosed()`, so final stream state remains inspectable.

Typed `http2.message.RequestFields` keeps ordinary, CONNECT, and Extended
CONNECT pseudo-field layouts distinct. `ResponseFields` formats numeric status
codes. Both build into caller/wrapper-owned `EncodedField` storage and run the
production field validator before Session/wire mutation.

`Connection.drain(input, max_frame_size, handler)` is the convenience counterpart
to one-event `receive()`. It synchronously invokes `handler.onEvent(result)` for
every immediately parseable event and stops when the handler returns the shared
`http.high_level.DrainAction.stop` or more transport bytes are required. No event batch is retained; copied field
sections follow the same collector lifetime as `receive()`. Core
`Session.receiveBytes()` remains intentionally one-event-at-a-time for runtimes
that want precise backpressure.

## Recommended composed API

Use `http.http2.Bootstrap` plus `http.http2.Session` when one ordered connection owner should compose connection establishment and frame
validation, HPACK, field semantics, stream transitions, SETTINGS/GOAWAY, flow
control, and state-aware sends while retaining caller-owned stream storage and
I/O.

Compile-tested starting points:

```text
examples/http2_high_level.zig
examples/http2_client_core.zig
examples/http2_server_core.zig
examples/http2_trailers.zig
examples/http2_priority.zig
examples/support/counting_field_sink.zig
```

`Session` owns no socket, TLS state, event loop, stream allocation, or HPACK
allocator. Its HPACK encoder/decoder and continuation storage are explicitly
provided connection-owned dependencies.


## Connection bootstrap

`http2.Bootstrap` removes the manual glue between `http2.preface.Parser`,
`preface.bytes`, and the first SETTINGS frame while still owning no socket.
Create it with the same role as the Session:

```zig
var bootstrap = http.http2.Bootstrap.init(.client);
var sync: http.http2.session.SettingsSync = .{};
_ = try bootstrap.start(&session, &sync, out, &initial_settings);

const result = try bootstrap.receiveBytes(
    &session, &store, input, http.http2.frame.default_max_frame_size,
    scratch, &sink,
);
```

For clients, `start()` writes the 24-byte client magic and initial SETTINGS. For
servers it writes only initial SETTINGS. Local settings are validated before any
preface byte is emitted. Receive-side bootstrap accepts a fragmented client
magic on servers and requires the peer's first frame to be a non-ACK SETTINGS
frame before forwarding later frames to Session. Writer failure poisons the
Bootstrap; discard the connection.

The low-level `http2.preface` parser/bytes remain available when a runtime owns
connection establishment itself.

## Preflight diagnostics

Normal Session send APIs intentionally keep compact error sets. For logging,
tests, configuration UIs, or development builds, use the opt-in diagnostic
companions before a send:

```zig
if (session.diagnoseSendHeaders(&store, id, end_stream, &fields)) |problem| {
    // e.g. .field{ .index = 4, .reason = .authority_host_mismatch }
}
if (session.diagnoseSettings(&settings)) |problem| {
    // problem.index + a SettingsPreflightReason
}
if (session.diagnoseSendData(&store, id, payload.len, end_stream)) |problem| {
    // e.g. .response_headers_not_sent or .connect_tunnel_not_established
}
```

These APIs do not mutate Session, HPACK, stream state, or the writer. The
header diagnostic uses the production validator for acceptance and classifies
only failures, so richer reporting is not part of the hot path. Arbitrary store
capacity cannot be predicted without a store-specific non-mutating probe;
`StoreFull` therefore remains a send-time result.

## Structural contracts

A Session stream store provides the operations checked by `http2.contracts`:

```zig
pub fn get(self: *@This(), id: u31) ?*http2.stream.Tracked;
pub fn insert(
    self: *@This(),
    id: u31,
    value: http2.stream.Tracked,
) ?*http2.stream.Tracked;
pub fn maxActiveSendAdjustment(self: *@This()) i32;
pub fn bodyState(self: *@This(), id: u31) ?*http2.fields.BodyState;
```

The contract predicates validate complete method signatures (receiver, arguments, and return type), so malformed adapters fail at the API boundary instead of later in generic instantiation. The exact storage topology is caller-owned. `http2.storage.FixedStreamStore(N)` is a bounded O(N) default implementation;
custom slabs/maps/shards remain supported through the same structural contract.

A field sink is invoked synchronously while HPACK fields are decoded and is
transactional at field-section granularity. The minimal shape is:

```zig
pub fn begin(self: *@This(), stream_id: u31, kind: http2.fields.Kind) void;
pub fn field(
    self: *@This(),
    stream_id: u31,
    kind: http2.fields.Kind,
    value: http.common.Header,
) void;
pub fn commit(self: *@This(), stream_id: u31, kind: http2.fields.Kind) void;
pub fn abort(self: *@This(), stream_id: u31, kind: http2.fields.Kind) void;
```

`field()` values are provisional. A later malformed field, HPACK failure, or
stream-state rejection causes `abort()` rather than exposing a partial field
section as committed application state. Borrowed header slices must still be
copied if the application keeps them beyond the callback.

The store-owned `BodyState` is reset by Session for each initial inbound request
or final response. A locally opened request starts in `awaiting_headers`, so DATA
from the peer cannot precede the final response field section. The state checks
declared Content-Length against DATA content bytes, validates the count when
END_STREAM or trailers finish the message, and rejects non-empty DATA for
messages defined to have no content. Padding remains only flow-control charge
and is not counted as message content. CONNECT request bytes remain forbidden
until a successful response establishes tunnel mode. Store insertion/reuse must
reset the associated `BodyState` to its default value; managed `sendHeaders()`
also enforces that reset for local request streams.

## Lower-level connection/stream composition

For runtimes that need more control, the namespaces remain independently usable:

- `http2.frame` — frame parsing/fragmentation;
- `http2.connection` — CONTINUATION and connection-flow ordering;
- `http2.stream` / `http2.streams` — caller-owned stream state;
- `http2.dispatch` — connection-ordered handoff of stream-local work;
- `http2.send` — raw allocation-free frame writers;
- `http2.flow`, `settings`, `peer`, `fields`, `priority` — focused protocol
  primitives.

Use `prepare*AssumeConnectionChecked()` and
`Session.receiveCompleteAssumeConnectionChecked()` only when the connection owner
has already committed the corresponding connection-wide invariant. The longer
names are intentional: they make skipped validation visible at call sites.

## Extensions and Extended CONNECT

Unknown validated extension frames and SETTINGS payloads can be surfaced to the
application without forcing a lower composition level. RFC 8441 Extended CONNECT
negotiation and `:protocol` semantics are in core; the tunneled application
protocol remains outside core.

## RFC 9218 priorities

`http2.priority` parses/serializes Priority Structured Fields and
PRIORITY_UPDATE. `priority.State` composes request, response-overlay, and update
signals while preserving their different omission semantics.

Scheduling policy, buffering priorities for not-yet-created streams, and merging
client/server preferences remain caller-owned. The HTTP core intentionally does
not impose a queue or scheduler topology.

## Trailer field semantics

HTTP/2 framing can validate trailer syntax and universally forbidden connection/framing fields, but core cannot know whether every registered or application-defined HTTP field permits trailer placement. The composed send path is therefore fail-closed for non-empty trailers.

`Session.sendHeaders()` / `sendHeadersExisting()` return `error.TrailerPolicyRequired` when a non-empty field section would be trailers. Use the explicit trailer APIs instead:

```zig
const Policy = struct {
    pub fn allows(_: @This(), name: []const u8) bool {
        return std.mem.eql(u8, name, "x-checksum");
    }
};

_ = try session.sendTrailers(
    &store,
    out,
    stream_id,
    &frame_staging,
    &trailers,
    Policy{},
);
```

`sendTrailers()` and `sendTrailersExisting()` always carry END_STREAM and preflight the complete field block plus caller policy before stream, HPACK, or wire mutation. Policy rejection returns `error.TrailerRejected`, so the caller can correct the trailers/policy and retry safely.

Inbound trailers remain structurally validated and surfaced to the field sink without requiring this outbound policy. That keeps proxies and extension-aware applications able to inspect or forward fields whose semantics live outside core. Lower-level HPACK/frame writers remain the raw escape hatch when the caller intentionally owns all semantic responsibility.
