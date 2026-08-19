# Operational error and ownership guide

zig-http owns HTTP protocol state, not transports, timers, retry queues, or
application objects. The most important integration rule is to distinguish a
**peer protocol fault**, a **local API/policy error**, and an **I/O failure after
wire state may already have advanced**. They require different recovery.

## Recovery matrix

| Signal | Meaning | Required caller action | Reusable state? |
| --- | --- | --- | --- |
| `http1.ConnectionDecoder.feed()` returns a malformed-message error and `failed()` is true | Peer HTTP/1 message is not safely recoverable on this connection | Stop HTTP parsing and close the transport | No |
| `MessageWriter.begin*()` returns a semantic/framing error before writing | Local request/response is invalid | Fix local data/policy and retry from the idle writer | Yes |
| `MessageWriter.writeData()` returns `ContentLengthMismatch` | Local fixed-length body would overrun, or `finish()` was called before all bytes were sent | Correct the body length/remaining bytes | Yes, unless `failed()` is true |
| `MessageWriter` returns a writer error and `failed()` is true | A HTTP/1 head/body/chunk may be partially on the wire | Close the transport; do not send another HTTP message | No |
| `MessageWriter.mustClose()` | The completed HTTP/1 message selected close semantics | Close after the message; do not start another message | No further HTTP messages |
| `MessageWriter.protocolSwitched()` or `ConnectionDecoder.protocolSwitched()` | HTTP/1 switched to a tunnel/protocol after `101` or successful CONNECT | Hand remaining transport bytes to the tunneled protocol | HTTP state is finished |
| `http2.Bootstrap.receiveBytes()` returns `InvalidPreface` | Peer did not send the required client magic / bootstrap is already failed | Close the HTTP/2 transport; GOAWAY may be omitted for invalid magic | No |
| `http2.Event.fault.connection` | Peer violated a connection-level HTTP/2 rule | Send GOAWAY when possible, then stop the HTTP/2 transport | No |
| `http2.Event.fault.stream` | Peer violated a stream-level HTTP/2 rule | Send RST_STREAM for that stream; keep the connection when the write succeeds | Other streams: yes |
| HTTP/2 send method returns local `Protocol`, `StreamClosed`, `FlowControl`, `PeerLimit`, `StoreFull`, or `GoAway` | Local operation cannot legally be performed in current protocol/application state | Correct policy/state; do not treat this as a peer fault | Usually yes |
| HTTP/2 send method returns `SendPoisoned` | Earlier outbound HPACK/wire state may have advanced partially | Abandon the HTTP/2 transport | No |
| HTTP/2 writer error during a stateful Session send | Transport write failed and Session poisons its send side where partial advancement is possible | Close transport; do not retry on the same Session | No send reuse |
| `dispatch.DataSendGrantError.StaleStreamCredit` | A delayed shard offer was invalidated by a SETTINGS decrease | Re-probe stream credit under the current ordered settings | Yes |

The table describes the composed APIs. Lower-level parsers and writers expose
smaller error sets because the caller is explicitly taking responsibility for
more of the state machine.

## HTTP/1 receive ownership

`http1.ConnectionDecoder` owns only parser/message state. The caller owns the
transport and the scratch buffers passed at initialization.

Event slices borrow caller-owned storage or the current input buffer. Consume or
copy them before the next call that reuses that storage. One `feed()` call emits
at most one event, making this lifetime boundary explicit.

A malformed peer message normally moves the decoder to `failed`. Once
`decoder.failed()` is true, do not attempt to resynchronize by searching for a
later CRLF or request line: HTTP/1 framing ambiguity makes connection reuse
unsafe. Close the transport.

In response mode, the outstanding request method is caller-owned. Call
`beginResponse(method)` before feeding the corresponding response. Informational
responses keep that context; the final response releases it.

## High-level transport lifecycle

At the composed layer, prefer the high-level lifecycle query before returning a
transport to a pool. HTTP/1 reports `closing` for either locally selected,
peer-selected, or clean transport-EOF close semantics and `failed` for truncated
EOF. HTTP/2 reports `draining` once GOAWAY is sent/received or the peer read side
closes cleanly, and `failed` after a terminal composed receive/decode/truncated-EOF
failure. These
queries summarize protocol state only; the application still owns the actual
socket close and retry policy.

A high-level HTTP/1 client also treats Upgrade negotiation failures as terminal.
If a structurally valid 101 selects a protocol that was not retained in the
corresponding request offer, the low-level decoder has already consumed the head,
but the high-level wrapper latches `failed`, suppresses `protocolSwitched()`, and
rejects any remaining request-body writes. Close the transport.

For an HTTP/2 receive error that terminates the composed connection before an
Event exists, `controlForReceiveError(err)` can produce the corresponding GOAWAY
when the failure has a peer-visible RFC error code **and** local initial SETTINGS
has already been emitted. Before `start()`, the helper returns `.none`; close the
transport rather than sending an out-of-order HTTP/2 control frame. All other
high-level HTTP/2 frame-emitting helpers likewise return `NotStarted` until the
local preface has been serialized.

When the transport read side reaches EOF, call the protocol-specific composed
EOF hook before recycling state: `http1.Connection.finishReceive()` or
`high_level.http2.Connection.finishReceive(pending_input)`. For HTTP/2, retain
any bytes not consumed from the final read and pass them to the hook so a partial
frame cannot be mistaken for a clean connection boundary.

## HTTP/1 send ownership

`http1.MessageWriter` owns only send-side message state. It never owns or closes
the `std.Io.Writer`.

`beginRequest()` and `beginResponse()` preflight syntax, framing, and HTTP
semantics before the first byte of a new head is written. Therefore errors such
as `InvalidHeader`, `MissingHost`, `InvalidRequestTarget`, or invalid response
framing leave an idle writer reusable.

After serialization starts, an I/O error can leave bytes partially written.
`MessageWriter` then becomes poisoned. Check `failed()` only when deciding
transport recovery; do not call another HTTP send operation on a poisoned
writer.

Fixed Content-Length mismatch is intentionally recoverable when no I/O failure
occurred. An overrun is rejected before touching the writer. An underrun reported
by `finish()` leaves the fixed message active so the caller can send the
remaining bytes.

`mustClose()` is not an error. It is a protocol result: close-delimited framing
or connection semantics require the transport to close after the current
message. Likewise, `protocolSwitched()` transfers ownership of subsequent bytes
to the tunnel/application protocol.

## HTTP/2 peer faults are values, not Zig errors

Inbound protocol violations are surfaced as `http2.Event.fault` so peer behavior
is not confused with local programming/control-flow errors:

```zig
switch (event) {
    .fault => |fault| switch (fault) {
        .connection => |code| {
            // Serialize GOAWAY if the transport is still writable, then close.
            _ = code;
        },
        .stream => |stream_fault| {
            // Serialize RST_STREAM(stream_fault.stream_id, stream_fault.code).
            // Other streams may continue.
            _ = stream_fault;
        },
    },
    else => {},
}
```

For an existing retained stream, `Session.sendReset()` is the convenient
state-aware path. A stream fault can also be detected before the stream has been
inserted into the caller-owned store. In that case `Session.sendReset()` cannot
look up a record; use the low-level `http2.send.writeReset()` to serialize the
required RST_STREAM, then keep caller-owned state consistent with the fact that
no retained stream was created.

For connection faults, `Session.sendGoAway()` is appropriate when Session state
is still usable and the caller has the desired last-stream-id cutoff. If the
fault occurs in a low-level path or Session cannot be safely mutated, the
allocation-free `http2.send.writeGoAway()` writer is available. Regardless of
which serializer is used, a connection-level fault terminates that HTTP/2
connection after the error response attempt.

Do not convert `Event.fault` into a generic Zig `error.Protocol` and immediately
tear down all streams: that loses the stream-vs-connection scope HTTP/2 uses for
recovery.

## HTTP/2 local errors

Errors from outbound Session methods describe the caller's attempted operation,
not a newly observed peer violation. When a compact `Protocol`/state result is
not descriptive enough, `diagnoseSendHeaders`, `diagnoseSendData`, and
`diagnoseSettings` provide a non-mutating reason pass intended for development
and observability rather than the hot path.

Common examples:

- `Protocol`: the local transition or generated frame is illegal;
- `StreamClosed`: the target retained stream cannot accept the operation;
- `FlowControl`: local send/receive credit would violate HTTP/2 limits;
- `PeerLimit`: peer SETTINGS currently forbid the operation;
- `StoreFull`: caller-owned stream storage declined a required insertion;
- `GoAway`: the requested new work is outside a known GOAWAY cutoff;
- `FrameTooLarge` / `BufferTooSmall`: caller-provided output/staging limits are
  insufficient;
- `StaleStreamCredit`: sharded DATA credit must be re-probed after an ordered
  SETTINGS change.

These errors normally leave the connection usable because the operation is
preflighted. The important exception is send poisoning.

## HTTP/2 send poisoning

HPACK and frame serialization are stateful. Once a writer has accepted only part
of an encoded field block or frame, the remote peer and local compression/wire
state can no longer be assumed synchronized.

Stateful Session send operations therefore poison the send side when a writer
failure may follow partial advancement. Subsequent send APIs return
`error.SendPoisoned`. Treat that as terminal for the transport: do not retry the
same HEADERS/DATA/control operation on that Session.

The receive side is conceptually separate, but a transport whose HTTP/2 send
state is unknown should still be abandoned rather than kept as a receive-only
connection.

## HPACK and field-sink lifetime

HTTP/2 HPACK decoder/encoder state belongs to the ordered connection context.
Do not decode field blocks from one connection with another connection's HPACK
state, and do not process field blocks from one connection concurrently without
providing equivalent ordering externally.

`Session` invokes the caller-owned field sink synchronously while decoding a
field section. Header name/value slices supplied to the sink may borrow HPACK or
caller scratch/input storage. Session calls `begin()` before delivery and exactly
one of `commit()`/`abort()` afterward; application-visible mutation should be
staged until commit. A sink that needs fields after the callback must copy them
into application-owned memory.

A stream-level semantic rejection still consumes the complete HPACK field block
when required to preserve compression synchronization. Do not abort transport
input consumption early just because application policy has already decided to
reject that stream.

## Frame and dispatch buffer lifetime

Complete-frame and dispatch DATA payload slices alias the caller's transport
buffer. If `http2.dispatch` hands work to another thread/shard, the caller must
keep the backing buffer alive until that work is consumed. Core intentionally
does not impose reference counting, copying, or queue ownership.

CONTINUATION/HPACK connection state remains ordered even when DATA, RST_STREAM,
and stream WINDOW_UPDATE work is routed to stream owners.

## Connection and stream concurrency ownership

Independent HTTP/1 or HTTP/2 connection objects may run concurrently. There is
no process-global mutable protocol state.

Within one HTTP/2 connection, SETTINGS, HPACK, connection flow control, stream
identifier ordering, GOAWAY, and CONTINUATION sequencing form one ordered
context. Give that context one logical mutator at a time. Stream records may be
sharded using `http2.dispatch` / detached stream APIs, but effects that order
later connection decisions must be returned to the connection owner as
specified by `StreamEffect.ordersConcurrency()` and `ordersSettings()`.

## Shutdown checklist

For a normal HTTP/1 close:

1. Complete the message.
2. If `MessageWriter.mustClose()` is true, flush as appropriate and close the
   transport.
3. Never start another HTTP message after close semantics or a protocol switch.

For an HTTP/1 parse/write failure:

1. Preserve logs/metrics if desired.
2. Do not search the byte stream for a new message boundary.
3. Close the transport.

For an HTTP/2 stream fault:

1. Serialize RST_STREAM with the reported code.
2. Mark/retain caller-owned stream state consistently with the chosen API path.
3. Continue unrelated streams if the reset write succeeds and the Session is
   not send-poisoned.

For an HTTP/2 connection fault:

1. Attempt GOAWAY with the reported code when the transport is writable.
2. Do not accept new work on that connection.
3. Close the transport after the error response attempt.

For `SendPoisoned` or a partial transport write:

1. Do not retry on the same protocol state.
2. Close the transport.
3. Retry application work only on a fresh connection according to caller-owned
   idempotency/retry policy.
