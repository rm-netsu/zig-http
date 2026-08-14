# Benchmarks

These microbenchmarks exercise parser hot paths without networking, TLS, or HPACK work. They are regression tests for protocol-core overhead rather than end-to-end HTTP throughput claims.

Run with Zig 0.16.0:

```sh
zig build bench -Doptimize=ReleaseFast
```

Wire data is mutated from the runtime clock before timing so the parser cannot be folded into compile-time constants. The HTTP/2 field benchmark also mutates one field value at runtime.

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

For a buffer containing eight 32-byte DATA frames, repeatedly calling `parseCompleteFrame` reaches about 398.4 M frames/s, while `CompleteFrameIterator` reaches about 442.0 M frames/s, approximately 1.11x faster. The iterator uses 32 bytes of temporary state on x86_64.

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
- The batch iterator is retained; a comptime callback dispatcher was only about 1-2% faster and added API complexity.

## Earlier rejected experiments

The 0.3.0 investigations also rejected `std.Io.Writer.writeVecAll` for the tested HTTP/1 and HTTP/2 serialization workloads, manual hexadecimal chunk-size formatting, scalar CR scanning in HTTP/1, and a more branch-minimized HTTP/2 field validator when those variants did not improve measured performance.
