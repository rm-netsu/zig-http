# Benchmarks

These microbenchmarks exercise parser hot paths without networking, TLS, or HPACK work. They are regression tests for protocol-core overhead rather than end-to-end HTTP throughput claims.

Run with Zig 0.16.0:

```sh
zig build bench -Doptimize=ReleaseFast
```

Wire data is mutated from the runtime clock before timing so the parser cannot be folded into compile-time constants. The HTTP/2 field benchmark also mutates one field value at runtime.

## 0.10.0 send-session regression check

The 0.10.0 control-send work adds separate Session methods and does not modify
the existing HEADERS/DATA hot path. Because Zig 0.16 code layout can still move
when unrelated functions are added to the same module, the isolated
`bench-real-send-session` executables were re-run five times after the change.
Median throughput from those direct runs was 1.001 M tx/s for manual
composition, 0.983 M tx/s for the lookup Session, and 0.967 M tx/s for the
stable-cursor Session. All cases retained 13,835.6 wire bytes per transaction.

These values are within the normal host-to-host/run-to-run spread of the 0.9.0
measurements and do not indicate a HEADERS/DATA regression. Control frames are
not given a synthetic throughput benchmark because SETTINGS/PING/GOAWAY/reset
frequency is application- and failure-driven; their primary regression coverage
is serialization/state-transition correctness.

## 0.9.0 send-session results

The send-side Session is measured in isolated executables so outbound HPACK and
frame-writing code in one case cannot affect the code layout of another:

```sh
zig build bench-real-send-session -Doptimize=ReleaseFast
```

The fixture uses the same eight connection scenarios and fourteen captured
request/response exchanges as the receive-side corpus. Each scenario owns an
independent HPACK encoder and monotonically increasing stream IDs. Response
field blocks use the same production-like indexing policy as the standalone
HPACK real-world benchmark: sensitive fields are never indexed, volatile values
are sent without indexing, and stable fields use incremental indexing. DATA
sizes come from captured `content-length` values and are split at 16 KiB. After
each DATA frame the harness models WINDOW_UPDATE so the timed path measures
steady-state framing/backpressure rather than stopping at the initial 65,535-byte
credit.

Nine direct runs of the already-built executables, rotated in order and pinned
to one physical CPU, produced these medians:

| Send composition | Median throughput | Field encode rate | Wire bytes/tx |
| --- | ---: | ---: | ---: |
| Manual `Validator + StreamManager + HeaderFramer + Encoder` | 0.990 M tx/s | 15.633 M fields/s | 13,835.6 B |
| `Session.sendHeaders()` + `sendData()` | 0.973 M tx/s | 15.364 M fields/s | 13,835.6 B |
| Stable `StreamCursor` + `sendHeadersExisting()` / `sendDataExisting()` | 0.970 M tx/s | 15.308 M fields/s | 13,835.6 B |

The lookup Session is therefore about 1.7% below equivalent manual composition
on this body-heavy fixture while adding field-section semantics, GOAWAY checks,
peer frame-size enforcement, both send windows, and explicit backpressure. The
stable-cursor case is deliberately reported even though this fixed-array store
is too cheap for it to win: it is statistically neutral/slightly slower here and
must not be presented as a synthetic speedup. Its purpose is to let applications
with more expensive hash/slab lookup retain a stable caller-owned stream pointer.

All three paths emit exactly the same logical wire byte count. `Session` remains
128 bytes and `stream.Tracked` remains 12 bytes on x86_64. Outbound field blocks
do not need a complete-block scratch allocation: the caller supplies a staging
buffer of `N + 1` bytes, which yields at most `min(N, peer MAX_FRAME_SIZE)` bytes
per HEADERS/CONTINUATION payload. The extra byte is lookahead used solely to
place END_HEADERS correctly when the block length is exactly frame-sized.

## 0.8.0 session-composition results

The optional `Session` layer is measured separately so its generic dispatch does
not perturb the existing frame/stream executables:

```sh
zig build bench-real-session -Doptimize=ReleaseFast
```

Both cases process the same normalized real response field blocks and captured
response body sizes. HEADERS are HPACK/Huffman encoded before timing; the timed
path decodes and validates those real values, applies connection and stream
state, consumes DATA in <=16 KiB chunks, and returns receive credit. Dynamic
indexing is intentionally disabled for this orchestration benchmark so the same
wire blocks can be replayed without resetting HPACK connection state; the
standalone HPACK real-world suite remains the source of truth for dynamic-table
performance.

The two benchmark cases are separate executables. Seven direct runs pinned to
CPU 0 produced these medians:

| Session composition | Median throughput | Field decode rate |
| --- | ---: | ---: |
| Manual `ConnectionState + Decoder + Validator + StreamManager` | 0.672 M tx/s | 10.616 M fields/s |
| `Session.receiveComplete()` | 0.654 M tx/s | 10.325 M fields/s |

The high-level layer is therefore about 2.7% below the equivalent manual
composition on this fixture while also handling CONTINUATION, request/response/
trailer phase, SETTINGS effects, WINDOW_UPDATE routing, RST_STREAM, GOAWAY, and
PUSH_PROMISE. The manual primitives remain available for applications that want
the last few percent or a different dispatch policy.

State sizes on x86_64:

| Type | Size |
| --- | ---: |
| `http2.Session` | 128 B per connection |
| `http2.stream.Tracked` | 12 B per stored stream |
| caller continuation storage | configurable |

`Tracked` does not grow in 0.8.0: the incoming field-section phase occupies
previous alignment padding. `header_block.Collector` also no longer requires a
complete single-frame field block to fit continuation storage; storage capacity
limits only blocks that actually span CONTINUATION frames.

## 0.7.0 stream-manager results

The stream layer has its own isolated target because frame-parser measurements
previously demonstrated that unrelated code in the same executable can alter Zig
0.16 inlining and instruction layout:

```sh
zig build bench-real-streams -Doptimize=ReleaseFast
```

Each case is a separate executable. The fixture uses response body lengths from
the same offline real-world corpus, DATA chunks no larger than 16 KiB, odd client
stream IDs, and caller-owned fixed O(1) storage. Five direct runs of the final
executables produced these medians:

| Isolated stream lifecycle | Median |
| --- | ---: |
| Raw primitives, lookup on frame operations | 112.884 M tx/s |
| `StreamManager`, lookup API | 91.961 M tx/s |
| Raw primitives, stable `Tracked*` | 147.771 M tx/s |
| `StreamManager` + `StreamCursor` | 119.748 M tx/s |
| Raw primitives, 64 simultaneously active streams | 108.840 M tx/s |
| `StreamManager`, 64 simultaneously active streams | 111.301 M tx/s |

The sequential cases intentionally maximize protocol-dispatch overhead and show
about a 19% cost for the full manager checks. The multiplexed case is closer to
the intended HTTP/2 use: all 64 request streams are opened before responses are
completed in permuted order. There the manager is effectively flat versus the
manual `Stream + Windows` baseline within run-to-run noise.

The stable-pointer cases are substantially faster than repeated store lookup for
both raw and managed paths. This is why the library exposes `StreamCursor` as an
opt-in short-lived cursor rather than putting a cache inside persistent connection
state.

State sizes on x86_64:

| Type | Size |
| --- | ---: |
| `http2.StreamManager` | 36 B |
| `http2.StreamCursor` | 24 B temporary |
| `http2.stream.Tracked` | 12 B per stored stream |
| `http2.StreamReceiveResult` | 1 B |

The manager performs no heap allocation. Store allocation, tombstone retention,
and reclamation policy remain outside the protocol core.

## 0.6.0 connection-state results

The broad `zig build bench-real -Doptimize=ReleaseFast` workload is intentionally
unchanged from 0.5.0. Five runs of the 0.6.0 candidate produced the following
medians on the same x86_64 Linux host:

| Scenario | 0.6.0 median |
| --- | ---: |
| HTTP/1 real request+response heads, contiguous | 879,289 tx/s |
| HTTP/1 real heads, compact fragmented parser | 552,373 tx/s |
| HTTP/1 real heads, streaming framed parser | 656,256 tx/s |
| HTTP/1 captured-length fixed bodies | 128.3 M bodies/s |
| HTTP/1 modeled chunked bodies | 329,747 bodies/s |
| HTTP/2 real field blocks | 5.468 M blocks/s |
| HTTP/2 complete trace, direct `parseCompleteFrame` loop | 269.95 M frames/s |
| HTTP/2 complete trace, `CompleteFrameIterator` | 295.38 M frames/s |
| HTTP/2 fragmented real frame trace | 33.90 M frames/s |
| Mixed real headers, 4 threads | 2.469 M tx/s |

During development, adding unrelated connection benchmark functions to the same
large executable changed the measured inlined `FrameDecoder` rate by more than
30% even though `frame.zig` itself was unchanged. This was a benchmark code-layout
artifact, not a library regression. HTTP/2 connection/frame decisions therefore
use a second target:

```sh
zig build bench-real-frames -Doptimize=ReleaseFast
```

Each row in this target is a **separate executable** built from the same captured
41-frame layout. That prevents one case from changing another case's inlining or
instruction layout. Five direct runs of each final executable produced:

| Isolated frame case | Median |
| --- | ---: |
| Per-connection complete, raw frame + continuation state | 298.22 M frames/s |
| Complete + `ConnectionState` | 291.09 M frames/s |
| Per-connection fragmented raw `FrameDecoder` | 34.45 M frames/s |
| Fragmented + `ConnectionState` | 33.94 M frames/s |

Connection-wide CONTINUATION and receive-flow accounting therefore cost about
2.4% on the complete-frame path and about 1.5% on the fragmented path in this
fixture. No heap allocation is introduced.

New state sizes on x86_64:

| Type | Size |
| --- | ---: |
| `http2.ConnectionState` | 8 B |
| `http2.ConnectionDecoder` | 28 B |
| `http2.ConnectionCompleteIterator` | 40 B temporary |
| `http2.PeerState` | 36 B |
| `http2.stream.Windows` | 8 B |
| `http2.stream.Tracked` | 12 B |
| `http2.settings.StreamDecoder` | 7 B |

The isolated frame benchmark is the primary criterion for future frame/connection
hot-path changes. The broad benchmark remains the primary criterion for HTTP/1,
field validation, and mixed protocol workloads.

## 0.5.0 real-world results

The primary 0.5.0 comparison uses `zig build bench-real -Doptimize=ReleaseFast`.
Five consecutive runs of the final candidate were collected on the same x86_64
Linux host; the values below are medians. The direct and iterator HTTP/2 rows
consume the exact same 41-frame HEADERS/DATA trace.

| Scenario | 0.5.0 median |
| --- | ---: |
| HTTP/1 real request+response heads, contiguous | 879,021 tx/s |
| HTTP/1 real heads, compact fragmented parser | 547,650 tx/s |
| HTTP/1 real heads, streaming framed parser | 651,649 tx/s |
| HTTP/1 captured-length fixed bodies | 128.3 M bodies/s |
| HTTP/1 modeled chunked bodies | 323,413 bodies/s |
| HTTP/2 real field blocks | 5.412 M blocks/s |
| HTTP/2 complete trace, direct `parseCompleteFrame` loop | 265.7 M frames/s |
| HTTP/2 complete trace, `CompleteFrameIterator` | 295.0 M frames/s |
| HTTP/2 fragmented real frame trace | 33.80 M frames/s |
| Mixed real headers, 4 threads | 2.259 M tx/s |

`FramedHeadParser` is 48 bytes on x86_64 versus 24 bytes for `HeadParser`. In
the full real-world suite it improves fragmented-head throughput by about 19.0%.
A pinned single-core parser-only run over the same head corpus measured 549,565
versus 670,996 tx/s, about 22.1%. It is therefore kept as an opt-in
memory-for-throughput path; the compact parser remains unchanged.

The 20-byte HTTP/2 `FrameDecoder` is unchanged in size. Against the older 0.4.x
real-world baseline, fragmented trace throughput rises from about 24.82 M to
33.80 M frames/s. A pinned frame-only diagnostic comparing the old and new frame
module measured 76.75 M versus 253.39 M frames/s for contiguous incremental calls
and 18.22 M versus 34.19 M frames/s for fragmented reads. These narrow numbers
are diagnostic; the full real trace remains the primary release criterion.

The real trace also corrects an earlier benchmark conclusion: the original
0.4.0 eight-identical-DATA-frame microbenchmark suggested that
`CompleteFrameIterator` was inherently faster. Historical real-trace testing did
not confirm that old implementation. The refined 0.5.0 iterator is retained
because the primary benchmark now compares it directly against a simple
`parseCompleteFrame` loop and measures about an 11.0% advantage on identical input.

Persistent state on x86_64:

| Type | Size |
| --- | ---: |
| `http1.HeadParser` | 24 B |
| `http1.FramedHeadParser` | 48 B |
| `http1.ChunkDecoder` | 32 B |
| `http2.FrameDecoder` | 20 B |
| `http2.FlowWindow` | 4 B |
| `http2.continuation.Guard` | 4 B |
| `http2.header_block.Collector` | 24 B |
| `http2.fields.Validator` | 8 B |
| `http2.CompleteFrameIterator` | 32 B temporary |

## 0.4.0 versus 0.3.0

Five consecutive ReleaseFast runs were collected from clean worktrees on the same x86_64 Linux host. Values below are medians.

| Benchmark | 0.3.0 | 0.4.0 | Change |
| --- | ---: | ---: | ---: |
| HTTP/1 legacy head + separate framing | 2.192 M ops/s | 2.931 M ops/s | 1.34x |
| HTTP/1 incremental framed head | 3.443 M ops/s | 4.313 M ops/s | 1.25x |
| HTTP/1 contiguous framed head | 3.472 M ops/s | 6.494 M ops/s | 1.87x |
| HTTP/2 incremental frame decoder | 280.4 M ops/s | 275.6 M ops/s | ~flat |
| HTTP/2 contiguous complete-frame parser | 606.6 M ops/s | 680.6 M ops/s | 1.12x |
| HTTP/2 request field validation | 8.013 M sets/s | 21.518 M sets/s | 2.69x |

The field-validation result includes the stricter RFC 9113 check that rejects leading/trailing SP and HTAB.

For a buffer containing eight identical 32-byte DATA frames, the original microbenchmark reported about 398.4 M frames/s for repeated `parseCompleteFrame` calls and 442.0 M frames/s for the 0.4.0 iterator. Later real-trace historical testing showed that this result did not generalize; treat it as a historical microbenchmark result rather than evidence that the 0.4.0 iterator was universally faster.

## Memory trade-off

The optimized common validator keeps two 256-byte read-only byte-class tables: one for HTTP token characters and one for scalar field-value tails. This is about 512 bytes per process/module image, not per connection. The existing persistent parser state sizes remain unchanged from 0.3.0:

| Type | Size on x86_64 Linux |
| --- | ---: |
| `http1.HeadParser` | 24 B |
| `http1.ChunkDecoder` | 32 B |
| `http2.FrameDecoder` | 20 B |
| `http2.FlowWindow` | 4 B |
| `http2.continuation.Guard` | 4 B |
| `http2.header_block.Collector` | 24 B |
| `http2.fields.Validator` | 8 B |
| `http2.CompleteFrameIterator` | 32 B temporary |

## Retained implementation choices

- HTTP/1 field values use 8-byte SIMD validation blocks followed by the byte-class table. Larger 16- and 32-byte blocks were slower for the representative short-header workload.
- HTTP token validation is unrolled four bytes at a time. Eight-byte unrolling increased code size and regressed the parser benchmark.
- HTTP/2 field values use 8-byte SIMD blocks. A 256-byte lowercase-name table did not improve the validator enough to justify another global table.
- HTTP/2 frame validation uses one type switch. A special DATA/HEADERS pre-branch did not improve the measured hot path.
- A callback-based complete-frame dispatcher was rejected after real-trace prototypes showed callback/event overhead. The iterator is compared directly with a simple `parseCompleteFrame` loop in `bench-real` instead of being assumed faster.

## Earlier rejected experiments

The 0.3.0 investigations also rejected `std.Io.Writer.writeVecAll` for the tested HTTP/1 and HTTP/2 serialization workloads, manual hexadecimal chunk-size formatting, scalar CR scanning in HTTP/1, and a more branch-minimized HTTP/2 field validator when those variants did not improve measured performance.

## Real-world protocol benchmark

`zig build bench-real -Doptimize=ReleaseFast` is the primary benchmark for
production-facing parser decisions. It uses the offline corpus documented in
`bench/REAL_CORPUS.md` rather than a single fixed request.

It covers:

- contiguous HTTP/1.1 request/response heads projected from captured fields;
- fragmented HTTP/1.1 heads across varied transport-read boundaries;
- chunked-body decoding using captured response sizes and modeled chunk splits;
- HTTP/2 field validation on captured request/response blocks;
- HTTP/2 complete-frame iteration over HEADERS and DATA frames whose HEADERS
  sizes come from real HPACK encoding and whose DATA sizes follow captured
  `content-length` values;
- the same HTTP/2 trace through the incremental decoder with varied read sizes.

Fixture construction and HPACK encoding happen before timing. Timed HTTP parser
and validator paths are allocation-free; state sizes are printed for every run.
The older `zig build bench` target remains useful for focused microdiagnostics,
but optimization decisions should prefer `bench-real` unless a change targets a
path not represented by the corpus.

### Current 0.4.x development baseline

Five consecutive `ReleaseFast` runs on the same x86_64 Linux host produced the
following medians. These numbers are a local regression baseline, not network or
end-to-end server throughput claims.

| Scenario | Median |
| --- | ---: |
| HTTP/1 real request+response heads, contiguous | 843,074 tx/s |
| HTTP/1 real request+response heads, fragmented | 533,890 tx/s |
| HTTP/1 captured-length fixed bodies | 128.7 M bodies/s |
| HTTP/1 modeled chunked bodies | 328,815 bodies/s |
| HTTP/2 real field blocks | 5.419 M blocks/s / 72.77 M fields/s |
| HTTP/2 complete real frame trace | 216.9 M frames/s |
| HTTP/2 fragmented real frame trace | 24.82 M frames/s |
| Mixed real headers, 4 threads | 2.142 M tx/s |

The reported frame-trace MiB/s is *wire coverage*: DATA payload slices are
returned zero-copy rather than scanned byte-by-byte, so it must not be read as
memory-copy bandwidth. Likewise, `FixedBody.take` is intentionally tiny and its
very high transaction rate is mainly useful for detecting regressions in that
primitive.
