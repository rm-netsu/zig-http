# HTTP/2 composition guide

## Optional high-level connection

For applications that want bounded defaults rather than custom storage,
`http.high_level.http2.Connection(config)` owns the repetitive HTTP-specific
connection wiring while leaving the transport outside the library:

```zig
const Conn = http.high_level.http2.Connection(.{});
var client = try Conn.initClient(allocator);
defer client.deinit();

_ = try client.start(out);
const sent = try client.sendRequest(
    out,
    http.http2.message.RequestFields.init("GET", "https", "example.com", "/"),
    &.{http.http2.message.header("accept", "application/json")},
    true,
);
```

The wrapper bundles HPACK encoder/decoder contexts, `Bootstrap`, `Session`, an
internal `SettingsSync`, `http2.storage.FixedStreamStore`, a copying
transactional `FixedFieldCollector`, and bounded scratch/staging buffers.
`Config.local_settings` is the source of the initial SETTINGS frame and the
associated receive policy; `start(out)` and `receive(input)` do not require a
second caller-maintained settings/max-frame copy.

Local SETTINGS are modeled as synchronized snapshots. `configuredInitialSettings()`
reports the initial target, `acknowledgedLocalSettings()` reports the last target
whose application the peer has ACKed, `effectiveLocalSettings()` reports what the
receiver currently accepts, and `pendingLocalSettings()` exposes the optional
in-flight target. Receive-capacity expansions such as a larger MAX_FRAME_SIZE,
MAX_HEADER_LIST_SIZE, concurrency allowance, or initial stream window are made
safe immediately after the SETTINGS write because the peer can apply them before
its ACK reaches us. Restrictions become authoritative at the ACK. HPACK
SETTINGS_HEADER_TABLE_SIZE changes are synchronized specifically at the ACK
boundary as required by RFC 9113 compression-state rules.

After the initial frame is acknowledged, `sendLocalSettings(out, next)` emits
only changed setting values and owns the same synchronization policy. The
high-level wrapper deliberately permits one unacknowledged local SETTINGS
snapshot at a time; a second call returns `SettingsPending`. Applications that
need multiple simultaneously outstanding local policy snapshots should use
`Session.sendSettings()` with their own policy queue. `LocalSettings.max_header_list_size`
uses `maxInt(u32)` as the wire-representable default/maximum rather than an
optional value, allowing a later SETTINGS update to restore that maximum.

The ordinary constructors perform one connection-state allocation so the public
handle is safely movable despite Session holding internal pointers.
`Connection(config).Storage` plus
`initClientInPlace` / `initServerInPlace` instead places that fixed state in
caller-owned stable memory; the supplied allocator is then used only by HPACK
dynamic tables. Sockets, TLS, transport buffers, timers, and application
scheduling remain caller-owned. `core()`, `store()`, `collector()`, and
`bootstrap()` expose the underlying components when an integration needs to
drop down a level.

The convenience defaults favor a practical standalone integration rather than
minimum bytes per connection. `Connection(config).state_bytes` exposes the fixed
allocation size at comptime; tune the bounds or use `Session` directly for very
high connection counts or custom storage topologies.

`receive()` returns copied header fields alongside HEADERS/PUSH_PROMISE events.
Collector exhaustion is fail-closed in the high-level layer: HPACK is fully drained
for synchronization, then `HeaderCollectionOverflow` is returned and subsequent
receive calls return `ReceiveFailed`; discard that high-level connection. The
low-level transactional collector still exposes `overflowed()` for diagnostic or
proxy integrations that intentionally manage this case themselves. Closed entries
are retained until the application explicitly reclaims them, so final stream state
remains inspectable. `reclaimStream(id)` removes one known-closed record without a
full bounded-store scan; `reclaimClosed()` remains convenient for batch cleanup.

`lifecycle()` reports `handshaking`, `active`, `draining`, or `failed`. Either a
received or locally sent GOAWAY enters `draining`; terminal receive/decode failures
are latched as `failed` so a later call cannot accidentally resume frame parsing.
For client retry policy, `peerGoAwayLastStreamId()` exposes the received cutoff and
`unprocessedByPeer(stream_id)` is true only when that cutoff proves a locally
initiated stream was not processed by the peer. This classification says nothing
about whether the application method itself is safe to retry.

Every receive result also carries a transport-neutral `control` action. Non-ACK
SETTINGS, non-ACK PING, and protocol faults that reach Session as semantic events
therefore do not require applications to reconstruct the mandatory response. Pass
the action to `sendControl(out, action)` when the transport is writable. No receive
call writes implicitly.

Errors raised before an Event can be produced (for example malformed frame headers
or connection preface) latch the high-level receive side as failed.
`controlForReceiveError(err)` maps RFC-defined peer faults such as FRAME_SIZE,
PROTOCOL, and HPACK compression failures to a GOAWAY action; local resource/policy
failures map to `.none` so the application closes without incorrectly blaming the
peer.

After consuming a DATA event, call `releaseData(data)` when the application has
released the corresponding capacity. `flushReceiveCredit(out, stream_id)` emits
connection/stream WINDOW_UPDATE frames when the built-in low-watermark policy is
ready. Custom runtimes can keep using `Session` with caller-owned `ReceiveCredit`.

Typed `http2.message.RequestFields` keeps ordinary, CONNECT, and Extended
CONNECT pseudo-field layouts distinct. `ResponseFields` formats numeric status
codes. `http2.message.ContentLength.init(n)` owns the decimal bytes required by
a canonical Content-Length field. Both builders build into caller/wrapper-owned
`EncodedField` storage and run the production field validator before Session/wire
mutation.

The high-level wrapper also forwards common lifecycle operations that otherwise
force an unnecessary drop to `Session`: `sendTrailers(...)`, `resetStream(...)`,
`sendGoAway(...)`, and the two-phase `announceGracefulGoAway(...)` /
`finishGracefulGoAway(...)`. Graceful shutdown still owns no timer; the
application chooses the grace interval and final application-processed stream
cutoff.

The high-level wrapper also honors a peer-advertised
`SETTINGS_MAX_HEADER_LIST_SIZE` before HPACK or wire mutation. This is enabled by
default with `Config.enforce_peer_header_list_size = true`; disable it when an
application intentionally treats the advisory setting as soft policy. Low-level
`Session.sendHeaders()` remains permissive. `Session.peerHeaderListLimit()`,
`peerHeaderList()`, `diagnosePeerHeaderList()`, and
`sendHeadersWithinPeerLimit()` provide explicit policy composition for custom
runtimes. `http2.message.fieldSectionSize()` exposes the same RFC accounting.

`Connection.drain(input, handler)` is the convenience counterpart
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
examples/http2_scheduler.zig
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
not impose a mandatory queue or scheduler topology. `http2.scheduler.Urgency` is
an optional reference RFC 9218 scheduler: lower urgency wins, non-incremental
responses are kept active while they can make progress, and incremental work
round-robins within the same urgency. If a higher-urgency stream is flow-control
blocked, ready lower-urgency work may proceed. The original tiny `RoundRobin`
remains available when an application owns priority policy elsewhere.

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
