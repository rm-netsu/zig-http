# http

High-performance, allocation-conscious HTTP/1.1 and HTTP/2 protocol engine for
Zig 0.16.0.

`http` owns HTTP protocol state, not your runtime. Sockets, TLS, DNS, timers,
event loops, thread pools, routing, and application queues stay outside the
core. The same protocol pieces can therefore be used in a simple synchronous
program, a custom reactor, or a sharded multithreaded server.

## Highlights

- Streaming HTTP/1.1 and HTTP/2 receive/send paths without whole-message
  buffering.
- Zero-copy fast paths for contiguous HTTP/1 heads and HTTP/2 frames, with
  incremental fallbacks for fragmented transport reads.
- Strict HTTP/1 framing and request-target/Host semantics, including
  pipelining, informational responses, HEAD, CONNECT, Upgrade, chunked bodies,
  trailers, and close-delimited responses.
- HTTP/2 frame, stream, SETTINGS, flow-control, HPACK, GOAWAY, server-push,
  Extended CONNECT, RFC 9218 priority, reference urgency scheduling, and extension composition.
- Optional composed APIs (`http1.ConnectionDecoder`, `http1.MessageWriter`,
  `http2.Bootstrap`, `http2.Session`) over the same independently usable low-level primitives.
- Optional `http.high_level.http1.Connection` bundles HTTP/1 parsing/writing, a
  bounded pipelining response-context queue, typed Host-aware request builders,
  and synchronous draining through the shared `high_level.DrainAction` without
  owning transport.
- Optional `http.high_level.http2.Connection` bundles HPACK, bootstrap, bounded
  stream/header storage, local SETTINGS policy, explicit control actions, receive-
  credit composition, typed request/response builders, client stream-ID allocation,
  and synchronous draining while still leaving transport ownership outside.
- Caller-owned buffers and HTTP/2 stream storage. The core does not force a
  slab, hash table, allocator, scheduler, queue, or synchronization strategy.
- Transactional HTTP/2 header delivery and fail-closed message-body semantics,
  including Content-Length, no-content responses, and CONNECT tunnel timing.
- No process-global mutable protocol state. Independent connections are
  naturally distributable across workers.
- Standalone `hpack` dependency pinned by commit and Zig package hash.

## Choose a composition level

Use the highest layer that matches the HTTP state you want the library to own.

### HTTP/1.1

For the shortest bounded-memory integration, use
`http.high_level.http1.Connection(config)`. It composes receive/send state,
automatically retains the HEAD/CONNECT/other response context required by
pipelining, and offers typed Host-aware request construction while leaving all
transport I/O caller-owned.

For direct message-state control use:

- receive: `http.http1.ConnectionDecoder`
- send: `http.http1.MessageWriter`

If your runtime already owns more of the message state machine, compose
`http1.head`, `http1.body`, `http1.semantics`, and `http1.write` directly.

See [the HTTP/1 composition guide](docs/http1.md).

### HTTP/2

For the shortest bounded-memory integration, use
`http.high_level.http2.Connection(config)`. It owns the routine per-connection
HPACK/storage/scratch composition but still reads from and writes to
caller-owned transport buffers.

For custom storage or one ordered connection owner that wants direct control, use `http.http2.Bootstrap` for the connection
preface/initial SETTINGS handshake and `http.http2.Session` for frame validation,
HPACK, field semantics, stream transitions, peer SETTINGS/GOAWAY, flow accounting,
and state-aware sends. Stream storage and HPACK memory remain caller-owned.

Local send failures keep compact hot-path errors; opt-in Session diagnostics explain
header/SETTINGS/DATA preflight failures when development tooling needs a reason.

Custom or sharded runtimes can instead compose `http2.connection`,
`http2.streams`, `http2.dispatch`, `http2.send`, `http2.flow`, and the frame and
field primitives directly.

See [the HTTP/2 composition guide](docs/http2.md) and
[concurrency guide](docs/concurrency.md).

## Getting started

Add the package with Zig's package manager:

```sh
zig fetch --save git+https://github.com/rm-netsu/zig-http.git#v0.19.0
```

Then import the module in `build.zig`:

```zig
const http_dep = b.dependency("http", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("http", http_dep.module("http"));
```

The package targets and is tested with Zig 0.16.0; the package manifest sets
0.16.0 as the minimum Zig version.

Both high-level connection types expose caller-owned `Storage` plus `init*InPlace`
constructors. HTTP/1 can therefore run fully allocation-free at the composed
layer; HTTP/2 can avoid the large fixed-state allocation while continuing to use
the caller-selected allocator only for HPACK dynamic tables. In-place storage
must remain at a stable address until `deinit`.

The best executable starting points are compile-tested examples:

- [`examples/http1_high_level.zig`](examples/http1_high_level.zig)
- [`examples/http1_expect_upgrade.zig`](examples/http1_expect_upgrade.zig)
- [`examples/http1_client_core.zig`](examples/http1_client_core.zig)
- [`examples/http1_server_core.zig`](examples/http1_server_core.zig)
- [`examples/http2_high_level.zig`](examples/http2_high_level.zig)
- [`examples/http2_client_core.zig`](examples/http2_client_core.zig)
- [`examples/http2_server_core.zig`](examples/http2_server_core.zig)
- [`examples/http2_scheduler.zig`](examples/http2_scheduler.zig)
- [`examples/error_handling.zig`](examples/error_handling.zig)

Trailer and RFC 9218 examples are listed in
[`examples/README.md`](examples/README.md). `zig build check` runs the examples,
so they are kept in sync with the public API.

## Documentation

Start with [`docs/README.md`](docs/README.md). The focused guides are:

- [Architecture and composition levels](docs/architecture.md)
- [HTTP/1.1 composition](docs/http1.md)
- [HTTP/2 composition](docs/http2.md)
- [Concurrency and ownership](docs/concurrency.md)
- [Errors, lifetimes, recovery, and shutdown](docs/operations.md)
- [Migration notes](docs/migration.md)

Generate declaration-level API docs with:

```sh
zig build docs
```

Then open `zig-out/docs/api/index.html`.

## Public module map

The root module intentionally stays small:

- `http.common` — shared field/value primitives.
- `http.uri` — allocation-free URI/request-target validation helpers.
- `http.http1` — HTTP/1.1 parser, body, semantics, typed message helpers, connection, and write APIs.
- `http.http2` — HTTP/2 framing, state, fields, flow control, streams, session,
  bounded default storage, typed message builders, dispatch, send, priority,
  and extension APIs.
- `http.high_level` — optional transport-neutral convenience composition built
  exclusively on the protocol core.

Owning namespaces are part of the DX: low-level declarations live under the
protocol component that owns their invariants instead of accumulating duplicate
flat aliases.

For the detailed layer and module responsibilities, see
[`docs/architecture.md`](docs/architecture.md).

## Verification

Common development gates:

```sh
zig build test
zig build check
zig build conformance
zig build all-checks
```

Release verification additionally requires upstream h2spec v2.6.0:

```sh
H2SPEC_BIN=/path/to/h2spec zig build release-checks
```

The release gate runs unit/property tests, deterministic fuzz replay,
compile-tested examples, conformance fixtures, generated API docs, external
HTTP/1 and HTTP/2 interoperability, RFC smoke tests, and strict upstream
h2spec. The release fixture passes h2spec v2.6.0 in strict mode with 147/147 tests.

Useful focused targets include:

```sh
zig build examples
zig build conformance-fixtures
H2SPEC_BIN=/path/to/h2spec zig build conformance-h2spec
zig build test -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSafe -Dsanitize-thread=true
```

See [`docs/README.md`](docs/README.md) for the verification workflow and
[`FUZZING.md`](FUZZING.md) for fuzzing details.

## Performance

The implementation is designed around bounded caller-owned state, streaming
work, and cheap common-case parsing. Layout-sensitive and real-corpus
benchmarks are kept in-tree so optimizations can be compared against earlier
releases instead of relying only on microbenchmarks.

Run the primary suites with:

```sh
zig build bench -Doptimize=ReleaseFast
zig build bench-real -Doptimize=ReleaseFast
zig build bench-real-session -Doptimize=ReleaseFast
zig build bench-real-send-session -Doptimize=ReleaseFast
```

Additional focused benchmark targets and methodology are documented in
[`BENCHMARKS.md`](BENCHMARKS.md).

## Dependency

HTTP/2 header compression uses the standalone `hpack` package from
`rm-netsu/zig-hpack`. `build.zig.zon` pins both its Git commit and Zig package
hash; the current dependency version is 0.4.1.

## Scope

The core deliberately does **not** own:

- sockets or platform networking APIs;
- TLS or certificate policy;
- DNS;
- timers and timeout policy;
- event loops or thread pools;
- application routing/work queues;
- a mandatory HTTP/2 stream storage or scheduling topology.

The optional `http.high_level` namespace may own routine HTTP-specific
connection storage/composition, but deliberately stops before sockets, TLS,
DNS, timers, or an event loop. The protocol core remains independently usable.

## Status

The project is still pre-1.0, so incompatible API refinements can occur when
needed to make the eventual 1.x contracts safer or clearer. Migration notes are
kept in [`docs/migration.md`](docs/migration.md), and release changes are listed
in [`CHANGELOG.md`](CHANGELOG.md).
