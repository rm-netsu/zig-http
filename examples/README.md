# Protocol-core examples

These examples are intentionally transport-neutral. They demonstrate how to
compose zig-http with caller-owned buffers, HPACK state, stream storage, and I/O
without making sockets, TLS, DNS, or an event loop part of the HTTP core.

- `http1_client_core.zig` — serialize a request with `MessageWriter`, then parse
  a response with `ConnectionDecoder` and explicit outstanding-method context.
- `http1_server_core.zig` — parse a request and serialize a framed response.
- `http2_client_core.zig` — create a client `Session`, fixed caller-owned stream
  store, HPACK codecs, and one request HEADERS block.
- `http2_server_core.zig` — in-memory client/server Session round-trip showing
  synchronous field sinks, stream storage, response HEADERS, and DATA.
- `http2_priority.zig` — parse and serialize RFC 9218 Priority values, compose
  request/response/PRIORITY_UPDATE omission semantics with caller-owned state,
  and emit a PRIORITY_UPDATE frame without introducing scheduling policy.
- `error_handling.zig` — exhaustive peer-fault scope mapping plus HTTP/1 writer
  recovery-state checks; see `docs/operations.md` for the full operational model.
- `support/fixed_stream_store.zig` — complete minimal `Session` store contract.
- `support/counting_field_sink.zig` — minimal synchronous field-sink contract.

Run all examples with:

```sh
zig build examples
```

`zig build check` also runs them, so public API changes that make these reference
compositions stale fail the normal merge gate.
