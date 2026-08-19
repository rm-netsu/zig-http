# Basic TCP client/server composition

The high-level connection wrappers own HTTP state, not networking. A complete
synchronous application therefore has two explicit layers:

1. `std.Io.net` (or another runtime) owns sockets, reads, writes, timeouts, TLS,
   DNS, and concurrency.
2. `http.high_level.http1.Connection` or `http.high_level.http2.Connection`
   consumes transport bytes and emits protocol bytes/events.

The runnable examples keep that seam visible and are split into independent
programs:

- HTTP/1.1 server: [`../examples/http1_tcp_server.zig`](../examples/http1_tcp_server.zig)
- HTTP/1.1 client: [`../examples/http1_tcp_client.zig`](../examples/http1_tcp_client.zig)
- HTTP/2 prior-knowledge server: [`../examples/http2_tcp_server.zig`](../examples/http2_tcp_server.zig)
- HTTP/2 prior-knowledge client: [`../examples/http2_tcp_client.zig`](../examples/http2_tcp_client.zig)

The HTTP/1 examples use `127.0.0.1:18080`; the HTTP/2 examples use
`127.0.0.1:18081`.

## Running HTTP/1.1

Start the server in one terminal:

```sh
zig build example-http1-server
```

Then run the client in another:

```sh
zig build example-http1-client
```

The server remains in its accept loop. The client opens one connection,
pipelines `GET /hello` and `POST /echo`, verifies both response bodies, and
exits.

The server allocates one independent high-level state object per accepted
connection:

```zig
var connection_storage: Conn.Storage = undefined;
var server = Conn.initServerInPlace(&connection_storage);
defer server.deinit();
```

Each socket read is appended to a caller-owned wire buffer. Complete events are
consumed through `server.receive()`, while an incomplete head/body fragment is
left in the buffer for the next transport read. Response bodies are streamed
with `writeData()`; `zig-http` does not require whole-message buffering.

The client deliberately sends both requests before it starts reading. The
high-level HTTP/1 connection retains only the bounded response-framing context
needed to correlate pipelined responses:

```zig
_ = try client.sendRequest(
    out,
    h1.message.RequestFields.origin("GET", "/hello", server_authority),
    &.{},
);

var length = h1.message.ContentLength.init(5);
_ = try client.sendRequest(
    out,
    h1.message.RequestFields.origin("POST", "/echo", server_authority),
    &.{ length.header(), h1.message.header("connection", "close") },
);
_ = try client.writeData(out, "hello");
```

Call `finishReceive()` when the transport reaches EOF so close-delimited HTTP/1
messages can complete correctly. `mustClose()` and `protocolSwitched()` tell
the transport owner when normal HTTP connection reuse is no longer valid.

## Running HTTP/2 prior knowledge

Start the cleartext HTTP/2 server:

```sh
zig build example-http2-server
```

Run the separate client:

```sh
zig build example-http2-client
```

The client sends two concurrent streams (`GET /hello` and `POST /echo`). The
server responds on both streams, returns consumed DATA flow-control credit, and
finishes that finite connection with GOAWAY before accepting the next TCP
connection.

Both peers begin HTTP/2 using the composed bootstrap:

```zig
var connection_storage: Conn.Storage = undefined;
var conn = Conn.initServerInPlace(&connection_storage, allocator);
defer conn.deinit();

_ = try conn.start(out);
try out.flush();
```

For a client, the same `start()` writes client magic plus initial SETTINGS. For
a server, it writes initial SETTINGS and `receive()` incrementally validates the
client preface.

Each receive result separates application work from required protocol output:

```zig
const result = (try conn.receive(input)) orelse break;
try conn.sendControl(out, result.control);

if (result.event) |event| {
    // Handle committed HEADERS, DATA, GOAWAY, and so on.
}
```

After the application is finished with DATA bytes, return receive credit
explicitly:

```zig
conn.releaseData(data);
_ = try conn.flushReceiveCredit(out, data.stream_id);
```

This prevents flow-control credit from getting ahead of actual body processing.

The finite server keeps parsing already-sent peer control bytes after its final
GOAWAY, then calls `finishReceive(pending_input)` at TCP EOF. This both avoids
turning an otherwise clean close into a reset while SETTINGS ACK/WINDOW_UPDATE
bytes are still unread and proves that no partial HTTP/2 frame was silently
discarded at the transport boundary.

## Build/check behavior

The four standalone TCP programs are compiled by:

```sh
zig build examples
zig build check
```

They are not automatically executed by those aggregate targets because the two
servers intentionally remain in accept loops. Run the protocol-specific
`example-*-server` and `example-*-client` targets explicitly when exercising the
network examples.

## Adapting to a real application

The examples intentionally keep transport responsibilities outside `zig-http`:

- dispatch each accepted stream to your chosen thread/task/event-loop model;
- assign one high-level connection state object to each live transport;
- add deadlines and cancellation in the runtime layer;
- for HTTPS, terminate TLS outside the HTTP state machine and feed decrypted
  bytes to the HTTP connection;
- for HTTP/2 over TLS, call `start()` after ALPN selects `h2`;
- keep DNS, connection pooling, retries, redirects, cookies, content decoding,
  routing, and WebSocket implementations in their own layers.

The protocol engine remains usable at lower levels when an application needs
custom storage, scheduling, or transport integration.
