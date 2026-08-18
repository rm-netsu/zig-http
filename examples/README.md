# Transport-neutral examples

These examples cover both the optional convenience layer and direct protocol-core
composition. None of them makes sockets, TLS, DNS, or an event loop part of the
HTTP package.

- `http1_high_level.zig` — shortest bounded-memory HTTP/1 client/server round-trip with typed Host-aware request construction, automatic response-context coordination, and synchronous event draining.
- `http1_client_core.zig` — serialize a request with `MessageWriter`, then parse
  a response with `ConnectionDecoder` and explicit outstanding-method context.
- `http1_server_core.zig` — parse a request and serialize a framed response.
- `http1_trailers.zig` — finish a chunked response with application-defined
  trailers through the explicit RFC 9110 semantic policy hook.
- `http2_high_level.zig` — shortest bounded-memory client/server round-trip using
  `high_level.http2.Connection`, typed message builders, copied header fields,
  and automatic client stream-ID allocation.
- `http2_client_core.zig` — create a client `Session`, public fixed stream store,
  HPACK codecs, and one request HEADERS block.
- `http2_server_core.zig` — in-memory client/server Session round-trip showing
  synchronous field sinks, stream storage, response HEADERS, and DATA.
- `http2_trailers.zig` — send HTTP/2 trailers only after an explicit application/domain semantic policy accepts every field.
- `http2_priority.zig` — parse and serialize RFC 9218 Priority values, compose
  request/response/PRIORITY_UPDATE omission semantics with caller-owned state,
  and emit a PRIORITY_UPDATE frame without introducing scheduling policy.
- `error_handling.zig` — exhaustive peer-fault scope mapping plus HTTP/1 writer
  recovery-state checks; see `docs/operations.md` for the full operational model.
- `support/counting_field_sink.zig` — minimal synchronous field-sink contract.

Run all examples with:

```sh
zig build examples
```

`zig build check` also runs them, so public API changes that make these reference
compositions stale fail the normal merge gate.
