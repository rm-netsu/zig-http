# HTTP/1.1 composition guide

## Recommended composed APIs

Use `http.http1.ConnectionDecoder` for receive-side message coordination and
`http.http1.MessageWriter` for send-side message coordination. They own HTTP
state only; the caller owns the transport and buffers.

The compile-tested starting points are:

```text
examples/http1_client_core.zig
examples/http1_server_core.zig
examples/http1_trailers.zig
```

## Receive path

`ConnectionDecoder` composes start-line/header parsing, request semantics,
message framing, body progression, trailers, persistence, informational
responses, HEAD semantics, CONNECT tunnels, and pipelined message boundaries.

Feed transport bytes incrementally. Event slices may borrow caller-owned input or
scratch storage; consume or copy them before reusing that storage. A parse failure
is terminal for that HTTP/1 transport because searching for a later apparent
message boundary is unsafe after framing becomes ambiguous.

For response decoding, the caller supplies the outstanding request method with
`beginResponse(method)`. Informational responses keep that context; the final
response completes it.

## Send path

`MessageWriter.beginRequest()` and `beginResponse()` preflight the complete head
before the first byte is emitted. `writeData()` then enforces the selected body
framing and exact Content-Length accounting. `finish()` completes fixed/chunked
messages and exposes close/protocol-switch outcomes through writer state.

Non-empty chunked trailers require
`finishWithTrailerPolicy(...)`. Core can enforce universally invalid trailer
fields but cannot know the field-definition semantics of application-specific or
future registered fields. The supplied policy makes that responsibility explicit
without embedding an HTTP field registry in core.

Writer I/O failure can leave the wire partially advanced and poisons the writer.
Do not reuse the transport after `failed()` becomes true. See
[`operations.md`](operations.md) for recovery rules.

## Lower-level composition

Consumers that deliberately own more protocol state may use:

- `http1.head` for contiguous/incremental head parsing;
- `http1.body` for body/chunk decoding;
- `http1.semantics` for request/response semantic checks;
- `http1.write` for raw serialization.

Raw writers are escape hatches, not alternate composed state machines. In
particular, `http1.write.endChunks()` serializes trailers without application
field-definition policy; the caller then owns that semantic check.
