const std = @import("std");
const session_mod = @import("session.zig");
const streams_mod = @import("streams.zig");

/// One caller-owned DATA work item. The scheduler never stores or mutates this
/// slice; applications can rebuild/reorder it to implement their own priority
/// policy while retaining round-robin fairness within the supplied order.
pub const Candidate = struct {
    stream_id: u31,
    remaining: usize,
    end_stream: bool = false,
};

pub const Ready = struct {
    index: usize,
    amount: usize,
    stream_id: u31,
    end_stream: bool,
};

pub const Decision = union(enum) {
    /// No candidate currently has application DATA or an empty END_STREAM to send.
    idle,
    /// Work exists, but every candidate inspected is flow-control blocked.
    blocked,
    ready: Ready,
};

/// Minimal caller-driven round-robin selector. It owns only the next scan
/// position; stream queues, buffers, priorities, and wakeups stay with the event
/// loop. DATA credit is probed through Session without mutating flow state.
pub const RoundRobin = struct {
    cursor: usize = 0,

    pub fn reset(self: *RoundRobin) void {
        self.cursor = 0;
    }

    /// Hot path for event loops whose runnable set contains only live streams
    /// owned by this Session. Missing/invalid stream records are programmer
    /// errors; flow-control blocking remains a normal `null` result.
    pub inline fn nextAssumeValid(
        self: *RoundRobin,
        session: *session_mod.Session,
        store: anytype,
        candidates: []const Candidate,
    ) ?Ready {
        if (candidates.len == 0) {
            self.cursor = 0;
            return null;
        }
        if (self.cursor >= candidates.len) self.cursor = 0;

        std.debug.assert(!session.sendPoisoned());
        const connection_blocked = session.peer.send_window.available() == 0;
        var index = self.cursor;
        var visited: usize = 0;
        while (visited < candidates.len) : (visited += 1) {
            const candidate = candidates[index];
            if (candidate.remaining != 0 or candidate.end_stream) {
                if (!connection_blocked or candidate.remaining == 0) {
                    const tracked = store.get(candidate.stream_id) orelse unreachable;
                    std.debug.assert(!session.streams.unprocessedByPeer(&session.peer, candidate.stream_id));
                    std.debug.assert(tracked.stream.state == .open or tracked.stream.state == .half_closed_remote);
                    const stream_window = tracked.windows.send.adjustment + @as(i32, @intCast(session.peer.settings.initial_window_size));
                    const bounded = @min(
                        session.peer.send_window.value,
                        stream_window,
                        @as(i32, @intCast(session.peer.settings.max_frame_size)),
                    );
                    const max_payload: usize = if (bounded <= 0) 0 else @intCast(bounded);
                    if (candidate.remaining == 0 or max_payload != 0) {
                        const amount = @min(candidate.remaining, max_payload);
                        self.cursor = if (index + 1 == candidates.len) 0 else index + 1;
                        return .{
                            .index = index,
                            .amount = amount,
                            .stream_id = candidate.stream_id,
                            .end_stream = candidate.end_stream and amount == candidate.remaining,
                        };
                    }
                }
            }
            index += 1;
            if (index == candidates.len) index = 0;
        }
        return null;
    }

    pub inline fn next(
        self: *RoundRobin,
        session: *session_mod.Session,
        store: anytype,
        candidates: []const Candidate,
    ) session_mod.DataSendCreditError!Decision {
        if (candidates.len == 0) {
            self.cursor = 0;
            return .idle;
        }
        if (self.cursor >= candidates.len) self.cursor = 0;

        var has_work = false;
        var index = self.cursor;
        var visited: usize = 0;
        while (visited < candidates.len) : (visited += 1) {
            const candidate = candidates[index];
            if (candidate.remaining != 0 or candidate.end_stream) {
                has_work = true;
                // The checked path resolves every work item even when the
                // connection window is globally blocked so stale stream IDs,
                // GOAWAY, and a poisoned send side are surfaced immediately.
                const existing = session.streams.existing(store, candidate.stream_id) orelse return error.StreamClosed;
                const credit = try session.dataSendCreditExisting(existing);
                if (candidate.remaining == 0 or credit.max_payload != 0) {
                    const amount = @min(candidate.remaining, credit.max_payload);
                    self.cursor = if (index + 1 == candidates.len) 0 else index + 1;
                    return .{ .ready = .{
                        .index = index,
                        .amount = amount,
                        .stream_id = candidate.stream_id,
                        .end_stream = candidate.end_stream and amount == candidate.remaining,
                    } };
                }
            }
            index += 1;
            if (index == candidates.len) index = 0;
        }
        return if (has_work) .blocked else .idle;
    }
};

test "round robin skips blocked streams and rotates ready work" {
    const hpack = @import("hpack");
    const stream_mod = @import("stream.zig");

    const Store = struct {
        const Entry = struct { id: u31 = 0, used: bool = false, value: stream_mod.Tracked = undefined };
        entries: [4]Entry = [_]Entry{.{}} ** 4,

        fn get(self: *@This(), id: u31) ?*stream_mod.Tracked {
            for (&self.entries) |*entry| if (entry.used and entry.id == id) return &entry.value;
            return null;
        }
        fn insert(self: *@This(), id: u31, value: stream_mod.Tracked) ?*stream_mod.Tracked {
            for (&self.entries) |*entry| if (!entry.used) {
                entry.* = .{ .id = id, .used = true, .value = value };
                return &entry.value;
            };
            return null;
        }
        pub fn maxActiveSendAdjustment(_: *@This()) i32 {
            return 0;
        }
    };

    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var header_storage: [64]u8 = undefined;
    var session = session_mod.Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &header_storage });
    var store: Store = .{};
    try session.streams.openLocal(&store, &session.peer, 1, false);
    try session.streams.openLocal(&store, &session.peer, 3, false);
    try session.streams.openLocal(&store, &session.peer, 5, false);
    store.get(1).?.windows.send.adjustment = -65_535;
    store.get(3).?.windows.send.adjustment = 100 - 65_535;
    store.get(5).?.windows.send.adjustment = 200 - 65_535;

    const candidates = [_]Candidate{
        .{ .stream_id = 1, .remaining = 80 },
        .{ .stream_id = 3, .remaining = 80 },
        .{ .stream_id = 5, .remaining = 150, .end_stream = true },
    };
    var scheduler: RoundRobin = .{};
    var decision = try scheduler.next(&session, &store, &candidates);
    try std.testing.expectEqual(@as(usize, 1), decision.ready.index);
    try std.testing.expectEqual(@as(usize, 80), decision.ready.amount);

    decision = try scheduler.next(&session, &store, &candidates);
    try std.testing.expectEqual(@as(usize, 2), decision.ready.index);
    try std.testing.expectEqual(@as(usize, 150), decision.ready.amount);
    try std.testing.expect(decision.ready.end_stream);

    decision = try scheduler.next(&session, &store, &candidates);
    try std.testing.expectEqual(@as(usize, 1), decision.ready.index);
    try std.testing.expectEqual(streams_mod.State.open, store.get(3).?.stream.state);
}

test "round robin schedules empty END_STREAM without flow credit" {
    const hpack = @import("hpack");
    const stream_mod = @import("stream.zig");

    const Store = struct {
        value: ?stream_mod.Tracked = null,
        fn get(self: *@This(), id: u31) ?*stream_mod.Tracked {
            if (id != 1 or self.value == null) return null;
            return &self.value.?;
        }
        fn insert(self: *@This(), id: u31, value: stream_mod.Tracked) ?*stream_mod.Tracked {
            if (id != 1 or self.value != null) return null;
            self.value = value;
            return &self.value.?;
        }
        pub fn maxActiveSendAdjustment(_: *@This()) i32 {
            return 0;
        }
    };

    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var header_storage: [32]u8 = undefined;
    var session = session_mod.Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &header_storage });
    var store: Store = .{};
    try session.streams.openLocal(&store, &session.peer, 1, false);
    session.peer.send_window.value = 0;
    store.get(1).?.windows.send.adjustment = -65_535;

    const candidates = [_]Candidate{.{ .stream_id = 1, .remaining = 0, .end_stream = true }};
    var scheduler: RoundRobin = .{};
    const decision = try scheduler.next(&session, &store, &candidates);
    try std.testing.expectEqual(@as(usize, 0), decision.ready.amount);
    try std.testing.expect(decision.ready.end_stream);
}

test "round robin distinguishes idle from flow-control blocking" {
    const hpack = @import("hpack");
    const stream_mod = @import("stream.zig");

    const Store = struct {
        value: ?stream_mod.Tracked = null,
        fn get(self: *@This(), id: u31) ?*stream_mod.Tracked {
            if (id != 1 or self.value == null) return null;
            return &self.value.?;
        }
        fn insert(self: *@This(), id: u31, value: stream_mod.Tracked) ?*stream_mod.Tracked {
            if (id != 1 or self.value != null) return null;
            self.value = value;
            return &self.value.?;
        }
        pub fn maxActiveSendAdjustment(_: *@This()) i32 {
            return 0;
        }
    };

    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var header_storage: [32]u8 = undefined;
    var session = session_mod.Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &header_storage });
    var store: Store = .{};
    try session.streams.openLocal(&store, &session.peer, 1, false);
    session.peer.send_window.value = 0;

    var scheduler: RoundRobin = .{};
    const blocked = [_]Candidate{.{ .stream_id = 1, .remaining = 64 }};
    try std.testing.expectEqual(Decision.blocked, try scheduler.next(&session, &store, &blocked));

    const idle = [_]Candidate{.{ .stream_id = 1, .remaining = 0 }};
    try std.testing.expectEqual(Decision.idle, try scheduler.next(&session, &store, &idle));
}

test "scheduler state stays tiny" {
    try std.testing.expectEqual(@as(usize, @sizeOf(usize)), @sizeOf(RoundRobin));
}
