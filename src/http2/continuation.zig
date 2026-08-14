const std = @import("std");
const frame = @import("frame.zig");

/// Enforces the connection-wide HEADERS/PUSH_PROMISE + CONTINUATION adjacency rule.
pub const Guard = struct {
    /// Zero means no continuation sequence is active; HTTP/2 stream 0 is never
    /// valid for HEADERS, PUSH_PROMISE, or CONTINUATION.
    stream_id: u31 = 0,

    pub fn observe(self: *Guard, h: frame.FrameHeader) error{Protocol}!void {
        if ((h.type == .headers or h.type == .push_promise or h.type == .continuation) and h.stream_id == 0)
            return error.Protocol;
        if (self.stream_id != 0) {
            const expected = self.stream_id;
            if (h.type != .continuation or h.stream_id != expected) return error.Protocol;
            if ((h.flags & 0x04) != 0) self.stream_id = 0;
            return;
        }
        if (h.type == .continuation) return error.Protocol;
        if ((h.type == .headers or h.type == .push_promise) and (h.flags & 0x04) == 0)
            self.stream_id = h.stream_id;
    }
};

test "continuation guard" {
    var g: Guard = .{};
    try g.observe(.{ .length = 0, .type = .headers, .flags = 0, .stream_id = 1 });
    try std.testing.expectError(error.Protocol, g.observe(.{ .length = 0, .type = .data, .flags = 0, .stream_id = 1 }));
    try g.observe(.{ .length = 0, .type = .continuation, .flags = 0x04, .stream_id = 1 });
    try std.testing.expectEqual(@as(u31, 0), g.stream_id);
    try std.testing.expectError(error.Protocol, g.observe(.{ .length = 0, .type = .headers, .flags = 0, .stream_id = 0 }));
}
