# HTTP/2 conformance and interoperability

This directory contains an intentionally thin cleartext HTTP/2 prior-knowledge
server around the protocol core. It exists only as a test fixture: sockets and
application responses remain outside the library's core API.

## Test layers

- `run-rfc-smoke.sh` runs raw-wire regression probes modeled after RFC 9113 and
  h2spec cases. It requires Python `hpack` and verifies error **scope** as well as
  error code. Coverage includes the connection preface, stream-ID monotonicity
  and lifecycle, PRIORITY, frame-size rules, padding, SETTINGS bounds and
  extension handling, WINDOW_UPDATE and flow-control overflow, CONTINUATION
  sequencing, HPACK compression errors, HTTP field semantics, Content-Length,
  and the advertised concurrent-stream limit.
- `run-external-interop.sh` drives the fixture with two independent HTTP/2
  implementations: Python `hyper-h2` and curl built with HTTP/2 support
  (normally libnghttp2). The hyper-h2 scenario reuses one connection for 16
  streams, including a streaming POST, multiplexed GETs, HPACK context reuse,
  PING/ACK, and deliberately fragmented TCP writes. curl performs a separate
  prior-knowledge HTTP/2 request and validates the status and body.
- `run-h2spec.sh` runs the complete h2spec `http2`, `hpack`, and `generic` suites
  in strict mode. Set `H2SPEC_BIN` when h2spec is not on `PATH`. Set
  `H2SPEC_JUNIT` to write a JUnit report. The runner fails fast when h2spec is
  unavailable instead of silently treating the raw smoke set as a full pass.

The fixture advertises `SETTINGS_MAX_CONCURRENT_STREAMS=32` so h2spec exercises
its concurrency-limit case instead of skipping it. It always responds to valid
GET/POST requests with status 200 and a non-empty `ok` body, as required by
h2spec's server contract. Request body accounting uses the caller-owned
`http2.fields.BodyLength` helper rather than adding application/message length
state to every core Session stream.

## Commands

```sh
zig build test
./test/conformance/run-rfc-smoke.sh
./test/conformance/run-external-interop.sh
H2SPEC_BIN=/path/to/h2spec ./test/conformance/run-h2spec.sh
```

Override `ZIG`, `PYTHON`, or `HTTP2_TEST_PORT` if needed. The scripts choose a
free loopback port by default and clean up their fixture process automatically.

## RFC 9113 versus h2spec 2.6.0

h2spec 2.6.0 targets RFC 7540/7541 and predates RFC 9113. Its malformed
RST_STREAM-length test has legacy wording/API structure: the prose specifies a
connection `FRAME_SIZE_ERROR`, while the test calls `VerifyStreamError`.
`VerifyStreamError` itself accepts either RST_STREAM or GOAWAY, so an
RFC-correct connection error is still accepted by h2spec. The raw suite is
intentionally stricter and asserts the exact RFC-defined scope; it also covers
some non-zero-stream variants that h2spec does not exercise directly, such as
malformed WINDOW_UPDATE length.
