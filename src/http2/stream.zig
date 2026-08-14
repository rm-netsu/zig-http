const std = @import("std");

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

test "normal request response stream lifecycle" {
    var s: Stream = .{};
    try s.remoteHeaders(true);
    try std.testing.expectEqual(State.half_closed_remote, s.state);
    try s.localHeaders(true);
    try std.testing.expectEqual(State.closed, s.state);
}
