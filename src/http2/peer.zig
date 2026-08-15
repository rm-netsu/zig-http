const std = @import("std");
const flow = @import("flow.zig");
const frame = @import("frame.zig");
const payload = @import("payload.zig");
const settings = @import("settings.zig");

pub const Role = enum { client, server };

/// State advertised by the peer and therefore constraining what the local
/// endpoint can send. Stream-level windows remain caller-owned; changes to
/// SETTINGS_INITIAL_WINDOW_SIZE are returned as ordered effects so composed
/// stream state can validate them in wire order.
pub const State = struct {
    settings: settings.Settings = .{},
    send_window: flow.FlowWindow = .{},
    local_role: Role,
    // Bit 31 is an impossible stream-id bit and therefore doubles as the
    // "no GOAWAY received" sentinel without an optional-value size penalty.
    goaway_last_stream_id: u32 = no_goaway,

    const no_goaway: u32 = 0x8000_0000;

    pub const InitialWindowChange = struct {
        old: u31,
        new: u31,

        pub fn delta(self: InitialWindowChange) i32 {
            return @intCast(@as(i64, self.new) - @as(i64, self.old));
        }
    };

    pub const SettingEffect = union(enum) {
        none,
        header_table_size: u32,
        enable_push: bool,
        max_concurrent_streams: u32,
        initial_window: InitialWindowChange,
        max_frame_size: u32,
        max_header_list_size: u32,
    };

    pub const StreamWindowUpdate = struct {
        stream_id: u31,
        increment: u31,
    };

    pub const SettingsEffects = struct {
        peer: *State,
        iterator: settings.Iterator,

        /// Effects are surfaced in wire order. This matters for repeated
        /// SETTINGS_INITIAL_WINDOW_SIZE values because each delta has to be
        /// applied to active stream windows before the next setting is handled.
        pub fn next(self: *SettingsEffects) error{ Protocol, FlowControl }!?SettingEffect {
            const setting = self.iterator.next() orelse return null;
            return try self.peer.applySetting(setting);
        }
    };

    pub const SettingsFrame = struct {
        ack: bool,
        effects: SettingsEffects,
    };

    pub fn init(local_role: Role) State {
        var result: State = .{ .local_role = local_role };
        // SETTINGS_ENABLE_PUSH describes whether a client permits server push.
        // For a server peer its initial value has no effect and is equivalent 0.
        if (local_role == .client) result.settings.enable_push = false;
        return result;
    }

    pub fn applySetting(self: *State, setting: settings.Setting) error{ Protocol, FlowControl }!SettingEffect {
        switch (setting.id) {
            .header_table_size => {
                try self.settings.apply(setting);
                return .{ .header_table_size = self.settings.header_table_size };
            },
            .enable_push => {
                if (self.local_role == .client and setting.value == 1) return error.Protocol;
                try self.settings.apply(setting);
                return .{ .enable_push = self.settings.enable_push };
            },
            .max_concurrent_streams => {
                try self.settings.apply(setting);
                return .{ .max_concurrent_streams = self.settings.max_concurrent_streams };
            },
            .initial_window_size => {
                const old = self.settings.initial_window_size;
                try self.settings.apply(setting);
                const new = self.settings.initial_window_size;
                return .{ .initial_window = .{ .old = old, .new = new } };
            },
            .max_frame_size => {
                try self.settings.apply(setting);
                return .{ .max_frame_size = self.settings.max_frame_size };
            },
            .max_header_list_size => {
                try self.settings.apply(setting);
                return .{ .max_header_list_size = self.settings.max_header_list_size };
            },
            else => return .none,
        }
    }

    /// Opens a validated SETTINGS payload as an ordered effect iterator. An ACK
    /// frame has an empty iterator and must not itself be acknowledged.
    pub fn settingsFrame(self: *State, header: frame.FrameHeader, bytes: []const u8) error{ FrameSize, Protocol }!SettingsFrame {
        if (header.type != .settings or header.stream_id != 0) return error.Protocol;
        if (bytes.len != header.length or bytes.len % 6 != 0) return error.FrameSize;
        const ack = (header.flags & 0x01) != 0;
        if (ack and bytes.len != 0) return error.FrameSize;
        return .{
            .ack = ack,
            .effects = .{ .peer = self, .iterator = try settings.Iterator.init(bytes) },
        };
    }

    /// Applies a received connection-level WINDOW_UPDATE. Stream-specific
    /// updates are returned to the caller for its stream table.
    pub fn windowUpdate(self: *State, header: frame.FrameHeader, bytes: []const u8) error{ FrameSize, Protocol, FlowControl }!?StreamWindowUpdate {
        if (header.type != .window_update) return error.Protocol;
        if (bytes.len != header.length) return error.FrameSize;
        const increment = try payload.windowIncrementValue(bytes);
        if (header.stream_id == 0) {
            if (increment == 0) return error.Protocol;
            try self.send_window.update(increment);
            return null;
        }
        // Zero is returned to the stream layer because RFC 9113 classifies it
        // as a stream PROTOCOL_ERROR rather than a connection error.
        return .{ .stream_id = header.stream_id, .increment = increment };
    }

    /// Records a received GOAWAY and rejects a later GOAWAY that increases its
    /// last-stream-id. The returned debug_data aliases caller-owned input.
    pub fn goAway(self: *State, header: frame.FrameHeader, bytes: []const u8) error{ FrameSize, Protocol }!payload.GoAway {
        if (header.type != .goaway or header.stream_id != 0) return error.Protocol;
        if (bytes.len != header.length) return error.FrameSize;
        const parsed = try payload.goAway(bytes);
        if (self.goaway_last_stream_id != no_goaway and parsed.last_stream_id > self.goaway_last_stream_id)
            return error.Protocol;
        self.goaway_last_stream_id = parsed.last_stream_id;
        return parsed;
    }

    pub inline fn goAwayReceived(self: State) bool {
        return self.goaway_last_stream_id != no_goaway;
    }

    pub inline fn lastGoAwayStream(self: State) ?u31 {
        if (!self.goAwayReceived()) return null;
        return @intCast(self.goaway_last_stream_id);
    }

    /// Applies peer-advertised connection constraints before an outbound frame
    /// is serialized. Stream state and stream-level flow control are checked by
    /// the caller-owned stream record. DATA length includes any padding.
    pub fn sendHeader(self: *State, header: frame.FrameHeader) error{ FrameSize, Protocol, FlowControl }!void {
        if (header.length > self.settings.max_frame_size) return error.FrameSize;
        if (header.type == .push_promise) {
            if (self.local_role != .server or !self.settings.enable_push) return error.Protocol;
        }
        if (header.type == .data) try self.send_window.consume(header.length);
    }

    /// Accounts DATA emitted by the local endpoint against the peer-advertised
    /// connection send window. Prefer `sendHeader` when a frame header is
    /// already available because it also enforces peer frame-size/push settings.
    pub fn consumeSend(self: *State, amount: u32) error{FlowControl}!void {
        try self.send_window.consume(amount);
    }
};

fn settingBytes(setting: settings.Setting) [6]u8 {
    var bytes: [6]u8 = undefined;
    settings.encode(&bytes, setting);
    return bytes;
}

test "settings frame effects preserve wire order" {
    var peer = State.init(.server);
    const a = settingBytes(.{ .id = .initial_window_size, .value = 70_000 });
    const b = settingBytes(.{ .id = .initial_window_size, .value = 60_000 });
    const bytes = a ++ b;
    const header: frame.FrameHeader = .{ .length = bytes.len, .type = .settings, .flags = 0, .stream_id = 0 };
    var parsed = try peer.settingsFrame(header, &bytes);
    try std.testing.expect(!parsed.ack);
    const first = (try parsed.effects.next()).?.initial_window;
    const second = (try parsed.effects.next()).?.initial_window;
    try std.testing.expectEqual(@as(i32, 4_465), first.delta());
    try std.testing.expectEqual(@as(i32, -10_000), second.delta());
    try std.testing.expect((try parsed.effects.next()) == null);
}

test "client rejects server SETTINGS_ENABLE_PUSH one" {
    var peer = State.init(.client);
    try std.testing.expectError(error.Protocol, peer.applySetting(.{ .id = .enable_push, .value = 1 }));
    const effect = try peer.applySetting(.{ .id = .enable_push, .value = 0 });
    try std.testing.expect(!effect.enable_push);
}

test "peer connection window update changes send credit" {
    var peer = State.init(.server);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, 1024, .big);
    const header: frame.FrameHeader = .{ .length = 4, .type = .window_update, .flags = 0, .stream_id = 0 };
    try std.testing.expect((try peer.windowUpdate(header, &bytes)) == null);
    try std.testing.expectEqual(@as(u31, 66_559), peer.send_window.available());
}

test "peer returns stream window updates to caller" {
    var peer = State.init(.server);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, 4096, .big);
    const header: frame.FrameHeader = .{ .length = 4, .type = .window_update, .flags = 0, .stream_id = 3 };
    const update = (try peer.windowUpdate(header, &bytes)).?;
    try std.testing.expectEqual(@as(u31, 3), update.stream_id);
    try std.testing.expectEqual(@as(u31, 4096), update.increment);
}

test "peer GOAWAY last stream id cannot increase" {
    var peer = State.init(.client);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], 7, .big);
    std.mem.writeInt(u32, bytes[4..8], 0, .big);
    const header: frame.FrameHeader = .{ .length = 8, .type = .goaway, .flags = 0, .stream_id = 0 };
    _ = try peer.goAway(header, &bytes);
    try std.testing.expectEqual(@as(?u31, 7), peer.lastGoAwayStream());
    std.mem.writeInt(u32, bytes[0..4], 3, .big);
    _ = try peer.goAway(header, &bytes);
    std.mem.writeInt(u32, bytes[0..4], 5, .big);
    try std.testing.expectError(error.Protocol, peer.goAway(header, &bytes));
}

test "SETTINGS ACK has no effects" {
    var peer = State.init(.server);
    const header: frame.FrameHeader = .{ .length = 0, .type = .settings, .flags = 0x01, .stream_id = 0 };
    var parsed = try peer.settingsFrame(header, &.{});
    try std.testing.expect(parsed.ack);
    try std.testing.expect((try parsed.effects.next()) == null);
}

test "initial-window effect changes relative stream window without mutation" {
    const stream = @import("stream.zig");
    var peer = State.init(.server);
    var windows = stream.Windows.init(65_535);
    try windows.consumeSend(peer.settings.initial_window_size, 10_000);
    const effect = try peer.applySetting(.{ .id = .initial_window_size, .value = 32_768 });
    try std.testing.expectEqual(@as(i32, -32_767), effect.initial_window.delta());
    try std.testing.expectEqual(@as(u31, 22_768), windows.send.available(peer.settings.initial_window_size));
}

test "outbound peer constraints cover frame size push and DATA credit" {
    var server = State.init(.server);
    try server.sendHeader(.{ .length = 1024, .type = .data, .flags = 0, .stream_id = 1 });
    try std.testing.expectEqual(@as(u31, 64_511), server.send_window.available());

    _ = try server.applySetting(.{ .id = .max_frame_size, .value = 32_768 });
    try std.testing.expectError(error.FrameSize, server.sendHeader(.{ .length = 40_000, .type = .headers, .flags = 4, .stream_id = 1 }));

    _ = try server.applySetting(.{ .id = .enable_push, .value = 0 });
    try std.testing.expectError(error.Protocol, server.sendHeader(.{ .length = 4, .type = .push_promise, .flags = 4, .stream_id = 1 }));

    var client = State.init(.client);
    try std.testing.expectError(error.Protocol, client.sendHeader(.{ .length = 4, .type = .push_promise, .flags = 4, .stream_id = 1 }));
}

test "stream WINDOW_UPDATE zero is returned for stream-level classification" {
    var peer = State.init(.server);
    const bytes = [_]u8{ 0, 0, 0, 0 };
    const header: frame.FrameHeader = .{ .length = 4, .type = .window_update, .flags = 0, .stream_id = 3 };
    const update = (try peer.windowUpdate(header, &bytes)).?;
    try std.testing.expectEqual(@as(u31, 3), update.stream_id);
    try std.testing.expectEqual(@as(u31, 0), update.increment);
}

test "connection WINDOW_UPDATE zero remains connection protocol error" {
    var peer = State.init(.server);
    const bytes = [_]u8{ 0, 0, 0, 0 };
    const header: frame.FrameHeader = .{ .length = 4, .type = .window_update, .flags = 0, .stream_id = 0 };
    try std.testing.expectError(error.Protocol, peer.windowUpdate(header, &bytes));
}
