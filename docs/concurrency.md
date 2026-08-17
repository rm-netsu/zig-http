# Concurrency and ownership

`zig-http` has no process-global mutable protocol state. Independent connection
objects can therefore run on different threads without library-side locking.

## HTTP/1

Each `ConnectionDecoder` or `MessageWriter` is one message/connection state
machine. Give a particular instance one logical mutator at a time. The transport,
request queue, timeout policy, and worker assignment are caller-owned.

## HTTP/2 ordered connection context

One HTTP/2 connection has ordered state that cannot be processed independently:

- HPACK dynamic tables;
- SETTINGS application and acknowledgement order;
- CONTINUATION adjacency;
- connection flow control;
- remote stream-ID high-water state;
- GOAWAY cutoffs.

Give that ordered context one logical mutator at a time, or provide externally
equivalent serialization when ownership moves between workers.

## Sharded stream work

The stream table itself is caller-owned and may be partitioned. `http2.dispatch`
lets the ordered connection owner commit connection-wide invariants and then hand
DATA, RST_STREAM, and stream WINDOW_UPDATE work to the relevant stream owner.

Dispatch DATA slices are zero-copy aliases of the transport buffer. A queued or
cross-thread work item therefore requires the caller to keep the backing buffer
alive until consumption completes.

`StreamEffect.ordersConcurrency()` and `ordersSettings()` indicate effects that
must return to the ordered connection owner before later connection decisions
that depend on those aggregates/settings.

## SETTINGS_INITIAL_WINDOW_SIZE

The composed Session stores each stream send window as an adjustment relative to
the current peer initial-window value. Normal setting changes are O(1) at the
connection layer instead of sweeping every stream. The rare possible-overflow
case asks the caller-owned store for `maxActiveSendAdjustment()`; the store may
answer by scanning, maintaining an aggregate, or coordinating shards.

This representation is a Session implementation choice, not a restriction on
lower-level consumers. Applications may compose `FlowWindow`, `StreamSendWindow`,
and stream primitives with another storage policy.

## Failure ownership

A connection-level peer fault terminates the connection owner after an optional
GOAWAY attempt. A stream-level fault normally resets only the affected stream.
Outbound send poisoning is terminal for that transport. See
[`operations.md`](operations.md) for the exact recovery matrix.
