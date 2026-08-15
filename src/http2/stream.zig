const std = @import("std");
const flow = @import("flow.zig");

pub const State = enum {
    idle,
    reserved_local,
    reserved_remote,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
};

/// Small standalone HTTP/2 stream state machine. Connection implementations can
/// embed this in their own hash table/slab without adopting an allocator here.
pub const Stream = struct {
    state: State = .idle,

    pub fn reserveLocal(self: *Stream) error{Protocol}!void {
        if (self.state != .idle) return error.Protocol;
        self.state = .reserved_local;
    }

    pub fn reserveRemote(self: *Stream) error{Protocol}!void {
        if (self.state != .idle) return error.Protocol;
        self.state = .reserved_remote;
    }

    pub fn localHeaders(self: *Stream, end_stream: bool) error{ StreamClosed, Protocol }!void {
        self.state = switch (self.state) {
            .idle => if (end_stream) .half_closed_local else .open,
            .reserved_local => if (end_stream) .closed else .half_closed_remote,
            .open => if (end_stream) .half_closed_local else .open,
            .half_closed_remote => if (end_stream) .closed else .half_closed_remote,
            .half_closed_local, .closed => return error.StreamClosed,
            .reserved_remote => return error.Protocol,
        };
    }

    pub fn remoteHeaders(self: *Stream, end_stream: bool) error{ StreamClosed, Protocol }!void {
        self.state = switch (self.state) {
            .idle => if (end_stream) .half_closed_remote else .open,
            .reserved_remote => if (end_stream) .closed else .half_closed_local,
            .open => if (end_stream) .half_closed_remote else .open,
            .half_closed_local => if (end_stream) .closed else .half_closed_local,
            .half_closed_remote, .closed => return error.StreamClosed,
            .reserved_local => return error.Protocol,
        };
    }

    pub fn localData(self: *Stream, end_stream: bool) error{ StreamClosed, Protocol }!void {
        self.state = switch (self.state) {
            .open => if (end_stream) .half_closed_local else .open,
            .half_closed_remote => if (end_stream) .closed else .half_closed_remote,
            .half_closed_local, .closed => return error.StreamClosed,
            else => return error.Protocol,
        };
    }

    pub fn remoteData(self: *Stream, end_stream: bool) error{ StreamClosed, Protocol }!void {
        self.state = switch (self.state) {
            .open => if (end_stream) .half_closed_remote else .open,
            .half_closed_local => if (end_stream) .closed else .half_closed_local,
            .half_closed_remote, .closed => return error.StreamClosed,
            else => return error.Protocol,
        };
    }

    pub fn reset(self: *Stream) error{Protocol}!void {
        if (self.state == .idle) return error.Protocol;
        self.state = .closed;
    }
};

/// Caller-owned stream flow-control state. `send` is constrained by the peer's
/// advertised receive credit; `receive` tracks credit advertised locally.
pub const Windows = struct {
    send: flow.FlowWindow,
    receive: flow.FlowWindow,

    pub fn init(peer_initial_window: u31, local_initial_window: u31) Windows {
        return .{
            .send = .{ .value = @intCast(peer_initial_window) },
            .receive = .{ .value = @intCast(local_initial_window) },
        };
    }

    pub inline fn consumeSend(self: *Windows, amount: u32) error{FlowControl}!void {
        try self.send.consume(amount);
    }

    pub inline fn receiveData(self: *Windows, amount: u32) error{FlowControl}!void {
        try self.receive.consume(amount);
    }

    pub inline fn peerWindowUpdate(self: *Windows, increment: u31) error{FlowControl}!void {
        try self.send.update(increment);
    }

    /// Call after emitting a stream-level WINDOW_UPDATE to the peer.
    pub inline fn creditReceive(self: *Windows, increment: u31) error{FlowControl}!void {
        try self.receive.update(increment);
    }

    /// Applies an old/new SETTINGS_INITIAL_WINDOW_SIZE pair returned by
    /// `peer.State.applySetting()` to this stream's send window.
    pub inline fn applyPeerInitialDelta(self: *Windows, old: u31, new: u31) error{FlowControl}!void {
        try self.send.applyInitialDelta(old, new);
    }
};

/// Minimal embeddable stream record for applications that want protocol state
/// plus both flow-control windows but still own the surrounding stream table.
pub const RemoteHeaders = enum(u2) { initial, regular, trailers };

pub const Tracked = struct {
    stream: Stream = .{},
    remote_headers: RemoteHeaders = .initial,
    windows: Windows,

    pub fn init(peer_initial_window: u31, local_initial_window: u31) Tracked {
        return .{ .windows = Windows.init(peer_initial_window, local_initial_window) };
    }
};

test "normal request response stream lifecycle" {
    var s: Stream = .{};
    try s.remoteHeaders(true);
    try std.testing.expectEqual(State.half_closed_remote, s.state);
    try s.localHeaders(true);
    try std.testing.expectEqual(State.closed, s.state);
}

test "stream windows track directional credit" {
    var windows = Windows.init(70_000, 80_000);
    try windows.consumeSend(10_000);
    try windows.receiveData(20_000);
    try std.testing.expectEqual(@as(u31, 60_000), windows.send.available());
    try std.testing.expectEqual(@as(u31, 60_000), windows.receive.available());
    try windows.peerWindowUpdate(2_000);
    try windows.creditReceive(3_000);
    try std.testing.expectEqual(@as(u31, 62_000), windows.send.available());
    try std.testing.expectEqual(@as(u31, 63_000), windows.receive.available());
}

test "stream windows apply peer initial size delta" {
    var windows = Windows.init(65_535, 65_535);
    try windows.applyPeerInitialDelta(65_535, 32_768);
    try std.testing.expectEqual(@as(u31, 32_768), windows.send.available());
}
