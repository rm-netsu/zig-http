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
        out[0] = @intCast((self.length >> 16) & 0xff);
        out[1] = @intCast((self.length >> 8) & 0xff);
        out[2] = @intCast(self.length & 0xff);
        out[3] = @intFromEnum(self.type);
        out[4] = self.flags;
        std.mem.writeInt(u32, out[5..9], self.stream_id, .big);
    }

    pub fn validate(self: FrameHeader, peer_max_frame_size: u32) error{ FrameSize, Protocol }!void {
        if (self.length > peer_max_frame_size) return error.FrameSize;
        switch (self.type) {
            .data => {
                if (self.stream_id == 0) return error.Protocol;
                if ((self.flags & 0x08) != 0 and self.length < 1) return error.FrameSize;
            },
            .headers => {
                if (self.stream_id == 0) return error.Protocol;
                const minimum: u32 = @as(u32, @intFromBool((self.flags & 0x08) != 0)) +
                    5 * @as(u32, @intFromBool((self.flags & 0x20) != 0));
                if (self.length < minimum) return error.FrameSize;
            },
            .priority => {
                if (self.stream_id == 0) return error.Protocol;
                if (self.length != 5) return error.FrameSize;
            },
            .rst_stream => {
                if (self.stream_id == 0) return error.Protocol;
                if (self.length != 4) return error.FrameSize;
            },
            .settings => {
                if (self.stream_id != 0) return error.Protocol;
                if ((self.flags & 0x1) != 0 and self.length != 0) return error.FrameSize;
                if (self.length % 6 != 0) return error.FrameSize;
            },
            .push_promise => {
                if (self.stream_id == 0) return error.Protocol;
                const minimum: u32 = 4 + @as(u32, @intFromBool((self.flags & 0x08) != 0));
                if (self.length < minimum) return error.FrameSize;
            },
            .ping => {
                if (self.stream_id != 0) return error.Protocol;
                if (self.length != 8) return error.FrameSize;
            },
            .goaway => {
                if (self.stream_id != 0) return error.Protocol;
                if (self.length < 8) return error.FrameSize;
            },
            .window_update => if (self.length != 4) return error.FrameSize,
            .continuation => if (self.stream_id == 0) return error.Protocol,
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

pub const CompleteFrame = struct {
    header: FrameHeader,
    payload: []const u8,
};

pub const CompleteResult = struct {
    consumed: usize,
    frame: CompleteFrame,
};

/// Stateless zero-copy fast path for a frame already contiguous in a transport
/// buffer. Returns `null` if either the 9-byte header or its complete payload is
/// not available; use `FrameDecoder` when reads can be consumed incrementally.
pub fn parseComplete(input: []const u8, receiver_max_frame_size: u32) error{ FrameSize, Protocol }!?CompleteResult {
    if (input.len < 9) return null;
    const ptr: *const [9]u8 = input[0..9];
    const h = FrameHeader.parse(ptr);
    try h.validate(receiver_max_frame_size);
    const total = 9 + @as(usize, h.length);
    if (input.len < total) return null;
    return .{
        .consumed = total,
        .frame = .{ .header = h, .payload = input[9..total] },
    };
}

/// Iterates complete frames already present in one caller-owned transport buffer.
/// The iterator keeps only the current offset and avoids rebuilding a remainder
/// slice/result wrapper for every frame. The returned payload remains zero-copy.
pub const CompleteIterator = struct {
    input: []const u8,
    receiver_max_frame_size: u32,
    offset: usize = 0,

    pub fn init(input: []const u8, receiver_max_frame_size: u32) CompleteIterator {
        return .{ .input = input, .receiver_max_frame_size = receiver_max_frame_size };
    }

    pub inline fn next(self: *CompleteIterator) error{ FrameSize, Protocol }!?CompleteFrame {
        if (self.input.len - self.offset < 9) return null;
        const ptr: *const [9]u8 = self.input[self.offset..][0..9];
        const h = FrameHeader.parse(ptr);
        try h.validate(self.receiver_max_frame_size);
        const total = 9 + @as(usize, h.length);
        if (self.input.len - self.offset < total) return null;
        const payload_start = self.offset + 9;
        const end = self.offset + total;
        self.offset = end;
        return .{ .header = h, .payload = self.input[payload_start..end] };
    }

    pub fn consumed(self: CompleteIterator) usize {
        return self.offset;
    }
};

/// Streaming HTTP/2 frame decoder. The fixed 9-byte frame header is copied only
/// when fragmented across transport reads; payload is always surfaced zero-copy.
pub const FrameDecoder = struct {
    peer_max_frame_size: u32 = default_max_frame_size,
    payload_remaining: u32 = 0,
    header_buf: [9]u8 = undefined,
    header_used: u4 = 0,

    pub fn init(peer_max: u32) FrameDecoder {
        return .{ .peer_max_frame_size = peer_max };
    }

    pub fn next(self: *FrameDecoder, input: []const u8) error{ FrameSize, Protocol }!Result {
        if (self.payload_remaining != 0) {
            if (input.len == 0) return .{ .consumed = 0 };
            const n = @min(input.len, @as(usize, self.payload_remaining));
            self.payload_remaining -= @intCast(n);
            return .{
                .consumed = n,
                .event = .{ .payload = .{ .bytes = input[0..n], .end_frame = self.payload_remaining == 0 } },
            };
        }

        if (self.header_used == 0 and input.len >= 9) {
            const ptr: *const [9]u8 = input[0..9];
            const h = FrameHeader.parse(ptr);
            try h.validate(self.peer_max_frame_size);
            self.payload_remaining = h.length;
            return .{ .consumed = 9, .event = .{ .header = h } };
        }

        const consumed = @min(input.len, 9 - @as(usize, self.header_used));
        @memcpy(self.header_buf[self.header_used..][0..consumed], input[0..consumed]);
        self.header_used += @intCast(consumed);
        if (self.header_used == 9) {
            const h = FrameHeader.parse(&self.header_buf);
            try h.validate(self.peer_max_frame_size);
            self.header_used = 0;
            self.payload_remaining = h.length;
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

test "frame header encodes the full 24-bit length" {
    const lengths = [_]u32{ 256, 4096, default_max_frame_size, max_frame_size };
    for (lengths) |length| {
        const h: FrameHeader = .{ .length = length, .type = .data, .flags = 0, .stream_id = 1 };
        var bytes: [9]u8 = undefined;
        try h.encode(&bytes);
        try std.testing.expectEqual(length, FrameHeader.parse(&bytes).length);
    }
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

test "complete frame fast path is zero-copy" {
    const h: FrameHeader = .{ .length = 5, .type = .data, .flags = 1, .stream_id = 3 };
    var header: [9]u8 = undefined;
    try h.encode(&header);
    const wire = header ++ "hello".*;
    const r = (try parseComplete(&wire, default_max_frame_size)).?;
    try std.testing.expectEqual(h, r.frame.header);
    try std.testing.expectEqualStrings("hello", r.frame.payload);
    try std.testing.expectEqual(wire.len, r.consumed);
}

test "frame validation rejects flag-dependent undersized payloads" {
    try std.testing.expectError(error.FrameSize, (FrameHeader{ .length = 0, .type = .data, .flags = 0x08, .stream_id = 1 }).validate(default_max_frame_size));
    try std.testing.expectError(error.FrameSize, (FrameHeader{ .length = 5, .type = .headers, .flags = 0x28, .stream_id = 1 }).validate(default_max_frame_size));
    try std.testing.expectError(error.FrameSize, (FrameHeader{ .length = 4, .type = .push_promise, .flags = 0x08, .stream_id = 1 }).validate(default_max_frame_size));
    try std.testing.expectError(error.FrameSize, (FrameHeader{ .length = 7, .type = .goaway, .flags = 0, .stream_id = 0 }).validate(default_max_frame_size));
}

test "complete iterator scans frames and leaves an incomplete tail" {
    const first: FrameHeader = .{ .length = 1, .type = .data, .flags = 0, .stream_id = 1 };
    const second: FrameHeader = .{ .length = 2, .type = .data, .flags = 1, .stream_id = 3 };
    var h1: [9]u8 = undefined;
    var h2: [9]u8 = undefined;
    try first.encode(&h1);
    try second.encode(&h2);
    var wire: [9 + 1 + 9 + 2 + 4]u8 = undefined;
    @memcpy(wire[0..9], &h1);
    wire[9] = 'a';
    @memcpy(wire[10..19], &h2);
    @memcpy(wire[19..21], "bc");
    @memcpy(wire[21..], "tail");

    var it = CompleteIterator.init(&wire, default_max_frame_size);
    const a = (try it.next()).?;
    const b = (try it.next()).?;
    try std.testing.expectEqualStrings("a", a.payload);
    try std.testing.expectEqualStrings("bc", b.payload);
    try std.testing.expect((try it.next()) == null);
    try std.testing.expectEqual(@as(usize, 21), it.consumed());
}
