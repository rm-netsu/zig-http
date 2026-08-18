const std = @import("std");
const frame = @import("frame.zig");
const peer_mod = @import("peer.zig");
const protocol = @import("protocol.zig");
const stream_mod = @import("stream.zig");

pub const Role = peer_mod.Role;
pub const Tracked = stream_mod.Tracked;
pub const State = stream_mod.State;

/// Limits advertised by the local endpoint and therefore enforced on streams
/// initiated by the remote peer.
pub const LocalLimits = struct {
    initial_window_size: u31 = 65_535,
    max_concurrent_streams: u32 = std.math.maxInt(u32),
    /// Effective inbound push policy. A client that sends
    /// SETTINGS_ENABLE_PUSH=0 should change this to false only once that
    /// SETTINGS value has been acknowledged, matching RFC 9113 synchronization.
    /// The value has no effect for a server because clients cannot push.
    enable_push: bool = true,
};

pub const ReceiveResult = enum(u8) {
    accepted,
    connection_protocol,
    connection_stream_closed,
    stream_protocol,
    stream_closed,
    stream_flow_control,
    refused_stream,
    ignored_after_goaway,

    pub inline fn errorCode(self: ReceiveResult) ?protocol.ErrorCode {
        return switch (self) {
            .accepted => null,
            .connection_protocol, .stream_protocol => .protocol_error,
            .connection_stream_closed => .stream_closed,
            .stream_closed => .stream_closed,
            .stream_flow_control => .flow_control_error,
            .refused_stream => .refused_stream,
            .ignored_after_goaway => null,
        };
    }

    pub inline fn isConnectionError(self: ReceiveResult) bool {
        return self == .connection_protocol or self == .connection_stream_closed;
    }
};

pub const LocalError = error{
    Protocol,
    StreamClosed,
    FlowControl,
    PeerLimit,
    StoreFull,
    GoAway,
};

pub const StreamLocalError = error{ Protocol, StreamClosed, FlowControl };

pub const AbsentFrame = enum(u2) { data, reset, window_update };

/// Compact connection-level bookkeeping produced by stream-local operations.
/// A detached worker can mutate only its caller-owned `Tracked` record and
/// return this value to the ordered connection owner. No locking, atomics, or
/// queueing policy is implied by core.
pub const StreamEffect = packed struct(u8) {
    activity: Activity = .none,
    positive_send_adjustment: bool = false,
    _reserved: u5 = 0,

    pub const Activity = enum(u2) { none, activated, deactivated };

    pub inline fn empty(self: StreamEffect) bool {
        return self.activity == .none and !self.positive_send_adjustment;
    }

    /// Activity changes affect SETTINGS_MAX_CONCURRENT_STREAMS enforcement and
    /// should be committed before the connection owner makes a decision that
    /// requires an exact active-stream count. Delaying a deactivation is safe
    /// but can conservatively refuse otherwise admissible new work.
    pub inline fn ordersConcurrency(self: StreamEffect) bool {
        return self.activity != .none;
    }

    /// Positive send-window effects participate in validation of later
    /// SETTINGS_INITIAL_WINDOW_SIZE increases and therefore must reach the
    /// ordered connection owner before such a SETTINGS transition is applied.
    pub inline fn ordersSettings(self: StreamEffect) bool {
        return self.positive_send_adjustment;
    }
};

pub const DetachedResult = struct {
    result: ReceiveResult,
    effect: StreamEffect = .{},
};

/// Stream-local outbound DATA credit captured under one ordered peer
/// SETTINGS_INITIAL_WINDOW_SIZE value. The connection owner can combine this
/// with its own connection window and MAX_FRAME_SIZE without reading `Tracked`.
pub const DataSendOffer = struct {
    stream_id: u31,
    peer_initial_window: u31,
    max_payload: u31,

    /// Commits stream-local DATA state after the connection owner accepted this
    /// offer and successfully wrote `amount` bytes. No PeerState is required on
    /// the stream shard during commit.
    pub inline fn commit(self: DataSendOffer, detached: Detached, amount: u32, end_stream: bool) StreamEffect {
        std.debug.assert(detached.stream_id == self.stream_id);
        std.debug.assert(amount <= self.max_payload);
        return detached.localDataAssumeGranted(amount, end_stream);
    }
};

/// Stream-local cursor that deliberately has no pointer to `Manager`. This is
/// the low-level path for sharded stores: a worker can process common existing-
/// stream frames against its own stable record, then hand the tiny `StreamEffect`
/// back to the connection owner for aggregate accounting.
///
/// The caller must already have resolved HTTP/2 routing invariants that depend
/// on Manager (stream-id validity, GOAWAY cutoff, missing-record semantics).
/// Lookup-based `Manager` methods remain the fully routed convenience path; an
/// `Existing` cursor keeps aggregate Manager commits fused to a stable record.
pub const Detached = struct {
    stream_id: u31,
    tracked: *Tracked,

    /// Probes only stream-local DATA credit/state. The connection owner can
    /// combine this with connection credit and SETTINGS_MAX_FRAME_SIZE without
    /// sharing `Manager` or the whole `PeerState` with this worker.
    pub inline fn dataSendCredit(self: Detached, peer_initial_window: u31) StreamLocalError!u31 {
        return dataSendCreditDetached(self.tracked, peer_initial_window);
    }

    /// Captures stream-local credit plus the SETTINGS snapshot that made it
    /// valid. This is the preferred handoff object when stream state and the
    /// ordered connection send state live on different workers.
    pub inline fn dataSendOffer(self: Detached, peer_initial_window: u31) StreamLocalError!DataSendOffer {
        return .{
            .stream_id = self.stream_id,
            .peer_initial_window = peer_initial_window,
            .max_payload = try self.dataSendCredit(peer_initial_window),
        };
    }

    /// Checked stream-local DATA transition. Prefer `localDataAssumeCredit`
    /// after a successful wire write when the same credit was already probed.
    pub inline fn localData(self: Detached, peer_initial_window: u31, payload_length: u32, end_stream: bool) StreamLocalError!StreamEffect {
        return localDataDetached(self.tracked, peer_initial_window, payload_length, end_stream);
    }

    /// Commit half of a two-phase send: caller first probes stream/connection
    /// credit, writes DATA, then commits the stream-local state only after the
    /// writer succeeds. Returned aggregate bookkeeping can be handed back to
    /// the connection owner separately.
    pub inline fn localDataAssumeCredit(self: Detached, peer_initial_window: u31, payload_length: u32, end_stream: bool) StreamEffect {
        return localDataDetachedAssumeCredit(self.tracked, peer_initial_window, payload_length, end_stream);
    }

    /// Commit-only counterpart for an accepted `DataSendOffer`. The caller must
    /// preserve per-stream operation order and call this only after the DATA
    /// write succeeds. Credit validation happened before the wire mutation.
    pub inline fn localDataAssumeGranted(self: Detached, payload_length: u32, end_stream: bool) StreamEffect {
        return localDataDetachedCommit(self.tracked, payload_length, end_stream);
    }

    pub inline fn localReset(self: Detached) error{Protocol}!StreamEffect {
        return localResetDetached(self.tracked);
    }

    pub inline fn receiveData(self: Detached, payload_length: u32, end_stream: bool) DetachedResult {
        return receiveDataDetached(self.tracked, payload_length, end_stream);
    }

    pub inline fn receiveReset(self: Detached) DetachedResult {
        return receiveResetDetached(self.tracked);
    }

    /// `peer_initial_window` must be the SETTINGS value ordered before this
    /// WINDOW_UPDATE frame. Passing it explicitly makes the dependency visible
    /// without sharing the entire connection/PeerState with the stream worker.
    pub inline fn receiveWindowUpdate(self: Detached, peer_initial_window: u31, increment: u31) DetachedResult {
        return receiveWindowUpdateDetached(self.tracked, peer_initial_window, increment);
    }
};

inline fn streamEffect(before: State, after: State) StreamEffect {
    const was_active = Manager.isActive(before);
    const now_active = Manager.isActive(after);
    return .{ .activity = if (was_active == now_active)
        .none
    else if (now_active)
        .activated
    else
        .deactivated };
}

inline fn dataSendCreditDetached(tracked: *const Tracked, peer_initial_window: u31) StreamLocalError!u31 {
    switch (tracked.stream.state) {
        .open, .half_closed_remote => {},
        .half_closed_local, .closed => return error.StreamClosed,
        else => return error.Protocol,
    }
    return tracked.windows.send.available(peer_initial_window);
}

inline fn localDataDetached(
    tracked: *Tracked,
    peer_initial_window: u31,
    payload_length: u32,
    end_stream: bool,
) StreamLocalError!StreamEffect {
    switch (tracked.stream.state) {
        .open, .half_closed_remote => {},
        .half_closed_local, .closed => return error.StreamClosed,
        else => return error.Protocol,
    }
    tracked.windows.consumeSend(peer_initial_window, payload_length) catch return error.FlowControl;
    const before = tracked.stream.state;
    tracked.stream.localData(end_stream) catch unreachable;
    return streamEffect(before, tracked.stream.state);
}

inline fn localDataDetachedAssumeCredit(
    tracked: *Tracked,
    peer_initial_window: u31,
    payload_length: u32,
    end_stream: bool,
) StreamEffect {
    std.debug.assert(tracked.windows.send.available(peer_initial_window) >= payload_length);
    return localDataDetachedCommit(tracked, payload_length, end_stream);
}

inline fn localDataDetachedCommit(
    tracked: *Tracked,
    payload_length: u32,
    end_stream: bool,
) StreamEffect {
    std.debug.assert(tracked.stream.state == .open or tracked.stream.state == .half_closed_remote);
    tracked.windows.consumeSendAssumeAvailable(payload_length);
    const before = tracked.stream.state;
    tracked.stream.localData(end_stream) catch unreachable;
    return streamEffect(before, tracked.stream.state);
}

inline fn localResetDetached(tracked: *Tracked) error{Protocol}!StreamEffect {
    const before = tracked.stream.state;
    tracked.stream.reset() catch return error.Protocol;
    return streamEffect(before, tracked.stream.state);
}

inline fn receiveDataDetached(tracked: *Tracked, payload_length: u32, end_stream: bool) DetachedResult {
    switch (tracked.stream.state) {
        .open, .half_closed_local => {},
        .half_closed_remote, .closed => return .{ .result = .stream_closed },
        else => return .{ .result = .connection_protocol },
    }
    tracked.windows.receiveData(payload_length) catch return .{ .result = .stream_flow_control };
    const before = tracked.stream.state;
    tracked.stream.remoteData(end_stream) catch unreachable;
    return .{ .result = .accepted, .effect = streamEffect(before, tracked.stream.state) };
}

inline fn receiveResetDetached(tracked: *Tracked) DetachedResult {
    const before = tracked.stream.state;
    tracked.stream.reset() catch return .{ .result = .connection_protocol };
    return .{ .result = .accepted, .effect = streamEffect(before, tracked.stream.state) };
}

inline fn receiveWindowUpdateDetached(tracked: *Tracked, peer_initial_window: u31, increment: u31) DetachedResult {
    if (increment == 0) return .{ .result = .stream_protocol };
    switch (tracked.stream.state) {
        .reserved_remote => return .{ .result = .connection_protocol },
        .closed => return .{ .result = .accepted },
        .idle => return .{ .result = .connection_protocol },
        else => {},
    }
    tracked.windows.peerWindowUpdate(peer_initial_window, increment) catch
        return .{ .result = .stream_flow_control };
    return .{
        .result = .accepted,
        .effect = .{ .positive_send_adjustment = (tracked.stream.state == .open or tracked.stream.state == .half_closed_remote) and
            tracked.windows.send.adjustment > 0 },
    };
}

/// Short-lived zero-allocation cursor for callers that already have a stable
/// pointer from their stream store. The pointer remains owned by the caller and
/// must not outlive any store operation that can move or remove the record.
pub const Existing = struct {
    manager: *Manager,
    stream_id: u31,
    tracked: *Tracked,

    /// Drops the Manager reference for stream-local work. Effects returned by
    /// the detached cursor can later be committed with `Manager.commitStreamEffect`.
    pub inline fn detached(self: Existing) Detached {
        return .{ .stream_id = self.stream_id, .tracked = self.tracked };
    }

    pub inline fn receiveHeaders(self: Existing, end_stream: bool) ReceiveResult {
        return self.manager.receiveHeadersTracked(self.stream_id, self.tracked, end_stream);
    }

    pub inline fn receiveData(self: Existing, payload_length: u32, end_stream: bool) ReceiveResult {
        return self.manager.receiveDataTracked(self.stream_id, self.tracked, payload_length, end_stream);
    }

    pub inline fn receiveReset(self: Existing) ReceiveResult {
        return self.manager.receiveResetTracked(self.stream_id, self.tracked);
    }

    pub inline fn receiveWindowUpdate(self: Existing, peer: *const peer_mod.State, increment: u31) ReceiveResult {
        return self.manager.receiveWindowUpdateTracked(peer, self.stream_id, self.tracked, increment);
    }

    pub inline fn localHeaders(self: Existing, peer: *const peer_mod.State, end_stream: bool) LocalError!void {
        try self.manager.localHeadersTracked(peer, self.stream_id, self.tracked, end_stream);
    }

    pub inline fn localData(self: Existing, peer: *const peer_mod.State, payload_length: u32, end_stream: bool) LocalError!void {
        try self.manager.localDataTracked(peer, self.stream_id, self.tracked, payload_length, end_stream);
    }

    pub inline fn localReset(self: Existing) LocalError!void {
        try self.manager.localResetTracked(self.stream_id, self.tracked);
    }

    /// Records receive credit after the local endpoint emits a stream-level
    /// WINDOW_UPDATE for this stream.
    pub inline fn creditReceive(self: Existing, increment: u31) LocalError!void {
        self.tracked.windows.creditReceive(increment) catch return error.FlowControl;
    }
};

/// Stream lifecycle/accounting independent of the application's storage.
///
/// `store` arguments are comptime duck-typed and need only provide:
///
///     get(stream_id: u31) ?*http2.stream.Tracked
///     insert(stream_id: u31, value: http2.stream.Tracked) ?*http2.stream.Tracked
///
/// The store may remove closed records when its application policy permits.
/// `Manager` retains high-water stream identifiers, so skipped or removed older
/// identifiers are never mistaken for idle streams. Retaining a recently closed
/// record lets applications preserve the RFC 9113 race-tolerant handling of late
/// frames after END_STREAM/RST_STREAM; removing it opts into the stricter
/// high-water-only closed-stream behavior.
pub const Manager = struct {
    // High bit is spare in HTTP/2 stream identifiers and records whether an
    // active stream has ever observed positive send-window adjustment since
    // the last exact validation scan. This avoids growing Manager/Session.
    highest_local_bits: u32 = 0,
    highest_remote_stream_id: u31 = 0,
    local_active: u32 = 0,
    remote_active: u32 = 0,
    local_limits: LocalLimits = .{},
    local_role: Role,
    // RFC 8441 capability this endpoint has actually advertised on the wire.
    // It lives here beside local role/policy state and consumes existing
    // alignment padding rather than growing Session.
    extended_connect_advertised: bool = false,
    // Bit 31 cannot occur in an HTTP/2 stream identifier and therefore acts as
    // an allocation-free "no local GOAWAY sent" sentinel.
    local_goaway_last_stream_id: u32 = no_goaway,

    const no_goaway: u32 = 0x8000_0000;
    const positive_send_adjustment_bit: u32 = 0x8000_0000;
    const stream_id_mask: u32 = 0x7fff_ffff;

    pub inline fn highestLocalStreamId(self: Manager) u31 {
        return @intCast(self.highest_local_bits & stream_id_mask);
    }

    inline fn positiveSendAdjustmentSeen(self: Manager) bool {
        return (self.highest_local_bits & positive_send_adjustment_bit) != 0;
    }

    inline fn notePositiveSendAdjustment(self: *Manager) void {
        self.highest_local_bits |= positive_send_adjustment_bit;
    }

    inline fn clearPositiveSendAdjustment(self: *Manager) void {
        self.highest_local_bits &= stream_id_mask;
    }

    pub fn init(local_role: Role, local_limits: LocalLimits) Manager {
        return .{ .local_role = local_role, .local_limits = local_limits };
    }

    pub inline fn extendedConnectAdvertised(self: Manager) bool {
        return self.extended_connect_advertised;
    }

    pub inline fn setExtendedConnectAdvertised(self: *Manager, enabled: bool) void {
        // RFC 8441 capability cannot be withdrawn once value 1 is sent.
        std.debug.assert(!self.extended_connect_advertised or enabled);
        self.extended_connect_advertised = enabled;
    }

    pub inline fn localInitiated(self: Manager, stream_id: u31) bool {
        return switch (self.local_role) {
            .client => protocol.clientInitiated(stream_id),
            .server => protocol.serverInitiated(stream_id),
        };
    }

    pub inline fn remoteInitiated(self: Manager, stream_id: u31) bool {
        return stream_id != 0 and !self.localInitiated(stream_id);
    }

    pub inline fn activeLocal(self: Manager) u32 {
        return self.local_active;
    }

    pub inline fn activeRemote(self: Manager) u32 {
        return self.remote_active;
    }

    pub const InitialWindowApplyError = error{ FlowControl, ExactWindowScanRequired };

    /// Validates a peer SETTINGS_INITIAL_WINDOW_SIZE change without touching
    /// every stream in the common case. Decreases are always safe with respect
    /// to the upper bound. Increases use a packed positive-adjustment marker;
    /// only a potential 2^31-1 overflow requires the caller to provide an exact
    /// maximum adjustment across open/half-closed(remote) streams.
    pub fn applyPeerInitialWindow(
        self: *Manager,
        change: peer_mod.State.InitialWindowChange,
        exact_active_max_adjustment: ?i32,
    ) InitialWindowApplyError!void {
        if (change.new <= change.old or !self.positiveSendAdjustmentSeen()) return;

        const exact = exact_active_max_adjustment orelse return error.ExactWindowScanRequired;
        if (@as(i64, change.new) + @as(i64, @max(exact, 0)) > 0x7fff_ffff)
            return error.FlowControl;
        // An exact scan that found no positive active adjustment lets future
        // SETTINGS increases return to the O(1) path until another WINDOW_UPDATE
        // grows a locally-sendable stream above its initial window.
        if (exact <= 0) self.clearPositiveSendAdjustment();
    }

    pub inline fn sendWindowAvailable(self: Manager, peer: *const peer_mod.State, tracked: *const Tracked) u31 {
        _ = self;
        return tracked.windows.send.available(peer.settings.initial_window_size);
    }

    /// Records the last peer-initiated stream identifier placed in a locally
    /// sent GOAWAY. Repeated GOAWAY values may only stay equal or decrease.
    pub fn sentGoAway(self: *Manager, last_stream_id: u31) LocalError!void {
        if (last_stream_id != 0 and !self.remoteInitiated(last_stream_id)) return error.Protocol;
        if (self.local_goaway_last_stream_id != no_goaway and last_stream_id > self.local_goaway_last_stream_id)
            return error.Protocol;
        self.local_goaway_last_stream_id = last_stream_id;
    }

    pub inline fn goAwaySent(self: Manager) bool {
        return self.local_goaway_last_stream_id != no_goaway;
    }

    pub inline fn lastSentGoAwayStream(self: Manager) ?u31 {
        if (!self.goAwaySent()) return null;
        return @intCast(self.local_goaway_last_stream_id);
    }

    /// True for a locally initiated stream that the peer's received GOAWAY
    /// proves was not processed and can therefore be retried on a new
    /// connection according to application semantics.
    pub inline fn unprocessedByPeer(self: Manager, peer: *const peer_mod.State, stream_id: u31) bool {
        if (!self.localInitiated(stream_id)) return false;
        const last = peer.lastGoAwayStream() orelse return false;
        return stream_id > last;
    }

    /// Returns a short-lived cursor when the caller knows its store keeps the
    /// returned pointer stable for the duration of the cursor.
    pub inline fn existing(self: *Manager, store: anytype, stream_id: u31) ?Existing {
        const tracked = store.get(stream_id) orelse return null;
        return .{ .manager = self, .stream_id = stream_id, .tracked = tracked };
    }

    fn absentClosed(self: Manager, stream_id: u31) bool {
        if (stream_id == 0) return false;
        const highest = if (self.localInitiated(stream_id)) self.highestLocalStreamId() else self.highest_remote_stream_id;
        return stream_id <= highest;
    }

    /// Classifies an already-confirmed missing stream record without touching
    /// caller-owned storage. This is the routing counterpart to `Detached`: a
    /// shard can report a miss and let the ordered connection owner resolve the
    /// RFC high-water/GOAWAY semantics without repeating the store lookup.
    pub inline fn receiveAbsent(self: Manager, kind: AbsentFrame, stream_id: u31) ReceiveResult {
        if (stream_id == 0) return .connection_protocol;
        if (self.ignoredAfterGoAway(stream_id)) return .ignored_after_goaway;
        if (!self.absentClosed(stream_id)) return .connection_protocol;
        return switch (kind) {
            .data => .stream_closed,
            .reset, .window_update => .accepted,
        };
    }

    inline fn ignoredAfterGoAway(self: Manager, stream_id: u31) bool {
        if (self.local_goaway_last_stream_id == no_goaway or !self.remoteInitiated(stream_id)) return false;
        return stream_id > self.local_goaway_last_stream_id;
    }

    inline fn isActive(state: State) bool {
        return state == .open or state == .half_closed_local or state == .half_closed_remote;
    }

    /// Applies aggregate bookkeeping returned by a detached stream-local
    /// operation. Effects are tiny values, so runtimes can return them through
    /// their existing handoff mechanism without exposing stream storage to the
    /// connection owner.
    pub inline fn commitStreamEffect(self: *Manager, stream_id: u31, effect: StreamEffect) void {
        std.debug.assert(stream_id != 0);
        const counter = if (self.localInitiated(stream_id)) &self.local_active else &self.remote_active;
        switch (effect.activity) {
            .none => {},
            .activated => counter.* += 1,
            .deactivated => {
                std.debug.assert(counter.* != 0);
                counter.* -= 1;
            },
        }
        if (effect.positive_send_adjustment) self.notePositiveSendAdjustment();
    }

    fn adjustActive(self: *Manager, stream_id: u31, before: State, after: State) void {
        const was_active = isActive(before);
        const now_active = isActive(after);
        if (was_active == now_active) return;
        const counter = if (self.localInitiated(stream_id)) &self.local_active else &self.remote_active;
        if (now_active) {
            counter.* += 1;
        } else {
            std.debug.assert(counter.* != 0);
            counter.* -= 1;
        }
    }

    fn remoteLimitAvailable(self: Manager) bool {
        return self.remote_active < self.local_limits.max_concurrent_streams;
    }

    fn peerLimitAvailable(self: Manager, peer: *const peer_mod.State) bool {
        return self.local_active < peer.settings.max_concurrent_streams;
    }

    fn newTracked(self: Manager) Tracked {
        return Tracked.init(self.local_limits.initial_window_size);
    }

    /// Registers a client-initiated request stream before sending its first
    /// HEADERS frame. Servers cannot open an idle stream directly; they reserve
    /// push streams with `reserveLocal` and later call `localHeaders`.
    pub fn openLocal(self: *Manager, store: anytype, peer: *const peer_mod.State, stream_id: u31, end_stream: bool) LocalError!void {
        if (self.local_role != .client or stream_id == 0 or !self.localInitiated(stream_id)) return error.Protocol;
        if (stream_id <= self.highestLocalStreamId() or store.get(stream_id) != null) return error.Protocol;
        if (peer.goAwayReceived()) return error.GoAway;
        if (!self.peerLimitAvailable(peer)) return error.PeerLimit;

        var value = self.newTracked();
        try value.stream.localHeaders(end_stream);
        const inserted = store.insert(stream_id, value) orelse return error.StoreFull;
        _ = inserted;
        self.highest_local_bits = (self.highest_local_bits & positive_send_adjustment_bit) | @as(u32, stream_id);
        self.local_active += 1;
    }

    /// Reserves a server-initiated push stream before sending PUSH_PROMISE.
    pub fn reserveLocal(self: *Manager, store: anytype, peer: *const peer_mod.State, associated_stream_id: u31, promised_stream_id: u31) LocalError!void {
        if (self.local_role != .server or !peer.settings.enable_push) return error.Protocol;
        if (peer.goAwayReceived()) return error.GoAway;
        if (associated_stream_id == 0 or !self.remoteInitiated(associated_stream_id)) return error.Protocol;
        const associated = store.get(associated_stream_id) orelse return error.Protocol;
        if (associated.stream.state != .open and associated.stream.state != .half_closed_remote) return error.Protocol;
        if (promised_stream_id == 0 or !self.localInitiated(promised_stream_id) or promised_stream_id <= self.highestLocalStreamId())
            return error.Protocol;
        if (store.get(promised_stream_id) != null) return error.Protocol;

        var value = self.newTracked();
        try value.stream.reserveLocal();
        _ = store.insert(promised_stream_id, value) orelse return error.StoreFull;
        self.highest_local_bits = (self.highest_local_bits & positive_send_adjustment_bit) | @as(u32, promised_stream_id);
    }

    /// Applies locally sent HEADERS to an existing stream, including the
    /// reserved(local) -> half-closed(remote) transition for server push.
    pub fn localHeaders(self: *Manager, store: anytype, peer: *const peer_mod.State, stream_id: u31, end_stream: bool) LocalError!void {
        const tracked = store.get(stream_id) orelse return error.StreamClosed;
        try self.localHeadersTracked(peer, stream_id, tracked, end_stream);
    }

    pub fn localHeadersTracked(self: *Manager, peer: *const peer_mod.State, stream_id: u31, tracked: *Tracked, end_stream: bool) LocalError!void {
        const before = tracked.stream.state;
        if (before == .reserved_local) {
            if (peer.goAwayReceived()) return error.GoAway;
            if (!self.peerLimitAvailable(peer)) return error.PeerLimit;
        }
        tracked.stream.localHeaders(end_stream) catch |err| switch (err) {
            error.StreamClosed => return error.StreamClosed,
            error.Protocol => return error.Protocol,
        };
        self.adjustActive(stream_id, before, tracked.stream.state);
    }

    pub fn localData(self: *Manager, store: anytype, peer: *const peer_mod.State, stream_id: u31, payload_length: u32, end_stream: bool) LocalError!void {
        const tracked = store.get(stream_id) orelse return error.StreamClosed;
        try self.localDataTracked(peer, stream_id, tracked, payload_length, end_stream);
    }

    pub fn localDataTracked(self: *Manager, peer: *const peer_mod.State, stream_id: u31, tracked: *Tracked, payload_length: u32, end_stream: bool) LocalError!void {
        switch (tracked.stream.state) {
            .open, .half_closed_remote => {},
            .half_closed_local, .closed => return error.StreamClosed,
            else => return error.Protocol,
        }
        tracked.windows.consumeSend(peer.settings.initial_window_size, payload_length) catch return error.FlowControl;
        const before = tracked.stream.state;
        tracked.stream.localData(end_stream) catch |err| switch (err) {
            error.StreamClosed => return error.StreamClosed,
            error.Protocol => return error.Protocol,
        };
        self.adjustActive(stream_id, before, tracked.stream.state);
    }

    /// Commit-only DATA transition for callers that already checked stream state
    /// and send credit against the same ordered connection state. The Session
    /// uses this after the frame write succeeds; external event loops can use it
    /// when they retain equivalent invariants.
    pub inline fn localDataTrackedAssumeCredit(
        self: *Manager,
        peer: *const peer_mod.State,
        stream_id: u31,
        tracked: *Tracked,
        payload_length: u32,
        end_stream: bool,
    ) void {
        std.debug.assert(tracked.stream.state == .open or tracked.stream.state == .half_closed_remote);
        std.debug.assert(tracked.windows.send.available(peer.settings.initial_window_size) >= payload_length);
        tracked.windows.consumeSendAssumeAvailable(payload_length);
        const before = tracked.stream.state;
        tracked.stream.localData(end_stream) catch unreachable;
        self.adjustActive(stream_id, before, tracked.stream.state);
    }

    pub fn localReset(self: *Manager, store: anytype, stream_id: u31) LocalError!void {
        const tracked = store.get(stream_id) orelse {
            if (self.absentClosed(stream_id)) return;
            return error.Protocol;
        };
        try self.localResetTracked(stream_id, tracked);
    }

    pub fn localResetTracked(self: *Manager, stream_id: u31, tracked: *Tracked) LocalError!void {
        const before = tracked.stream.state;
        tracked.stream.reset() catch return error.Protocol;
        self.adjustActive(stream_id, before, tracked.stream.state);
    }

    /// Applies received HEADERS after frame/payload syntax and HPACK processing
    /// have succeeded. A new idle stream can only be opened by a client, so an
    /// idle server-initiated identifier received by a client is a connection
    /// PROTOCOL_ERROR.
    pub fn classifyHeaders(self: Manager, store: anytype, stream_id: u31) ReceiveResult {
        if (stream_id == 0) return .connection_protocol;
        if (self.ignoredAfterGoAway(stream_id)) return .ignored_after_goaway;
        if (store.get(stream_id)) |tracked| {
            return switch (tracked.stream.state) {
                .idle, .open, .half_closed_local => .accepted,
                .reserved_remote => if (self.remoteLimitAvailable()) .accepted else .refused_stream,
                .half_closed_remote => .stream_closed,
                .closed => .connection_stream_closed,
                .reserved_local => .connection_protocol,
            };
        }

        if (!self.remoteInitiated(stream_id)) return .connection_protocol;
        if (self.local_role != .server) return .connection_protocol;
        if (stream_id <= self.highest_remote_stream_id) return .connection_protocol;
        if (!self.remoteLimitAvailable()) return .refused_stream;
        return .accepted;
    }

    pub fn receiveHeaders(self: *Manager, store: anytype, stream_id: u31, end_stream: bool) ReceiveResult {
        if (stream_id == 0) return .connection_protocol;
        if (self.ignoredAfterGoAway(stream_id)) return .ignored_after_goaway;
        if (store.get(stream_id)) |tracked| return self.receiveHeadersTracked(stream_id, tracked, end_stream);

        if (!self.remoteInitiated(stream_id)) return .connection_protocol;
        // Servers can accept client-created request streams. Clients cannot
        // receive an unsolicited server-created HEADERS stream; server streams
        // must first be reserved by PUSH_PROMISE.
        if (self.local_role != .server) return .connection_protocol;
        if (stream_id <= self.highest_remote_stream_id) return .connection_protocol;

        self.highest_remote_stream_id = stream_id;
        if (!self.remoteLimitAvailable()) return .refused_stream;

        var value = self.newTracked();
        value.stream.remoteHeaders(end_stream) catch unreachable;
        _ = store.insert(stream_id, value) orelse return .refused_stream;
        self.remote_active += 1;
        return .accepted;
    }

    /// Fast path for a stream record already resolved by caller-owned storage.
    pub fn receiveHeadersTracked(self: *Manager, stream_id: u31, tracked: *Tracked, end_stream: bool) ReceiveResult {
        const before = tracked.stream.state;
        if (before == .closed) return .connection_stream_closed;
        if (before == .reserved_remote and !self.remoteLimitAvailable()) {
            tracked.stream.state = .closed;
            return .refused_stream;
        }
        tracked.stream.remoteHeaders(end_stream) catch |err| return switch (err) {
            error.StreamClosed => .stream_closed,
            error.Protocol => .connection_protocol,
        };
        self.adjustActive(stream_id, before, tracked.stream.state);
        return .accepted;
    }

    /// Applies a received DATA frame. `payload_length` is the complete frame
    /// payload length, including Pad Length and padding bytes.
    pub fn receiveData(self: *Manager, store: anytype, stream_id: u31, payload_length: u32, end_stream: bool) ReceiveResult {
        if (stream_id == 0) return .connection_protocol;
        if (self.ignoredAfterGoAway(stream_id)) return .ignored_after_goaway;
        const tracked = store.get(stream_id) orelse return self.receiveAbsent(.data, stream_id);
        return self.receiveDataTracked(stream_id, tracked, payload_length, end_stream);
    }

    pub fn receiveDataTracked(self: *Manager, stream_id: u31, tracked: *Tracked, payload_length: u32, end_stream: bool) ReceiveResult {
        switch (tracked.stream.state) {
            .open, .half_closed_local => {},
            .half_closed_remote, .closed => return .stream_closed,
            else => return .connection_protocol,
        }
        tracked.windows.receiveData(payload_length) catch return .stream_flow_control;
        const before = tracked.stream.state;
        tracked.stream.remoteData(end_stream) catch unreachable;
        self.adjustActive(stream_id, before, tracked.stream.state);
        return .accepted;
    }

    pub fn receiveReset(self: *Manager, store: anytype, stream_id: u31) ReceiveResult {
        if (stream_id == 0) return .connection_protocol;
        if (self.ignoredAfterGoAway(stream_id)) return .ignored_after_goaway;
        const tracked = store.get(stream_id) orelse return self.receiveAbsent(.reset, stream_id);
        return self.receiveResetTracked(stream_id, tracked);
    }

    pub fn receiveResetTracked(self: *Manager, stream_id: u31, tracked: *Tracked) ReceiveResult {
        const before = tracked.stream.state;
        tracked.stream.reset() catch return .connection_protocol;
        self.adjustActive(stream_id, before, tracked.stream.state);
        return .accepted;
    }

    /// Applies a stream-level WINDOW_UPDATE. Connection-level updates belong to
    /// `peer.State.windowUpdate()`.
    pub fn receiveWindowUpdate(self: *Manager, store: anytype, peer: *const peer_mod.State, stream_id: u31, increment: u31) ReceiveResult {
        if (stream_id == 0) return .connection_protocol;
        if (increment == 0) return .stream_protocol;
        if (self.ignoredAfterGoAway(stream_id)) return .ignored_after_goaway;
        const tracked = store.get(stream_id) orelse return self.receiveAbsent(.window_update, stream_id);
        return self.receiveWindowUpdateTracked(peer, stream_id, tracked, increment);
    }

    pub fn receiveWindowUpdateTracked(self: *Manager, peer: *const peer_mod.State, stream_id: u31, tracked: *Tracked, increment: u31) ReceiveResult {
        _ = stream_id;
        if (increment == 0) return .stream_protocol;
        switch (tracked.stream.state) {
            .reserved_remote => return .connection_protocol,
            .closed => return .accepted,
            .idle => return .connection_protocol,
            else => {},
        }
        tracked.windows.peerWindowUpdate(peer.settings.initial_window_size, increment) catch return .stream_flow_control;
        if ((tracked.stream.state == .open or tracked.stream.state == .half_closed_remote) and
            tracked.windows.send.adjustment > 0)
            self.notePositiveSendAdjustment();
        return .accepted;
    }

    /// Reserves a remotely initiated server-push stream. The associated stream
    /// may be closed because RFC 9113 permits minimal processing of frames that
    /// raced with a locally sent RST_STREAM.
    pub fn receivePushPromise(self: *Manager, store: anytype, associated_stream_id: u31, promised_stream_id: u31) ReceiveResult {
        if (self.local_role != .client or !self.local_limits.enable_push) return .connection_protocol;
        if (associated_stream_id == 0 or !self.localInitiated(associated_stream_id)) return .connection_protocol;

        if (store.get(associated_stream_id)) |associated| {
            switch (associated.stream.state) {
                .open, .half_closed_local, .closed => {},
                else => return .connection_protocol,
            }
        } else if (!self.absentClosed(associated_stream_id)) {
            return .connection_protocol;
        }

        if (promised_stream_id == 0 or !self.remoteInitiated(promised_stream_id) or promised_stream_id <= self.highest_remote_stream_id)
            return .connection_protocol;
        if (self.ignoredAfterGoAway(promised_stream_id)) return .ignored_after_goaway;
        if (store.get(promised_stream_id) != null) return .connection_protocol;

        self.highest_remote_stream_id = promised_stream_id;
        var value = self.newTracked();
        value.stream.reserveRemote() catch unreachable;
        _ = store.insert(promised_stream_id, value) orelse return .refused_stream;
        return .accepted;
    }
};

test "detached send probe and commit keep Manager separate" {
    var manager = Manager.init(.client, .{});
    var tracked = Tracked.init(65_535);
    try tracked.stream.localHeaders(false);
    try tracked.stream.remoteHeaders(true);
    manager.local_active = 1;
    const detached: Detached = .{ .stream_id = 1, .tracked = &tracked };

    try std.testing.expectEqual(@as(u31, 65_535), try detached.dataSendCredit(65_535));
    const effect = detached.localDataAssumeCredit(65_535, 100, true);
    try std.testing.expectEqual(StreamEffect.Activity.deactivated, effect.activity);
    try std.testing.expectEqual(@as(u31, 65_435), tracked.windows.send.available(65_535));
    try std.testing.expectEqual(@as(u32, 1), manager.local_active);
    manager.commitStreamEffect(1, effect);
    try std.testing.expectEqual(@as(u32, 0), manager.local_active);
}

test "detached checked local DATA reports flow control" {
    var tracked = Tracked.init(65_535);
    try tracked.stream.localHeaders(false);
    const detached: Detached = .{ .stream_id = 1, .tracked = &tracked };
    try tracked.windows.consumeSend(65_535, 65_535);
    try std.testing.expectError(error.FlowControl, detached.localData(65_535, 1, false));
    try std.testing.expectEqual(State.open, tracked.stream.state);
}

test "detached DATA returns aggregate deactivation effect" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(StreamEffect));
    var manager = Manager.init(.client, .{});
    var tracked = Tracked.init(65_535);
    try tracked.stream.localHeaders(true);
    try tracked.stream.remoteHeaders(false);
    manager.local_active = 1;

    const detached: Detached = .{ .stream_id = 1, .tracked = &tracked };
    const first = detached.receiveData(10, false);
    try std.testing.expectEqual(ReceiveResult.accepted, first.result);
    try std.testing.expect(first.effect.empty());
    try std.testing.expectEqual(@as(u32, 1), manager.local_active);

    const last = detached.receiveData(10, true);
    try std.testing.expectEqual(ReceiveResult.accepted, last.result);
    try std.testing.expectEqual(StreamEffect.Activity.deactivated, last.effect.activity);
    try std.testing.expectEqual(@as(u32, 1), manager.local_active);
    manager.commitStreamEffect(1, last.effect);
    try std.testing.expectEqual(@as(u32, 0), manager.local_active);
}

test "detached WINDOW_UPDATE exposes SETTINGS ordering effect" {
    var tracked = Tracked.init(65_535);
    try tracked.stream.localHeaders(false);
    const detached: Detached = .{ .stream_id = 1, .tracked = &tracked };
    const update = detached.receiveWindowUpdate(65_535, 70_000);
    try std.testing.expectEqual(ReceiveResult.accepted, update.result);
    try std.testing.expect(update.effect.positive_send_adjustment);
    try std.testing.expect(update.effect.ordersSettings());

    var manager = Manager.init(.client, .{});
    manager.local_active = 1;
    manager.commitStreamEffect(1, update.effect);
    try std.testing.expect(manager.positiveSendAdjustmentSeen());
}

test "fused tracked receive path commits detached effects" {
    var manager = Manager.init(.client, .{});
    var tracked = Tracked.init(65_535);
    try tracked.stream.localHeaders(true);
    try tracked.stream.remoteHeaders(false);
    manager.local_active = 1;
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveDataTracked(1, &tracked, 1, true));
    try std.testing.expectEqual(@as(u32, 0), manager.local_active);
}

const TestStore = struct {
    const Entry = struct {
        id: u31 = 0,
        used: bool = false,
        value: Tracked = undefined,
    };

    entries: [16]Entry = [_]Entry{.{}} ** 16,

    fn get(self: *TestStore, id: u31) ?*Tracked {
        for (&self.entries) |*entry| {
            if (entry.used and entry.id == id) return &entry.value;
        }
        return null;
    }

    fn insert(self: *TestStore, id: u31, value: Tracked) ?*Tracked {
        if (self.get(id) != null) return null;
        for (&self.entries) |*entry| {
            if (!entry.used) {
                entry.* = .{ .id = id, .used = true, .value = value };
                return &entry.value;
            }
        }
        return null;
    }
};

test "client request response lifecycle uses caller-owned store" {
    var store: TestStore = .{};
    var manager = Manager.init(.client, .{});
    var peer = peer_mod.State.init(.client);

    try manager.openLocal(&store, &peer, 1, true);
    try std.testing.expectEqual(@as(u32, 1), manager.activeLocal());
    try std.testing.expectEqual(State.half_closed_local, store.get(1).?.stream.state);

    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveHeaders(&store, 1, false));
    try std.testing.expectEqual(State.half_closed_local, store.get(1).?.stream.state);
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveData(&store, 1, 1024, true));
    try std.testing.expectEqual(State.closed, store.get(1).?.stream.state);
    try std.testing.expectEqual(@as(u32, 0), manager.activeLocal());
}

test "server accepts monotonically increasing client streams and closes skipped ids" {
    var store: TestStore = .{};
    var manager = Manager.init(.server, .{});

    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveHeaders(&store, 1, true));
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveHeaders(&store, 5, true));
    const skipped = manager.receiveReset(&store, 3);
    try std.testing.expectEqual(ReceiveResult.accepted, skipped);
    const reused = manager.receiveHeaders(&store, 3, true);
    try std.testing.expectEqual(ReceiveResult.connection_protocol, reused);
}

test "HEADERS classification observes state without mutating it" {
    var manager = Manager.init(.server, .{});
    var store: TestStore = .{};
    try std.testing.expectEqual(ReceiveResult.accepted, manager.classifyHeaders(&store, 1));
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveHeaders(&store, 1, true));
    try std.testing.expectEqual(ReceiveResult.stream_closed, manager.classifyHeaders(&store, 1));
    try std.testing.expectEqual(State.half_closed_remote, store.get(1).?.stream.state);
}

test "HEADERS on a fully closed stream can be a connection STREAM_CLOSED error" {
    var manager = Manager.init(.server, .{});
    var store: TestStore = .{};
    var peer = peer_mod.State.init(.server);

    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveHeaders(&store, 1, true));
    try manager.localHeaders(&store, &peer, 1, true);
    try std.testing.expectEqual(State.closed, store.get(1).?.stream.state);

    const classified = manager.classifyHeaders(&store, 1);
    try std.testing.expectEqual(ReceiveResult.connection_stream_closed, classified);
    try std.testing.expect(classified.isConnectionError());
    try std.testing.expectEqual(protocol.ErrorCode.stream_closed, classified.errorCode().?);
    try std.testing.expectEqual(ReceiveResult.connection_stream_closed, manager.receiveHeaders(&store, 1, true));
}

test "server enforces local concurrent stream limit with REFUSED_STREAM" {
    var store: TestStore = .{};
    var manager = Manager.init(.server, .{ .max_concurrent_streams = 1 });

    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveHeaders(&store, 1, true));
    const refused = manager.receiveHeaders(&store, 3, true);
    try std.testing.expectEqual(ReceiveResult.refused_stream, refused);
}

test "stream receive flow control returns stream error" {
    var store: TestStore = .{};
    var manager = Manager.init(.server, .{ .initial_window_size = 4 });
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveHeaders(&store, 1, false));
    const result = manager.receiveData(&store, 1, 5, false);
    try std.testing.expectEqual(ReceiveResult.stream_flow_control, result);
}

test "client accepts server push reservation and pushed response" {
    var store: TestStore = .{};
    var manager = Manager.init(.client, .{});
    var peer = peer_mod.State.init(.client);
    try manager.openLocal(&store, &peer, 1, true);

    try std.testing.expectEqual(ReceiveResult.accepted, manager.receivePushPromise(&store, 1, 2));
    try std.testing.expectEqual(State.reserved_remote, store.get(2).?.stream.state);
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveHeaders(&store, 2, false));
    try std.testing.expectEqual(State.half_closed_local, store.get(2).?.stream.state);
}

test "window update is accepted on closed stream but rejected on idle" {
    var store: TestStore = .{};
    var manager = Manager.init(.server, .{});
    var peer = peer_mod.State.init(.server);
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveHeaders(&store, 1, true));
    try manager.localHeaders(&store, &peer, 1, true);
    try std.testing.expectEqual(State.closed, store.get(1).?.stream.state);
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveWindowUpdate(&store, &peer, 1, 1));
    const idle = manager.receiveWindowUpdate(&store, &peer, 3, 1);
    try std.testing.expectEqual(ReceiveResult.connection_protocol, idle);
}

test "local server push reservation opens only when peer limit allows" {
    var store: TestStore = .{};
    var manager = Manager.init(.server, .{});
    var peer = peer_mod.State.init(.server);
    // Client request stream 1 is peer initiated and half-closed(remote).
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveHeaders(&store, 1, true));
    try manager.reserveLocal(&store, &peer, 1, 2);
    try std.testing.expectEqual(State.reserved_local, store.get(2).?.stream.state);

    _ = try peer.applySetting(.{ .id = .max_concurrent_streams, .value = 0 });
    try std.testing.expectError(error.PeerLimit, manager.localHeaders(&store, &peer, 2, false));
}

test "local stream creation obeys peer max concurrency and GOAWAY" {
    var store: TestStore = .{};
    var manager = Manager.init(.client, .{});
    var peer = peer_mod.State.init(.client);
    _ = try peer.applySetting(.{ .id = .max_concurrent_streams, .value = 1 });
    try manager.openLocal(&store, &peer, 1, true);
    try std.testing.expectError(error.PeerLimit, manager.openLocal(&store, &peer, 3, true));

    var goaway_bytes: [8]u8 = [_]u8{0} ** 8;
    std.mem.writeInt(u32, goaway_bytes[0..4], 1, .big);
    const goaway_header: frame.FrameHeader = .{ .length = 8, .type = .goaway, .flags = 0, .stream_id = 0 };
    _ = try peer.goAway(goaway_header, &goaway_bytes);
    try std.testing.expectError(error.GoAway, manager.openLocal(&store, &peer, 5, true));
}

test "tracked cursor avoids another caller-store lookup" {
    var store: TestStore = .{};
    var manager = Manager.init(.client, .{});
    var peer = peer_mod.State.init(.client);
    try manager.openLocal(&store, &peer, 1, true);
    const cursor = manager.existing(&store, 1).?;
    try std.testing.expectEqual(ReceiveResult.accepted, cursor.receiveHeaders(false));
    try std.testing.expectEqual(ReceiveResult.accepted, cursor.receiveData(1, true));
    try std.testing.expectEqual(State.closed, cursor.tracked.stream.state);
}

test "tracked cursor supports local send state with relative peer window" {
    var store: TestStore = .{};
    var manager = Manager.init(.client, .{});
    var peer = peer_mod.State.init(.client);
    try manager.openLocal(&store, &peer, 1, false);
    const cursor = manager.existing(&store, 1).?;

    const effect = try peer.applySetting(.{ .id = .initial_window_size, .value = 70_000 });
    try manager.applyPeerInitialWindow(effect.initial_window, null);
    try std.testing.expectEqual(@as(u31, 70_000), cursor.tracked.windows.send.available(peer.settings.initial_window_size));

    try cursor.localData(&peer, 1024, true);
    try std.testing.expectEqual(State.half_closed_local, cursor.tracked.stream.state);
    try std.testing.expectEqual(@as(u31, 68_976), cursor.tracked.windows.send.available(peer.settings.initial_window_size));
}

test "peer initial window decrease is O(1) with relative stream windows" {
    var store: TestStore = .{};
    var manager = Manager.init(.client, .{});
    var peer = peer_mod.State.init(.client);
    try manager.openLocal(&store, &peer, 1, false);
    try manager.localData(&store, &peer, 1, 60_000, false);
    const effect = try peer.applySetting(.{ .id = .initial_window_size, .value = 16_384 });
    try manager.applyPeerInitialWindow(effect.initial_window, null);
    const tracked = store.get(1).?;
    try std.testing.expectEqual(@as(i64, -43_616), tracked.windows.send.signed(peer.settings.initial_window_size));
    try std.testing.expectEqual(@as(u31, 0), manager.sendWindowAvailable(&peer, tracked));
}

test "zero-length local DATA can end a stream with negative send window" {
    var store: TestStore = .{};
    var manager = Manager.init(.client, .{});
    var peer = peer_mod.State.init(.client);
    try manager.openLocal(&store, &peer, 1, false);
    try manager.localData(&store, &peer, 1, 60_000, false);

    const effect = try peer.applySetting(.{ .id = .initial_window_size, .value = 16_384 });
    try manager.applyPeerInitialWindow(effect.initial_window, null);
    try std.testing.expect(store.get(1).?.windows.send.signed(peer.settings.initial_window_size) < 0);

    try manager.localData(&store, &peer, 1, 0, true);
    try std.testing.expectEqual(State.half_closed_local, store.get(1).?.stream.state);
}

test "stream manager and detached effects remain compact" {
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(Manager));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(StreamEffect));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Detached));
}

test "peer initial window increase detects active stream overflow exactly" {
    var store: TestStore = .{};
    var manager = Manager.init(.client, .{});
    var peer = peer_mod.State.init(.client);
    try manager.openLocal(&store, &peer, 1, false);

    // Grow the stream to the maximum effective window using WINDOW_UPDATE.
    const increment: u31 = 0x7fff_ffff - 65_535;
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveWindowUpdate(&store, &peer, 1, increment));
    const effect = try peer.applySetting(.{ .id = .initial_window_size, .value = 65_536 });
    try std.testing.expectError(error.ExactWindowScanRequired, manager.applyPeerInitialWindow(effect.initial_window, null));
    try std.testing.expectError(error.FlowControl, manager.applyPeerInitialWindow(
        effect.initial_window,
        store.get(1).?.windows.send.adjustment,
    ));
}

test "local GOAWAY ignores newer remote streams without creating state" {
    var store: TestStore = .{};
    var manager = Manager.init(.server, .{});
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveHeaders(&store, 1, true));
    try manager.sentGoAway(1);
    try std.testing.expectEqual(@as(?u31, 1), manager.lastSentGoAwayStream());
    try std.testing.expectEqual(ReceiveResult.ignored_after_goaway, manager.receiveHeaders(&store, 3, true));
    try std.testing.expect(store.get(3) == null);
    try std.testing.expectError(error.Protocol, manager.sentGoAway(2));
}

test "peer GOAWAY identifies unprocessed local streams" {
    var manager = Manager.init(.client, .{});
    var peer = peer_mod.State.init(.client);
    var bytes: [8]u8 = [_]u8{0} ** 8;
    std.mem.writeInt(u32, bytes[0..4], 3, .big);
    const header: frame.FrameHeader = .{ .length = 8, .type = .goaway, .flags = 0, .stream_id = 0 };
    _ = try peer.goAway(header, &bytes);
    try std.testing.expect(!manager.unprocessedByPeer(&peer, 3));
    try std.testing.expect(manager.unprocessedByPeer(&peer, 5));
    try std.testing.expect(!manager.unprocessedByPeer(&peer, 2));
}

test "zero window update remains an error on a closed stream" {
    var store: TestStore = .{};
    var manager = Manager.init(.server, .{});
    var peer = peer_mod.State.init(.server);
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveHeaders(&store, 1, true));
    try manager.localHeaders(&store, &peer, 1, true);
    try std.testing.expectEqual(State.closed, store.get(1).?.stream.state);
    try std.testing.expectEqual(ReceiveResult.stream_protocol, manager.receiveWindowUpdate(&store, &peer, 1, 0));
}

test "missing stream classification is reusable without store lookup" {
    var manager = Manager.init(.client, .{});
    manager.highest_local_bits = 5;
    try std.testing.expectEqual(ReceiveResult.stream_closed, manager.receiveAbsent(.data, 3));
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveAbsent(.reset, 3));
    try std.testing.expectEqual(ReceiveResult.accepted, manager.receiveAbsent(.window_update, 3));
    try std.testing.expectEqual(ReceiveResult.connection_protocol, manager.receiveAbsent(.data, 7));
}

test "detached DATA offer commits without PeerState on shard" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(DataSendOffer));
    var tracked = Tracked.init(65_535);
    try tracked.stream.localHeaders(false);
    try tracked.stream.remoteHeaders(true);
    const detached: Detached = .{ .stream_id = 1, .tracked = &tracked };
    const offer = try detached.dataSendOffer(65_535);
    try std.testing.expectEqual(@as(u31, 65_535), offer.max_payload);
    const effect = offer.commit(detached, 1024, true);
    try std.testing.expectEqual(StreamEffect.Activity.deactivated, effect.activity);
    try std.testing.expectEqual(@as(u31, 64_511), tracked.windows.send.available(65_535));
}
