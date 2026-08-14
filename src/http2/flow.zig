const std = @import("std");

/// Signed local accounting is useful when SETTINGS_INITIAL_WINDOW_SIZE shrinks
/// a peer's per-stream send window below zero.
pub const FlowWindow = struct {
    value: i64 = 65_535,

    pub fn consume(self: *FlowWindow, amount: u32) error{FlowControl}!void {
        const next = self.value - @as(i64, amount);
        if (next < 0) return error.FlowControl;
        self.value = next;
    }

    pub fn update(self: *FlowWindow, increment: u31) error{FlowControl}!void {
        if (increment == 0) return error.FlowControl;
        const next = self.value + @as(i64, increment);
        if (next > 0x7fff_ffff) return error.FlowControl;
        self.value = next;
    }

    pub fn applyInitialDelta(self: *FlowWindow, old: u31, new: u31) error{FlowControl}!void {
        self.value += @as(i64, new) - @as(i64, old);
        if (self.value > 0x7fff_ffff or self.value < -0x7fff_ffff) return error.FlowControl;
    }

    pub fn available(self: FlowWindow) u31 {
        if (self.value <= 0) return 0;
        return @intCast(@min(self.value, 0x7fff_ffff));
    }
};

test "flow control window" {
    var w: FlowWindow = .{};
    try w.consume(1024);
    try w.update(512);
    try std.testing.expectEqual(@as(u31, 65023), w.available());
    try std.testing.expectError(error.FlowControl, w.update(0));
}
