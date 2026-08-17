const std = @import("std");
const http = @import("http");

const FlowWindow = http.http2.FlowWindow;

const Model = struct {
    value: i64 = 65_535,

    fn consume(self: *Model, amount: u32) bool {
        const next = self.value - @as(i64, amount);
        if (next < 0) return false;
        self.value = next;
        return true;
    }

    fn update(self: *Model, increment: u31) bool {
        if (increment == 0) return false;
        const next = self.value + @as(i64, increment);
        if (next > 0x7fff_ffff) return false;
        self.value = next;
        return true;
    }

    fn initialDelta(self: *Model, old: u31, new: u31) bool {
        const next = self.value + @as(i64, new) - @as(i64, old);
        if (next > 0x7fff_ffff or next < -0x7fff_ffff) return false;
        self.value = next;
        return true;
    }
};

fn resultOk(result: error{FlowControl}!void) bool {
    result catch return false;
    return true;
}

fn expectState(sut: FlowWindow, model: Model) !void {
    try std.testing.expectEqual(@as(i32, @intCast(model.value)), sut.value);
    const expected: u31 = if (model.value <= 0) 0 else @intCast(model.value);
    try std.testing.expectEqual(expected, sut.available());
}

fn fuzzFlowWindow(_: void, smith: *std.testing.Smith) !void {
    var sut: FlowWindow = .{};
    var model: Model = .{};

    var n: u8 = 0;
    while (n < 64 and !smith.eosWeightedSimple(15, 1)) : (n += 1) {
        switch (smith.valueRangeAtMost(u2, 0, 2)) {
            0 => {
                const amount = smith.value(u32);
                const before = sut.value;
                const expected = model.consume(amount);
                const actual = resultOk(sut.consume(amount));
                try std.testing.expectEqual(expected, actual);
                if (!actual) try std.testing.expectEqual(before, sut.value);
            },
            1 => {
                const increment: u31 = @intCast(smith.valueRangeAtMost(u32, 0, 0x7fff_ffff));
                const before = sut.value;
                const expected = model.update(increment);
                const actual = resultOk(sut.update(increment));
                try std.testing.expectEqual(expected, actual);
                if (!actual) try std.testing.expectEqual(before, sut.value);
            },
            else => {
                const old: u31 = @intCast(smith.valueRangeAtMost(u32, 0, 0x7fff_ffff));
                const new: u31 = @intCast(smith.valueRangeAtMost(u32, 0, 0x7fff_ffff));
                const before = sut.value;
                const expected = model.initialDelta(old, new);
                const actual = resultOk(sut.applyInitialDelta(old, new));
                try std.testing.expectEqual(expected, actual);
                if (!actual) try std.testing.expectEqual(before, sut.value);
            },
        }
        try expectState(sut, model);
    }
}

test "fuzz flow window against signed reference model" {
    try std.testing.fuzz({}, fuzzFlowWindow, .{
        .corpus = &.{
            "",
            "\x00\x00\x00\x00\x00\x00\x00\x00",
            "\xff\xff\xff\xff\xff\xff\xff\xff",
        },
    });
}

const http1 = http.http1;
const FrameHeader = http.http2.FrameHeader;
const FrameDecoder = http.http2.FrameDecoder;

fn fuzzHttp1RequestFragmentation(_: void, smith: *std.testing.Smith) !void {
    var input_buf: [512]u8 = undefined;
    const len: usize = smith.slice(&input_buf);
    const input = input_buf[0..len];

    const complete = http1.parseRequest(input) catch return;
    const expected = complete orelse return;
    if (expected.consumed > 512) return;

    var scratch: [512]u8 = undefined;
    var parser = http1.FramedHeadParser.init(.request, &scratch);
    var pos: usize = 0;
    var actual: ?http1.head.FramedHead = null;
    while (pos < expected.consumed) {
        const result = parser.feedRequest(input[pos .. pos + 1]) catch |err| {
            std.debug.panic("contiguous HTTP/1 request parsed but fragmented parser failed: {s}", .{@errorName(err)});
        };
        if (result.consumed != 1) return error.FragmentationDidNotAdvance;
        pos += 1;
        if (result.framed) |framed| actual = framed;
    }
    const framed = actual orelse return error.FragmentationLostCompletedHead;
    try std.testing.expectEqual(expected.framing, framed.framing);
    try std.testing.expectEqual(expected.head.version, framed.head.version);
    try std.testing.expectEqualStrings(expected.head.start.request.method, framed.head.start.request.method);
    try std.testing.expectEqualStrings(expected.head.start.request.target, framed.head.start.request.target);
}

test "fuzz HTTP/1 contiguous and fragmented request parsing agree" {
    try std.testing.fuzz({}, fuzzHttp1RequestFragmentation, .{
        .corpus = &.{
            "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
            "POST /upload HTTP/1.1\r\nHost: example.com\r\nContent-Length: 7\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n",
            "OPTIONS * HTTP/1.1\r\nHost: example.com\r\n\r\n",
        },
    });
}

fn fuzzHttp1ResponseFragmentation(_: void, smith: *std.testing.Smith) !void {
    var input_buf: [512]u8 = undefined;
    const len: usize = smith.slice(&input_buf);
    const input = input_buf[0..len];
    const methods = [_][]const u8{ "GET", "HEAD", "CONNECT" };
    const method = methods[smith.valueRangeAtMost(u2, 0, methods.len - 1)];

    const complete = http1.parseResponse(input, method) catch return;
    const expected = complete orelse return;

    var scratch: [512]u8 = undefined;
    var parser = http1.FramedHeadParser.init(.response, &scratch);
    var pos: usize = 0;
    var actual: ?http1.head.FramedHead = null;
    while (pos < expected.consumed) {
        const result = parser.feedResponse(input[pos .. pos + 1], method) catch |err| {
            std.debug.panic("contiguous HTTP/1 response parsed but fragmented parser failed: {s}", .{@errorName(err)});
        };
        if (result.consumed != 1) return error.FragmentationDidNotAdvance;
        pos += 1;
        if (result.framed) |framed| actual = framed;
    }
    const framed = actual orelse return error.FragmentationLostCompletedHead;
    try std.testing.expectEqual(expected.framing, framed.framing);
    try std.testing.expectEqual(expected.head.version, framed.head.version);
    try std.testing.expectEqual(expected.head.start.response.status, framed.head.start.response.status);
}

test "fuzz HTTP/1 contiguous and fragmented response parsing agree" {
    try std.testing.fuzz({}, fuzzHttp1ResponseFragmentation, .{
        .corpus = &.{
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n",
            "HTTP/1.1 204 No Content\r\nContent-Length: 99\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            "HTTP/1.1 103 Early Hints\r\nLink: </x>\r\n\r\n",
        },
    });
}

fn fuzzHttp2FrameFragmentation(_: void, smith: *std.testing.Smith) !void {
    var payload: [128]u8 = undefined;
    const payload_len: usize = smith.valueRangeAtMost(u8, 0, payload.len);
    smith.bytes(payload[0..payload_len]);

    const type_choice = smith.valueRangeAtMost(u3, 0, 4);
    var header: FrameHeader = switch (type_choice) {
        0 => .{ .length = @intCast(payload_len), .type = .data, .flags = smith.value(u8), .stream_id = 1 },
        1 => .{ .length = 8, .type = .ping, .flags = smith.value(u8), .stream_id = 0 },
        2 => .{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 },
        3 => .{ .length = 5, .type = .priority, .flags = smith.value(u8), .stream_id = 1 },
        else => .{ .length = @intCast(payload_len), .type = @enumFromInt(@as(u8, 0xf0)), .flags = smith.value(u8), .stream_id = @intCast(smith.valueRangeAtMost(u32, 0, 0x7fff_ffff)) },
    };
    const actual_payload_len: usize = @intCast(header.length);
    if (actual_payload_len > payload.len) unreachable;
    if (header.type == .ping and payload_len < 8) smith.bytes(payload[0..8]);
    if (header.type == .priority and payload_len < 5) smith.bytes(payload[0..5]);

    var wire: [9 + payload.len]u8 = undefined;
    try header.encode(wire[0..9]);
    @memcpy(wire[9 .. 9 + actual_payload_len], payload[0..actual_payload_len]);
    const input = wire[0 .. 9 + actual_payload_len];

    const complete = (try http.http2.parseCompleteFrame(input, http.http2.frame.default_max_frame_size)).?;
    try std.testing.expectEqual(header, complete.frame.header);

    var decoder = FrameDecoder.init(http.http2.frame.default_max_frame_size);
    var pos: usize = 0;
    var saw_header = false;
    var payload_used: usize = 0;
    var decoded_payload: [128]u8 = undefined;
    while (pos < input.len) {
        const max_chunk = @min(input.len - pos, @as(usize, 7));
        const chunk_len = @max(@as(usize, 1), @as(usize, smith.valueRangeAtMost(u8, 1, @intCast(max_chunk))));
        const result = try decoder.next(input[pos .. pos + chunk_len]);
        if (result.consumed == 0) return error.FragmentationDidNotAdvance;
        pos += result.consumed;
        if (result.event) |event| switch (event) {
            .header => |decoded| {
                try std.testing.expect(!saw_header);
                try std.testing.expectEqual(header, decoded);
                saw_header = true;
            },
            .payload => |part| {
                @memcpy(decoded_payload[payload_used .. payload_used + part.bytes.len], part.bytes);
                payload_used += part.bytes.len;
            },
        };
    }
    try std.testing.expect(saw_header);
    try std.testing.expectEqualStrings(payload[0..actual_payload_len], decoded_payload[0..payload_used]);
}

test "fuzz HTTP/2 complete and fragmented frame decoding agree" {
    try std.testing.fuzz({}, fuzzHttp2FrameFragmentation, .{
        .corpus = &.{
            "",
            "\x00",
            "HTTP/2",
        },
    });
}

const ChunkOutcome = struct {
    body: [128]u8 = undefined,
    body_len: usize = 0,
    trailers: u8 = 0,
    done: bool = false,
};

fn decodeChunkedForFuzz(input: []const u8, one_byte: bool) !ChunkOutcome {
    var line_storage: [256]u8 = undefined;
    var decoder = http1.ChunkDecoder.init(&line_storage);
    var outcome: ChunkOutcome = .{};
    var pos: usize = 0;
    var spins: usize = 0;
    while (!outcome.done and spins < input.len * 4 + 16) : (spins += 1) {
        const available = input[pos..];
        const piece = if (one_byte and available.len > 1) available[0..1] else available;
        const result = try decoder.feed(piece);
        pos += result.consumed;
        if (result.event) |event| switch (event) {
            .data => |bytes| {
                if (bytes.len > outcome.body.len - outcome.body_len) return error.BodyTooLarge;
                @memcpy(outcome.body[outcome.body_len .. outcome.body_len + bytes.len], bytes);
                outcome.body_len += bytes.len;
            },
            .trailer => outcome.trailers += 1,
            .trailers_done => outcome.done = true,
            .done => outcome.done = true,
        };
        if (pos == input.len and result.event == null) break;
        if (result.consumed == 0 and result.event == null and piece.len != 0) return error.DecoderDidNotAdvance;
    }
    return outcome;
}

fn fuzzChunkedFragmentation(_: void, smith: *std.testing.Smith) !void {
    var data: [96]u8 = undefined;
    const data_len: usize = smith.valueRangeAtMost(u8, 1, data.len);
    smith.bytes(data[0..data_len]);

    var wire: [512]u8 = undefined;
    var used: usize = 0;
    const prefix = try std.fmt.bufPrint(wire[used..], "{x} ; fuzz = \"a,b\"\r\n", .{data_len});
    used += prefix.len;
    @memcpy(wire[used .. used + data_len], data[0..data_len]);
    used += data_len;
    const suffix = "\r\n0 ; end\r\nX-Fuzz: ok\r\n\r\n";
    @memcpy(wire[used .. used + suffix.len], suffix);
    used += suffix.len;

    const contiguous = try decodeChunkedForFuzz(wire[0..used], false);
    const fragmented = try decodeChunkedForFuzz(wire[0..used], true);
    try std.testing.expect(contiguous.done and fragmented.done);
    try std.testing.expectEqual(contiguous.trailers, fragmented.trailers);
    try std.testing.expectEqualStrings(contiguous.body[0..contiguous.body_len], fragmented.body[0..fragmented.body_len]);
    try std.testing.expectEqualStrings(data[0..data_len], fragmented.body[0..fragmented.body_len]);
}

test "fuzz HTTP/1 chunked decoding across fragmentation" {
    try std.testing.fuzz({}, fuzzChunkedFragmentation, .{
        .corpus = &.{ "", "chunked", "\xff\x00\x7f" },
    });
}
