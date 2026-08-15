const std = @import("std");
const continuation = @import("continuation.zig");
const flow = @import("flow.zig");
const frame = @import("frame.zig");

/// Connection-wide receive state that is independent of stream storage.
///
/// It deliberately tracks only invariants that apply across all streams:
/// CONTINUATION adjacency and the connection receive flow-control window.
/// Stream state and stream-level windows remain caller-owned so applications can
/// choose their own slab/hash-table layout.
pub const Violation = enum(u2) { none, protocol, flow_control };

pub const State = struct {
    continuation_guard: continuation.Guard = .{},
    receive_window: flow.FlowWindow = .{},

    /// Records credit after the application sends a connection-level
    /// WINDOW_UPDATE. HTTP/2 starts with 65,535 octets of receive credit.
    pub fn creditReceive(self: *State, increment: u31) error{FlowControl}!void {
        try self.receive_window.update(increment);
    }

    /// Applies connection-wide receive rules from a validated frame header.
    pub inline fn check(self: *State, header: frame.FrameHeader) Violation {
        const active = self.continuation_guard.stream_id;
        if (active != 0) {
            if (header.type != .continuation or header.stream_id != active) return .protocol;
            if ((header.flags & 0x04) != 0) self.continuation_guard.stream_id = 0;
        } else {
            if (header.type == .continuation or
                ((header.type == .headers or header.type == .push_promise) and header.stream_id == 0))
                return .protocol;
            if ((header.type == .headers or header.type == .push_promise) and (header.flags & 0x04) == 0)
                self.continuation_guard.stream_id = header.stream_id;
        }
        if (header.type == .data) {
            if (self.receive_window.value < 0 or @as(u32, @intCast(self.receive_window.value)) < header.length)
                return .flow_control;
            self.receive_window.value -= @intCast(header.length);
        }
        return .none;
    }

    pub inline fn observe(self: *State, header: frame.FrameHeader) error{ Protocol, FlowControl }!void {
        switch (self.check(header)) {
            .none => {},
            .protocol => return error.Protocol,
            .flow_control => return error.FlowControl,
        }
    }
};

/// Zero-copy iterator for complete frames already present in one transport read.
/// Connection-wide state is updated before each frame is returned.
pub const CompleteIterator = struct {
    frames: frame.CompleteIterator,
    state: *State,

    pub fn init(state: *State, input: []const u8, receiver_max_frame_size: u32) CompleteIterator {
        return .{
            .frames = frame.CompleteIterator.init(input, receiver_max_frame_size),
            .state = state,
        };
    }

    pub inline fn next(self: *CompleteIterator) error{ FrameSize, Protocol, FlowControl }!?frame.CompleteFrame {
        const complete = (try self.frames.next()) orelse return null;
        try self.state.observe(complete.header);
        return complete;
    }

    pub inline fn consumed(self: CompleteIterator) usize {
        return self.frames.consumed();
    }
};

/// Persistent connection receive decoder. Applications normally drain complete
/// frames with `complete()` and use the embedded `frames` decoder only for the
/// final frame that crosses a transport-read boundary. Both paths share state.
pub const Decoder = struct {
    state: State = .{},
    frames: frame.FrameDecoder,

    pub fn init(receiver_max_frame_size: u32) Decoder {
        return .{ .frames = frame.FrameDecoder.init(receiver_max_frame_size) };
    }

    pub fn creditReceive(self: *Decoder, increment: u31) error{FlowControl}!void {
        try self.state.creditReceive(increment);
    }

    pub inline fn complete(self: *Decoder, input: []const u8) error{FragmentedFrameActive}!CompleteIterator {
        if (!self.idle()) return error.FragmentedFrameActive;
        return self.completeAssumeIdle(input);
    }

    /// Unchecked hot-path variant for event loops whose control flow already
    /// proves that no fragmented frame is active.
    pub inline fn completeAssumeIdle(self: *Decoder, input: []const u8) CompleteIterator {
        std.debug.assert(self.idle());
        return CompleteIterator.init(&self.state, input, self.frames.peer_max_frame_size);
    }

    /// Applies connection-wide state after `frames.next()` returns a header
    /// event. This two-phase fragmented API is intentional: keeping the frame
    /// decoder's small error set out of the connection-state error path produces
    /// materially better code on Zig 0.16.0 than a fused wrapper.
    pub inline fn checkHeader(self: *Decoder, header: frame.FrameHeader) Violation {
        return self.state.check(header);
    }

    pub inline fn observeHeader(self: *Decoder, header: frame.FrameHeader) error{ Protocol, FlowControl }!void {
        try self.state.observe(header);
    }

    pub inline fn idle(self: Decoder) bool {
        return self.frames.payload_remaining == 0 and self.frames.header_used == 0;
    }
};

fn encodeFrame(storage: []u8, header: frame.FrameHeader, frame_payload: []const u8) ![]const u8 {
    var encoded: [9]u8 = undefined;
    try header.encode(&encoded);
    @memcpy(storage[0..9], &encoded);
    @memcpy(storage[9..][0..frame_payload.len], frame_payload);
    return storage[0 .. 9 + frame_payload.len];
}

test "connection complete iterator updates receive state" {
    var wire: [32]u8 = undefined;
    const bytes = try encodeFrame(&wire, .{ .length = 3, .type = .data, .flags = 1, .stream_id = 1 }, "abc");
    var state: State = .{};
    var it = CompleteIterator.init(&state, bytes, frame.default_max_frame_size);
    const complete = (try it.next()).?;
    try std.testing.expectEqualStrings("abc", complete.payload);
    try std.testing.expect((try it.next()) == null);
    try std.testing.expectEqual(bytes.len, it.consumed());
    try std.testing.expectEqual(@as(u31, 65_532), state.receive_window.available());
}

test "safe complete path rejects active fragmented frame" {
    var wire: [32]u8 = undefined;
    const bytes = try encodeFrame(&wire, .{ .length = 3, .type = .data, .flags = 0, .stream_id = 1 }, "abc");
    var decoder = Decoder.init(frame.default_max_frame_size);
    _ = try decoder.frames.next(bytes[0..9]);
    try std.testing.expectError(error.FragmentedFrameActive, decoder.complete(bytes[9..]));
}

test "connection state enforces continuation adjacency" {
    var state: State = .{};
    try state.observe(.{ .length = 1, .type = .headers, .flags = 0, .stream_id = 1 });
    try std.testing.expectError(error.Protocol, state.observe(.{ .length = 1, .type = .data, .flags = 0, .stream_id = 1 }));
}

test "connection flow control counts padded DATA by frame length" {
    var state: State = .{};
    try state.observe(.{ .length = 4, .type = .data, .flags = 0x08, .stream_id = 1 });
    try std.testing.expectEqual(@as(u31, 65_531), state.receive_window.available());
}

test "connection state accepts explicitly advertised receive credit" {
    var state: State = .{};
    try state.creditReceive(1000);
    try std.testing.expectEqual(@as(u31, 66_535), state.receive_window.available());
}

test "fragmented connection path shares continuation and flow state" {
    var h1: [9]u8 = undefined;
    var h2: [9]u8 = undefined;
    try (frame.FrameHeader{ .length = 1, .type = .headers, .flags = 0, .stream_id = 1 }).encode(&h1);
    try (frame.FrameHeader{ .length = 2, .type = .continuation, .flags = 0x04, .stream_id = 1 }).encode(&h2);
    const wire = h1 ++ "a".* ++ h2 ++ "bc".*;

    var decoder = Decoder.init(frame.default_max_frame_size);
    var pos: usize = 0;
    while (pos < wire.len) {
        const end = @min(wire.len, pos + 5);
        while (pos < end) {
            const result = try decoder.frames.next(wire[pos..end]);
            pos += result.consumed;
            if (result.event) |event| switch (event) {
                .header => |header| try decoder.observeHeader(header),
                .payload => {},
            };
            if (result.consumed == 0) return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(u31, 0), decoder.state.continuation_guard.stream_id);
}
