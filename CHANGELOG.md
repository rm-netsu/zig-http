# Changelog

## Unreleased

- Add synchronized runtime local SETTINGS updates to `high_level.http2.Connection`, with explicit configured/acknowledged/effective/pending snapshots and one bounded outstanding high-level policy update.
- Correct local SETTINGS timing so receive-capacity expansions are accepted as soon as the peer can apply them, restrictive transitions wait for ACK, and HPACK table-size changes retain their RFC-defined ACK synchronization. Streams opened while an increased INITIAL_WINDOW_SIZE is in flight now receive the safe expanded window.
- Make high-level `LocalSettings.max_header_list_size` a concrete `u32` defaulting to `maxInt(u32)`, allowing runtime policy to restore the largest wire-representable header-list limit without an ambiguous optional state.
- Add preflight validation for fixed-store initial-window transitions before a peer-visible SETTINGS write, plus regression coverage for restrictive/permissive updates, ACK ordering, no-op updates, and header-limit restoration.
- Add a compile-time smoke contract for the 1.0-candidate composed API and document explicit pre-1.0 stability tiers.
- Add a compile-tested `http2_settings` example for initial and runtime high-level SETTINGS synchronization.
- Split the runnable TCP integrations into independent HTTP/1.1 and cleartext prior-knowledge HTTP/2 server/client executables, with persistent server accept loops, explicit per-process build targets, and aggregate checks that compile rather than run the standalone servers. The examples retain pipelining/multiplexing, streaming bodies, HTTP/2 control responses and receive-credit handling.

## 0.19.0

- Add caller-owned in-place storage for both high-level connection families: HTTP/1 can now run fully allocation-free at the composed layer, while HTTP/2 can avoid its large fixed-state allocation and retain allocator use only for HPACK dynamic-table memory.
- Forward common HTTP/2 lifecycle operations through the high-level wrapper, including semantic trailer sends and caller-timed two-phase graceful GOAWAY, without changing the underlying Session ownership model.
- Add allocation-free typed body-framing helpers: stable decimal `ContentLength` holders for HTTP/1 and HTTP/2 plus canonical HTTP/1 `chunked()` construction, with final legality still enforced by the production writer/field validators.
- Strengthen high-level state-model coverage with repeated bounded HTTP/1 pipeline reuse and HTTP/2 closed-stream reclamation/reuse tests.
- Make high-level HTTP/2 local SETTINGS authoritative: `Config.local_settings` now drives the initial SETTINGS frame, inbound frame/header/stream limits, and HPACK decoder policy; restrictive values activate only after the matching SETTINGS ACK, including existing-stream initial-window adjustment, while safe receive expansions can be accepted eagerly. Remove the divergent `start(settings)` and `receive(max_frame_size)` arguments.
- Add transport-neutral high-level HTTP/2 `ControlAction` responses for SETTINGS/PING/protocol faults plus `releaseData` / `flushReceiveCredit` flow-control composition; receive never writes implicitly.
- Make high-level HTTP/2 field collection fail closed on bounded collector overflow after fully draining HPACK, rather than publishing empty headers with an easy-to-ignore overflow flag.
- Make high-level HTTP/1 Upgrade selection fail closed in both directions by retaining bounded exact offers across pipelining, rejecting unsolicited client-side 101 responses, and preventing servers from selecting protocols that were not offered.
- Add strict opt-in HTTP/2 peer field-section limit preflight using RFC `SETTINGS_MAX_HEADER_LIST_SIZE` accounting; the high-level HTTP/2 wrapper honors the advertised limit by default before HPACK/wire mutation while low-level `Session.sendHeaders()` remains permissive because the setting is advisory.
- Add HTTP/1 `Expectation`/`ContinueGate` helpers and canonical `expectContinue()` construction so 100-continue coordination no longer requires application-side field scanning or timer ownership in core.
- Add borrowed `UpgradeOffer` validation that checks Connection/Upgrade structure, case-insensitive protocol-name matching, and that a 101 response selects only client-offered protocols.
- Add optional `http2.scheduler.Urgency`, a caller-driven RFC 9218 reference scheduler with urgency ordering, non-incremental continuation, incremental round-robin sharing, and flow-control-aware fallback to ready lower-priority work.
- Add compile-tested HTTP/1 Expect/Upgrade and HTTP/2 priority-scheduler examples.
- Add optional `http.high_level.http1.Connection(config)` composition with bounded parser/writer storage, automatic pipelined HEAD/CONNECT/other response-context tracking, server response-order enforcement/backpressure, typed Host-aware requests, and streaming send/receive while preserving caller-owned transport.
- Add allocation-free `http1.message.RequestFields` / `ResponseFields` helpers for origin/absolute/asterisk/CONNECT composition and duplicate-Host prevention before wire mutation.
- Add synchronous high-level `drain` helpers for HTTP/1 and HTTP/2 so event loops can consume immediately parseable events without hand-writing receive loops or buffering borrowed event batches.
- Add optional `http.high_level.http2.Connection(config)` composition with owned HPACK contexts, Bootstrap/Session, bounded stream/header storage, scratch/staging buffers, SETTINGS synchronization, copied receive fields, client stream-ID allocation, and typed request/response sends while keeping transport ownership outside the package.
- Add public bounded `http2.storage.FixedStreamStore` with explicit closed-record reclamation and transactional copying `FixedFieldCollector`; migrate examples away from a copied support-only store.
- Add allocation-free `http2.message.RequestFields` / `ResponseFields` builders that order pseudo-fields by construction, distinguish CONNECT variants, preserve regular-field HPACK indexing policy, and validate complete field sections before Session/wire mutation.
- Add transport-neutral `http2.Bootstrap` composition for client/server connection prefaces and initial SETTINGS ordering, including fragmented client-magic receive, strict first-peer-SETTINGS enforcement, and a preflight-before-wire `start()` path.
- Make HTTP/2 structural contracts validate complete method signatures for stream/session stores, transactional field sinks, and trailer policies instead of only checking declaration names.
- Add opt-in HTTP/2 local preflight diagnostics for HEADERS, DATA, and SETTINGS, including field/setting indices and semantic reasons, while preserving the compact production send error sets and validator hot path.

## 0.18.0

- Make composed HTTP/2 message receive semantics fail-closed with caller-owned `BodyState`: Session now rejects DATA before final response headers, correlates HEAD/CONNECT request methods, validates Content-Length against DATA content octets through END_STREAM/trailers, rejects non-empty DATA for no-content messages, and opens CONNECT tunnel DATA only after a successful response without increasing the 12-byte `Tracked` record.
- Enforce normalized HTTP/2 `Host` / `:authority` consistency on shared receive/send field validation, including case, default-port, percent-encoding, and IPv6 textual normalization without retaining callback-lifetime HPACK slices.
- Make the HTTP/2 field-sink contract transactional (`begin` / `field` / `commit` / `abort`) so late semantic/HPACK/stream failures cannot accidentally publish a partial header section.
- Add `zig build release-checks`, which serializes the normal `all-checks` gate before strict upstream h2spec instead of allowing a release to omit the explicit h2spec target.
- Replace the oversized root README with a compact package landing page and move architecture/composition details into `docs/architecture.md`; reorganize migration guidance around explicit release-to-release transitions.
- Verify the strict release fixture against upstream h2spec v2.6.0: 147/147 tests pass with zero skips or failures, and pin the release script to that suite version for reproducible release gates.

## 0.17.0

- Harden HTTP/1 request routing semantics: validate absolute-form with shared RFC 3986 URI rules, expose `effective_authority` from semantic/composed receive APIs, and ensure absolute-form and CONNECT derive routing authority from request-target rather than a conflicting Host field; send-side absolute-form now rejects a Host value not derived from its request-target authority. The composed `HeadEvent`/`Event` intentionally grow by one borrowed slice (88/96 B to 104/112 B on x86_64) to avoid a second header traversal on normal routing paths.
- Make composed HTTP/1 response handling fail-closed: receive/send coordination rejects non-HTTP 600..999 status codes and malformed 101 Upgrade handshakes before switching protocols, while raw head parsing/serialization remains available for diagnostic tooling; response receive has an explicit `validate_responses = false` escape hatch.
- Share allocation-free URI authority/path/scheme validation between HTTP/1 and HTTP/2, and distinguish tolerant recipient parsing from strict sender generation for empty `#rule` members in Connection/Upgrade lists.

- Make composed HTTP/2 trailer sending fail-closed: non-empty trailers through `Session.sendHeaders()` now require an explicit caller-owned semantic policy, while new `sendTrailers()` / `sendTrailersExisting()` preflight trailer syntax and policy before HPACK, stream, or wire mutation. Add a compile-tested trailer example and structural policy diagnostics; inbound and low-level extension/proxy paths remain unrestricted by application field semantics.

- Add aggregate `zig build conformance`, `conformance-h2spec`, and `all-checks` workflows so contributors can run reproducible external interoperability/RFC smoke, strict upstream h2spec, or the complete merge/docs/conformance gate without memorizing individual fixture scripts; aggregate fixture runs automatically reuse the invoking Zig executable.

- Add a first-class documentation workflow: `zig build docs` generates and installs Zig API reference pages, while focused HTTP/1, HTTP/2, concurrency, operations, and migration guides separate architectural/ownership guidance from declaration-level docs.
- Make composed HTTP/1 trailer generation safe by default: non-empty `MessageWriter` trailers now require an explicit caller-owned field-definition policy, with complete syntax/universally-forbidden/policy preflight before the terminal chunk; raw `endChunks` remains available for deliberately low-level composition.
- Add caller-owned RFC 9218 priority signal composition state that distinguishes request/update default-reset semantics from response omission overlays without imposing scheduler or client/server merge policy.
- Add a unified operational error/ownership guide and compile-tested recovery example covering HTTP/1 parser/writer terminal states, HTTP/2 peer-fault scope, local versus poisoned send failures, HPACK/buffer lifetimes, and sharded connection ownership.
- Add compile-tested, transport-neutral HTTP/1 and HTTP/2 executable examples plus minimal fixed stream-store and synchronous field-sink reference implementations; `zig build check` now runs the examples to catch public API drift.
- Complete the policy-free RFC 9218 priority surface with allocation-free Structured Fields parsing/serialization for `u`/`i`, preserved omission/default semantics, extension-member validation, duplicate-key handling, and preflighted HTTP/2 PRIORITY_UPDATE writers.
- Harden HTTP/2 request-target semantics with RFC 3986 scheme/path/authority validation, scheme-specific HTTP/HTTPS empty-path and userinfo rules, asterisk-form OPTIONS checks, and strict host:port authority-form validation for traditional CONNECT.
- Add allocation-free HTTP/1 `MessageWriter` send-side composition with preflight request/response semantics, exact Content-Length accounting, chunked/trailer completion, close-delimited reuse prevention, HEAD/CONNECT protocol-switch boundaries, and writer-failure poisoning; raw head writers now validate all fields before emitting any bytes.

## 0.16.0

- Remove the accumulated pre-1.0 compatibility surface: HTTP/2 low-level types now live only under their owning namespaces, HTTP/1 raw parsers/body primitives likewise use `head`/`body`/`semantics`, `Session.init` accepts only named `Options`, HTTP/1 head writers take an explicit version, and the client preface lives at `http2.preface.bytes`. The composed shortcuts remain `http1.ConnectionDecoder` and `http2.Session`/`Event`/`Role`.
- Add a transport-fragmentation-invariance fuzz target for the composed HTTP/2 `Session`, comparing complete-frame receive against the incremental frame path while checking emitted events, HPACK field counts, peer/connection state, stream records, and aggregate stream counters after every generated frame.
- Harden HTTP/1 response status-line parsing by requiring the RFC-mandated SP after the status code, including when the reason phrase is empty.
- Replace naive `Transfer-Encoding` comma splitting with an allocation-free scanner that respects quoted-string commas and validates parameter syntax.
- Reject `Transfer-Encoding` on HTTP/1.0 requests and responses consistently across contiguous, incremental, and framed parser paths.
- Add a reproducible Zig 0.16.0 builtin-fuzz workaround using a fuzz-only vendored test runner, plus a stateful `FlowWindow` reference-model fuzz target.
- Add allocation-free HTTP/1 `ConnectionDecoder` composition over caller-owned storage, including strict request semantics, persistence, informational/final response sequencing, HEAD/CONNECT protocol switches, fixed/chunked/close-delimited bodies, trailers, and pipelined message boundaries without owning I/O or request queues.
- Add opt-out HTTP/1 request-target/Host validation, strict RFC 9112 chunk-extension grammar, and explicit HTTP/1.0 serialization while keeping the raw syntax/framing APIs independently usable.
- Expand deterministic fuzz/property coverage to six targets spanning fragmented HTTP/1 request/response parsing, chunk decoding, HTTP/2 frame decoding, flow-control state, and generated stream-manager lifecycle sequences.
- Add bidirectional external interoperability for both HTTP/1 and HTTP/2: curl/Python/hyper-h2 exercise Zig server fixtures and Zig protocol clients exercise independent Python/hyper-h2 servers.
- Add RFC 8441 `SETTINGS_ENABLE_CONNECT_PROTOCOL` and Extended CONNECT `:protocol` semantics with per-connection negotiation; application protocols such as WebSocket remain outside the HTTP core.
- Add `zig build check` as a dependency-free unit/property/fixture-compilation gate and keep full h2spec/external stacks as explicit optional test commands.
- Add public compile-time HTTP/2 structural-contract diagnostics for Session stream stores and field sinks, plus a named `Session.initOptions` initializer without replacing the existing positional API.
- Preserve unsupported HTTP/2 extension frames and raw validated SETTINGS payloads as zero-copy Session events so applications can implement negotiated extensions without dropping to a lower composition level; base Session still owns no extension policy.
- Add policy-free RFC 9218 identifiers and PRIORITY_UPDATE wire parsing under `http2.priority`; stream-priority storage and scheduling remain caller-owned.

## 0.15.0

- Add `http2.dispatch`, a connection-ordered receive front-end that commits CONTINUATION adjacency and connection DATA flow control before extracting DATA, RST_STREAM, and stream WINDOW_UPDATE as caller-routable stream-local work; HPACK/HEADERS, SETTINGS, GOAWAY, connection WINDOW_UPDATE, PING, and extensions remain on the ordered path.
- Add flat 32-byte `DispatchPrepared` and queue-oriented 32-byte `DispatchStreamWork` values plus typed DATA/RST_STREAM/WINDOW_UPDATE preparation APIs. `prepare*AssumeConnectionChecked()` integrates directly with `ConnectionCompleteIterator`/`ConnectionDecoder` so high-performance runtimes do not repeat connection-state checks.
- Add `StreamManager.receiveAbsent()` so a stream shard can report a lookup miss and let the ordered owner resolve high-water/GOAWAY RFC semantics without a second caller-store lookup. Existing fused receive methods use the same missing-stream classifier.
- Add a 12-byte `DataSendOffer` and connection-side `grantDataSend()` for sharded outbound DATA. The offer captures the peer initial-window value used by the stream probe; a later SETTINGS increase stays conservatively valid while an unsafe decrease returns `error.StaleStreamCredit`. Post-write stream commit no longer needs `PeerState`.
- Add `Session.receiveCompleteAssumeConnectionChecked()` for mixed composed/detached receive loops that already committed connection-wide state before deciding whether a frame remains on Session or is handed to a stream owner.
- Correct WINDOW_UPDATE error classification: an increment of zero on stream 0 remains a connection `PROTOCOL_ERROR`, while a non-zero stream now reaches stream-level handling and produces a stream `PROTOCOL_ERROR` as required by HTTP/2.
- Add real-corpus dispatch and send-offer benchmarks. Seven alternating runs measured a 24-byte manual handoff at 149.927 M DATA frames/s versus 140.088 M/s for the prechecked typed dispatch path (~-6.6%) and 117.678 M/s for the fully generic flat dispatch (~-21.5%); the offer/grant send split measured 125.692 M chunks/s versus 128.305 M/s manual (~-2.0%). These are deliberately tiny state-machine loops; fused Session paths remain specialized and do not pay these handoff costs.
- Re-check the existing composed hot paths against 0.14.0: alternating managed receive and stable-cursor send runs stayed in the same run-to-run range, with unchanged 13,835.6 outbound wire bytes/transaction. Persistent sizes remain `Tracked=12 B`, `StreamManager=36 B`, and `Session=128 B`.

## 0.14.0

- Add a 16-byte `DetachedStreamCursor` for runtimes that keep caller-owned HTTP/2 stream records on separate shards and do not want the ordered connection owner to hold a `StreamManager` pointer while applying common stream-local transitions.
- Add a 1-byte `StreamEffect` carrying only aggregate active-count and positive-send-adjustment bookkeeping back to `StreamManager`; explicit `ordersConcurrency()` and `ordersSettings()` hints expose the HTTP/2 ordering barriers without prescribing locks, atomics, queues, or a worker topology.
- Support detached receive-side DATA, RST_STREAM, and stream WINDOW_UPDATE transitions plus send-side DATA credit probing and checked/unchecked post-write DATA commits, while keeping manager-level routing/GOAWAY/missing-stream semantics available through the existing fused APIs.
- Keep the composed Session and stable `StreamCursor` on specialized direct hot paths after rejecting an initial implementation that reused the detached effect path and regressed the send-session benchmark by several percent.
- Extend `bench-real-streams` with a detached stable-record workload; seven CPU-pinned runs measured 122.029 M tx/s detached versus 122.666 M tx/s fused at the median (~-0.5%), while a final stable-cursor send-session A/B was flat at roughly 1.040 versus 1.041 M tx/s with identical wire output.
- Correct stale README documentation from the pre-0.13 Session store contract: ordinary initial-window SETTINGS changes no longer require a per-stream store hook, and only the rare overflow-validation path asks for `maxActiveSendAdjustment()`.
- Preserve `stream.Tracked` at 12 bytes, `StreamManager` at 36 bytes, and `Session` at 128 bytes; detached state is temporary and caller-owned.
- Pass Debug, ReleaseFast, and ReleaseSafe+ThreadSanitizer test configurations on Zig 0.16.0; the broad real-corpus benchmark remains in the established performance range.

## 0.13.0

- Represent each HTTP/2 stream send window as a signed adjustment relative to the peer's current `SETTINGS_INITIAL_WINDOW_SIZE`, removing the mandatory live-stream table mutation on ordinary SETTINGS changes.
- Keep SETTINGS initial-window decreases and safe increases O(1) in connection state while preserving overflow semantics: only an increase that could exceed `2^31-1` asks caller-owned storage for an exact `maxActiveSendAdjustment()`.
- Let stream stores implement that rare exact query by scanning, maintaining an aggregate, or coordinating shards, avoiding a core-imposed synchronization/storage strategy for multithreaded applications.
- Add an unchecked post-write DATA credit commit used by `Session` after its preflight succeeds, so the settings-relative representation does not duplicate effective-window work on the send hot path; checked lower-level operations remain available.
- Remove now-unnecessary peer-state dependencies from remote HEADERS/PUSH_PROMISE stream creation and expose `http2.StreamSendWindow` for consumers composing the lower-level protocol pieces directly.
- Add `bench-real-settings`, an isolated 4096-stream scalability workload: the old eager implementation performs 4096 stream mutations per initial-window SETTINGS (~0.410 M settings/s in the pinned five-run median), while the common relative-window path performs zero store scans (~527.3 M settings/s). This is an isolated control-plane scaling benchmark, not end-to-end HTTP throughput.
- Record the DATA-path tradeoff rather than hiding it: CPU-pinned five-run send-session medians stayed within ~0.6% for manual/lookup composition but the stable-cursor Session was ~2.8% below 0.12.0. Larger lazy-window records and encoded hybrid forms were rejected because cache footprint or Zig 0.16.0 compile-time costs were worse; the 12-byte `Tracked` layout is retained.
- Document the concurrency model explicitly: no process-global mutable protocol state, caller-owned/shardable stream storage, independent connections freely distributable across workers, and one logical mutator for each ordered HTTP/2 connection context unless the caller provides equivalent synchronization.
- Keep `stream.Tracked` at 12 bytes and `Session` at 128 bytes, and pass Debug, ReleaseFast, and ReleaseSafe+ThreadSanitizer test configurations on Zig 0.16.0.

## 0.12.0

- Define the library boundary explicitly: HTTP-only state, scheduling, flow-control, and shutdown orchestration stay in the `http1`/`http2` core; sockets, TLS, timers, event loops, thread pools, and cross-subsystem queues belong only in optional higher-level wrappers.
- Add a 12-byte caller-owned `http2.ReceiveCredit` low-watermark policy with two-phase proposal/commit semantics so freed receive capacity is never lost when WINDOW_UPDATE serialization fails.
- Add `Session.replenishConnectionReceive()`, `replenishStreamReceive()`, and stable-cursor replenishment without growing the 128-byte Session or 12-byte `stream.Tracked`.
- Expose the complete 24-bit flow-controlled DATA payload charge through `Data.flowControlledBytes()`, including padding, while packing it into existing event padding so `Data` remains 24 bytes and `Event` remains 32 bytes.
- Add caller-owned `GracefulGoAway` for the RFC 9113 two-phase server shutdown sequence; timing and the final application-processed stream cutoff remain explicit caller decisions.
- Re-run isolated receive/send Session benchmarks against 0.11.0 after the layout-sensitive additions; compact DATA accounting avoids the regression seen with an initially tested 32-byte Data event and keeps both hot paths in their established range.

## 0.11.0

- Add streaming outbound HTTP/2 `PUSH_PROMISE` support to Session, including bounded first-frame prefix handling, CONTINUATION framing, server/push-policy preflight, and reserved(local) promised-stream state.
- Add `Session.sendSettings()` plus an 8-byte caller-owned `SettingsSync` ticket tracker so received ACKs can be matched to sent SETTINGS in wire order without Session owning a policy queue.
- Validate locally generated SETTINGS before wire mutation, including ENABLE_PUSH role/value rules, INITIAL_WINDOW_SIZE bounds, and MAX_FRAME_SIZE bounds; failed writes do not create synchronization tickets.
- Add non-mutating Session DATA credit probes and a one-word caller-driven round-robin DATA scheduler that combines connection, stream, and peer frame-size credit while leaving buffers, priorities, wakeups, and queues to the application.
- Add a lower-overhead `nextAssumeValid()` scheduler path for event loops that already maintain a valid active-stream set, while retaining a checked `idle` / `blocked` / `ready` API.
- Add an isolated 64-stream scheduler benchmark using captured response body sizes and mixed stream/connection blocking; document its convenience overhead instead of presenting the helper as a scan-speed optimization.
- Keep `Session` at 128 bytes and `stream.Tracked` at 12 bytes; the new synchronization and scheduling state is caller-owned (8 bytes each on x86_64).
- Re-run the real send-session benchmark after the additions; HEADERS/DATA throughput remains in the established range with identical wire bytes per transaction.

## 0.10.0

- Add allocation-free HTTP/2 control-frame writers for SETTINGS, SETTINGS ACK, PING, RST_STREAM, WINDOW_UPDATE, and GOAWAY.
- Add state-aware `Session.sendSettingsAck()`, `sendPing()` / `sendPingAck()`, `sendWindowUpdate()`, `sendReset()`, and `sendGoAway()` paths while keeping Session at 128 bytes and `stream.Tracked` at 12 bytes.
- Commit local receive-window credit, stream reset state, and GOAWAY cutoffs only after the corresponding frame is successfully written; protocol/size preflight failures remain retry-safe while partial writer failures poison only the send side.
- Add stable-cursor WINDOW_UPDATE and RST_STREAM send variants for applications with expensive caller-owned stream lookup.
- Keep outbound SETTINGS value application caller-owned: `http2.send.writeSettings()` serializes ordered values without a whole-frame buffer while the application controls ACK-synchronized local policy changes.
- Re-run the isolated real send-session benchmark after the control-send additions; existing HEADERS/DATA throughput remains within run-to-run noise with identical wire bytes per transaction.

## 0.9.0

- Add streaming send-side HTTP/2 Session support for HPACK field blocks, emitting HEADERS plus CONTINUATION frames without buffering the complete encoded block.
- Bound outbound field-block memory by caller-owned staging storage; one lookahead byte preserves correct END_HEADERS placement when an encoded block exactly fills a frame payload.
- Add `Session.sendHeaders()` and `sendHeadersExisting()` with HTTP/2 field validation, request/response/informational/trailer phase tracking, stream lifecycle integration, and peer GOAWAY checks.
- Add `Session.sendData()` and `sendDataExisting()` with one-frame caller-driven backpressure constrained by peer MAX_FRAME_SIZE plus connection and stream send windows.
- Keep `Session` at 128 bytes and `stream.Tracked` at 12 bytes by storing the local field-section phase in existing per-stream padding and the send-poison bit in an impossible stream-id bit.
- Poison only the Session send side after HPACK/allocator or writer failures that may have partially advanced the connection compression/wire state; semantic and store preflight failures remain retry-safe.
- Add isolated `bench-real-send-session` cases over the real response corpus with production-like HPACK indexing and captured body sizes. Nine direct pinned runs measured the lookup Session about 1.7% below manual composition with identical wire bytes per transaction.

## 0.8.0

- Add a 128-byte allocation-free `Session` that composes complete-frame receive handling with connection rules, HPACK decoding, HTTP/2 field semantics, caller-owned stream transitions, peer SETTINGS/GOAWAY state, and DATA/window accounting.
- Add `Session.receiveBytes()` for validated zero-copy parse-and-dispatch from a contiguous transport buffer and `receiveComplete()` for callers that already parsed a complete frame.
- Track incoming request/response/trailer phase inside existing `stream.Tracked` padding, keeping the per-stream record at 12 bytes while supporting repeated informational responses, final responses, and trailers.
- Drain semantically malformed field sections through HPACK before returning a stream protocol fault, preserving connection compression state; drain HPACK header-list-limit failures through the supported iterator finish path as well.
- Apply peer SETTINGS in wire order through the session, including outbound HPACK table limits and caller-store `SETTINGS_INITIAL_WINDOW_SIZE` propagation.
- Remove the continuation-storage size requirement for single-frame HEADERS/PUSH_PROMISE blocks; caller storage is now required only when CONTINUATION assembly is actually needed.
- Add isolated `bench-real-session` manual-versus-managed composition cases over real response fields/body sizes; the 128-byte session is about 2.7% below equivalent manual composition in the pinned median.

## 0.7.0

- Add allocation-free `StreamManager` over caller-owned stream storage, enforcing stream initiator parity, monotonically increasing stream IDs, concurrent-stream limits, stream state transitions, and per-stream flow control.
- Add a short-lived `StreamCursor` / `streams.Existing` fast path for event loops that already hold a stable `Tracked` pointer, avoiding repeated slab/hash lookups across HEADERS, DATA, WINDOW_UPDATE, and local send handling.
- Add local GOAWAY tracking and `ignored_after_goaway` receive results while keeping HPACK and connection-flow minimal processing explicit at the connection layer.
- Add `unprocessedByPeer()` so callers can identify locally initiated streams that a received GOAWAY proves were not processed.
- Keep the stream table fully caller-owned: the required store contract is only `get` plus `insert`, with removal policy left to the application.
- Add isolated `bench-real-streams` cases for lookup-heavy, stable-pointer, and 64-stream multiplexed lifecycles using captured response body sizes.
- Add `-Dsanitize-thread=true` build support and propagate ThreadSanitizer instrumentation through both `http` and the pinned `hpack` dependency.
- Keep zero WINDOW_UPDATE increments as stream PROTOCOL_ERROR even on a closed stream, while valid late WINDOW_UPDATE remains accepted.

## 0.6.0

- Add allocation-free HTTP/2 `ConnectionState` / `ConnectionDecoder` primitives that enforce CONTINUATION adjacency and connection receive flow control across complete and fragmented transport reads.
- Add a compact `ConnectionViolation` fast path so event loops can map protocol and flow-control failures directly to HTTP/2 connection errors without forcing an error-union wrapper into the fragmented hot path.
- Add `PeerState` for ordered peer SETTINGS application, connection send credit, outbound maximum-frame/push checks, stream WINDOW_UPDATE routing, and monotonic GOAWAY tracking.
- Add a seven-byte streaming SETTINGS decoder for setting values split across transport boundaries.
- Add 8-byte caller-owned per-stream flow windows and a 12-byte `Tracked` stream record, leaving stream-table allocation/layout entirely to the application.
- Correct zero WINDOW_UPDATE increments to surface a protocol violation; flow-window overflow remains a flow-control violation.
- Add `bench-real-frames`, which compiles raw/connection and complete/fragmented HTTP/2 cases as separate executables to avoid Zig 0.16 code-layout/inlining cross-contamination between benchmark cases.
- Keep the broad `bench-real` corpus unchanged from 0.5.0 so historical HTTP/1, field-validation, and raw frame baselines remain comparable.

## 0.5.0

- Add an offline real-world protocol benchmark covering diverse captured HTTP headers, fragmented reads, body framing, HTTP/2 field validation, and realistic HEADERS/DATA frame traces.
- Fix HTTP/2 frame serialization for payload lengths above 255 bytes by encoding all three 24-bit length octets correctly.
- Update the standalone `hpack` dependency to 0.4.1.
- Add `FramedHeadParser`, an opt-in incremental HTTP/1 parser that spends a small amount of extra state to accumulate framing while lines arrive and avoid the final header-field traversal.
- Split common HTTP/2 DATA/HEADERS validation from uncommon frame validation and inline the incremental decoder hot path without increasing its 20-byte state.
- Refine `CompleteFrameIterator` to retain a shrinking input remainder and reuse the validated complete-frame parser.
- Extend the real-world benchmark so HTTP/1 compact versus streaming framed parsing and HTTP/2 direct complete parsing versus iteration are measured on identical corpus data.

## 0.4.0

- Parse contiguous HTTP/1 heads line-by-line without a preliminary CRLF-CRLF scan.
- Use process-wide byte-class tables, four-byte token validation, and short SIMD blocks for HTTP field validation.
- Keep the validation tables to 512 bytes of read-only process state; persistent per-connection parser sizes are unchanged.
- Collapse HTTP/2 frame stream/length validation into one frame-type dispatch.
- Add `CompleteFrameIterator` for zero-copy traversal of multiple complete frames in one transport buffer.
- Accelerate HTTP/2 field validation with direct pseudo-header classification, one-pass lowercase token checks, and SIMD value checks.
- Enforce the RFC 9113 prohibition on leading/trailing SP or HTAB in HTTP/2 field values.
- Extend the regression benchmark with batched HTTP/2 frame traversal and field validation.

## 0.3.0

- Add zero-copy contiguous HTTP/1 request and response head parsing.
- Add single-pass request/response framing APIs that avoid a second field traversal.
- Add incremental single-pass framing methods to `HeadParser`.
- Parse complete chunk-size and trailer lines directly from transport input, buffering only fragmented lines.
- Add checked chunk-size and content-length arithmetic and stricter control-byte validation.
- Add a stateless zero-copy HTTP/2 complete-frame parser for contiguous transport buffers.
- Compact HTTP/1 and HTTP/2 parser state, including 32-bit flow-control windows and sentinel-based continuation state.
- Avoid copying HPACK field blocks completed in a single HEADERS or PUSH_PROMISE frame.
- Tighten flag-dependent HTTP/2 frame length validation.
- Ensure the root test target executes all nested protocol tests under Zig 0.16.0 lazy analysis.
- Add reproducible ReleaseFast parser microbenchmarks with `zig build bench`.

## 0.2.2

- Update the standalone `hpack` dependency to 0.3.0.

## 0.2.1

- Update the standalone `hpack` dependency to 0.2.0.

## 0.2.0

- Extract HPACK into the standalone `hpack` package.

## 0.1.0

- Initial HTTP/1.1 and HTTP/2 protocol core with streaming parsers, framing, flow control, and HPACK support.
