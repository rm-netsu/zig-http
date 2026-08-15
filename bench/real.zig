const std = @import("std");
const http = @import("http");
const hpack = @import("hpack");
const corpus = @import("real_corpus.zig");

const Io = std.Io;
const ns_per_s: u64 = 1_000_000_000;
const max_head_bytes = 8192;
const max_h2_wire_bytes = 1024 * 1024;
const max_hpack_block_bytes = 16 * 1024;
const max_chunk_wire_bytes = 128 * 1024;
const data_frame_size = 16 * 1024;

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn exchangeCount() comptime_int {
    var n: usize = 0;
    for (corpus.scenarios) |scenario| n += scenario.exchanges.len;
    return n;
}

const exchange_count = exchangeCount();

const HeadFixture = struct {
    request: [max_head_bytes]u8 = undefined,
    request_len: u16 = 0,
    response: [max_head_bytes]u8 = undefined,
    response_len: u16 = 0,
    request_method: []const u8 = "GET",
    request_fields: []const corpus.Field = &.{},
    response_fields: []const corpus.Field = &.{},
    response_body_len: u64 = 0,
};

const ChunkFixture = struct {
    wire: [max_chunk_wire_bytes]u8 = undefined,
    len: u32 = 0,
    payload_len: u32 = 0,
};

const Fixtures = struct {
    heads: [exchange_count]HeadFixture = undefined,
    head_count: usize = 0,
    chunks: [exchange_count]ChunkFixture = undefined,
    chunk_count: usize = 0,
    h2_wire: [max_h2_wire_bytes]u8 = undefined,
    h2_len: usize = 0,
    h2_frames: u64 = 0,
    h2_payload_bytes: u64 = 0,
};

fn fieldValue(fields: []const corpus.Field, name: []const u8) ?[]const u8 {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn statusReason(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "200")) return "OK";
    if (std.mem.eql(u8, status, "204")) return "No Content";
    if (std.mem.eql(u8, status, "206")) return "Partial Content";
    if (std.mem.eql(u8, status, "301")) return "Moved Permanently";
    if (std.mem.eql(u8, status, "302")) return "Found";
    if (std.mem.eql(u8, status, "304")) return "Not Modified";
    if (std.mem.eql(u8, status, "404")) return "Not Found";
    return "Status";
}

fn writeHttp1Request(storage: []u8, fields: []const corpus.Field) !usize {
    const method = fieldValue(fields, ":method") orelse return error.MissingPseudoHeader;
    const path = fieldValue(fields, ":path") orelse return error.MissingPseudoHeader;
    const authority = fieldValue(fields, ":authority") orelse return error.MissingPseudoHeader;
    var writer = Io.Writer.fixed(storage);
    try writer.print("{s} {s} HTTP/1.1\r\n", .{ method, path });
    try writer.print("host: {s}\r\n", .{authority});
    for (fields) |field| {
        if (field.name.len != 0 and field.name[0] == ':') continue;
        // HTTP/2 captures may contain fields that are legal in HTTP/1 as-is.
        try writer.print("{s}: {s}\r\n", .{ field.name, field.value });
    }
    try writer.writeAll("\r\n");
    return writer.buffered().len;
}

fn writeHttp1Response(storage: []u8, fields: []const corpus.Field) !usize {
    const status = fieldValue(fields, ":status") orelse return error.MissingPseudoHeader;
    var writer = Io.Writer.fixed(storage);
    try writer.print("HTTP/1.1 {s} {s}\r\n", .{ status, statusReason(status) });
    for (fields) |field| {
        if (field.name.len != 0 and field.name[0] == ':') continue;
        try writer.print("{s}: {s}\r\n", .{ field.name, field.value });
    }
    try writer.writeAll("\r\n");
    return writer.buffered().len;
}

fn parseDecimal(value: []const u8) !u64 {
    var n: u64 = 0;
    for (value) |c| {
        if (c < '0' or c > '9') return error.InvalidNumber;
        n = try std.math.mul(u64, n, 10);
        n = try std.math.add(u64, n, c - '0');
    }
    return n;
}

fn responseBodyLength(exchange: corpus.Exchange) !u64 {
    const method = fieldValue(exchange.request, ":method") orelse "GET";
    if (std.mem.eql(u8, method, "HEAD")) return 0;
    const status = fieldValue(exchange.response, ":status") orelse "200";
    if (std.mem.eql(u8, status, "204") or std.mem.eql(u8, status, "304")) return 0;
    const value = fieldValue(exchange.response, "content-length") orelse return 0;
    return parseDecimal(value);
}

fn buildChunkFixture(fixture: *ChunkFixture, payload_len: u64, seed: u8) !void {
    // Chunked transfer is modeled using captured body lengths. Payload content is
    // deterministic because the HTTP parser only observes framing and slices.
    const target = @min(payload_len, 64 * 1024);
    if (target == 0) return;
    var writer = Io.Writer.fixed(&fixture.wire);
    var remaining: usize = @intCast(target);
    var ordinal: usize = 0;
    const sizes = [_]usize{ 731, 4096, 16384, 2048, 8192 };
    var payload: [data_frame_size]u8 = undefined;
    while (remaining != 0) : (ordinal += 1) {
        const n = @min(remaining, sizes[ordinal % sizes.len]);
        try writer.print("{x}\r\n", .{n});
        for (payload[0..n], 0..) |*byte, i| byte.* = seed +% @as(u8, @truncate(i + ordinal));
        try writer.writeAll(payload[0..n]);
        try writer.writeAll("\r\n");
        remaining -= n;
    }
    try writer.writeAll("0\r\nx-corpus-end: 1\r\n\r\n");
    fixture.len = @intCast(writer.buffered().len);
    fixture.payload_len = @intCast(target);
}

fn indexingFor(name: []const u8) hpack.Indexing {
    if (std.mem.eql(u8, name, "cookie") or std.mem.eql(u8, name, "set-cookie") or
        std.mem.eql(u8, name, "authorization") or std.mem.eql(u8, name, "proxy-authorization")) return .never;
    if (std.mem.eql(u8, name, ":path") or std.mem.eql(u8, name, "date") or
        std.mem.eql(u8, name, "content-length") or std.mem.eql(u8, name, "content-range") or
        std.mem.eql(u8, name, "range") or std.mem.eql(u8, name, "etag") or
        std.mem.eql(u8, name, "last-modified") or std.mem.eql(u8, name, "age") or
        std.mem.eql(u8, name, "cf-ray") or std.mem.eql(u8, name, "x-cache-hits") or
        std.mem.eql(u8, name, "x-timer") or std.mem.eql(u8, name, "x-response-time") or
        std.mem.eql(u8, name, "x-connection-hash") or std.mem.eql(u8, name, "x-amz-request-id")) return .without;
    return .incremental;
}

fn encodeHpack(encoder: *hpack.Encoder, fields: []const corpus.Field, storage: []u8) ![]const u8 {
    var writer = Io.Writer.fixed(storage);
    for (fields) |field| try encoder.field(&writer, .{ .name = field.name, .value = field.value }, indexingFor(field.name));
    return writer.buffered();
}

fn appendFrame(fixtures: *Fixtures, header: http.http2.FrameHeader, payload: []const u8) !void {
    const total = 9 + payload.len;
    if (fixtures.h2_len > fixtures.h2_wire.len or total > fixtures.h2_wire.len - fixtures.h2_len)
        return error.TraceTooLarge;
    var encoded: [9]u8 = undefined;
    try header.encode(&encoded);
    @memcpy(fixtures.h2_wire[fixtures.h2_len..][0..9], &encoded);
    @memcpy(fixtures.h2_wire[fixtures.h2_len + 9 ..][0..payload.len], payload);
    fixtures.h2_len += total;
    fixtures.h2_frames += 1;
    fixtures.h2_payload_bytes += payload.len;
}

fn appendDataFrames(fixtures: *Fixtures, stream_id: u31, body_len: u64, seed: u8) !void {
    var remaining: usize = @intCast(@min(body_len, 128 * 1024));
    var payload: [data_frame_size]u8 = undefined;
    var ordinal: usize = 0;
    while (remaining != 0) : (ordinal += 1) {
        const n = @min(remaining, payload.len);
        for (payload[0..n], 0..) |*byte, i| byte.* = seed +% @as(u8, @truncate(i + ordinal));
        remaining -= n;
        try appendFrame(fixtures, .{
            .length = @intCast(n),
            .type = .data,
            .flags = if (remaining == 0) 0x01 else 0,
            .stream_id = stream_id,
        }, payload[0..n]);
    }
}

fn buildFixtures(fixtures: *Fixtures) !void {
    var head_index: usize = 0;
    var chunk_index: usize = 0;
    var hpack_storage: [max_hpack_block_bytes]u8 = undefined;

    for (corpus.scenarios, 0..) |scenario, scenario_index| {
        var request_encoder = hpack.Encoder.init(std.heap.smp_allocator, 4096);
        defer request_encoder.deinit();
        var response_encoder = hpack.Encoder.init(std.heap.smp_allocator, 4096);
        defer response_encoder.deinit();
        var stream_id: u31 = 1;

        for (scenario.exchanges, 0..) |exchange, exchange_index| {
            var fixture = &fixtures.heads[head_index];
            const method = fieldValue(exchange.request, ":method") orelse return error.MissingPseudoHeader;
            fixture.request_method = method;
            fixture.request_fields = exchange.request;
            fixture.response_fields = exchange.response;
            fixture.request_len = @intCast(try writeHttp1Request(&fixture.request, exchange.request));
            fixture.response_len = @intCast(try writeHttp1Response(&fixture.response, exchange.response));
            const body_len = try responseBodyLength(exchange);
            fixture.response_body_len = body_len;
            head_index += 1;

            if (body_len != 0) {
                try buildChunkFixture(&fixtures.chunks[chunk_index], body_len, @truncate(scenario_index * 31 + exchange_index * 17));
                chunk_index += 1;
            }

            const request_block = try encodeHpack(&request_encoder, exchange.request, &hpack_storage);
            try appendFrame(fixtures, .{
                .length = @intCast(request_block.len),
                .type = .headers,
                .flags = 0x05, // END_HEADERS | END_STREAM for captured bodyless requests.
                .stream_id = stream_id,
            }, request_block);

            const response_block = try encodeHpack(&response_encoder, exchange.response, &hpack_storage);
            try appendFrame(fixtures, .{
                .length = @intCast(response_block.len),
                .type = .headers,
                .flags = if (body_len == 0) 0x05 else 0x04,
                .stream_id = stream_id,
            }, response_block);
            if (body_len != 0)
                try appendDataFrames(fixtures, stream_id, body_len, @truncate(scenario_index * 29 + exchange_index * 13));
            stream_id += 2;
        }
    }

    fixtures.head_count = head_index;
    fixtures.chunk_count = chunk_index;
}

fn verifyFixtures(fixtures: *const Fixtures) !void {
    for (fixtures.heads[0..fixtures.head_count]) |fixture| {
        const request_wire = fixture.request[0..fixture.request_len];
        const response_wire = fixture.response[0..fixture.response_len];
        const request = (try http.http1.parseRequest(request_wire)) orelse return error.IncompleteRequest;
        const response = (try http.http1.parseResponse(response_wire, fixture.request_method)) orelse return error.IncompleteResponse;
        if (request.consumed != request_wire.len or response.consumed != response_wire.len)
            return error.UnconsumedHeadBytes;
    }

    for (corpus.scenarios) |scenario| for (scenario.exchanges) |exchange| {
        var request_validator = http.http2.fields.Validator.init(.request);
        for (exchange.request) |field| try request_validator.field(.{ .name = field.name, .value = field.value });
        try request_validator.finish();
        var response_validator = http.http2.fields.Validator.init(.response);
        for (exchange.response) |field| try response_validator.field(.{ .name = field.name, .value = field.value });
        try response_validator.finish();
    };

    var it = http.http2.CompleteFrameIterator.init(fixtures.h2_wire[0..fixtures.h2_len], http.http2.frame.default_max_frame_size);
    var frames: u64 = 0;
    while (try it.next()) |frame| {
        frames += 1;
        switch (frame.header.type) {
            .headers => _ = try http.http2.payload.headers(frame.header, frame.payload),
            .data => _ = try http.http2.payload.data(frame.header, frame.payload),
            else => {},
        }
    }
    if (it.consumed() != fixtures.h2_len or frames != fixtures.h2_frames) return error.InvalidH2Trace;
}

const Result = struct {
    elapsed: i96,
    transactions: u64 = 0,
    operations: u64 = 0,
    bytes: u64 = 0,
    fields: u64 = 0,
    frames: u64 = 0,
    checksum: usize = 0,
};

fn report(out: *Io.Writer, name: []const u8, result: Result) !void {
    const ns: u64 = @intCast(result.elapsed);
    const seconds_den = @max(ns, 1);
    try out.print("{s}: ", .{name});
    if (result.transactions != 0)
        try out.print("{d} tx/s", .{result.transactions * ns_per_s / seconds_den});
    if (result.operations != 0)
        try out.print("{s}{d} ops/s", .{ if (result.transactions != 0) ", " else "", result.operations * ns_per_s / seconds_den });
    if (result.frames != 0)
        try out.print("{s}{d} frames/s", .{ if (result.transactions != 0 or result.operations != 0) ", " else "", result.frames * ns_per_s / seconds_den });
    if (result.fields != 0)
        try out.print(", {d} fields/s", .{result.fields * ns_per_s / seconds_den});
    if (result.bytes != 0) {
        const mib_x100: u128 = @as(u128, result.bytes) * ns_per_s * 100 / seconds_den / (1024 * 1024);
        try out.print(", {d}.{d:0>2} MiB/s", .{ mib_x100 / 100, mib_x100 % 100 });
    }
    try out.print(" ({d} ns)\n", .{ns});
}

fn benchHttp1Contiguous(io: Io, fixtures: *const Fixtures, transactions: u64) !Result {
    var checksum: usize = 0;
    var bytes: u64 = 0;
    const start = now(io);
    for (0..transactions) |i| {
        const fixture = fixtures.heads[i % fixtures.head_count];
        const request_wire = fixture.request[0..fixture.request_len];
        const response_wire = fixture.response[0..fixture.response_len];
        const request = (try http.http1.parseRequest(request_wire)).?;
        const response = (try http.http1.parseResponse(response_wire, fixture.request_method)).?;
        checksum +%= request.head.headers.len + response.head.headers.len + @as(usize, response.head.start.response.status);
        bytes += request_wire.len + response_wire.len;
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .elapsed = elapsed, .transactions = transactions, .operations = transactions * 2, .bytes = bytes, .checksum = checksum };
}

const fragment_sizes = [_]usize{ 1, 3, 7, 17, 43, 127, 509, 1536 };

fn parseFragmentedHead(parser: *http.http1.HeadParser, mode: http.http1.head.Mode, wire: []const u8, method: []const u8, seed: usize) !usize {
    parser.reset(mode);
    var pos: usize = 0;
    var step: usize = seed;
    while (pos < wire.len) : (step += 1) {
        const n = @min(fragment_sizes[step % fragment_sizes.len], wire.len - pos);
        const r = if (mode == .request)
            try parser.feedRequest(wire[pos .. pos + n])
        else
            try parser.feedResponse(wire[pos .. pos + n], method);
        pos += r.consumed;
        if (r.framed) |framed| return framed.head.headers.len + pos;
        if (r.consumed == 0) return error.NoProgress;
    }
    return error.IncompleteHead;
}

fn benchHttp1Fragmented(io: Io, fixtures: *const Fixtures, transactions: u64) !Result {
    var scratch: [max_head_bytes]u8 = undefined;
    var parser = http.http1.HeadParser.init(.request, &scratch);
    var checksum: usize = 0;
    var bytes: u64 = 0;
    const start = now(io);
    for (0..transactions) |i| {
        const fixture = fixtures.heads[i % fixtures.head_count];
        const request_wire = fixture.request[0..fixture.request_len];
        const response_wire = fixture.response[0..fixture.response_len];
        checksum +%= try parseFragmentedHead(&parser, .request, request_wire, fixture.request_method, @intCast(i));
        checksum +%= try parseFragmentedHead(&parser, .response, response_wire, fixture.request_method, @intCast(i + 3));
        bytes += request_wire.len + response_wire.len;
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .elapsed = elapsed, .transactions = transactions, .operations = transactions * 2, .bytes = bytes, .checksum = checksum };
}

fn parseStreamingFramedHead(parser: *http.http1.FramedHeadParser, mode: http.http1.head.Mode, wire: []const u8, method: []const u8, seed: usize) !usize {
    parser.reset(mode);
    var pos: usize = 0;
    var step: usize = seed;
    while (pos < wire.len) : (step += 1) {
        const n = @min(fragment_sizes[step % fragment_sizes.len], wire.len - pos);
        const r = if (mode == .request)
            try parser.feedRequest(wire[pos .. pos + n])
        else
            try parser.feedResponse(wire[pos .. pos + n], method);
        pos += r.consumed;
        if (r.framed) |framed| return framed.head.headers.len + pos;
        if (r.consumed == 0) return error.NoProgress;
    }
    return error.IncompleteHead;
}

fn benchHttp1StreamingFramed(io: Io, fixtures: *const Fixtures, transactions: u64) !Result {
    var scratch: [max_head_bytes]u8 = undefined;
    var parser = http.http1.FramedHeadParser.init(.request, &scratch);
    var checksum: usize = 0;
    var bytes: u64 = 0;
    const start = now(io);
    for (0..transactions) |i| {
        const fixture = fixtures.heads[i % fixtures.head_count];
        const request_wire = fixture.request[0..fixture.request_len];
        const response_wire = fixture.response[0..fixture.response_len];
        checksum +%= try parseStreamingFramedHead(&parser, .request, request_wire, fixture.request_method, @intCast(i));
        checksum +%= try parseStreamingFramedHead(&parser, .response, response_wire, fixture.request_method, @intCast(i + 3));
        bytes += request_wire.len + response_wire.len;
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .elapsed = elapsed, .transactions = transactions, .operations = transactions * 2, .bytes = bytes, .checksum = checksum };
}

fn benchHttp1FixedBodies(io: Io, fixtures: *const Fixtures, bodies: u64) !Result {
    var input: [data_frame_size]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = @truncate(i * 17 + 11);
    var checksum: usize = 0;
    var bytes: u64 = 0;
    var body_index: usize = 0;
    const start = now(io);
    for (0..bodies) |_| {
        // Skip captured HEAD/bodyless responses while retaining their natural
        // frequency in the head benchmarks.
        while (fixtures.heads[body_index % fixtures.head_count].response_body_len == 0) body_index += 1;
        const body_len = fixtures.heads[body_index % fixtures.head_count].response_body_len;
        body_index += 1;
        var body = http.http1.body.FixedBody.init(body_len);
        var step: usize = body_index;
        while (!body.done()) : (step += 1) {
            const offered = @min(input.len, fragment_sizes[step % fragment_sizes.len] * 8);
            const part = body.take(input[0..offered]);
            checksum +%= part.len;
            if (part.len != 0) checksum +%= part[part.len - 1];
            bytes += part.len;
        }
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .elapsed = elapsed, .transactions = bodies, .bytes = bytes, .checksum = checksum };
}

fn benchHttp1Chunked(io: Io, fixtures: *const Fixtures, bodies: u64) !Result {
    var scratch: [512]u8 = undefined;
    var decoder = http.http1.ChunkDecoder.init(&scratch);
    var checksum: usize = 0;
    var bytes: u64 = 0;
    const start = now(io);
    for (0..bodies) |i| {
        const fixture = fixtures.chunks[i % fixtures.chunk_count];
        decoder.reset();
        var pos: usize = 0;
        const wire = fixture.wire[0..fixture.len];
        while (true) {
            const r = try decoder.feed(wire[pos..]);
            pos += r.consumed;
            if (r.event) |event| switch (event) {
                .data => |data| checksum +%= data.len,
                .trailer => |trailer| checksum +%= trailer.name.len + trailer.value.len,
                .trailers_done => {},
                .done => break,
            };
            if (r.consumed == 0 and r.event == null) return error.NoProgress;
        }
        bytes += wire.len;
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .elapsed = elapsed, .transactions = bodies, .bytes = bytes, .checksum = checksum };
}

fn benchH2Fields(io: Io, blocks: u64) !Result {
    var checksum: usize = 0;
    var total_fields: u64 = 0;
    var scenario_index: usize = 0;
    var exchange_index: usize = 0;
    var response = false;
    const start = now(io);
    for (0..blocks) |_| {
        const scenario = corpus.scenarios[scenario_index];
        const exchange = scenario.exchanges[exchange_index];
        const fields = if (response) exchange.response else exchange.request;
        var validator = http.http2.fields.Validator.init(if (response) .response else .request);
        for (fields) |field| try validator.field(.{ .name = field.name, .value = field.value });
        try validator.finish();
        total_fields += fields.len;
        checksum +%= fields.len + @intFromBool(validator.regular_seen);

        response = !response;
        if (!response) {
            exchange_index += 1;
            if (exchange_index == scenario.exchanges.len) {
                exchange_index = 0;
                scenario_index = (scenario_index + 1) % corpus.scenarios.len;
            }
        }
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .elapsed = elapsed, .operations = blocks, .fields = total_fields, .checksum = checksum };
}

fn dispatchFrame(frame: http.http2.frame.CompleteFrame, guard: *http.http2.continuation.Guard) !usize {
    try guard.observe(frame.header);
    return switch (frame.header.type) {
        .headers => (try http.http2.payload.headers(frame.header, frame.payload)).fragment.len,
        .data => (try http.http2.payload.data(frame.header, frame.payload)).len,
        else => frame.payload.len,
    };
}

fn benchH2ParseComplete(io: Io, fixtures: *const Fixtures, target_frames: u64) !Result {
    const loops = @max(@as(u64, 1), target_frames / @max(fixtures.h2_frames, 1));
    const wire = fixtures.h2_wire[0..fixtures.h2_len];
    var checksum: usize = 0;
    var frames: u64 = 0;
    var bytes: u64 = 0;
    const start = now(io);
    for (0..loops) |_| {
        var guard: http.http2.continuation.Guard = .{};
        var pos: usize = 0;
        while (pos < wire.len) {
            const parsed = (try http.http2.parseCompleteFrame(wire[pos..], http.http2.frame.default_max_frame_size)).?;
            checksum +%= try dispatchFrame(parsed.frame, &guard);
            pos += parsed.consumed;
            frames += 1;
        }
        bytes += wire.len;
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .elapsed = elapsed, .frames = frames, .bytes = bytes, .checksum = checksum };
}

fn benchH2Complete(io: Io, fixtures: *const Fixtures, target_frames: u64) !Result {
    const loops = @max(@as(u64, 1), target_frames / @max(fixtures.h2_frames, 1));
    var checksum: usize = 0;
    var frames: u64 = 0;
    var bytes: u64 = 0;
    const start = now(io);
    for (0..loops) |_| {
        var guard: http.http2.continuation.Guard = .{};
        var it = http.http2.CompleteFrameIterator.init(fixtures.h2_wire[0..fixtures.h2_len], http.http2.frame.default_max_frame_size);
        while (try it.next()) |frame| {
            checksum +%= try dispatchFrame(frame, &guard);
            frames += 1;
        }
        bytes += fixtures.h2_len;
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .elapsed = elapsed, .frames = frames, .bytes = bytes, .checksum = checksum };
}

fn benchH2Fragmented(io: Io, fixtures: *const Fixtures, target_frames: u64) !Result {
    const loops = @max(@as(u64, 1), target_frames / @max(fixtures.h2_frames, 1));
    const wire = fixtures.h2_wire[0..fixtures.h2_len];
    var checksum: usize = 0;
    var frames: u64 = 0;
    var bytes: u64 = 0;
    const start = now(io);
    for (0..loops) |loop_index| {
        var decoder = http.http2.FrameDecoder.init(http.http2.frame.default_max_frame_size);
        var pos: usize = 0;
        var step: usize = @intCast(loop_index);
        while (pos < wire.len) : (step += 1) {
            const chunk_end = @min(wire.len, pos + fragment_sizes[step % fragment_sizes.len]);
            while (pos < chunk_end) {
                const r = try decoder.next(wire[pos..chunk_end]);
                pos += r.consumed;
                if (r.event) |event| switch (event) {
                    .header => |header| {
                        frames += 1;
                        checksum +%= header.length + header.stream_id;
                    },
                    .payload => |payload| checksum +%= payload.bytes.len + @intFromBool(payload.end_frame),
                };
                if (r.consumed == 0) return error.NoProgress;
            }
        }
        bytes += wire.len;
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(checksum);
    return .{ .elapsed = elapsed, .frames = frames, .bytes = bytes, .checksum = checksum };
}

const parallel_threads = 4;

const ParallelControl = struct {
    ready: std.atomic.Value(usize) = .init(0),
    start: std.atomic.Value(bool) = .init(false),
};

const ParallelWorker = struct {
    control: *ParallelControl,
    fixtures: *const Fixtures,
    worker_index: usize,
    transactions: u64,
    result: Result = .{ .elapsed = 0 },
    failed: bool = false,
};

fn validateBlock(fields: []const corpus.Field, kind: http.http2.fields.Kind) !usize {
    var validator = http.http2.fields.Validator.init(kind);
    for (fields) |field| try validator.field(.{ .name = field.name, .value = field.value });
    try validator.finish();
    return fields.len + @intFromBool(validator.regular_seen);
}

fn runParallelWorker(worker: *ParallelWorker) void {
    _ = worker.control.ready.fetchAdd(1, .release);
    while (!worker.control.start.load(.acquire)) std.atomic.spinLoopHint();
    var checksum: usize = 0;
    var bytes: u64 = 0;
    var fields: u64 = 0;
    for (0..worker.transactions) |i| {
        const fixture = worker.fixtures.heads[(i + worker.worker_index * 5) % worker.fixtures.head_count];
        const request_wire = fixture.request[0..fixture.request_len];
        const response_wire = fixture.response[0..fixture.response_len];
        const request = http.http1.parseRequest(request_wire) catch {
            worker.failed = true;
            return;
        };
        const response = http.http1.parseResponse(response_wire, fixture.request_method) catch {
            worker.failed = true;
            return;
        };
        if (request == null or response == null) {
            worker.failed = true;
            return;
        }
        checksum +%= request.?.head.headers.len + response.?.head.headers.len;
        checksum +%= validateBlock(fixture.request_fields, .request) catch {
            worker.failed = true;
            return;
        };
        checksum +%= validateBlock(fixture.response_fields, .response) catch {
            worker.failed = true;
            return;
        };
        fields += fixture.request_fields.len + fixture.response_fields.len;
        bytes += request_wire.len + response_wire.len;
    }
    worker.result.transactions = worker.transactions;
    worker.result.operations = worker.transactions * 4;
    worker.result.fields = fields;
    worker.result.bytes = bytes;
    worker.result.checksum = checksum;
    std.mem.doNotOptimizeAway(checksum);
}

fn benchParallelMixed(io: Io, fixtures: *const Fixtures, transactions_per_thread: u64) !Result {
    var control: ParallelControl = .{};
    var workers: [parallel_threads]ParallelWorker = undefined;
    var threads: [parallel_threads]std.Thread = undefined;
    for (&workers, 0..) |*worker, i| {
        worker.* = .{
            .control = &control,
            .fixtures = fixtures,
            .worker_index = i,
            .transactions = transactions_per_thread,
        };
        threads[i] = try std.Thread.spawn(.{}, runParallelWorker, .{worker});
    }
    while (control.ready.load(.acquire) != parallel_threads) std.atomic.spinLoopHint();
    const start = now(io);
    control.start.store(true, .release);
    for (&threads) |*thread| thread.join();
    const elapsed = now(io) - start;

    var result: Result = .{ .elapsed = elapsed };
    for (&workers) |*worker| {
        if (worker.failed) return error.ParallelWorkerFailed;
        result.transactions += worker.result.transactions;
        result.operations += worker.result.operations;
        result.fields += worker.result.fields;
        result.bytes += worker.result.bytes;
        result.checksum +%= worker.result.checksum;
    }
    std.mem.doNotOptimizeAway(result.checksum);
    return result;
}

fn corpusStats(out: *Io.Writer, fixtures: *const Fixtures) !void {
    var exchanges: usize = 0;
    var fields: usize = 0;
    var raw_header_bytes: usize = 0;
    for (corpus.scenarios) |scenario| {
        exchanges += scenario.exchanges.len;
        for (scenario.exchanges) |exchange| {
            fields += exchange.request.len + exchange.response.len;
            raw_header_bytes += corpus.payloadBytes(exchange.request) + corpus.payloadBytes(exchange.response);
        }
    }
    try out.print("corpus: {d} connection scenarios, {d} exchanges, {d} fields, {d} raw name/value bytes\n", .{
        corpus.scenarios.len, exchanges, fields, raw_header_bytes,
    });
    try out.print("fixtures: {d} HTTP/1 head pairs, {d} modeled chunked bodies, HTTP/2 trace {d} bytes / {d} frames / {d} frame-payload bytes\n", .{
        fixtures.head_count, fixtures.chunk_count, fixtures.h2_len, fixtures.h2_frames, fixtures.h2_payload_bytes,
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var fixtures: Fixtures = .{};
    try buildFixtures(&fixtures);
    try verifyFixtures(&fixtures);
    try corpusStats(out, &fixtures);

    // Work counts are long enough to drown out timer noise while keeping the
    // complete suite practical for repeated A/B runs.
    try report(out, "http1 real heads contiguous", try benchHttp1Contiguous(io, &fixtures, 500_000));
    try report(out, "http1 real heads fragmented", try benchHttp1Fragmented(io, &fixtures, 250_000));
    try report(out, "http1 real heads streaming framed", try benchHttp1StreamingFramed(io, &fixtures, 250_000));
    try report(out, "http1 captured-length fixed bodies", try benchHttp1FixedBodies(io, &fixtures, 5_000_000));
    try report(out, "http1 modeled chunked bodies", try benchHttp1Chunked(io, &fixtures, 50_000));
    try report(out, "http2 real field validation", try benchH2Fields(io, 2_000_000));
    try report(out, "http2 real frame trace parseComplete", try benchH2ParseComplete(io, &fixtures, 20_000_000));
    try report(out, "http2 real frame trace iterator", try benchH2Complete(io, &fixtures, 20_000_000));
    try report(out, "http2 real frame trace fragmented", try benchH2Fragmented(io, &fixtures, 5_000_000));
    try report(out, "parallel mixed headers (4 threads)", try benchParallelMixed(io, &fixtures, 200_000));

    try out.print("state sizes: HeadParser={d} FramedHeadParser={d} ChunkDecoder={d} FrameDecoder={d} CompleteFrameIterator={d} FlowWindow={d} Guard={d} Collector={d} H2FieldValidator={d}\n", .{
        @sizeOf(http.http1.HeadParser),
        @sizeOf(http.http1.FramedHeadParser),
        @sizeOf(http.http1.ChunkDecoder),
        @sizeOf(http.http2.FrameDecoder),
        @sizeOf(http.http2.CompleteFrameIterator),
        @sizeOf(http.http2.FlowWindow),
        @sizeOf(http.http2.continuation.Guard),
        @sizeOf(http.http2.header_block.Collector),
        @sizeOf(http.http2.fields.Validator),
    });
    try out.print("allocation model: timed HTTP parser/validator paths perform no heap allocation; fixture construction is excluded from timing\n", .{});
}
