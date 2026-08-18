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
        if ((target == 0 and low_watermark != 0) or (target != 0 and low_watermark >= target)) return error.InvalidPolicy;
        return .{ .target = target, .low_watermark = low_watermark };
    }

    /// Reconfigures the target without discarding capacity already released by
    /// the application. A zero target is useful while a reduced
    /// SETTINGS_INITIAL_WINDOW_SIZE is being activated after its ACK: released
    /// bytes can still recover a temporarily negative stream receive window.
    pub fn setPolicy(self: *ReceiveCredit, target: u31, low_watermark: u31) error{InvalidPolicy}!void {
        if ((target == 0 and low_watermark != 0) or (target != 0 and low_watermark >= target)) return error.InvalidPolicy;
        self.target = target;
        self.low_watermark = low_watermark;
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
        const signed = @as(i64, current.value);
        if (signed >= 0) {
            const available: u31 = @intCast(signed);
            if (available > self.low_watermark or available >= self.target) return null;
        }
        const gap = @as(i64, self.target) - signed;
        if (gap <= 0) return null;
        const bounded_gap: u32 = @intCast(@min(gap, @as(i64, std.math.maxInt(u31))));
        const increment: u31 = @intCast(@min(self.released, bounded_gap));
        return if (increment == 0) null else increment;
    }

    /// Commits a successfully written WINDOW_UPDATE proposal.
    pub inline fn commit(self: *ReceiveCredit, increment: u31) void {
        std.debug.assert(increment != 0 and @as(u32, increment) <= self.released);
        self.released -= increment;
    }
};

/// Per-stream send credit represented as a signed adjustment relative to the
/// peer's current SETTINGS_INITIAL_WINDOW_SIZE. SETTINGS changes therefore
/// remain O(1) connection state updates: no active-stream table sweep is needed.
///
/// `adjustment` accounts only for stream-local DATA consumption and
/// WINDOW_UPDATE increments. The effective window is
/// `peer_initial_window + adjustment` and can be negative after a SETTINGS
/// decrease, as required by HTTP/2.
pub const StreamSendWindow = struct {
    adjustment: i32 = 0,

    pub inline fn signed(self: StreamSendWindow, peer_initial_window: u31) i64 {
        return @as(i64, peer_initial_window) + @as(i64, self.adjustment);
    }

    pub inline fn available(self: StreamSendWindow, peer_initial_window: u31) u31 {
        // Validated SETTINGS transitions guarantee that the effective stream
        // window remains <= 2^31-1; the negative bound is representable too.
        // Keep the DATA hot path in i32 instead of widening every probe to i64.
        const value = self.adjustment + @as(i32, @intCast(peer_initial_window));
        return if (value <= 0) 0 else @intCast(value);
    }

    pub inline fn consume(self: *StreamSendWindow, peer_initial_window: u31, amount: u32) error{FlowControl}!void {
        if (amount > 0x7fff_ffff) return error.FlowControl;
        // Empty DATA consumes no flow-control credit and remains legal even
        // when a SETTINGS decrease has made the effective stream window
        // negative. Stream-state validation is handled separately.
        if (amount == 0) return;
        const current = self.adjustment + @as(i32, @intCast(peer_initial_window));
        if (current <= 0 or @as(u32, @intCast(current)) < amount) return error.FlowControl;
        self.adjustment -= @as(i32, @intCast(amount));
    }

    /// Commit counterpart for a caller that already proved `amount <= available`.
    /// This is useful after bytes have been successfully written, where repeating
    /// the same effective-window calculation only adds hot-path overhead.
    pub inline fn consumeAssumeAvailable(self: *StreamSendWindow, amount: u32) void {
        std.debug.assert(amount <= 0x7fff_ffff);
        self.adjustment -= @as(i32, @intCast(amount));
    }

    pub fn update(self: *StreamSendWindow, peer_initial_window: u31, increment: u31) error{FlowControl}!void {
        if (increment == 0) return error.FlowControl;
        const next_adjustment = @as(i64, self.adjustment) + @as(i64, increment);
        const max_adjustment = @as(i64, 0x7fff_ffff) - @as(i64, peer_initial_window);
        if (next_adjustment > max_adjustment) return error.FlowControl;
        self.adjustment = @intCast(next_adjustment);
    }
};

/// Generic signed flow-control window used for connection send/receive and
/// stream receive accounting. Stream send windows use `StreamSendWindow`.
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

    /// Applies SETTINGS_INITIAL_WINDOW_SIZE to an absolute stream window.
    /// The composed HTTP/2 Session uses `StreamSendWindow` instead, but this
    /// primitive remains available for callers that intentionally choose an
    /// eager per-stream update policy.
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

test "relative stream send window follows peer initial size lazily" {
    var w: StreamSendWindow = .{};
    try std.testing.expectEqual(@as(u31, 65_535), w.available(65_535));
    try w.consume(65_535, 10_000);
    try std.testing.expectEqual(@as(u31, 55_535), w.available(65_535));
    try std.testing.expectEqual(@as(u31, 22_768), w.available(32_768));
    try std.testing.expectEqual(@as(i32, -10_000), w.adjustment);
    try w.update(32_768, 2_000);
    try std.testing.expectEqual(@as(u31, 24_768), w.available(32_768));
}

test "relative stream send window tracks negative settings result" {
    var w: StreamSendWindow = .{};
    try w.consume(65_535, 60_000);
    try std.testing.expectEqual(@as(i32, -27_232), w.signed(32_768));
    try std.testing.expectEqual(@as(u31, 0), w.available(32_768));
    try w.update(32_768, 27_232);
    try std.testing.expectEqual(@as(u31, 0), w.available(32_768));
    try w.update(32_768, 1);
    try std.testing.expectEqual(@as(u31, 1), w.available(32_768));
}

test "zero-length DATA is allowed with a negative stream send window" {
    var w: StreamSendWindow = .{};
    try w.consume(65_535, 60_000);
    try std.testing.expect(w.signed(32_768) < 0);
    try w.consume(32_768, 0);
    try std.testing.expectError(error.FlowControl, w.consume(32_768, 1));
}

test "relative stream window rejects overflow against current initial size" {
    var w: StreamSendWindow = .{};
    try std.testing.expectError(error.FlowControl, w.update(65_535, 0));
    try std.testing.expectError(error.FlowControl, w.update(65_535, 0x7fff_ffff));
}

test "flow control window" {
    var w: FlowWindow = .{};
    try w.consume(1024);
    try w.update(512);
    try std.testing.expectEqual(@as(u31, 65023), w.available());
    try std.testing.expectError(error.FlowControl, w.update(0));
}

test "absolute flow window retains eager initial SETTINGS primitive" {
    var w: FlowWindow = .{};
    try w.consume(60_000);
    try w.applyInitialDelta(65_535, 16_384);
    try std.testing.expectEqual(@as(i32, -43_616), w.value);
    try w.applyInitialDelta(16_384, 65_535);
    try std.testing.expectEqual(@as(i32, 5_535), w.value);
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
    const zero = try ReceiveCredit.init(0, 0);
    try std.testing.expectEqual(@as(u31, 0), zero.target);
    try std.testing.expectError(error.InvalidPolicy, ReceiveCredit.init(0, 1));
    try std.testing.expectError(error.InvalidPolicy, ReceiveCredit.init(10, 10));
}

test "receive credit can recover a negative window after local settings activation" {
    var credit = try ReceiveCredit.init(65_535, 32_767);
    credit.release(20_000);
    try credit.setPolicy(0, 0);
    const window: FlowWindow = .{ .value = -10_000 };
    try std.testing.expectEqual(@as(?u31, 10_000), credit.proposal(window));
}
