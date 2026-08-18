# Basic TCP client/server composition

The high-level connection wrappers own HTTP state, not networking. A complete
synchronous application therefore has two explicit layers:

1. `std.Io.net` (or another runtime) owns sockets, reads, writes, timeouts, TLS,
   DNS, and concurrency.
2. `http.high_level.http1.Connection` or `http.high_level.http2.Connection`
   consumes transport bytes and emits protocol bytes/events.

The runnable examples deliberately keep that seam visible instead of hiding it
behind a package-specific socket adapter:

- [`../examples/http1_tcp_client_server.zig`](../examples/http1_tcp_client_server.zig)
- [`../examples/http2_tcp_client_server.zig`](../examples/http2_tcp_client_server.zig)

Both bind an ephemeral loopback TCP port, start one server thread, run one
client against it, verify the exchange, and exit. This makes them safe to run
inside `zig build check` while leaving the server/client functions directly
reusable in separate processes.

Run them individually with:

```sh
zig build example-http1-tcp
zig build example-http2-tcp
```

## HTTP/1.1 shape

The HTTP/1 example uses caller-owned high-level storage and a normal buffered
TCP reader/writer:

```zig
const Conn = http.high_level.http1.Connection(.{});
var storage: Conn.Storage = undefined;
var conn = Conn.initServerInPlace(&storage);

var socket_reader = stream.reader(io, &read_storage);
var socket_writer = stream.writer(io, &write_storage);
const in = &socket_reader.interface;
const out = &socket_writer.interface;
```

The transport loop appends received bytes to a caller-owned wire buffer and
repeatedly calls `conn.receive()` until no complete event remains. Consumed
bytes are shifted out; partial message bytes stay in the wire buffer for the
next socket read.

The example exercises two pipelined requests:

- `GET /hello` with no request body;
- `POST /echo` with typed `Content-Length` and a streamed body.

The client emits both requests before reading either response. The high-level
connection retains only the response-framing semantics needed to correlate the
ordered responses. The server sends responses through `sendResponse()` and
`writeData()`; no whole-message buffering is required by the library.

For a real service, keep the accept loop outside the per-connection function:

```zig
while (true) {
    const stream = try listener.accept(io);
    // Dispatch `stream` to the runtime/thread/task model chosen by the app.
    // Each connection gets its own Conn.Storage and transport buffers.
}
```

Use `finishReceive()` when the transport reaches EOF so close-delimited HTTP/1
messages can complete correctly. `mustClose()` / `protocolSwitched()` tell the
runtime when ordinary HTTP reuse is no longer valid.

## HTTP/2 prior-knowledge shape

The HTTP/2 runnable example uses cleartext prior-knowledge HTTP/2. TLS/ALPN is
outside `zig-http`; after ALPN selects `h2`, the same connection loop starts at
`Connection.start()`.

```zig
const Conn = http.high_level.http2.Connection(.{});
var storage: Conn.Storage = undefined;
var conn = Conn.initServerInPlace(&storage, allocator);

_ = try conn.start(out); // server SETTINGS, or client magic + SETTINGS
try out.flush();
```

Each transport read is fed to `conn.receive()`. A returned result has three
independent pieces:

- `event` — application-visible HTTP/2 work such as HEADERS or DATA;
- `fields` — copied decoded fields when the event commits a field section;
- `control` — an explicit protocol response such as SETTINGS ACK, PING ACK,
  RST_STREAM, or GOAWAY.

The runtime writes control responses explicitly:

```zig
const result = (try conn.receive(input)) orelse break;
try conn.sendControl(out, result.control);
```

The example multiplexes a bodyless `GET /hello` and a streamed `POST /echo` on
separate streams. After DATA has been consumed by the application, receive
window capacity is returned explicitly:

```zig
conn.releaseData(data);
_ = try conn.flushReceiveCredit(out, data.stream_id);
```

This separation is intentional: application code decides when DATA storage is
actually reusable, so flow-control credit cannot accidentally outrun body
processing.

The finite example sends a clean `GOAWAY` after both responses. A long-lived
server would instead keep accepting streams, and during shutdown can use the
high-level two-phase `announceGracefulGoAway()` / `finishGracefulGoAway()` API.

## Splitting the loopback example into real programs

The example files contain independent `serveOne()` and `runClient()` functions.
To turn them into standalone applications:

- server: replace the loopback setup in `main()` with a fixed/listener address
  and call `serveOne()` from your worker model for every accepted stream;
- client: resolve/connect to the target address and call the same client loop;
- add deadlines/cancellation in the transport/runtime layer;
- for HTTPS, wrap the socket in TLS first and feed only decrypted HTTP bytes to
  the HTTP connection object;
- for HTTP/2 over TLS, call `start()` only after ALPN selected `h2`;
- for connection pooling, keep one high-level connection object per live
  transport and let the pool own transport lifetime/reuse policy.

The examples intentionally do not add routing, DNS, TLS, retries, cookies,
redirects, compression, or pooling because those responsibilities are outside
the protocol engine.
