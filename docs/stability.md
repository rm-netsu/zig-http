# API stability and 1.0 freeze policy

`zig-http` is still pre-1.0. The project intentionally prefers removing an
ambiguous API over carrying a compatibility alias that would make the eventual
1.x surface harder to understand. At the same time, the main composed APIs are
now treated as **1.0 candidates** so accidental churn is caught before release.

## Tier 1: 1.0-candidate composed surface

These are the recommended integration points. Their owning namespaces and the
core method families are covered by a compile-time smoke contract in
`src/root.zig`:

- `http.common.Header` and the public URI validation helpers;
- `http.http1.ConnectionDecoder`;
- `http.http1.MessageWriter`;
- `http.http1.message` typed request/response and framing helpers;
- `http.http2.Bootstrap`;
- `http.http2.Session` and its receive/send/control lifecycle;
- `http.http2.message` typed request/response helpers;
- `http.high_level.http1.Connection(config)`;
- `http.high_level.http2.Connection(config)`.

Source-breaking changes to these APIs before 1.0 require an explicit migration
note and a concrete correctness or major-DX justification. Compatibility shims
are not retained merely to preserve a pre-1.0 spelling.

The smoke contract is deliberately not a substitute for semantic tests. It
prevents accidental removal of the candidate entry points while unit,
property/fuzz, external interoperability, and h2spec tests protect behavior.

## Tier 2: advanced public protocol components

The focused namespaces remain public because custom runtimes need them:

- HTTP/1 head/body/semantics/write primitives;
- HTTP/2 frame, payload, continuation, header-block, flow, settings, peer,
  stream/streams, storage, send, priority, scheduler, dispatch, and contracts.

They are production-tested and are not "internal" APIs. However, before the 1.0
freeze they can still receive source-level cleanup when measurements or protocol
correctness justify it. Such changes must be documented in `CHANGELOG.md` and
`docs/migration.md`.

Before tagging 1.0, every Tier 2 namespace will either be accepted into the
normal SemVer surface or explicitly moved under an experimental namespace. The
project will not silently declare a currently public namespace exempt from
SemVer after 1.0.

## Not package API

The following are development/reference assets rather than library API:

- `build_support/`;
- `test/` and conformance fixtures;
- `bench/`;
- executable examples and their local support code.

Examples are compile-tested so they remain trustworthy usage references, but
applications should import `http`, not files from `examples/` or `test/`.

## Release expectations

A 1.0 candidate should satisfy all of the following before the final API freeze:

1. `zig build check` succeeds in the supported Zig configuration;
2. ReleaseSafe and ReleaseFast focused protocol tests pass;
3. external HTTP/1 and HTTP/2 interoperability passes;
4. upstream h2spec v2.6.0 passes in strict mode;
5. public examples compile against only documented API;
6. migration notes contain no unresolved compatibility ambiguity in Tier 1.

After 1.0, changes to the accepted public surface follow normal SemVer. New
optional functionality can be added in minor releases without forcing consumers
to adopt high-level composition or any particular transport/runtime.
