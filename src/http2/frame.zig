const std = @import("std");

pub const default_max_frame_size: u32 = 16_384;
pub const max_frame_size: u32 = 16_777_215;

pub const Type = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
    _,
};

pub const FrameHeader = struct {
    length: u32,
    type: Type,
    flags: u8,
    stream_id: u31,

    pub fn parse(bytes: *const [9]u8) FrameHeader {
        const raw_stream = std.mem.readInt(u32, bytes[5..9], .big);
        return .{
            .length = (@as(u32, bytes[0]) << 16) | (@as(u32, bytes[1]) << 8) | bytes[2],
            .type = @enumFromInt(bytes[3]),
            .flags = bytes[4],
            .stream_id = @intCast(raw_stream & 0x7fff_ffff),
        };
    }

    pub fn encode(self: FrameHeader, out: *[9]u8) error{FrameTooLarge}!void {
        if (self.length > max_frame_size) return error.FrameTooLarge;
        out[0] = @intCast(self.length >> 16);
        out[1] = @intCast(self.length >> 8);
        out[2] = @intCast(self.length);
        out[3] = @intFromEnum(self.type);
        out[4] = self.flags;
        std.mem.writeInt(u32, out[5..9], self.stream_id, .big);
    }

    pub fn validate(self: FrameHeader, peer_max_frame_size: u32) error{ FrameSize, Protocol }!void {
        if (self.length > peer_max_frame_size) return error.FrameSize;
        switch (self.type) {
            .data, .headers, .priority, .rst_stream, .push_promise, .continuation => if (self.stream_id == 0) return error.Protocol,
            .settings, .ping, .goaway => if (self.stream_id != 0) return error.Protocol,
            .window_update => {},
            else => {},
        }
        switch (self.type) {
            .priority => if (self.length != 5) return error.FrameSize,
            .rst_stream => if (self.length != 4) return error.FrameSize,
            .ping => if (self.length != 8) return error.FrameSize,
            .window_update => if (self.length != 4) return error.FrameSize,
            .settings => {
                if ((self.flags & 0x1) != 0 and self.length != 0) return error.FrameSize;
                if (self.length % 6 != 0) return error.FrameSize;
            },
            else => {},
        }
    }
};

pub const Payload = struct {
    bytes: []const u8,
    end_frame: bool,
};

pub const Event = union(enum) {
    header: FrameHeader,
    payload: Payload,
};

pub const Result = struct {
    consumed: usize,
    event: ?Event = null,
};

/// Streaming HTTP/2 frame decoder. The fixed 9-byte frame header is copied only
/// when fragmented across transport reads; payload is always surfaced zero-copy.
pub const FrameDecoder = struct {
    header_buf: [9]u8 = undefined,
    header_used: u4 = 0,
    current: ?FrameHeader = null,
    payload_read: u32 = 0,
    peer_max_frame_size: u32 = default_max_frame_size,

    pub fn init(peer_max: u32) FrameDecoder {
        return .{ .peer_max_frame_size = peer_max };
    }

    pub fn next(self: *FrameDecoder, input: []const u8) error{ FrameSize, Protocol }!Result {
        if (self.current) |h| {
            if (self.payload_read == h.length) {
                self.current = null;
                self.payload_read = 0;
            } else if (input.len == 0) return .{ .consumed = 0 } else {
                const n = @min(input.len, @as(usize, h.length - self.payload_read));
                self.payload_read += @intCast(n);
                return .{
                    .consumed = n,
                    .event = .{ .payload = .{ .bytes = input[0..n], .end_frame = self.payload_read == h.length } },
                };
            }
        }

        if (self.header_used == 0 and input.len >= 9) {
            const ptr: *const [9]u8 = input[0..9];
            const h = FrameHeader.parse(ptr);
            try h.validate(self.peer_max_frame_size);
            self.current = h;
            self.payload_read = 0;
            return .{ .consumed = 9, .event = .{ .header = h } };
        }

        var consumed: usize = 0;
        while (self.header_used < 9 and consumed < input.len) {
            self.header_buf[self.header_used] = input[consumed];
            self.header_used += 1;
            consumed += 1;
        }
        if (self.header_used == 9) {
            const h = FrameHeader.parse(&self.header_buf);
            try h.validate(self.peer_max_frame_size);
            self.header_used = 0;
            self.current = h;
            self.payload_read = 0;
            return .{ .consumed = consumed, .event = .{ .header = h } };
        }
        return .{ .consumed = consumed };
    }
};

pub fn writeFrame(w: *std.Io.Writer, header: FrameHeader, payload: []const u8) (std.Io.Writer.Error || error{FrameTooLarge})!void {
    if (payload.len != header.length) return error.FrameTooLarge;
    var bytes: [9]u8 = undefined;
    try header.encode(&bytes);
    try w.writeAll(&bytes);
    try w.writeAll(payload);
}

test "frame encode and fragmented decode" {
    const h: FrameHeader = .{ .length = 5, .type = .data, .flags = 1, .stream_id = 3 };
    var bytes: [9]u8 = undefined;
    try h.encode(&bytes);
    var d = FrameDecoder.init(default_max_frame_size);
    var r = try d.next(bytes[0..4]);
    try std.testing.expect(r.event == null);
    r = try d.next(bytes[4..]);
    try std.testing.expectEqual(h, r.event.?.header);
    r = try d.next("hello");
    try std.testing.expectEqualStrings("hello", r.event.?.payload.bytes);
    try std.testing.expect(r.event.?.payload.end_frame);
}

test "frame decoder survives one-byte fragmentation" {
    const h: FrameHeader = .{ .length = 3, .type = .data, .flags = 1, .stream_id = 1 };
    var header: [9]u8 = undefined;
    try h.encode(&header);
    const wire = header ++ [_]u8{ 'a', 'b', 'c' };
    var d = FrameDecoder.init(default_max_frame_size);
    var pos: usize = 0;
    var saw_header = false;
    var payload_bytes: usize = 0;
    while (pos < wire.len) {
        const r = try d.next(wire[pos .. pos + 1]);
        pos += r.consumed;
        if (r.event) |event| switch (event) {
            .header => saw_header = true,
            .payload => |p| payload_bytes += p.bytes.len,
        };
        if (r.consumed == 0) return error.TestUnexpectedResult;
    }
    try std.testing.expect(saw_header);
    try std.testing.expectEqual(@as(usize, 3), payload_bytes);
}
