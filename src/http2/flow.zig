const std = @import("std");

/// Caller-owned receive-credit replenishment state. Applications report bytes
/// only after they have released the corresponding receive-side capacity; the
/// helper then proposes WINDOW_UPDATE increments when the advertised HTTP/2
/// window reaches a chosen low watermark.
///
/// The proposal/commit split is intentional: protocol state and released-byte
/// accounting can be committed only after the WINDOW_UPDATE reaches the writer.
pub const ReceiveCredit = struct {
    target: u31,
    low_watermark: u31,
    released: u32 = 0,

    pub fn init(target: u31, low_watermark: u31) error{InvalidPolicy}!ReceiveCredit {
        if (target == 0 or low_watermark >= target) return error.InvalidPolicy;
        return .{ .target = target, .low_watermark = low_watermark };
    }

    /// Adds receive capacity released by the caller. For DATA with padding,
    /// use the full flow-controlled frame payload length rather than only the
    /// application-visible data bytes.
    pub inline fn release(self: *ReceiveCredit, amount: u32) void {
        self.released +|= amount;
    }

    /// Returns the next safe WINDOW_UPDATE increment without mutating state.
    /// No update is proposed while the current advertised credit remains above
    /// the low watermark or while the caller has not released capacity.
    pub inline fn proposal(self: ReceiveCredit, current: FlowWindow) ?u31 {
        if (self.released == 0) return null;
        const available = current.available();
        if (available > self.low_watermark or available >= self.target) return null;
        const gap: u31 = self.target - available;
        const increment: u31 = @intCast(@min(self.released, @as(u32, gap)));
        return if (increment == 0) null else increment;
    }

    /// Commits a successfully written WINDOW_UPDATE proposal.
    pub inline fn commit(self: *ReceiveCredit, increment: u31) void {
        std.debug.assert(increment != 0 and @as(u32, increment) <= self.released);
        self.released -= increment;
    }
};

/// Signed local accounting is useful when SETTINGS_INITIAL_WINDOW_SIZE shrinks
/// a peer's per-stream send window below zero.
pub const FlowWindow = struct {
    value: i32 = 65_535,

    pub fn consume(self: *FlowWindow, amount: u32) error{FlowControl}!void {
        const next = @as(i64, self.value) - @as(i64, amount);
        if (next < 0) return error.FlowControl;
        self.value = @intCast(next);
    }

    pub fn update(self: *FlowWindow, increment: u31) error{FlowControl}!void {
        if (increment == 0) return error.FlowControl;
        const next = @as(i64, self.value) + @as(i64, increment);
        if (next > 0x7fff_ffff) return error.FlowControl;
        self.value = @intCast(next);
    }

    pub fn applyInitialDelta(self: *FlowWindow, old: u31, new: u31) error{FlowControl}!void {
        const next = @as(i64, self.value) + @as(i64, new) - @as(i64, old);
        if (next > 0x7fff_ffff or next < -0x7fff_ffff) return error.FlowControl;
        self.value = @intCast(next);
    }

    pub fn available(self: FlowWindow) u31 {
        if (self.value <= 0) return 0;
        return @intCast(self.value);
    }
};

test "flow control window" {
    var w: FlowWindow = .{};
    try w.consume(1024);
    try w.update(512);
    try std.testing.expectEqual(@as(u31, 65023), w.available());
    try std.testing.expectError(error.FlowControl, w.update(0));
}

test "receive credit replenishment is caller driven and two phase" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(ReceiveCredit));
    var credit = try ReceiveCredit.init(65_535, 32_767);
    var window: FlowWindow = .{};
    credit.release(20_000);
    try std.testing.expect(credit.proposal(window) == null);
    try window.consume(40_000);
    const increment = credit.proposal(window).?;
    try std.testing.expectEqual(@as(u31, 20_000), increment);
    try std.testing.expectEqual(@as(u32, 20_000), credit.released);
    credit.commit(increment);
    try std.testing.expectEqual(@as(u32, 0), credit.released);
}

test "receive credit caps updates at target" {
    var credit = try ReceiveCredit.init(100_000, 50_000);
    credit.release(90_000);
    const window: FlowWindow = .{ .value = 40_000 };
    try std.testing.expectEqual(@as(?u31, 60_000), credit.proposal(window));
    try std.testing.expectError(error.InvalidPolicy, ReceiveCredit.init(0, 0));
    try std.testing.expectError(error.InvalidPolicy, ReceiveCredit.init(10, 10));
}
