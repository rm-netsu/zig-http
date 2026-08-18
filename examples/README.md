# Examples

These examples cover the optional convenience layer, direct protocol-core composition, and two runnable loopback TCP integrations. The TCP examples keep socket ownership in application code; they do not make transport part of the HTTP package.

- `http1_high_level.zig` — shortest in-memory bounded HTTP/1 client/server round-trip with typed Host-aware request construction, automatic response-context coordination, and synchronous event draining.
- `http1_tcp_client_server.zig` — runnable loopback TCP HTTP/1.1 client/server with pipelined GET+POST, streamed request/response bodies, keep-alive correlation, and clean close.
- `http1_expect_upgrade.zig` — allocation-free Expect: 100-continue coordination and validation of an HTTP/1.1 Upgrade selection against the original offer.
- `http1_client_core.zig` — serialize a request with `MessageWriter`, then parse
  a response with `ConnectionDecoder` and explicit outstanding-method context.
- `http1_server_core.zig` — parse a request and serialize a framed response.
- `http1_trailers.zig` — finish a chunked response with application-defined
  trailers through the explicit RFC 9110 semantic policy hook.
- `http2_high_level.zig` — shortest in-memory bounded client/server round-trip using
  `high_level.http2.Connection`, typed message builders, copied header fields,
  and automatic client stream-ID allocation.
- `http2_tcp_client_server.zig` — runnable loopback cleartext prior-knowledge HTTP/2 client/server with SETTINGS bootstrap, multiplexed GET+POST streams, explicit control responses, receive-credit replenishment, and GOAWAY.
- `http2_client_core.zig` — create a client `Session`, public fixed stream store,
  HPACK codecs, and one request HEADERS block.
- `http2_server_core.zig` — in-memory client/server Session round-trip showing
  synchronous field sinks, stream storage, response HEADERS, and DATA.
- `http2_trailers.zig` — send HTTP/2 trailers only after an explicit application/domain semantic policy accepts every field.
- `http2_priority.zig` — parse and serialize RFC 9218 Priority values, compose
  request/response/PRIORITY_UPDATE omission semantics with caller-owned state,
  and emit a PRIORITY_UPDATE frame.
- `http2_scheduler.zig` — apply caller-owned effective RFC 9218 priorities with
  the optional urgency/incremental reference scheduler.
- `error_handling.zig` — exhaustive peer-fault scope mapping plus HTTP/1 writer
  recovery-state checks; see `docs/operations.md` for the full operational model.
- `support/counting_field_sink.zig` — minimal synchronous field-sink contract.

Run all examples with:

```sh
zig build examples
```

`zig build check` also runs them, so public API changes that make these reference
compositions stale fail the normal merge gate.

Focused runnable TCP targets:

```sh
zig build example-http1-tcp
zig build example-http2-tcp
```

See [`../docs/basic-client-server.md`](../docs/basic-client-server.md) for how to split the loopback examples into standalone client/server processes.
