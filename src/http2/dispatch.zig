const std = @import("std");
const connection = @import("connection.zig");
const frame = @import("frame.zig");
const payload = @import("payload.zig");
const peer_mod = @import("peer.zig");
const protocol = @import("protocol.zig");
const streams = @import("streams.zig");

/// DATA already charged against the connection receive window and stripped of
/// optional HTTP/2 padding. `bytes` aliases the caller-owned frame payload.
pub const Data = struct {
    stream_id: u31,
    end_stream: bool,
    // HTTP/2 frame length is 24-bit. Packing it into the three bytes after the
    // bool keeps this temporary work item compact on 64-bit targets.
    _flow_charge: [3]u8,
    bytes: []const u8,

    pub inline fn flowControlledBytes(self: Data) u32 {
        return (@as(u32, self._flow_charge[0]) << 16) |
            (@as(u32, self._flow_charge[1]) << 8) |
            @as(u32, self._flow_charge[2]);
    }

    pub inline fn apply(self: Data, detached: streams.Detached) streams.DetachedResult {
        std.debug.assert(detached.stream_id == self.stream_id);
        return detached.receiveData(self.flowControlledBytes(), self.end_stream);
    }

    pub inline fn absent(self: Data, manager: *const streams.Manager) streams.ReceiveResult {
        return manager.receiveAbsent(.data, self.stream_id);
    }
};

pub const Reset = struct {
    stream_id: u31,
    error_code: u32,

    pub inline fn apply(self: Reset, detached: streams.Detached) streams.DetachedResult {
        std.debug.assert(detached.stream_id == self.stream_id);
        return detached.receiveReset();
    }

    pub inline fn absent(self: Reset, manager: *const streams.Manager) streams.ReceiveResult {
        return manager.receiveAbsent(.reset, self.stream_id);
    }
};

/// A stream WINDOW_UPDATE carries the peer initial-window value that was
/// ordered before this frame. Capturing that 31-bit setting here lets a delayed
/// stream worker apply the frame correctly even if the connection owner later
/// processes another SETTINGS_INITIAL_WINDOW_SIZE.
pub const WindowUpdate = struct {
    stream_id: u31,
    increment: u31,
    peer_initial_window: u31,

    pub inline fn apply(self: WindowUpdate, detached: streams.Detached) streams.DetachedResult {
        std.debug.assert(detached.stream_id == self.stream_id);
        return detached.receiveWindowUpdate(self.peer_initial_window, self.increment);
    }

    pub inline fn absent(self: WindowUpdate, manager: *const streams.Manager) streams.ReceiveResult {
        if (self.increment == 0) return .stream_protocol;
        return manager.receiveAbsent(.window_update, self.stream_id);
    }
};

/// Connection-owner result for one stream-local DATA offer. `max_payload` is
/// already bounded by connection send credit, peer MAX_FRAME_SIZE, and the
/// stream credit captured in the offer.
pub const DataSendGrant = struct {
    max_payload: u31,
};

pub const DataSendGrantError = error{StaleStreamCredit};

/// Combines a stream-shard offer with ordered connection send state. A later
/// SETTINGS increase is safe (the old offer is conservative); a decrease makes
/// the offer stale and requires the stream owner to probe again. The connection
/// owner must keep its PeerState ordered between this check and the wire write.
pub inline fn grantDataSend(
    peer: *const peer_mod.State,
    offer: streams.DataSendOffer,
) DataSendGrantError!DataSendGrant {
    if (peer.settings.initial_window_size < offer.peer_initial_window)
        return error.StaleStreamCredit;
    return .{ .max_payload = @min(
        offer.max_payload,
        peer.send_window.available(),
        @as(u31, @intCast(peer.settings.max_frame_size)),
    ) };
}

/// Work that can be applied against one caller-owned `Tracked` stream record
/// without sharing connection state with the stream worker.
pub const StreamWork = union(enum) {
    data: Data,
    reset: Reset,
    window_update: WindowUpdate,

    pub inline fn streamId(self: StreamWork) u31 {
        return switch (self) {
            .data => |work| work.stream_id,
            .reset => |work| work.stream_id,
            .window_update => |work| work.stream_id,
        };
    }

    /// Applies work to an already-resolved stream record. Connection-wide frame
    /// ordering and DATA receive-window accounting must have been committed by
    /// `prepare()` before this is called.
    pub inline fn apply(self: StreamWork, detached: streams.Detached) streams.DetachedResult {
        return switch (self) {
            .data => |work| work.apply(detached),
            .reset => |work| work.apply(detached),
            .window_update => |work| work.apply(detached),
        };
    }

    /// Resolves the RFC result when the caller's shard has no record for this
    /// stream. This keeps the stream table outside the ordered connection owner:
    /// only the exceptional missing-record result needs Manager state.
    pub inline fn absent(self: StreamWork, manager: *const streams.Manager) streams.ReceiveResult {
        return switch (self) {
            .data => |work| work.absent(manager),
            .reset => |work| work.absent(manager),
            .window_update => |work| work.absent(manager),
        };
    }
};

/// Result of the connection-ordered receive front-end.
///
/// `.stream` can be handed to a caller-selected stream shard. `.ordered` still
/// requires connection-owned processing (HPACK/HEADERS, SETTINGS, GOAWAY,
/// connection WINDOW_UPDATE, PING, extensions). Unknown/PRIORITY frames are
/// returned as `.ignored` after connection-wide invariants are observed.
pub const Prepared = union(enum) {
    data: Data,
    reset: Reset,
    window_update: WindowUpdate,
    ordered,
    ignored,
    fault: protocol.ErrorCode,

    pub inline fn streamId(self: Prepared) ?u31 {
        return switch (self) {
            .data => |work| work.stream_id,
            .reset => |work| work.stream_id,
            .window_update => |work| work.stream_id,
            else => null,
        };
    }

    /// Materializes the queue-friendly tagged stream item only when the caller
    /// actually needs to hand work across an ownership boundary. Callers that
    /// process the concrete Prepared tag in place avoid this second union.
    pub inline fn streamWork(self: Prepared) ?StreamWork {
        return switch (self) {
            .data => |work| .{ .data = work },
            .reset => |work| .{ .reset = work },
            .window_update => |work| .{ .window_update = work },
            else => null,
        };
    }
};

/// Applies only the HTTP/2 state that is inherently ordered across the whole
/// connection, then extracts stream-local work where possible.
///
/// `complete` must already have passed `FrameHeader.validate()` (normally via
/// `parseComplete`, `CompleteFrameIterator`, or `ConnectionCompleteIterator`).
/// `peer_initial_window` must be the peer SETTINGS value current at this exact
/// wire position. The caller must finish processing an `.ordered` SETTINGS frame
/// before preparing later frames if those frames can be dispatched elsewhere.
pub inline fn prepare(
    state: *connection.State,
    peer_initial_window: u31,
    complete: frame.CompleteFrame,
) Prepared {
    switch (state.check(complete.header)) {
        .none => {},
        .protocol => return .{ .fault = .protocol_error },
        .flow_control => return .{ .fault = .flow_control_error },
    }

    return prepareAssumeConnectionChecked(peer_initial_window, complete);
}

/// Generic counterpart for `ConnectionCompleteIterator`/`ConnectionDecoder`,
/// which have already applied connection-wide receive state before returning
/// the complete frame. Typed `prepare*AssumeConnectionChecked` functions avoid
/// even this union when the caller already switched on frame type.
pub inline fn prepareAssumeConnectionChecked(
    peer_initial_window: u31,
    complete: frame.CompleteFrame,
) Prepared {
    return switch (complete.header.type) {
        .data => prepareDataAfterConnectionCheck(complete),
        .rst_stream => prepareResetAfterConnectionCheck(complete),
        .window_update => prepareWindowUpdateAfterConnectionCheck(peer_initial_window, complete),
        .priority => .ignored,
        .headers, .continuation, .push_promise, .settings, .ping, .goaway => .ordered,
        else => .ignored,
    };
}

/// Typed DATA fast path for callers that already switched on frame type. It
/// performs the same connection-ordered accounting as `prepare()` but returns
/// the concrete 24-byte work item directly, avoiding tagged-union dispatch.
pub inline fn prepareData(state: *connection.State, complete: frame.CompleteFrame) error{ FrameSize, Protocol, FlowControl }!Data {
    try state.observe(complete.header);
    return try prepareDataAssumeConnectionChecked(complete);
}

/// DATA payload-to-work conversion for a frame whose connection-wide state was
/// already observed by `ConnectionState`/`ConnectionCompleteIterator`.
pub inline fn prepareDataAssumeConnectionChecked(complete: frame.CompleteFrame) error{ FrameSize, Protocol }!Data {
    const bytes = try payload.data(complete.header, complete.payload);
    return .{
        .stream_id = complete.header.stream_id,
        .end_stream = (complete.header.flags & 0x01) != 0,
        ._flow_charge = .{
            @intCast((complete.header.length >> 16) & 0xff),
            @intCast((complete.header.length >> 8) & 0xff),
            @intCast(complete.header.length & 0xff),
        },
        .bytes = bytes,
    };
}

inline fn prepareDataAfterConnectionCheck(complete: frame.CompleteFrame) Prepared {
    const work = prepareDataAssumeConnectionChecked(complete) catch |err| return switch (err) {
        error.FrameSize => .{ .fault = .frame_size_error },
        error.Protocol => .{ .fault = .protocol_error },
    };
    return .{ .data = work };
}

pub inline fn prepareReset(state: *connection.State, complete: frame.CompleteFrame) error{ FrameSize, Protocol, FlowControl }!Reset {
    if (complete.header.type != .rst_stream) return error.Protocol;
    try state.observe(complete.header);
    return try prepareResetAssumeConnectionChecked(complete);
}

pub inline fn prepareResetAssumeConnectionChecked(complete: frame.CompleteFrame) error{FrameSize}!Reset {
    std.debug.assert(complete.header.type == .rst_stream);
    return .{ .stream_id = complete.header.stream_id, .error_code = try payload.rstErrorCode(complete.payload) };
}

inline fn prepareResetAfterConnectionCheck(complete: frame.CompleteFrame) Prepared {
    const work = prepareResetAssumeConnectionChecked(complete) catch return .{ .fault = .frame_size_error };
    return .{ .reset = work };
}

/// Typed stream WINDOW_UPDATE fast path. The stream id must be non-zero; zero
/// increments are intentionally preserved for stream-level PROTOCOL_ERROR.
pub inline fn prepareStreamWindowUpdate(
    state: *connection.State,
    peer_initial_window: u31,
    complete: frame.CompleteFrame,
) error{ FrameSize, Protocol, FlowControl }!WindowUpdate {
    if (complete.header.type != .window_update or complete.header.stream_id == 0) return error.Protocol;
    try state.observe(complete.header);
    return try prepareStreamWindowUpdateAssumeConnectionChecked(peer_initial_window, complete);
}

pub inline fn prepareStreamWindowUpdateAssumeConnectionChecked(
    peer_initial_window: u31,
    complete: frame.CompleteFrame,
) error{FrameSize}!WindowUpdate {
    std.debug.assert(complete.header.type == .window_update and complete.header.stream_id != 0);
    return .{
        .stream_id = complete.header.stream_id,
        .increment = try payload.windowIncrementValue(complete.payload),
        .peer_initial_window = peer_initial_window,
    };
}

inline fn prepareWindowUpdateAfterConnectionCheck(peer_initial_window: u31, complete: frame.CompleteFrame) Prepared {
    // Keep zero visible for stream-level handling: RFC 9113 makes increment=0 a
    // connection error only on stream 0 and a stream error otherwise.
    const increment = payload.windowIncrementValue(complete.payload) catch
        return .{ .fault = .frame_size_error };
    if (complete.header.stream_id == 0) {
        if (increment == 0) return .{ .fault = .protocol_error };
        return .ordered;
    }
    return .{ .window_update = .{
        .stream_id = complete.header.stream_id,
        .increment = increment,
        .peer_initial_window = peer_initial_window,
    } };
}

test "prepare DATA charges connection and returns detached work" {
    const wire_payload = [_]u8{ 2, 'a', 'b', 'c', 0, 0 };
    const complete: frame.CompleteFrame = .{
        .header = .{ .length = wire_payload.len, .type = .data, .flags = 0x09, .stream_id = 1 },
        .payload = &wire_payload,
    };
    var conn: connection.State = .{};
    const prepared = prepare(&conn, 65_535, complete);
    try std.testing.expectEqual(@as(u31, 65_529), conn.receive_window.available());
    try std.testing.expectEqualStrings("abc", prepared.data.bytes);
    try std.testing.expectEqual(@as(u32, 6), prepared.data.flowControlledBytes());
    try std.testing.expect(prepared.data.end_stream);
}

test "stream WINDOW_UPDATE snapshots SETTINGS and keeps zero stream-local" {
    var conn: connection.State = .{};
    const zero = [_]u8{ 0, 0, 0, 0 };
    const complete: frame.CompleteFrame = .{
        .header = .{ .length = 4, .type = .window_update, .flags = 0, .stream_id = 3 },
        .payload = &zero,
    };
    const prepared = prepare(&conn, 32_768, complete);
    try std.testing.expectEqual(@as(u31, 3), prepared.window_update.stream_id);
    try std.testing.expectEqual(@as(u31, 0), prepared.window_update.increment);
    try std.testing.expectEqual(@as(u31, 32_768), prepared.window_update.peer_initial_window);
}

test "connection WINDOW_UPDATE zero is a connection fault" {
    var conn: connection.State = .{};
    const zero = [_]u8{ 0, 0, 0, 0 };
    const complete: frame.CompleteFrame = .{
        .header = .{ .length = 4, .type = .window_update, .flags = 0, .stream_id = 0 },
        .payload = &zero,
    };
    try std.testing.expectEqual(protocol.ErrorCode.protocol_error, prepare(&conn, 65_535, complete).fault);
}

test "stream work applies without Manager ownership" {
    var tracked = streams.Tracked.init(65_535);
    try tracked.stream.localHeaders(true);
    try tracked.stream.remoteHeaders(false);
    const detached: streams.Detached = .{ .stream_id = 1, .tracked = &tracked };
    const work: StreamWork = .{ .data = .{
        .stream_id = 1,
        .end_stream = true,
        ._flow_charge = .{ 0, 0, 3 },
        .bytes = "abc",
    } };
    const applied = work.apply(detached);
    try std.testing.expectEqual(streams.ReceiveResult.accepted, applied.result);
    try std.testing.expectEqual(streams.StreamEffect.Activity.deactivated, applied.effect.activity);
}

test "prepared temporary sizes remain bounded" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Data));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(StreamWork));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Prepared));
}

test "DATA send grant rejects only unsafe SETTINGS decrease" {
    var tracked = streams.Tracked.init(65_535);
    try tracked.stream.localHeaders(false);
    const detached: streams.Detached = .{ .stream_id = 1, .tracked = &tracked };
    const offer = try detached.dataSendOffer(65_535);

    var peer = peer_mod.State.init(.client);
    var grant = try grantDataSend(&peer, offer);
    try std.testing.expectEqual(@as(u31, 16_384), grant.max_payload);

    _ = try peer.applySetting(.{ .id = .initial_window_size, .value = 80_000 });
    grant = try grantDataSend(&peer, offer);
    try std.testing.expectEqual(@as(u31, 16_384), grant.max_payload);

    _ = try peer.applySetting(.{ .id = .initial_window_size, .value = 32_768 });
    try std.testing.expectError(error.StaleStreamCredit, grantDataSend(&peer, offer));
}

test "DATA send grant combines stream connection and frame credit" {
    var peer = peer_mod.State.init(.server);
    peer.send_window.value = 9000;
    const offer: streams.DataSendOffer = .{
        .stream_id = 1,
        .peer_initial_window = 65_535,
        .max_payload = 12_000,
    };
    const grant = try grantDataSend(&peer, offer);
    try std.testing.expectEqual(@as(u31, 9000), grant.max_payload);
}

test "flat prepared work materializes queue item only on demand" {
    const bytes = "abc";
    var conn: connection.State = .{};
    const complete: frame.CompleteFrame = .{
        .header = .{ .length = bytes.len, .type = .data, .flags = 0, .stream_id = 1 },
        .payload = bytes,
    };
    const prepared = prepare(&conn, 65_535, complete);
    try std.testing.expectEqual(@as(?u31, 1), prepared.streamId());
    const queued = prepared.streamWork().?;
    try std.testing.expectEqual(@as(u31, 1), queued.streamId());
    try std.testing.expectEqualStrings(bytes, queued.data.bytes);
}

test "typed stream preparation rejects wrong frame class" {
    var conn: connection.State = .{};
    const bytes = [_]u8{ 0, 0, 0, 1 };
    const wrong: frame.CompleteFrame = .{
        .header = .{ .length = 4, .type = .ping, .flags = 0, .stream_id = 0 },
        .payload = &bytes,
    };
    try std.testing.expectError(error.Protocol, prepareReset(&conn, wrong));
    try std.testing.expectError(error.Protocol, prepareStreamWindowUpdate(&conn, 65_535, wrong));
}

test "prechecked generic preparation leaves connection state untouched" {
    const bytes = "abc";
    const complete: frame.CompleteFrame = .{
        .header = .{ .length = bytes.len, .type = .data, .flags = 0, .stream_id = 1 },
        .payload = bytes,
    };
    var conn: connection.State = .{};
    try conn.observe(complete.header);
    const before = conn.receive_window.value;
    const prepared = prepareAssumeConnectionChecked(65_535, complete);
    try std.testing.expectEqual(before, conn.receive_window.value);
    try std.testing.expectEqualStrings(bytes, prepared.data.bytes);
}
