const std = @import("std");
const frame = @import("frame.zig");
const protocol = @import("protocol.zig");
const settings = @import("settings.zig");

pub const HeaderFrameStats = struct {
    encoded_bytes: usize,
    frame_count: u32,
};

/// Writes a SETTINGS frame without retaining the payload. Each six-byte value
/// is encoded through a tiny stack buffer, so large extension setting lists do
/// not require a caller-owned contiguous frame buffer.
pub fn writeSettings(
    out: *std.Io.Writer,
    items: []const settings.Setting,
    peer_max_frame_size: u32,
) (std.Io.Writer.Error || error{FrameTooLarge})!void {
    const payload_len = std.math.mul(usize, items.len, 6) catch return error.FrameTooLarge;
    if (payload_len > peer_max_frame_size or payload_len > frame.max_frame_size) return error.FrameTooLarge;

    var header_bytes: [9]u8 = undefined;
    try (frame.FrameHeader{
        .length = @intCast(payload_len),
        .type = .settings,
        .flags = 0,
        .stream_id = 0,
    }).encode(&header_bytes);
    try out.writeAll(&header_bytes);

    for (items) |item| {
        var encoded: [6]u8 = undefined;
        settings.encode(&encoded, item);
        try out.writeAll(&encoded);
    }
}

/// Writes an empty SETTINGS acknowledgment frame.
pub fn writeSettingsAck(out: *std.Io.Writer) std.Io.Writer.Error!void {
    var wire: [9]u8 = undefined;
    (frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0x01, .stream_id = 0 }).encode(&wire) catch unreachable;
    try out.writeAll(&wire);
}

/// Writes one PING request or response using a single writer call.
pub fn writePing(out: *std.Io.Writer, ack: bool, payload_bytes: *const [8]u8) std.Io.Writer.Error!void {
    var wire: [17]u8 = undefined;
    (frame.FrameHeader{
        .length = 8,
        .type = .ping,
        .flags = @intFromBool(ack),
        .stream_id = 0,
    }).encode(wire[0..9]) catch unreachable;
    @memcpy(wire[9..17], payload_bytes);
    try out.writeAll(&wire);
}

/// Writes RST_STREAM. Stream zero is rejected before any bytes are written.
pub fn writeReset(
    out: *std.Io.Writer,
    stream_id: u31,
    code: protocol.ErrorCode,
) (std.Io.Writer.Error || error{Protocol})!void {
    if (stream_id == 0) return error.Protocol;
    var wire: [13]u8 = undefined;
    (frame.FrameHeader{ .length = 4, .type = .rst_stream, .flags = 0, .stream_id = stream_id }).encode(wire[0..9]) catch unreachable;
    std.mem.writeInt(u32, wire[9..13], @intFromEnum(code), .big);
    try out.writeAll(&wire);
}

/// Writes a connection- or stream-level WINDOW_UPDATE. Zero credit is rejected
/// before any bytes are written.
pub fn writeWindowUpdate(
    out: *std.Io.Writer,
    stream_id: u31,
    increment: u31,
) (std.Io.Writer.Error || error{Protocol})!void {
    if (increment == 0) return error.Protocol;
    var wire: [13]u8 = undefined;
    (frame.FrameHeader{ .length = 4, .type = .window_update, .flags = 0, .stream_id = stream_id }).encode(wire[0..9]) catch unreachable;
    std.mem.writeInt(u32, wire[9..13], increment, .big);
    try out.writeAll(&wire);
}

/// Writes GOAWAY while respecting the peer's advertised maximum frame size.
/// Debug data stays caller-owned and is streamed after the fixed 17-byte prefix.
pub fn writeGoAway(
    out: *std.Io.Writer,
    peer_max_frame_size: u32,
    last_stream_id: u31,
    code: protocol.ErrorCode,
    debug_data: []const u8,
) (std.Io.Writer.Error || error{FrameTooLarge})!void {
    const payload_len = std.math.add(usize, debug_data.len, 8) catch return error.FrameTooLarge;
    if (payload_len > peer_max_frame_size or payload_len > frame.max_frame_size) return error.FrameTooLarge;

    var prefix: [17]u8 = undefined;
    try (frame.FrameHeader{
        .length = @intCast(payload_len),
        .type = .goaway,
        .flags = 0,
        .stream_id = 0,
    }).encode(prefix[0..9]);
    std.mem.writeInt(u32, prefix[9..13], last_stream_id, .big);
    std.mem.writeInt(u32, prefix[13..17], @intFromEnum(code), .big);
    try out.writeAll(&prefix);
    try out.writeAll(debug_data);
}

/// Streaming writer that turns one HPACK field block into HEADERS or
/// PUSH_PROMISE followed by zero or more CONTINUATION frames. The caller-owned
/// staging buffer bounds memory usage independently of the encoded block size.
///
/// One extra staging byte is required so a payload exactly equal to the chosen
/// frame size can remain buffered until `finish()` knows whether it is final.
/// For PUSH_PROMISE, the four-byte promised-stream prefix consumes space only in
/// the first frame; continuation frames can use the full staging/frame limit.
pub const HeaderFramer = struct {
    out: *std.Io.Writer,
    writer: std.Io.Writer,
    stream_id: u31,
    peer_max_frame_size: u32,
    staging_limit: usize,
    end_stream: bool,
    first_type: frame.Type = .headers,
    promised_stream_id: u31 = 0,
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
        return initCommon(out, staging, peer_max_frame_size, stream_id, end_stream, .headers, 0);
    }

    pub fn initPushPromise(
        out: *std.Io.Writer,
        staging: []u8,
        peer_max_frame_size: u32,
        associated_stream_id: u31,
        promised_stream_id: u31,
    ) error{BufferTooSmall}!HeaderFramer {
        if (peer_max_frame_size <= 4) return error.BufferTooSmall;
        return initCommon(out, staging, peer_max_frame_size, associated_stream_id, false, .push_promise, promised_stream_id);
    }

    fn initCommon(
        out: *std.Io.Writer,
        staging: []u8,
        peer_max_frame_size: u32,
        stream_id: u31,
        end_stream: bool,
        first_type: frame.Type,
        promised_stream_id: u31,
    ) error{BufferTooSmall}!HeaderFramer {
        if (staging.len < 2 or peer_max_frame_size == 0) return error.BufferTooSmall;
        const staging_limit = @min(@as(usize, peer_max_frame_size), staging.len - 1);
        if (staging_limit == 0) return error.BufferTooSmall;
        return .{
            .out = out,
            .writer = .{
                .buffer = staging[0 .. staging_limit + 1],
                .vtable = &.{ .drain = drain },
            },
            .stream_id = stream_id,
            .peer_max_frame_size = peer_max_frame_size,
            .staging_limit = staging_limit,
            .end_stream = end_stream,
            .first_type = first_type,
            .promised_stream_id = promised_stream_id,
        };
    }

    pub fn finish(self: *HeaderFramer) std.Io.Writer.Error!HeaderFrameStats {
        const limit = self.currentPayloadLimit();
        if (self.writer.end > limit) {
            try self.emit(self.writer.buffer[0..limit], false);
            const tail = self.writer.end - limit;
            @memmove(self.writer.buffer[0..tail], self.writer.buffer[limit..self.writer.end]);
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
            const limit = self.currentPayloadLimit();
            if (self.writer.end > limit) {
                try self.emit(self.writer.buffer[0..limit], false);
                const tail = self.writer.end - limit;
                @memmove(self.writer.buffer[0..tail], self.writer.buffer[limit..self.writer.end]);
                self.writer.end = tail;
            } else if (self.writer.end == limit) {
                // `bytes` proves there is more HPACK data, so this full payload
                // cannot be the final frame of the field block.
                try self.emit(self.writer.buffer[0..limit], false);
                self.writer.end = 0;
            }

            const n = @min(bytes.len, self.writer.buffer.len - self.writer.end);
            @memcpy(self.writer.buffer[self.writer.end..][0..n], bytes[0..n]);
            self.writer.end += n;
            bytes = bytes[n..];
        }
    }

    inline fn currentPayloadLimit(self: HeaderFramer) usize {
        if (self.first and self.first_type == .push_promise)
            return @min(self.staging_limit, @as(usize, self.peer_max_frame_size) - 4);
        return self.staging_limit;
    }

    fn emit(self: *HeaderFramer, field_block_fragment: []const u8, end_headers: bool) std.Io.Writer.Error!void {
        const first_push = self.first and self.first_type == .push_promise;
        const prefix_len: usize = if (first_push) 4 else 0;
        std.debug.assert(field_block_fragment.len + prefix_len <= self.peer_max_frame_size);

        var prefix: [13]u8 = undefined;
        const header: frame.FrameHeader = .{
            .length = @intCast(field_block_fragment.len + prefix_len),
            .type = if (self.first) self.first_type else .continuation,
            .flags = (if (self.first and self.first_type == .headers and self.end_stream) @as(u8, 0x01) else 0) |
                (if (end_headers) @as(u8, 0x04) else 0),
            .stream_id = self.stream_id,
        };
        header.encode(prefix[0..9]) catch unreachable;
        if (first_push) {
            std.mem.writeInt(u32, prefix[9..13], self.promised_stream_id, .big);
            try self.out.writeAll(&prefix);
        } else {
            try self.out.writeAll(prefix[0..9]);
        }
        try self.out.writeAll(field_block_fragment);
        self.first = false;
        self.frame_count +|= 1;
        self.encoded_bytes +|= field_block_fragment.len;
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

test "push promise framer accounts promised id only in first frame" {
    var out_storage: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_storage);
    var staging: [9]u8 = undefined; // up to eight HPACK bytes after the first frame
    var framer = try HeaderFramer.initPushPromise(&out, &staging, 8, 1, 2);
    try framer.writer.writeAll("abcdefghij");
    const stats = try framer.finish();
    try std.testing.expectEqual(@as(u32, 2), stats.frame_count);
    try std.testing.expectEqual(@as(usize, 10), stats.encoded_bytes);

    var it = frame.CompleteIterator.init(out.buffered(), frame.default_max_frame_size);
    const first = (try it.next()).?;
    try std.testing.expectEqual(frame.Type.push_promise, first.header.type);
    try std.testing.expectEqual(@as(u8, 0), first.header.flags);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, first.payload[0..4], .big));
    try std.testing.expectEqualStrings("abcd", first.payload[4..]);

    const continuation = (try it.next()).?;
    try std.testing.expectEqual(frame.Type.continuation, continuation.header.type);
    try std.testing.expectEqual(@as(u8, 0x04), continuation.header.flags);
    try std.testing.expectEqualStrings("efghij", continuation.payload);
    try std.testing.expect((try it.next()) == null);
}

test "push promise exact first-frame boundary keeps END_HEADERS" {
    var out_storage: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_storage);
    var staging: [9]u8 = undefined;
    var framer = try HeaderFramer.initPushPromise(&out, &staging, 8, 1, 2);
    try framer.writer.writeAll("abcd");
    const stats = try framer.finish();
    try std.testing.expectEqual(@as(u32, 1), stats.frame_count);

    const parsed = (try frame.parseComplete(out.buffered(), frame.default_max_frame_size)).?;
    try std.testing.expectEqual(frame.Type.push_promise, parsed.frame.header.type);
    try std.testing.expectEqual(@as(u8, 0x04), parsed.frame.header.flags);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, parsed.frame.payload[0..4], .big));
    try std.testing.expectEqualStrings("abcd", parsed.frame.payload[4..]);
}

test "control frame writers serialize fixed payloads" {
    var storage: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);

    const ping_data = "12345678".*;
    try writeSettingsAck(&out);
    try writePing(&out, true, &ping_data);
    try writeReset(&out, 3, .cancel);
    try writeWindowUpdate(&out, 3, 1024);
    try writeGoAway(&out, frame.default_max_frame_size, 3, .no_error, "bye");

    var it = frame.CompleteIterator.init(out.buffered(), frame.default_max_frame_size);
    const ack = (try it.next()).?;
    try std.testing.expectEqual(frame.Type.settings, ack.header.type);
    try std.testing.expectEqual(@as(u8, 0x01), ack.header.flags);
    try std.testing.expectEqual(@as(usize, 0), ack.payload.len);

    const ping = (try it.next()).?;
    try std.testing.expectEqual(frame.Type.ping, ping.header.type);
    try std.testing.expectEqual(@as(u8, 0x01), ping.header.flags);
    try std.testing.expectEqualStrings(&ping_data, ping.payload);

    const reset = (try it.next()).?;
    try std.testing.expectEqual(frame.Type.rst_stream, reset.header.type);
    try std.testing.expectEqual(@as(u32, @intFromEnum(protocol.ErrorCode.cancel)), std.mem.readInt(u32, reset.payload[0..4], .big));

    const update = (try it.next()).?;
    try std.testing.expectEqual(frame.Type.window_update, update.header.type);
    try std.testing.expectEqual(@as(u32, 1024), std.mem.readInt(u32, update.payload[0..4], .big));

    const goaway = (try it.next()).?;
    try std.testing.expectEqual(frame.Type.goaway, goaway.header.type);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, goaway.payload[0..4], .big));
    try std.testing.expectEqual(@as(u32, @intFromEnum(protocol.ErrorCode.no_error)), std.mem.readInt(u32, goaway.payload[4..8], .big));
    try std.testing.expectEqualStrings("bye", goaway.payload[8..]);
    try std.testing.expect((try it.next()) == null);
}

test "settings writer streams ordered values" {
    const values = [_]settings.Setting{
        .{ .id = .header_table_size, .value = 2048 },
        .{ .id = .max_concurrent_streams, .value = 100 },
        .{ .id = .initial_window_size, .value = 131_072 },
        .{ .id = .max_frame_size, .value = 32_768 },
        .{ .id = .max_header_list_size, .value = 65_536 },
        .{ .id = @enumFromInt(0x10), .value = 1 },
        .{ .id = @enumFromInt(0x11), .value = 2 },
        .{ .id = @enumFromInt(0x12), .value = 3 },
        .{ .id = @enumFromInt(0x13), .value = 4 },
    };
    var storage: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    try writeSettings(&out, &values, frame.default_max_frame_size);
    const parsed = (try frame.parseComplete(out.buffered(), frame.default_max_frame_size)).?;
    try std.testing.expectEqual(frame.Type.settings, parsed.frame.header.type);
    var it = try settings.Iterator.init(parsed.frame.payload);
    var i: usize = 0;
    while (it.next()) |value| : (i += 1) try std.testing.expectEqual(values[i], value);
    try std.testing.expectEqual(values.len, i);
}

test "control writers reject invalid sizes before writing" {
    var storage: [32]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.Protocol, writeReset(&out, 0, .cancel));
    try std.testing.expectError(error.Protocol, writeWindowUpdate(&out, 1, 0));
    try std.testing.expectError(error.FrameTooLarge, writeGoAway(&out, 8, 0, .no_error, "x"));
    try std.testing.expectEqual(@as(usize, 0), out.buffered().len);
}
