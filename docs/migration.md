# Migration guide

The package is pre-1.0 and intentionally removes obsolete compatibility surfaces
rather than carrying aliases indefinitely. Release notes remain authoritative;
this document highlights source-level migration patterns.


## 0.18.x Unreleased high-level API cleanup

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
