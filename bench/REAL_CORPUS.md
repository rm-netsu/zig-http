# Real-world benchmark corpus

The benchmark corpus is built from public HTTP/HAR captures rather than generated
`example.com` strings. Only request/response header fields needed by the benchmark
are vendored; response bodies are not included.

Sources:

- Open Bus Map Search Playwright HAR, `tests/HAR/timeline.har`:
  `https://github.com/hasadna/open-bus-map-search/blob/main/tests/HAR/timeline.har`
- Caroline S. Lebar portfolio HAR:
  `https://gist.github.com/jlebar/9b790889d18900b75fdaf2b8e67450d9`
- Rubydoc `net-ssh` HAR:
  `https://gist.github.com/baelter/3a5f900a83bd481ffe902afd565aafe7`
- Twitter HTTP/2 HAR sample:
  `https://gist.github.com/samccone/e36c31bc80f75a13f138435772b18c2c`
- UAEPass HAR containing Google Fonts traffic:
  `https://gist.github.com/DInuwan97/57f5828738ccf56d96e237a789d51f1c`
- mitmproxy issue #6547, containing a real HTTP/2 PyPI `HEAD` + ranged-download
  trace and HAR:
  `https://github.com/mitmproxy/mitmproxy/issues/6547`

## Normalization

- Header names are normalized to lowercase for HTTP/2.
- Pseudo-header fields are retained when the capture contains them. If a HAR
  exporter omitted them, `:method`, `:scheme`, `:authority`, `:path`, or
  `:status` are reconstructed from the captured method, URL, and status.
- Tracking-cookie identifiers in public captures are redacted while preserving
  realistic cookie syntax and approximate size. No authorization secret is
  vendored.
- Different authorities use separate benchmark connection contexts. In
  particular, `fonts.googleapis.com` and `fonts.gstatic.com` do not share HPACK
  state.
- Where the HAR exposes a connection identifier, multiple requests recorded on
  the same HTTP/2 connection are kept together. The Twitter media scenario uses
  several `abs.twimg.com` exchanges from connection `833177`.
- Captured field order is preserved as far as possible, except that reconstructed
  HTTP/2 pseudo-fields are placed before regular fields as required by HTTP/2.

The fixture is intentionally static and offline so A/B runs are deterministic and
do not depend on current network content.

## zig-http benchmark projection

The HTTP benchmark reuses the captured HTTP/2 fields in two ways:

- HTTP/2 validation consumes the captured field blocks directly.
- HTTP/1 head fixtures project the same method, path, authority, status, and
  regular fields onto HTTP/1.1 wire syntax. This isolates HTTP/1 parser cost
  while keeping field names, values, path lengths, cookie sizes, and response
  metadata grounded in real captures.

For body/framing benchmarks, captured `content-length` values determine DATA and
chunked-body sizes. The payload bytes themselves are deterministic generated
bytes because the protocol core does not inspect application body content.
Chunk boundaries are deliberately varied and are therefore modeled rather than
claimed to come from the HAR files.

HTTP/2 HEADERS payloads are HPACK-encoded once during fixture construction using
this repository's pinned HPACK dependency. Fixture construction is excluded from
all timed regions; HPACK performance is measured separately by zig-hpack.

## HTTP parser comparisons

The HTTP/1 fragmented-head workload is measured through both the compact
`HeadParser` and the larger `FramedHeadParser`. This keeps the memory-for-CPU
trade-off visible in the primary benchmark rather than only in a microbenchmark.

The HTTP/2 complete-frame trace is measured twice over the exact same bytes:
once with a direct `parseCompleteFrame` loop and once with
`CompleteFrameIterator`. This prevents iterator-specific optimizations from being
credited unless they beat the simpler complete-frame API on the real trace.


## Isolated HTTP/2 frame projection

`zig build bench-real-frames -Doptimize=ReleaseFast` snapshots the 41 HTTP/2
HEADERS/DATA frame lengths, flags, stream identifiers, and the eight connection
boundaries produced by this corpus with hpack 0.4.1. Payload bytes are replaced
with deterministic noise because the isolated benchmark measures frame and
connection-state overhead rather than HPACK or application-body processing.

The four measured cases (raw/connection state x complete/fragmented) are compiled
as separate executables. This is intentional: Zig 0.16 aggressively inlines the
small frame decoder, and placing unrelated benchmark cases in one executable was
observed to change instruction layout enough to move measured throughput despite
identical library source. Separate executables make A/B decisions substantially
more stable.
