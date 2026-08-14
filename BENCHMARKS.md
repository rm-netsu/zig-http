# Benchmarks

These microbenchmarks exercise parser hot paths without networking, TLS, or HPACK work. They are intended for regression tracking rather than as end-to-end HTTP throughput claims.

Run with the supplied Zig 0.16.0 toolchain:

```sh
zig build bench -Doptimize=ReleaseFast
```

The benchmark mutates its wire input from the runtime clock before timing so the compiler cannot fold the parser work into constants.

## 0.3.0 hot paths

Three consecutive runs on the development x86_64 Linux host produced:

| Benchmark | Run 1 | Run 2 | Run 3 | Median |
| --- | ---: | ---: | ---: | ---: |
| HTTP/1 legacy head + separate framing | 2.019 M ops/s | 2.013 M ops/s | 1.988 M ops/s | 2.013 M ops/s |
| HTTP/1 incremental single-pass framing | 3.133 M ops/s | 3.026 M ops/s | 3.108 M ops/s | 3.108 M ops/s |
| HTTP/1 contiguous single-pass framing | 3.198 M ops/s | 3.193 M ops/s | 3.113 M ops/s | 3.193 M ops/s |
| HTTP/1 chunk decoder | 40.527 M ops/s | 39.438 M ops/s | 39.810 M ops/s | 39.810 M ops/s |
| HTTP/2 incremental frame decoder | 264.020 M ops/s | 246.705 M ops/s | 271.180 M ops/s | 264.020 M ops/s |
| HTTP/2 contiguous complete-frame parser | 595.830 M ops/s | 606.036 M ops/s | 565.634 M ops/s | 595.830 M ops/s |

On this workload, the HTTP/1 single-pass paths are about 1.54x to 1.59x faster than validating the head and then scanning fields again for framing. The complete HTTP/2 frame path is about 2.26x faster than driving the two-event incremental decoder when the transport already has a full frame available.

## Connection-state size

Type sizes on x86_64 Linux:

| Type | 0.2.2 | 0.3.0 |
| --- | ---: | ---: |
| `http1.HeadParser` | 32 B | 24 B |
| `http1.ChunkDecoder` | 40 B | 32 B |
| `http2.FrameDecoder` | 36 B | 20 B |
| `http2.FlowWindow` | 8 B | 4 B |
| `http2.continuation.Guard` | 8 B | 4 B |
| `http2.header_block.Collector` | 32 B | 24 B |

A representative HTTP/2 parser-state set consisting of one frame decoder, one flow window, one continuation guard, and one header-block collector is 52 B in 0.3.0 versus 84 B in 0.2.2. Each additional per-stream `FlowWindow` is 4 B instead of 8 B.

## Rejected experiments

The following experiments were measured and intentionally not retained:

- `std.Io.Writer.writeVecAll` for HTTP/2 frame output was slower than two `writeAll` calls in the tested buffered-writer workload.
- `writeVecAll` for HTTP/1 field lines was slower than the existing small `writeAll` sequence.
- Manual hexadecimal chunk-size formatting did not improve over Zig 0.16.0 `Writer.print`.
- A more branch-minimized HTTP/2 field validator regressed the representative validation benchmark.
- Replacing the optimized CRLF substring search with a scalar CR scan did not improve HTTP/1 header iteration.

These are deliberately excluded to keep the implementation simple and to avoid trading benchmark-neutral or negative changes for extra code.
