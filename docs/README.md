# Documentation

`zig-http` keeps transport ownership outside the package. The documentation is
therefore organized around protocol composition rather than a particular socket,
TLS, event-loop, or thread-pool implementation.

## Start here

- [`../README.md`](../README.md) — package overview, quick starts, build commands,
  and composition-level selection.
- [`../examples/README.md`](../examples/README.md) — compile-tested high-level, protocol-core, and runnable loopback TCP examples.
- [`basic-client-server.md`](basic-client-server.md) — end-to-end TCP client/server composition for HTTP/1.1 and HTTP/2.
- [`architecture.md`](architecture.md) — protocol/core boundary, composition
  levels, memory model, and low-level module map.
- [`http1.md`](http1.md) — HTTP/1.1 receive/send composition and lower-level
  escape hatches.
- [`http2.md`](http2.md) — HTTP/2 Session, lower-level connection/stream
  composition, extensions, and priority signals.
- [`concurrency.md`](concurrency.md) — ownership and sharding rules.
- [`operations.md`](operations.md) — error scope, poisoning, buffer lifetime,
  and recovery/shutdown rules.
- [`migration.md`](migration.md) — migration notes for public API changes.

## Generated API reference

Run:

```sh
zig build docs
```

The generated Zig API reference is installed under:

```text
zig-out/docs/api/
```

Open `zig-out/docs/api/index.html` in a browser. The generated reference is for
declaration-level details; the guides above define composition, ownership, and
operational expectations that cannot be expressed by signatures alone.

## Verification workflows

- `zig build check` — dependency-light merge gate.
- `zig build conformance` — HTTP/1 interoperability plus HTTP/2 RFC smoke and bidirectional external interoperability.
- `H2SPEC_BIN=/path/to/h2spec zig build conformance-h2spec` — strict upstream h2spec v2.6.0.
- `zig build all-checks` — merge gate, generated API docs, and reproducible external conformance.
- `H2SPEC_BIN=/path/to/h2spec zig build release-checks` — `all-checks` followed serially by strict upstream h2spec v2.6.0; intended as the release gate.

Granular conformance scripts and build targets remain available for focused debugging.
