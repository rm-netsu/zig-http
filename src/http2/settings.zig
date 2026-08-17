const std = @import("std");
const frame = @import("frame.zig");

pub const Id = enum(u16) {
    header_table_size = 0x1,
    enable_push = 0x2,
    max_concurrent_streams = 0x3,
    initial_window_size = 0x4,
    max_frame_size = 0x5,
    max_header_list_size = 0x6,
    enable_connect_protocol = 0x8,
    _,
};

pub const Setting = struct { id: Id, value: u32 };

pub inline fn parse(bytes: *const [6]u8) Setting {
    return .{
        .id = @enumFromInt(std.mem.readInt(u16, bytes[0..2], .big)),
        .value = std.mem.readInt(u32, bytes[2..6], .big),
    };
}

pub const Iterator = struct {
    payload: []const u8,
    offset: usize = 0,

    pub fn init(payload: []const u8) error{FrameSize}!Iterator {
        if (payload.len % 6 != 0) return error.FrameSize;
        return .{ .payload = payload };
    }

    pub fn next(self: *Iterator) ?Setting {
        if (self.offset == self.payload.len) return null;
        const p: *const [6]u8 = self.payload[self.offset..][0..6];
        self.offset += 6;
        return parse(p);
    }
};

/// Incremental SETTINGS payload decoder. It emits one six-byte setting at a
/// time and copies only a setting that itself crosses a transport boundary.
pub const StreamDecoder = struct {
    scratch: [6]u8 = undefined,
    used: u3 = 0,

    pub const Result = struct {
        consumed: usize,
        setting: ?Setting = null,
    };

    pub fn reset(self: *StreamDecoder) void {
        self.used = 0;
    }

    pub inline fn feed(self: *StreamDecoder, input: []const u8) Result {
        if (self.used == 0 and input.len >= 6) {
            const p: *const [6]u8 = input[0..6];
            return .{ .consumed = 6, .setting = parse(p) };
        }
        if (input.len == 0) return .{ .consumed = 0 };

        const n = @min(input.len, 6 - @as(usize, self.used));
        @memcpy(self.scratch[self.used..][0..n], input[0..n]);
        self.used += @intCast(n);
        if (self.used != 6) return .{ .consumed = n };

        self.used = 0;
        return .{ .consumed = n, .setting = parse(&self.scratch) };
    }

    pub fn finish(self: StreamDecoder) error{FrameSize}!void {
        if (self.used != 0) return error.FrameSize;
    }
};

pub const Settings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = true,
    max_concurrent_streams: u32 = std.math.maxInt(u32),
    initial_window_size: u31 = 65_535,
    max_frame_size: u32 = frame.default_max_frame_size,
    max_header_list_size: u32 = std.math.maxInt(u32),
    /// RFC 8441 Extended CONNECT capability advertised by the peer. Once
    /// enabled it is effectively monotonic for the lifetime of a connection.
    enable_connect_protocol: bool = false,

    pub fn apply(self: *Settings, s: Setting) error{ Protocol, FlowControl }!void {
        switch (s.id) {
            .header_table_size => self.header_table_size = s.value,
            .enable_push => switch (s.value) {
                0 => self.enable_push = false,
                1 => self.enable_push = true,
                else => return error.Protocol,
            },
            .max_concurrent_streams => self.max_concurrent_streams = s.value,
            .initial_window_size => {
                if (s.value > 0x7fff_ffff) return error.FlowControl;
                self.initial_window_size = @intCast(s.value);
            },
            .max_frame_size => {
                if (s.value < frame.default_max_frame_size or s.value > frame.max_frame_size) return error.Protocol;
                self.max_frame_size = s.value;
            },
            .max_header_list_size => self.max_header_list_size = s.value,
            .enable_connect_protocol => switch (s.value) {
                0 => {}, // A peer is forbidden from withdrawing value 1; keep effective state monotonic.
                1 => self.enable_connect_protocol = true,
                else => return error.Protocol,
            },
            else => {},
        }
    }
};

pub fn encode(out: *[6]u8, s: Setting) void {
    std.mem.writeInt(u16, out[0..2], @intFromEnum(s.id), .big);
    std.mem.writeInt(u32, out[2..6], s.value, .big);
}

test "settings validation" {
    var s: Settings = .{};
    try s.apply(.{ .id = .max_frame_size, .value = 32768 });
    try std.testing.expectEqual(@as(u32, 32768), s.max_frame_size);
    try std.testing.expectError(error.Protocol, s.apply(.{ .id = .enable_push, .value = 2 }));
    try s.apply(.{ .id = .enable_connect_protocol, .value = 1 });
    try std.testing.expect(s.enable_connect_protocol);
    // RFC 8441 makes enablement monotonic. A non-conforming peer cannot make
    // an already enabled connection lose the capability by sending zero.
    try s.apply(.{ .id = .enable_connect_protocol, .value = 0 });
    try std.testing.expect(s.enable_connect_protocol);
    try std.testing.expectError(error.Protocol, s.apply(.{ .id = .enable_connect_protocol, .value = 2 }));
}

test "streaming settings decoder handles split setting" {
    var bytes: [6]u8 = undefined;
    encode(&bytes, .{ .id = .max_frame_size, .value = 32768 });
    var d: StreamDecoder = .{};
    var r = d.feed(bytes[0..2]);
    try std.testing.expect(r.setting == null);
    r = d.feed(bytes[2..5]);
    try std.testing.expect(r.setting == null);
    r = d.feed(bytes[5..]);
    try std.testing.expectEqual(Id.max_frame_size, r.setting.?.id);
    try std.testing.expectEqual(@as(u32, 32768), r.setting.?.value);
    try d.finish();
}

test "streaming settings decoder rejects partial finish" {
    var d: StreamDecoder = .{};
    _ = d.feed("abc");
    try std.testing.expectError(error.FrameSize, d.finish());
}
