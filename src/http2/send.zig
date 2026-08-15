const std = @import("std");
const frame = @import("frame.zig");

pub const HeaderFrameStats = struct {
    encoded_bytes: usize,
    frame_count: u32,
};

/// Streaming writer that turns one HPACK field block into HEADERS followed by
/// zero or more CONTINUATION frames. The caller-owned staging buffer bounds
/// memory usage independently of the encoded field-block size.
///
/// One extra staging byte is required so a payload exactly equal to the chosen
/// frame size can remain buffered until `finish()` knows whether it is final.
pub const HeaderFramer = struct {
    out: *std.Io.Writer,
    writer: std.Io.Writer,
    stream_id: u31,
    payload_limit: usize,
    end_stream: bool,
    first: bool = true,
    frame_count: u32 = 0,
    encoded_bytes: usize = 0,

    pub fn init(
        out: *std.Io.Writer,
        staging: []u8,
        peer_max_frame_size: u32,
        stream_id: u31,
        end_stream: bool,
    ) error{BufferTooSmall}!HeaderFramer {
        if (staging.len < 2 or peer_max_frame_size == 0) return error.BufferTooSmall;
        const payload_limit = @min(@as(usize, peer_max_frame_size), staging.len - 1);
        if (payload_limit == 0) return error.BufferTooSmall;
        return .{
            .out = out,
            .writer = .{
                .buffer = staging[0 .. payload_limit + 1],
                .vtable = &.{ .drain = drain },
            },
            .stream_id = stream_id,
            .payload_limit = payload_limit,
            .end_stream = end_stream,
        };
    }

    pub fn finish(self: *HeaderFramer) std.Io.Writer.Error!HeaderFrameStats {
        if (self.writer.end > self.payload_limit) {
            try self.emit(self.writer.buffer[0..self.payload_limit], false);
            const tail = self.writer.end - self.payload_limit;
            @memmove(self.writer.buffer[0..tail], self.writer.buffer[self.payload_limit..self.writer.end]);
            self.writer.end = tail;
        }
        try self.emit(self.writer.buffer[0..self.writer.end], true);
        self.writer.end = 0;
        return .{ .encoded_bytes = self.encoded_bytes, .frame_count = self.frame_count };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *HeaderFramer = @alignCast(@fieldParentPtr("writer", w));
        var consumed: usize = 0;

        for (data[0 .. data.len - 1]) |bytes| {
            try self.append(bytes);
            consumed += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.append(pattern);
            consumed += pattern.len;
        }
        return consumed;
    }

    fn append(self: *HeaderFramer, input: []const u8) std.Io.Writer.Error!void {
        var bytes = input;
        while (bytes.len != 0) {
            if (self.writer.end > self.payload_limit) {
                try self.emit(self.writer.buffer[0..self.payload_limit], false);
                const tail = self.writer.end - self.payload_limit;
                @memmove(self.writer.buffer[0..tail], self.writer.buffer[self.payload_limit..self.writer.end]);
                self.writer.end = tail;
            } else if (self.writer.end == self.payload_limit) {
                // `bytes` proves there is more HPACK data, so this full payload
                // cannot be the final frame of the field block.
                try self.emit(self.writer.buffer[0..self.payload_limit], false);
                self.writer.end = 0;
            }

            const n = @min(bytes.len, self.writer.buffer.len - self.writer.end);
            @memcpy(self.writer.buffer[self.writer.end..][0..n], bytes[0..n]);
            self.writer.end += n;
            bytes = bytes[n..];
        }
    }

    fn emit(self: *HeaderFramer, payload: []const u8, end_headers: bool) std.Io.Writer.Error!void {
        std.debug.assert(payload.len <= self.payload_limit);
        var header_bytes: [9]u8 = undefined;
        const header: frame.FrameHeader = .{
            .length = @intCast(payload.len),
            .type = if (self.first) .headers else .continuation,
            .flags = (if (self.first and self.end_stream) @as(u8, 0x01) else 0) |
                (if (end_headers) @as(u8, 0x04) else 0),
            .stream_id = self.stream_id,
        };
        header.encode(&header_bytes) catch unreachable;
        try self.out.writeAll(&header_bytes);
        try self.out.writeAll(payload);
        self.first = false;
        self.frame_count +|= 1;
        self.encoded_bytes +|= payload.len;
    }
};

test "header framer marks exact-size final frame with END_HEADERS" {
    var out_storage: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_storage);
    var staging: [5]u8 = undefined; // four-byte frame payload plus lookahead byte
    var framer = try HeaderFramer.init(&out, &staging, 16_384, 1, true);
    try framer.writer.writeAll("abcd");
    const stats = try framer.finish();
    try std.testing.expectEqual(@as(u32, 1), stats.frame_count);
    try std.testing.expectEqual(@as(usize, 4), stats.encoded_bytes);
    const wire = out.buffered();
    const parsed = (try frame.parseComplete(wire, frame.default_max_frame_size)).?;
    try std.testing.expectEqual(frame.Type.headers, parsed.frame.header.type);
    try std.testing.expectEqual(@as(u8, 0x05), parsed.frame.header.flags);
    try std.testing.expectEqualStrings("abcd", parsed.frame.payload);
}

test "header framer streams HEADERS and CONTINUATION frames" {
    var out_storage: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_storage);
    var staging: [5]u8 = undefined;
    var framer = try HeaderFramer.init(&out, &staging, 16_384, 3, false);
    try framer.writer.writeAll("abcdefghij");
    const stats = try framer.finish();
    try std.testing.expectEqual(@as(u32, 3), stats.frame_count);
    try std.testing.expectEqual(@as(usize, 10), stats.encoded_bytes);

    var it = frame.CompleteIterator.init(out.buffered(), frame.default_max_frame_size);
    const a = (try it.next()).?;
    const b = (try it.next()).?;
    const c = (try it.next()).?;
    try std.testing.expectEqual(frame.Type.headers, a.header.type);
    try std.testing.expectEqual(@as(u8, 0), a.header.flags);
    try std.testing.expectEqualStrings("abcd", a.payload);
    try std.testing.expectEqual(frame.Type.continuation, b.header.type);
    try std.testing.expectEqual(@as(u8, 0), b.header.flags);
    try std.testing.expectEqualStrings("efgh", b.payload);
    try std.testing.expectEqual(frame.Type.continuation, c.header.type);
    try std.testing.expectEqual(@as(u8, 0x04), c.header.flags);
    try std.testing.expectEqualStrings("ij", c.payload);
    try std.testing.expect((try it.next()) == null);
}
