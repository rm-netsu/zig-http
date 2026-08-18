# Architecture and composition levels

`zig-http` is an HTTP protocol engine rather than a networking framework. The
boundary is intentional: state and decisions that are purely HTTP belong in the
core; transport, scheduling, and application policy stay caller-owned.

## Core boundary

The core owns protocol concerns such as:

- HTTP/1 start lines, fields, framing, persistence, Upgrade, CONNECT, and body
  progression;
- HTTP/2 frames, continuation ordering, HPACK integration, SETTINGS, stream
  state, flow control, GOAWAY, server push, Extended CONNECT, and protocol
  extensions;
- optional HTTP-only helpers such as receive-credit bookkeeping, DATA
  scheduling primitives, graceful GOAWAY state, and priority signal parsing.

The core does not open sockets, run TLS, resolve DNS, register timers, create
threads, select an event loop, or own application routing/work queues.

That split keeps the library usable both as a composed engine and as a source of
lower-level components for runtimes that already own some HTTP coordination.

## HTTP/1 levels

### Composed message coordination

`http1.ConnectionDecoder` is the recommended receive-side coordinator. It
combines incremental head parsing, semantic validation, body framing,
trailers, informational/final response sequencing, HEAD/CONNECT behavior,
persistence, and close-delimited EOF.

`http1.MessageWriter` is the matching send-side coordinator. It preflights a
message before first output, tracks Content-Length/chunked completion, enforces
trailer policy hooks, and exposes connection reuse or protocol-switch outcomes.

Both are transport-neutral and allocation-free with caller-owned scratch
storage.

### Lower-level composition

Use these directly when an existing runtime already owns more state:

- `http1.head` — contiguous and incremental start-line/field parsing;
- `http1.body` — fixed-length and chunked body decoding;
- `http1.semantics` — request-target, Host, persistence, and message semantics;
- `http1.write` — raw serialization escape hatches.

Raw serializers intentionally remain less opinionated than the composed
coordinator so diagnostic/proxy tooling can reproduce unusual wire input.

## HTTP/2 levels

### Bootstrap and Session

`http2.Bootstrap` owns only HTTP/2 connection-preface ordering: client magic,
initial local SETTINGS, fragmented server-side client-preface parsing, and the
requirement that the first peer frame is a non-ACK SETTINGS frame. It remains
transport-neutral and hands established frame processing to `Session`.

`http2.Session` is the recommended composed connection engine after/alongside
bootstrap. It is a small
connection object over caller-owned dependencies and composes:

- complete/incremental frame validation;
- HPACK encode/decode and continuation handling;
- request/response/trailer field semantics;
- transactional field-sink delivery;
- stream creation and lifecycle transitions;
- Content-Length/no-content/CONNECT body semantics;
- SETTINGS, PING, RST_STREAM, WINDOW_UPDATE, GOAWAY, and push handling;
- connection and stream flow accounting;
- state-aware send preflight.

Session does not own the stream table or HPACK allocator. The stream store can
be a fixed slab, hash table, shard-local structure, or another caller-selected
layout. Per-message `BodyState` is likewise store-owned so richer semantic
checking does not inflate the compact `stream.Tracked` record.

### Stream manager and stable cursors

`http2.streams` provides stream-ID, concurrency, lifecycle, and missing-stream
classification over caller-owned storage. Stable-cursor APIs avoid repeated
lookups when the application already has a stream record.

### Ordered dispatch and shard handoff

HTTP/2 has connection-wide ordering constraints even when application stream
work is sharded. `http2.dispatch` lets one ordered connection owner commit
connection DATA flow control and CONTINUATION adjacency before turning DATA,
RST_STREAM, and stream WINDOW_UPDATE into temporary caller-routable work.

The stream shard therefore does not need the whole Session/connection object.
Typed `prepare*AssumeConnectionChecked()` paths exist for runtimes that already
committed the relevant connection invariant; their longer names intentionally
make skipped validation visible at the call site.

### Focused primitives

The lower namespaces remain independently useful:

- `http2.bootstrap` — composed connection-preface and initial SETTINGS ordering;
- `http2.frame` — zero-copy complete/batched/incremental frame parsing;
- `http2.connection` — connection receive ordering and complete-frame state;
- `http2.peer` — peer SETTINGS, outbound limits, send window, and GOAWAY state;
- `http2.settings`, `http2.flow` — SETTINGS and flow-control primitives;
- `http2.stream`, `http2.streams` — stream state and caller-owned management;
- `http2.fields` — HTTP/2 field and message semantic validation;
- `http2.send` — bounded streaming HPACK/frame serialization;
- `http2.payload` — typed frame payload helpers;
- `http2.continuation`, `http2.header_block` — field-block sequencing;
- `http2.priority` — RFC 9218 parsing/serialization and signal composition;
- `http2.dispatch` — ordered-to-sharded handoff helpers.

## Memory and lifetime model

Parsers and serializers are slice-oriented. Complete contiguous input takes
zero-copy fast paths; fragmented input uses caller-owned bounded storage.
HTTP/1 bodies and HTTP/2 DATA are surfaced incrementally instead of buffering a
whole message.

HPACK callback field slices are borrowed. A synchronous field sink may inspect
or copy them during `field()`, but must not retain the slices after the callback.
The transactional `begin` / `field` / `commit` / `abort` contract lets an
application stage decoded fields without publishing a partial section if a
later field or stream check fails.

See [`operations.md`](operations.md) for the complete buffer and failure
ownership rules.

## Concurrency model

There is no process-global mutable protocol state. Different connections can be
processed independently on different workers.

Within one HTTP/2 connection, connection framing, HPACK state, SETTINGS, and
other connection-order-sensitive state still require one logical mutation order.
A runtime can satisfy that with one owner, a lock, a serialized queue, or an
equivalent scheme. Stream-local work can be handed to shards after the ordered
connection invariants are committed.

See [`concurrency.md`](concurrency.md) for the detailed ownership rules.

## Performance model

The project favors small persistent connection/stream records and makes richer
policy or bookkeeping caller-owned when doing so avoids penalizing every
connection or stream. Small bounded read-only tables and SIMD validation are
used when they materially improve common parsing paths.

Performance-sensitive changes are tested against real-corpus and isolated
layout-sensitive benchmarks. See [`../BENCHMARKS.md`](../BENCHMARKS.md).

## Integration layers

Both high-level connection families can either allocate their fixed connection
state once or bind to caller-owned stable `Storage`. The in-place HTTP/1 path is
fully allocation-free; HTTP/2 still uses the configured allocator for HPACK
dynamic-table payloads while avoiding a large wrapper-state allocation.

`http.high_level` is the optional in-package convenience layer. Its HTTP/1
connection wrapper owns bounded parser/writer scratch storage plus the ordered
request semantics queue needed to correlate pipelined responses. Its HTTP/2
wrapper owns routine HPACK/Bootstrap/Session, bounded stream/header storage,
scratch buffers, and client stream-ID allocation. Both consume and produce
caller-owned byte streams and are implemented entirely on top of public core
APIs.

A concrete socket/TLS/event-loop adapter crosses the protocol boundary and
belongs in an application or separate adapter package. The core never requires
consumers to adopt `high_level`, and custom/sharded runtimes can bypass it
without losing functionality.
