# Migration guide

The package is pre-1.0 and intentionally removes obsolete compatibility surfaces
rather than carrying aliases indefinitely. Release notes remain authoritative;
this document highlights source-level migration patterns.


## 0.19.x to 0.20.x

High-level cancellation is now explicit. HTTP/1 clients can call `cancelRequestBody()` to abandon an unfinished outbound body; because HTTP/1 has no stream reset, the connection becomes non-reusable while the already queued response context remains available to drain. HTTP/2 clients can call `cancelRequest(out, stream_id)`, which sends `RST_STREAM(CANCEL)` and reclaims the bounded stream slot only after a successful write.

HTTP/2 high-level drain/scheduling code can use `activeLocalStreams()`, `activeRemoteStreams()`, `activeStreams()`, `retainedStreams()`, and `streamsDrained()` instead of inspecting the bundled Session/store directly. The existing `resetStream()` + explicit `reclaimStream()` path remains the lower-level choice when an application wants to retain a closed record after reset.


### Additional 0.20.0 lifecycle changes

High-level transport EOF handling is now explicit and fail-closed. HTTP/1
`finishReceive()` latches `failed` on truncated EOF and treats clean EOF as a
non-reusable connection boundary; servers preserve already parsed pipeline order
and force only the final queued response to close. HTTP/2 adds
`finishReceive(pending_input)` / `peerReceiveClosed()`: pass any bytes that the
last `receive()` could not consume, otherwise a partial frame or unfinished
CONTINUATION block cannot be distinguished from clean EOF. Clean HTTP/2 EOF
enters `draining`; truncated EOF enters `failed`.

`canOpenRequest()` is now backed by `requestAvailability()`, which also reports
peer-concurrency and bounded-store backpressure plus stream-ID exhaustion. Code
that needs to schedule fairly should switch on `requestAvailability()` rather
than treating every false result as GOAWAY.

High-level terminal send/receive ordering is stricter. HTTP/1 clients now latch a terminal high-level receive failure when a structurally valid `101` selects an unoffered protocol; `protocolSwitched()` stays false, `lifecycle()` reports `failed`, and client `writeData()` / `finish()` return `ConnectionFailed`. Subsequent receive calls return `ReceiveFailed`; close the transport.

For HTTP/2, `start(out)` is now the only operation allowed to emit the local connection preface. `sendResponse`, `sendData`, `sendTrailers`, `sendPing`, non-empty `sendControl`, receive-credit flushes, stream resets, GOAWAY, and graceful-GOAWAY helpers return `NotStarted` until initial SETTINGS has been emitted. A server may still call `receive()` before `start()`; it must call `start()` before serializing any response/control frame. `controlForReceiveError()` returns `.none` for failures that occur before local start, because a GOAWAY cannot precede the mandatory initial SETTINGS frame.

The high-level HTTP/2 connection now owns runtime local SETTINGS updates rather
than exposing its internal `SettingsSync`. `settingsSync()`, `localSettings()`,
and `localSettingsActive()` are removed. Use `configuredInitialSettings()`,
`acknowledgedLocalSettings()`, `effectiveLocalSettings()`,
`pendingLocalSettings()`, and `initialSettingsAcknowledged()` instead. Send a
new complete policy snapshot with `sendLocalSettings(out, next)`; high-level
composition serializes updates and returns `SettingsPending` while one snapshot
is awaiting ACK.

`LocalSettings.max_header_list_size` is now a `u32` rather than `?u32`. The
default is `std.math.maxInt(u32)`, which is both the largest value expressible by
SETTINGS_MAX_HEADER_LIST_SIZE and a value that can be explicitly restored by a
later runtime update. Replace `.max_header_list_size = null` with the default or
`std.math.maxInt(u32)`.

SETTINGS enforcement is now asymmetric around the ACK boundary. Receive-side
expansions that the peer can use immediately after processing the frame are
accepted immediately; restrictions wait for the matching ACK. HPACK table-size
changes remain ACK-synchronized. This also fixes streams created while an
increased INITIAL_WINDOW_SIZE is in flight.

The project now documents explicit pre-1.0 stability tiers in
[`stability.md`](stability.md), and the 1.0-candidate composed method families
are covered by a compile-time smoke contract.

High-level lifecycle enforcement is now fail-closed. HTTP/2 client
`sendRequest()` must follow `start()` and returns `NotStarted` before the local
preface; after either GOAWAY direction it returns `ConnectionDraining` instead
of exposing the lower-level `GoAway` error. Ordinary application sends return
`ConnectionFailed` after a terminal composed receive/send failure, while
`sendControl()` remains usable for the terminal GOAWAY. Use `canOpenRequest()`
when a scheduler wants to test request-stream eligibility without attempting a
send.

HTTP/1 high-level clients now integrate `Expect: 100-continue` directly. When a
request with content carries `expectContinue()`, `writeData()`/`finish()` return
`ContinuePending` until a 100 response arrives or the application calls
`proceedWithoutContinue()`. `continuePhase()` exposes the gate state. A final
response received before the active request content completes abandons the
remaining body and makes the transport closing; code that previously sent the
body regardless of the early final response must instead open a new connection
for subsequent requests.


## 0.18.x to 0.19.x

The pre-1.0 high-level APIs intentionally remove ambiguous compatibility forms.
For HTTP/2, replace `Config.hpack_table_size` / `Config.local_limits` and
`start(out, settings)` with one `Config.local_settings`; call `start(out)` and
`receive(input)`. The configured SETTINGS now drive the initial wire frame, HPACK
decoder policy, stream limits, and receive `SETTINGS_MAX_FRAME_SIZE`. Restrictive
policy is activated only when the initial SETTINGS ticket is ACKed, so no caller
has to coordinate the RFC synchronization boundary manually. Mandatory
SETTINGS/PING/fault responses are exposed as `ReceiveResult.control` and can be
written with `sendControl`. Header collector exhaustion is now terminal for the
high-level receive path instead of returning an empty field list with an
`overflowed` flag.

HTTP/1 high-level Upgrade handling now retains a bounded exact offer per pending
request. `sendResponse(101, ...)` validates the selected protocol automatically,
and clients reject unsolicited or unoffered 101 responses. Increase
`Config.upgrade_offer_bytes` if an application intentionally uses unusually large
Upgrade lists; no compatibility boolean-only mode is retained.

High-level connections now expose `Storage` and `init*InPlace` constructors.
Existing allocator constructors remain valid, but applications that want stable
caller-owned memory can remove the wrapper-state allocation directly. HTTP/2
callers should keep the in-place storage address stable and still pass an
allocator for HPACK dynamic-table memory. Common lifecycle calls such as HTTP/2
trailers and graceful GOAWAY no longer require dropping to `core()`.

## 0.16.x to 0.17.x

### Route HTTP/1 requests with `effective_authority`

`http1.semantics.RequestInfo` and composed request `HeadEvent` values now expose
`effective_authority`. Use it for routing instead of assuming the Host field is
authoritative. Absolute-form requests use the authority from request-target and
CONNECT uses authority-form; origin/asterisk requests use Host. Send-side
`MessageWriter.beginRequest()` now rejects an HTTP/1.1 absolute-form request when
Host does not match the request-target authority (excluding userinfo).

### Composed HTTP/1 response validation is stricter

`ConnectionDecoder` response mode now validates HTTP response semantics by
default. Status codes outside 100..599 and structurally invalid 101 Upgrade
responses fail before a protocol-switch event is exposed. Diagnostic tools that
intentionally accept non-HTTP responses can set:

```zig
.{ .validate_responses = false }
```

`MessageWriter.beginResponse()` always applies the strict send-side checks before
writing. The raw `http1.write.responseHead()` remains a syntax-level escape hatch.

### Shared URI validation

HTTP/1 request-target and HTTP/2 pseudo-field validation now share `http.uri`.
Malformed percent escapes, authority syntax, IP literals, and HTTP(S) userinfo
therefore have one implementation and one behavior across protocol versions.

## 0.17.x to 0.18.x

### HTTP/2 Session store and field sink contracts

The composed HTTP/2 `Session` now requires each stored stream to expose
`bodyState(id) ?*http2.fields.BodyState`. Keep that state beside the existing
`Tracked` record and reset it to `.{}` when a store slot is reused; Session owns
its protocol transitions but not its allocation/storage. A local request begins
in `awaiting_headers`, then final response headers establish Content-Length,
no-content, or tunnel semantics for subsequent DATA.

Field sinks are now transactional. Add no-throw `begin(stream_id, kind)`,
`commit(stream_id, kind)`, and `abort(stream_id, kind)` methods around the existing
`field(...)` callback. Stage mutations after `begin`; publish them on `commit`;
discard them on `abort`. Do not retain borrowed HPACK slices without copying.

HTTP/2 request validation also rejects conflicting `Host` and `:authority` after
URI normalization, including on send preflight. Applications that deliberately
need malformed-message inspection should use lower-level HPACK/frame composition.

## 0.15.x to 0.16.x

### Prefer owning namespaces

HTTP/2 low-level declarations live under the namespace that owns their protocol
responsibility. Replace old flat compatibility aliases with paths such as:

```text
http.http2.FrameDecoder      -> http.http2.frame.FrameDecoder
http.http2.FlowWindow        -> http.http2.flow.FlowWindow
http.http2.StreamManager     -> http.http2.streams.Manager
```

HTTP/1 raw functionality similarly lives under `http1.head`, `http1.body`,
`http1.semantics`, and `http1.write`.

The intended composed shortcuts remain:

```zig
http.http1.ConnectionDecoder
http.http1.MessageWriter
http.http2.Session
http.http2.Event
http.http2.Role
```

### Session construction

Construct HTTP/2 Session with named options rather than positional arguments:

```zig
var session = http.http2.Session.init(.{
    .role = .client,
    .decoder = &decoder,
    .encoder = &encoder,
    .header_storage = header_storage[0..],
});
```

Use the compiler diagnostics in `http2.contracts` and the reference store/sink in
`examples/support/` when adapting caller-owned storage.

### HTTP/1 sending

For complete message coordination, migrate manual head/body/framing bookkeeping
to `http1.MessageWriter`. Raw functions under `http1.write` remain available when
the application deliberately owns the surrounding state machine.

Non-empty chunked trailers through `MessageWriter` require an explicit
field-definition policy with `finishWithTrailerPolicy(...)`.

### Client preface

Use:

```zig
http.http2.preface.bytes
```

for the HTTP/2 client connection preface.

### New semantic validation

HTTP/2 request pseudo-fields now receive URI/request-target semantic validation,
including traditional CONNECT authority-form requirements. If an application
previously depended on accepting malformed or non-HTTP-compliant targets, move
that specialized behavior to lower-level composition rather than weakening the
composed Session path.

### RFC 9218

Use `http2.priority` for Priority Field Value and PRIORITY_UPDATE parsing and
serialization. `priority.State` is available when the application wants standard
request/update defaults and response omission overlays without adopting a core
scheduler policy.
