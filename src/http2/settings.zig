const std = @import("std");
const frame = @import("frame.zig");

pub const Id = enum(u16) {
    header_table_size = 0x1,
    enable_push = 0x2,
    max_concurrent_streams = 0x3,
    initial_window_size = 0x4,
    max_frame_size = 0x5,
    max_header_list_size = 0x6,
    _,
};

pub const Setting = struct { id: Id, value: u32 };

pub const Iterator = struct {
    payload: []const u8,
    offset: usize = 0,

    pub fn init(payload: []const u8) error{FrameSize}!Iterator {
        if (payload.len % 6 != 0) return error.FrameSize;
        return .{ .payload = payload };
    }

    pub fn next(self: *Iterator) ?Setting {
        if (self.offset == self.payload.len) return null;
        const p = self.payload[self.offset..][0..6];
        self.offset += 6;
        return .{
            .id = @enumFromInt(std.mem.readInt(u16, p[0..2], .big)),
            .value = std.mem.readInt(u32, p[2..6], .big),
        };
    }
};

pub const Settings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = true,
    max_concurrent_streams: u32 = std.math.maxInt(u32),
    initial_window_size: u31 = 65_535,
    max_frame_size: u32 = frame.default_max_frame_size,
    max_header_list_size: u32 = std.math.maxInt(u32),

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
}
