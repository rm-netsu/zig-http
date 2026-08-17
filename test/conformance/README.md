# HTTP/1 and HTTP/2 conformance and interoperability

This directory contains intentionally thin cleartext transport fixtures around
the protocol core. They are tests, not library APIs: sockets and canned
application responses remain outside `src/http1` and `src/http2`.

## HTTP/1 interoperability

`run-http1-interop.sh` exercises both roles with independent stacks:

- curl plus Python stdlib/raw clients drive the Zig HTTP/1 server fixture over
  persistent connections, HEAD, Content-Length POST, pipelining, chunked
  extensions/trailers, and malformed Host handling.
- the Zig HTTP/1 client fixture drives an independent raw Python server through
  103 informational responses, HEAD, chunked trailers, deliberately fragmented
  writes, and close-delimited EOF semantics.

The fixtures use `http1.ConnectionDecoder` and the ordinary HTTP/1 writers; no
socket behavior is embedded into the library itself.

## HTTP/2 test layers

- `run-rfc-smoke.sh` runs raw-wire regression probes modeled after RFC 9113 and
  h2spec cases. It requires Python `hpack` and verifies error **scope** as well
  as error code. Coverage includes the connection preface, stream-ID
  monotonicity/lifecycle, PRIORITY, frame-size rules, padding, SETTINGS,
  WINDOW_UPDATE/flow-control overflow, CONTINUATION sequencing, HPACK errors,
  HTTP field semantics, Content-Length, and concurrency limits.
- `run-external-interop.sh` is bidirectional. Python `hyper-h2` and
  curl/libnghttp2 drive the Zig server fixture, while a Zig `Session` client
  drives an independent hyper-h2 server. Scenarios include multiplexing,
  fragmented transport writes, POST DATA, informational responses, HEAD,
  trailers, SETTINGS/PING synchronization, and RFC 8441 Extended CONNECT in
  both directions. The Zig client waits for the peer capability before sending
  `:protocol`, exercising negotiation rather than only field syntax.
- `run-h2spec.sh` runs complete h2spec `http2`, `hpack`, and `generic` suites in
  strict mode. Set `H2SPEC_BIN` when h2spec is not on `PATH`; set
  `H2SPEC_JUNIT` for a JUnit report. Missing h2spec is an explicit failure, not
  a silent substitution with the smoke suite.

The HTTP/2 server fixture advertises `SETTINGS_MAX_CONCURRENT_STREAMS=32` so
h2spec executes its concurrency case and sends an 8-byte `zig-http` response so
its dynamic/negative flow-window cases are not skipped. It also advertises
`SETTINGS_ENABLE_CONNECT_PROTOCOL=1` for RFC 8441 interoperability; h2spec 2.6.0
predates that extension and correctly treats the setting as an ignorable
extension parameter.

Request Content-Length accounting uses caller-owned `http2.fields.BodyLength`
rather than adding application-message length state to every Session stream.
Each fixture connection owns an independent Session; the test server uses worker
threads only so helper/test connections cannot block acceptance of another
connection. That threading model is not imposed on consumers.

## Commands

```sh
zig build check
./test/conformance/run-http1-interop.sh
./test/conformance/run-rfc-smoke.sh
./test/conformance/run-external-interop.sh
H2SPEC_BIN=/path/to/h2spec ./test/conformance/run-h2spec.sh
```

Override `ZIG`, `PYTHON`, or the test ports when needed. Scripts choose free
loopback ports by default and clean up fixture processes automatically.

## RFC 9113 versus h2spec 2.6.0

h2spec 2.6.0 targets RFC 7540/7541 and predates RFC 9113. Its malformed
RST_STREAM-length testcase has legacy wording/API structure: the prose specifies
a connection `FRAME_SIZE_ERROR`, while the test calls `VerifyStreamError`.
`VerifyStreamError` accepts either RST_STREAM or GOAWAY, so an RFC-correct
connection error remains accepted. The raw suite intentionally asserts the
exact current-RFC scope and includes variants h2spec does not exercise directly.
