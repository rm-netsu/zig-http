# Migration guide

The package is pre-1.0 and intentionally removes obsolete compatibility surfaces
rather than carrying aliases indefinitely. Release notes remain authoritative;
this document highlights source-level migration patterns.

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
