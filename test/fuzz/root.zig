const std = @import("std");
const http = @import("http");

const FlowWindow = http.http2.flow.FlowWindow;

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
const FrameHeader = http.http2.frame.FrameHeader;
const FrameDecoder = http.http2.frame.FrameDecoder;

fn fuzzHttp1RequestFragmentation(_: void, smith: *std.testing.Smith) !void {
    var input_buf: [512]u8 = undefined;
    const len: usize = smith.slice(&input_buf);
    const input = input_buf[0..len];

    const complete = http1.head.parseRequest(input) catch return;
    const expected = complete orelse return;
    if (expected.consumed > 512) return;

    var scratch: [512]u8 = undefined;
    var parser = http1.head.FramedHeadParser.init(.request, &scratch);
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

    const complete = http1.head.parseResponse(input, method) catch return;
    const expected = complete orelse return;

    var scratch: [512]u8 = undefined;
    var parser = http1.head.FramedHeadParser.init(.response, &scratch);
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

    const complete = (try http.http2.frame.parseComplete(input, http.http2.frame.default_max_frame_size)).?;
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
    var decoder = http1.body.ChunkDecoder.init(&line_storage);
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

const stream_mod = http.http2.stream;
const streams_mod = http.http2.streams;
const peer_mod = http.http2.peer;

const SequenceStore = struct {
    const Entry = struct {
        used: bool = false,
        id: u31 = 0,
        tracked: stream_mod.Tracked = undefined,
    };

    entries: [32]Entry = [_]Entry{.{}} ** 32,

    pub fn get(self: *SequenceStore, id: u31) ?*stream_mod.Tracked {
        for (&self.entries) |*entry| {
            if (entry.used and entry.id == id) return &entry.tracked;
        }
        return null;
    }

    pub fn insert(self: *SequenceStore, id: u31, tracked: stream_mod.Tracked) ?*stream_mod.Tracked {
        if (self.get(id) != null) return null;
        for (&self.entries) |*entry| {
            if (!entry.used) {
                entry.* = .{ .used = true, .id = id, .tracked = tracked };
                return &entry.tracked;
            }
        }
        return null;
    }

    pub fn maxActiveSendAdjustment(self: *SequenceStore) i32 {
        var result: i32 = 0;
        for (&self.entries) |*entry| {
            if (!entry.used or !activeState(entry.tracked.stream.state)) continue;
            result = @max(result, entry.tracked.windows.send.adjustment);
        }
        return result;
    }
};

fn activeState(state: stream_mod.State) bool {
    return state == .open or state == .half_closed_local or state == .half_closed_remote;
}

fn expectManagerCounters(manager: *const streams_mod.Manager, store: *const SequenceStore) !void {
    var local: u32 = 0;
    var remote: u32 = 0;
    for (&store.entries) |*entry| {
        if (!entry.used or !activeState(entry.tracked.stream.state)) continue;
        if (manager.localInitiated(entry.id)) local += 1 else remote += 1;
    }
    try std.testing.expectEqual(local, manager.activeLocal());
    try std.testing.expectEqual(remote, manager.activeRemote());
}

fn sequenceId(smith: *std.testing.Smith, role: peer_mod.Role, local: bool) u31 {
    const ordinal: u31 = @intCast(smith.valueRangeAtMost(u8, 0, 15));
    const client_initiated = if (role == .client) local else !local;
    return ordinal * 2 + (if (client_initiated) @as(u31, 1) else @as(u31, 2));
}

fn fuzzStreamManagerSequences(_: void, smith: *std.testing.Smith) !void {
    const role: peer_mod.Role = if (smith.value(bool)) .client else .server;
    var manager = streams_mod.Manager.init(role, .{ .max_concurrent_streams = 16 });
    var peer = peer_mod.State.init(role);
    peer.settings.max_concurrent_streams = 16;
    var store: SequenceStore = .{};

    var step: u8 = 0;
    while (step < 128 and !smith.eosWeightedSimple(20, 1)) : (step += 1) {
        const local_id = sequenceId(smith, role, true);
        const remote_id = sequenceId(smith, role, false);
        const amount: u32 = smith.valueRangeAtMost(u16, 0, 2048);
        const increment: u31 = @intCast(smith.valueRangeAtMost(u16, 0, 4096));
        const end_stream = smith.value(bool);

        switch (smith.valueRangeAtMost(u4, 0, 11)) {
            0 => {
                if (role == .client) manager.openLocal(&store, &peer, local_id, end_stream) catch {};
            },
            1 => {
                if (role == .server) _ = manager.receiveHeaders(&store, remote_id, end_stream);
            },
            2 => manager.localHeaders(&store, &peer, local_id, end_stream) catch {},
            3 => _ = manager.receiveHeaders(&store, local_id, end_stream),
            4 => manager.localData(&store, &peer, local_id, amount, end_stream) catch {},
            5 => _ = manager.receiveData(&store, local_id, amount, end_stream),
            6 => manager.localReset(&store, local_id) catch {},
            7 => _ = manager.receiveReset(&store, local_id),
            8 => _ = manager.receiveWindowUpdate(&store, &peer, local_id, increment),
            9 => {
                if (increment != 0) {
                    if (manager.existing(&store, local_id)) |existing| existing.creditReceive(increment) catch {};
                }
            },
            10 => {
                if (role == .server) {
                    manager.reserveLocal(&store, &peer, remote_id, local_id) catch {};
                } else {
                    _ = manager.receivePushPromise(&store, local_id, remote_id);
                }
            },
            else => {
                if (role == .server) {
                    _ = manager.receiveData(&store, remote_id, amount, end_stream);
                } else {
                    _ = manager.receiveReset(&store, remote_id);
                }
            },
        }
        try expectManagerCounters(&manager, &store);
    }
}

test "fuzz HTTP/2 stream-manager state sequences preserve aggregate invariants" {
    try std.testing.fuzz({}, fuzzStreamManagerSequences, .{
        .corpus = &.{
            "",
            "\x00\x01\x02\x03\x04\x05\x06\x07",
            "\xff\xff\xff\xff\xff\xff\xff\xff",
            "stream-state-sequence",
        },
    });
}

const SessionSink = struct {
    fields: u32 = 0,

    pub fn field(self: *SessionSink, _: u31, _: http.http2.fields.Kind, _: http.common.Header) void {
        self.fields += 1;
    }
};

fn expectStoresEqual(a: *const SequenceStore, b: *const SequenceStore) !void {
    for (a.entries, b.entries) |left, right| {
        try std.testing.expectEqual(left.used, right.used);
        if (!left.used) continue;
        try std.testing.expectEqual(left.id, right.id);
        try std.testing.expectEqualDeep(left.tracked, right.tracked);
    }
}

fn expectSessionsEquivalent(
    a: *const http.http2.Session,
    a_store: *const SequenceStore,
    a_sink: *const SessionSink,
    b: *const http.http2.Session,
    b_store: *const SequenceStore,
    b_sink: *const SessionSink,
) !void {
    try std.testing.expectEqual(a.connection.receive_window.value, b.connection.receive_window.value);
    try std.testing.expectEqual(a.connection.continuation_guard.stream_id, b.connection.continuation_guard.stream_id);
    try std.testing.expectEqual(a.streams.activeLocal(), b.streams.activeLocal());
    try std.testing.expectEqual(a.streams.activeRemote(), b.streams.activeRemote());
    try std.testing.expectEqualDeep(a.peer.settings, b.peer.settings);
    try std.testing.expectEqual(a.peer.send_window.value, b.peer.send_window.value);
    try std.testing.expectEqual(a_sink.fields, b_sink.fields);
    try expectStoresEqual(a_store, b_store);
}

const FragmentedSession = struct {
    decoder: http.http2.frame.FrameDecoder = http.http2.frame.FrameDecoder.init(http.http2.frame.default_max_frame_size),
    header: ?http.http2.frame.FrameHeader = null,
    payload: [64]u8 = undefined,
    payload_len: usize = 0,

    fn receive(
        self: *FragmentedSession,
        smith: *std.testing.Smith,
        session: *http.http2.Session,
        store: *SequenceStore,
        wire: []const u8,
        scratch: []u8,
        sink: *SessionSink,
    ) !http.http2.Event {
        var pos: usize = 0;
        while (pos < wire.len) {
            const remaining = wire.len - pos;
            const max_piece = @min(remaining, @as(usize, 7));
            const piece_len: usize = @max(@as(usize, 1), @as(usize, smith.valueRangeAtMost(u8, 1, @intCast(max_piece))));
            const result = try self.decoder.next(wire[pos .. pos + piece_len]);
            if (result.consumed == 0) return error.FragmentationDidNotAdvance;
            pos += result.consumed;
            if (result.event) |decoder_event| switch (decoder_event) {
                .header => |header| {
                    if (self.header != null) return error.OverlappingFrames;
                    if (session.connection.check(header) != .none) return error.UnexpectedConnectionViolation;
                    self.header = header;
                    self.payload_len = 0;
                    if (header.length == 0) {
                        const complete: http.http2.frame.CompleteFrame = .{ .header = header, .payload = &.{} };
                        self.header = null;
                        return session.receiveCompleteAssumeConnectionChecked(store, complete, scratch, sink);
                    }
                },
                .payload => |part| {
                    if (part.bytes.len > self.payload.len - self.payload_len) return error.PayloadTooLarge;
                    @memcpy(self.payload[self.payload_len .. self.payload_len + part.bytes.len], part.bytes);
                    self.payload_len += part.bytes.len;
                    if (part.end_frame) {
                        const header = self.header orelse return error.PayloadWithoutHeader;
                        const complete: http.http2.frame.CompleteFrame = .{
                            .header = header,
                            .payload = self.payload[0..self.payload_len],
                        };
                        self.header = null;
                        return session.receiveCompleteAssumeConnectionChecked(store, complete, scratch, sink);
                    }
                },
            };
        }
        return error.IncompleteGeneratedFrame;
    }
};

fn encodeFuzzFrame(out: []u8, header: http.http2.frame.FrameHeader, payload: []const u8) ![]const u8 {
    if (payload.len != header.length or out.len < 9 + payload.len) return error.InvalidGeneratedFrame;
    var encoded: [9]u8 = undefined;
    try header.encode(&encoded);
    @memcpy(out[0..9], &encoded);
    @memcpy(out[9 .. 9 + payload.len], payload);
    return out[0 .. 9 + payload.len];
}

fn compareSessionFrame(
    smith: *std.testing.Smith,
    direct: *http.http2.Session,
    direct_store: *SequenceStore,
    direct_sink: *SessionSink,
    direct_scratch: []u8,
    fragmented: *http.http2.Session,
    fragmented_store: *SequenceStore,
    fragmented_sink: *SessionSink,
    fragmented_scratch: []u8,
    fragmented_transport: *FragmentedSession,
    wire_storage: []u8,
    header: http.http2.frame.FrameHeader,
    payload_bytes: []const u8,
) !void {
    try header.validate(http.http2.frame.default_max_frame_size);
    const wire = try encodeFuzzFrame(wire_storage, header, payload_bytes);
    const direct_event = try direct.receiveComplete(
        direct_store,
        .{ .header = header, .payload = payload_bytes },
        direct_scratch,
        direct_sink,
    );
    const fragmented_event = try fragmented_transport.receive(
        smith,
        fragmented,
        fragmented_store,
        wire,
        fragmented_scratch,
        fragmented_sink,
    );
    try std.testing.expectEqualDeep(direct_event, fragmented_event);
    try expectSessionsEquivalent(
        direct,
        direct_store,
        direct_sink,
        fragmented,
        fragmented_store,
        fragmented_sink,
    );
}

fn fuzzSessionFragmentation(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    var direct_decoder = http.http2.hpack.Decoder.init(allocator, 4096);
    defer direct_decoder.deinit();
    var direct_encoder = http.http2.hpack.Encoder.init(allocator, 4096);
    defer direct_encoder.deinit();
    var fragmented_decoder = http.http2.hpack.Decoder.init(allocator, 4096);
    defer fragmented_decoder.deinit();
    var fragmented_encoder = http.http2.hpack.Encoder.init(allocator, 4096);
    defer fragmented_encoder.deinit();

    var direct_headers: [256]u8 = undefined;
    var fragmented_headers: [256]u8 = undefined;
    var direct = http.http2.Session.init(.{
        .role = .server,
        .decoder = &direct_decoder,
        .encoder = &direct_encoder,
        .header_storage = &direct_headers,
    });
    var fragmented = http.http2.Session.init(.{
        .role = .server,
        .decoder = &fragmented_decoder,
        .encoder = &fragmented_encoder,
        .header_storage = &fragmented_headers,
    });
    var direct_store: SequenceStore = .{};
    var fragmented_store: SequenceStore = .{};
    var direct_sink: SessionSink = .{};
    var fragmented_sink: SessionSink = .{};
    var fragmented_transport: FragmentedSession = .{};
    var direct_scratch: [256]u8 = undefined;
    var fragmented_scratch: [256]u8 = undefined;
    var wire_storage: [96]u8 = undefined;
    var payload_storage: [64]u8 = undefined;
    var next_stream_id: u31 = 1;
    var current_stream_id: u31 = 0;

    // Static-table-only HPACK request: :method GET, :scheme https, :path /.
    const request_block = [_]u8{ 0x82, 0x87, 0x84 };

    var step: u8 = 0;
    while (step < 64 and !smith.eosWeightedSimple(18, 1)) : (step += 1) {
        var header: http.http2.frame.FrameHeader = undefined;
        var payload_bytes: []const u8 = &.{};
        const operation = smith.valueRangeAtMost(u4, 0, 10);

        if (operation == 9) {
            if (next_stream_id > 63) continue;
            current_stream_id = next_stream_id;
            next_stream_id += 2;
            const first: http.http2.frame.FrameHeader = .{
                .length = 1,
                .type = .headers,
                .flags = @intFromBool(smith.value(bool)),
                .stream_id = current_stream_id,
            };
            try compareSessionFrame(
                smith,
                &direct,
                &direct_store,
                &direct_sink,
                &direct_scratch,
                &fragmented,
                &fragmented_store,
                &fragmented_sink,
                &fragmented_scratch,
                &fragmented_transport,
                &wire_storage,
                first,
                request_block[0..1],
            );
            const continuation_header: http.http2.frame.FrameHeader = .{
                .length = request_block.len - 1,
                .type = .continuation,
                .flags = 0x04,
                .stream_id = current_stream_id,
            };
            try compareSessionFrame(
                smith,
                &direct,
                &direct_store,
                &direct_sink,
                &direct_scratch,
                &fragmented,
                &fragmented_store,
                &fragmented_sink,
                &fragmented_scratch,
                &fragmented_transport,
                &wire_storage,
                continuation_header,
                request_block[1..],
            );
            continue;
        }

        if (operation == 10) {
            std.mem.writeInt(u32, payload_storage[0..4], 0, .big);
            std.mem.writeInt(u32, payload_storage[4..8], @intFromEnum(http.http2.protocol.ErrorCode.no_error), .big);
            header = .{ .length = 8, .type = .goaway, .flags = 0, .stream_id = 0 };
            payload_bytes = payload_storage[0..8];
        } else {
            switch (operation) {
                0, 1 => {
                    if (next_stream_id > 63) continue;
                    current_stream_id = next_stream_id;
                    next_stream_id += 2;
                    header = .{
                        .length = request_block.len,
                        .type = .headers,
                        .flags = 0x04 | @as(u8, @intFromBool(smith.value(bool))),
                        .stream_id = current_stream_id,
                    };
                    payload_bytes = &request_block;
                },
                2 => {
                    if (current_stream_id == 0) continue;
                    const len: usize = smith.valueRangeAtMost(u8, 0, 16);
                    smith.bytes(payload_storage[0..len]);
                    header = .{
                        .length = @intCast(len),
                        .type = .data,
                        .flags = @intFromBool(smith.value(bool)),
                        .stream_id = current_stream_id,
                    };
                    payload_bytes = payload_storage[0..len];
                },
                3 => {
                    const setting_choice = smith.valueRangeAtMost(u3, 0, 4);
                    const setting_id: u16 = switch (setting_choice) {
                        0 => 0x3, // MAX_CONCURRENT_STREAMS
                        1 => 0x4, // INITIAL_WINDOW_SIZE
                        2 => 0x5, // MAX_FRAME_SIZE
                        3 => 0x8, // ENABLE_CONNECT_PROTOCOL
                        else => 0xf0, // unknown extension setting
                    };
                    const setting_value: u32 = switch (setting_choice) {
                        0 => smith.valueRangeAtMost(u16, 0, 64),
                        1 => smith.valueRangeAtMost(u16, 0, 65_535),
                        2 => http.http2.frame.default_max_frame_size + smith.valueRangeAtMost(u16, 0, 4096),
                        3 => @intFromBool(smith.value(bool)),
                        else => smith.value(u32),
                    };
                    std.mem.writeInt(u16, payload_storage[0..2], setting_id, .big);
                    std.mem.writeInt(u32, payload_storage[2..6], setting_value, .big);
                    header = .{ .length = 6, .type = .settings, .flags = 0, .stream_id = 0 };
                    payload_bytes = payload_storage[0..6];
                },
                4 => {
                    smith.bytes(payload_storage[0..8]);
                    header = .{ .length = 8, .type = .ping, .flags = smith.value(u8) & 0x01, .stream_id = 0 };
                    payload_bytes = payload_storage[0..8];
                },
                5 => {
                    const stream_id: u31 = if (smith.value(bool) and current_stream_id != 0) current_stream_id else 0;
                    const increment: u31 = @intCast(smith.valueRangeAtMost(u16, 1, 4096));
                    std.mem.writeInt(u32, payload_storage[0..4], increment, .big);
                    header = .{ .length = 4, .type = .window_update, .flags = 0, .stream_id = stream_id };
                    payload_bytes = payload_storage[0..4];
                },
                6 => {
                    if (current_stream_id == 0) continue;
                    @memset(payload_storage[0..5], 0);
                    header = .{ .length = 5, .type = .priority, .flags = 0, .stream_id = current_stream_id };
                    payload_bytes = payload_storage[0..5];
                },
                7 => {
                    if (current_stream_id == 0) continue;
                    std.mem.writeInt(u32, payload_storage[0..4], @intFromEnum(http.http2.protocol.ErrorCode.cancel), .big);
                    header = .{ .length = 4, .type = .rst_stream, .flags = 0, .stream_id = current_stream_id };
                    payload_bytes = payload_storage[0..4];
                },
                else => {
                    const len: usize = smith.valueRangeAtMost(u8, 0, 16);
                    smith.bytes(payload_storage[0..len]);
                    header = .{
                        .length = @intCast(len),
                        .type = @enumFromInt(@as(u8, 0xf0)),
                        .flags = smith.value(u8),
                        .stream_id = if (smith.value(bool)) current_stream_id else 0,
                    };
                    payload_bytes = payload_storage[0..len];
                },
            }
        }

        try compareSessionFrame(
            smith,
            &direct,
            &direct_store,
            &direct_sink,
            &direct_scratch,
            &fragmented,
            &fragmented_store,
            &fragmented_sink,
            &fragmented_scratch,
            &fragmented_transport,
            &wire_storage,
            header,
            payload_bytes,
        );
    }
}

test "fuzz HTTP/2 Session is transport-fragmentation invariant" {
    try std.testing.fuzz({}, fuzzSessionFragmentation, .{
        .corpus = &.{
            "",
            "session-fragmentation",
            "\x00\x01\x02\x03\x04\x05\x06\x07",
            "\xff\xff\xff\xff\xff\xff\xff\xff",
        },
    });
}
