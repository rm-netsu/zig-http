# HTTP/2 composition guide

## Recommended composed API

Use `http.http2.Session` when one ordered connection owner should compose frame
validation, HPACK, field semantics, stream transitions, SETTINGS/GOAWAY, flow
control, and state-aware sends while retaining caller-owned stream storage and
I/O.

Compile-tested starting points:

```text
examples/http2_client_core.zig
examples/http2_server_core.zig
examples/http2_trailers.zig
examples/http2_priority.zig
examples/support/fixed_stream_store.zig
examples/support/counting_field_sink.zig
```

`Session` owns no socket, TLS state, event loop, stream allocation, or HPACK
allocator. Its HPACK encoder/decoder and continuation storage are explicitly
provided connection-owned dependencies.

## Structural contracts

A Session stream store provides the operations diagnosed by `http2.contracts`:

```zig
pub fn get(self: *@This(), id: u31) ?*http2.stream.Tracked;
pub fn insert(
    self: *@This(),
    id: u31,
    value: http2.stream.Tracked,
) ?*http2.stream.Tracked;
pub fn maxActiveSendAdjustment(self: *@This()) i32;
```

The exact storage topology is caller-owned. `examples/support/fixed_stream_store.zig`
is a small reference implementation, not a required production layout.

A field sink is invoked synchronously while HPACK fields are decoded. The
minimal shape is:

```zig
pub fn field(
    self: *@This(),
    stream_id: u31,
    kind: http2.fields.Kind,
    value: http.common.Header,
) void;
```

The sink may also return an error; Session propagates it through its receive
path. Borrowed header slices must be copied if the application keeps them beyond
the callback.

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
