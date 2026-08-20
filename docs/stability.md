# API stability policy

`zig-http` 1.x treats every declaration reachable from the installed `http`
module as normal SemVer-governed source API unless this document explicitly
marks it otherwise. The package does not keep a second hidden category of
"public but unstable" protocol declarations.

The compatibility promise is source/API and documented-behavior compatibility
for the supported Zig toolchain. It is not a frozen C ABI and does not promise
that private implementation layouts or generated machine code remain identical.

## Stable composed surface

These are the recommended integration points and receive the strongest API
regression coverage:

- `http.common`, including the shared `Role` and header primitives;
- `http.uri` validation helpers;
- `http.http1.ConnectionDecoder`;
- `http.http1.MessageWriter`;
- `http.http1.message` typed request/response/framing helpers;
- `http.http2.Bootstrap`;
- `http.http2.Session`;
- `http.http2.message` typed request/response helpers;
- `http.http2.storage` bounded reference stores/collectors;
- `http.high_level.http1.Connection(config)`;
- `http.high_level.http2.Connection(config)`.

The high-level module-level result and error types are intentionally independent
from the generic `Connection(config)` instantiation and from internal parser /
HPACK error unions. Different storage configurations therefore share the same
error/result API, and adding an internal low-level error cannot silently widen a
1.x high-level error set.

`Connection(config).Storage` is caller-owned but opaque-by-convention. Its size
and alignment are available so it can be placed in application memory, but its
byte representation is not protocol API. Do not inspect or copy an initialized
Storage value. Keep its address stable until `deinit`.

High-level wrappers deliberately do not expose pointers to their bundled
Session, parser, writer, stream store, collector, or Bootstrap. Applications
that need lower-level control instantiate those public components directly.
This prevents a convenience wrapper from freezing its private composition for
all of 1.x.

## Stable low-level protocol surface

The independently composable protocol namespaces are also SemVer-governed API:

- HTTP/1 head, body, semantics, connection, write, and message primitives;
- HTTP/2 frame, settings, flow, fields, payload, continuation, preface,
  bootstrap, protocol, priority, stream/streams, header-block, connection,
  peer, session, send, scheduler, dispatch, contracts, storage, and message
  namespaces;
- the `http.http2.hpack` re-export used by low-level HPACK-facing signatures.

This is intentional: one of the library's design goals is that custom event
loops and sharded runtimes can drop below the composed APIs without copying
internal implementation files.

A source-breaking change to this surface requires a new major version after
1.0. New declarations, new optional helpers, and behavior fixes that preserve
existing valid usage may ship in 1.x minor/patch releases according to SemVer.

## What is not package API

The following remain development/reference assets rather than installed library
API:

- `build_support/`;
- `test/` and conformance fixtures;
- `bench/`;
- executable files under `examples/`.

Examples are compile-tested so they remain trustworthy usage references, but
applications should import `http`, not source files from those directories.

## API regression gate

`src/root.zig` contains a compile-time stable-surface contract. It verifies:

- required composed entry points remain present;
- key HTTP/1 and HTTP/2 high-level signatures remain exact;
- high-level errors/results remain module-level rather than config-specific;
- the shared endpoint `Role` keeps one type identity;
- high-level wrappers do not re-expose their private composition;
- caller-owned in-place Storage stays opaque-by-convention.

This is deliberately only one layer of the release gate. Unit/property tests,
fuzz replay, external interoperability, generated API docs, and upstream h2spec
protect semantics that declaration signatures cannot express.

## 1.x release expectations

A stable release must keep all of the following green:

1. `zig build check`;
2. ReleaseSafe and ReleaseFast tests;
3. external HTTP/1 and HTTP/2 interoperability;
4. strict upstream h2spec v2.6.0;
5. compile-tested examples using only documented API;
6. migration notes for every intentional source break in the next major line.

The project may change implementation layouts, storage internals, algorithms,
and performance strategies in compatible 1.x releases as long as the public
source/API and documented protocol behavior remain compatible.
