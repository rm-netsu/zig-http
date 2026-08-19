# HTTP/1.1 composition guide

## Recommended composed APIs

For the shortest bounded-memory integration use
`http.high_level.http1.Connection(config)`. It owns the HTTP-specific parser,
writer, scratch storage, outbound Header descriptor array, and the bounded
response-context queue required by pipelining. It still owns no socket, TLS
session, timer, or event loop.

The queue retains only `HEAD`, `CONNECT`, or `other` semantics rather than
borrowed method strings. This is sufficient for HTTP response-body framing and
allows arbitrary extension methods without copied method storage. Clients queue
that semantic context when a request head is successfully written; responses
are bound automatically in request order. Servers queue it when request heads
are parsed and `sendResponse()` always uses the oldest outstanding request.

When the configured queue is full, client `sendRequest()` returns
`RequestQueueFull` before writing bytes. A server returns the same local
backpressure error before consuming a new request head; send an outstanding
final response (or choose a larger bound) and retry with the same input.

`Connection(config).Storage` exposes the complete fixed high-level state. Use
`initClientInPlace(&storage)` / `initServerInPlace(&storage)` when the application
wants fully allocation-free HTTP/1 composition. The storage address must remain
stable until `deinit`; the ordinary allocator constructors remain convenient when
a movable handle backed by one allocation is preferable.

Typed `http1.message.RequestFields` constructors cover origin-form, absolute-
form, OPTIONS `*`, and CONNECT. They compose Host by construction and reject a
regular-field list that tries to duplicate the generated Host. `ResponseFields`
packages the response start line while leaving body framing fields explicit for
streaming applications. `http1.message.ContentLength.init(n)` owns canonical
decimal bytes for a `content-length` field, and `http1.message.chunked()` emits
the canonical transfer-coding field; `MessageWriter` still validates that the
chosen framing is legal. `http1.message.expectContinue()` and `upgrade(...)`
provide canonical field construction for the two handshakes without hiding their
application policy.

`http1.semantics.requestExpectation()` classifies request Expect fields as
`none`, `continue_100`, or `unsupported`; HTTP/1.0 expectations are ignored.
`ContinueGate` remains the tiny low-level caller-owned coordinator. The high-level
client now wires the same state into the active request automatically:
`continuePhase()` reports whether content is waiting/allowed/finally suppressed,
`writeData()` and `finish()` return `ContinuePending` while a 100 response is
outstanding, and `proceedWithoutContinue()` lets an application-selected timeout
open the gate without giving the HTTP package timer ownership. Other 1xx responses
do not open the gate. A final response received before the request content is
finished suppresses the remaining content and makes that HTTP/1 transport
non-reusable so unsent bytes cannot become a later-message framing ambiguity.
`MessageWriter.beginRequest()` also rejects generation of `100-continue` when
request framing indicates no content, before any wire byte is written.

For Upgrade, `http1.semantics.UpgradeOffer.init(head)` validates the request's
`Connection: Upgrade` + Upgrade list once. `offers(protocol)` performs the RFC
case-insensitive protocol-name match, and `validateSelection(response_head)`
ensures a structurally valid 101 selected only protocols actually offered by
the client. The low-level helper borrows the parsed request head and performs no
copying.

The high-level connection is stricter: it retains a bounded copy of each queued
Upgrade offer (`Config.upgrade_offer_bytes`) and validates the complete 101
selection automatically on both roles. A server cannot select a protocol the
client did not offer. On the client, an unsolicited or mismatched 101 is a
terminal composed receive failure: `lifecycle()` becomes `failed`,
`protocolSwitched()` remains false, pending request-body writes return
`ConnectionFailed`, and later receive calls return `ReceiveFailed`. This avoids
exposing the low-level decoder's tunnel transition after high-level negotiation
policy rejected the switch. `Expect: 100-continue` still requires the 100 response
before switching. If a server receives an offer larger than its configured
retained capacity it may still process the request normally, but attempting 101
fails closed with `UpgradeOfferTooLarge`. Client sends reject an oversized offer
before wire output.

Both high-level roles expose `drain(input, handler)`. It repeatedly drives the
one-event decoder and invokes `handler.onEvent(event)` synchronously; returning
`http.high_level.DrainAction.stop` leaves the remaining input untouched. This preserves the ordinary
borrowed-slice lifetime and avoids buffering an event batch.

High-level persistence is also symmetric with the peer. `lifecycle()` reports
`active`, `closing`, `switched`, or `failed`, and `peerCloseRequired()` exposes
the received close decision directly. Once a closing request body completes, a
server refuses to parse another pipelined request on that transport and forces
the corresponding final response to close even if the application omitted a
`Connection: close` field. A client that receives a closing final response stops
opening or decoding another response on that transport and abandons any later
request body that was still being streamed. Likewise, if a server sends a final
response before the current request body completes (the common early-final /
`Expect: 100-continue` case), the high-level client abandons the remaining body
and closes rather than trying to reuse an ambiguous connection. Any later
outstanding pipeline entries remain visible through `pendingResponses()` so
application retry/idempotency policy can decide what to do with them.

Use `http.http1.ConnectionDecoder` and `http.http1.MessageWriter` directly when
your runtime already owns the request/response queue or wants independent
receive/send composition.

The compile-tested starting points are:

```text
examples/http1_high_level.zig
examples/http1_expect_upgrade.zig
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

Request `HeadEvent` values expose `effective_authority` from the same semantic
pass that validates Host/request-target syntax. For origin-form and asterisk-form
this is the Host field; for absolute-form and CONNECT it comes from the
request-target. Route on `effective_authority`, not the raw Host field, so a
conflicting Host cannot override an absolute request target.

For response decoding, the caller supplies the outstanding request method with
`beginResponse(method)`. Informational responses keep that context; the final
response completes it. Response semantics are strict by default: composed
receive rejects status codes outside 100..599 and only reports a `101` protocol
switch after validating the response's Upgrade field and `Connection: Upgrade`
option. Diagnostic/proxy tooling that deliberately accepts invalid HTTP can opt
out with `.{ .validate_responses = false }` and apply its own policy.

The protocol selected by a valid 101 still belongs to the application: compare
it with the Upgrade protocols offered by the corresponding request before
handing transport bytes to that protocol.

## Send path

`MessageWriter.beginRequest()` and `beginResponse()` preflight the complete head
before the first byte is emitted. HTTP/1.1 absolute-form requests must provide a
Host value derived from the request-target authority; a mismatch fails before
output. Response preflight includes the 100..599 status range and structural 101
Upgrade handshake. `writeData()` then enforces
the selected body framing and exact Content-Length accounting. `finish()` completes fixed/chunked
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
particular, `http1.write.responseHead()` retains syntax-level support for any
three-digit status so diagnostic tooling can reproduce invalid wire input, and
`http1.write.endChunks()` serializes trailers without application field-definition
policy. Callers using these raw APIs own the corresponding semantic checks.

URI wire-syntax helpers shared by HTTP/1 and HTTP/2 are available under
`http.uri`; they perform no DNS resolution or normalization.
