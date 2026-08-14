const std = @import("std");
const http = @import("http");

const Io = std.Io;
const ns_per_s: u64 = 1_000_000_000;

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn report(out: *Io.Writer, name: []const u8, elapsed: i96, operations: u64) !void {
    const ns: u64 = @intCast(elapsed);
    const ops_per_s = operations * ns_per_s / @max(ns, 1);
    try out.print("{s}: {d} ns total, {d} ops/s\n", .{ name, ns, ops_per_s });
}

fn benchHttp1Legacy(io: Io, wire: []const u8, operations: u64) !i96 {
    var storage: [512]u8 = undefined;
    var parser = http.http1.HeadParser.init(.request, &storage);
    var sum: u64 = 0;
    const start = now(io);
    for (0..operations) |_| {
        parser.reset(.request);
        const r = try parser.feed(wire);
        const framing = try http.http1.head.requestBodyFraming(r.head.?);
        sum +%= switch (framing) {
            .content_length => |n| n,
            else => 0,
        };
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(sum);
    return elapsed;
}

fn benchHttp1IncrementalFast(io: Io, wire: []const u8, operations: u64) !i96 {
    var storage: [512]u8 = undefined;
    var parser = http.http1.HeadParser.init(.request, &storage);
    var sum: u64 = 0;
    const start = now(io);
    for (0..operations) |_| {
        parser.reset(.request);
        const r = try parser.feedRequest(wire);
        sum +%= switch (r.framed.?.framing) {
            .content_length => |n| n,
            else => 0,
        };
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(sum);
    return elapsed;
}

fn benchHttp1Contiguous(io: Io, wire: []const u8, operations: u64) !i96 {
    var sum: u64 = 0;
    const start = now(io);
    for (0..operations) |_| {
        const r = (try http.http1.parseRequest(wire)).?;
        sum +%= switch (r.framing) {
            .content_length => |n| n,
            else => 0,
        };
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(sum);
    return elapsed;
}

fn benchChunkDecode(io: Io, wire: []const u8, operations: u64) !i96 {
    var line: [128]u8 = undefined;
    var decoder = http.http1.ChunkDecoder.init(&line);
    var sum: usize = 0;
    const start = now(io);
    for (0..operations) |_| {
        decoder.reset();
        var pos: usize = 0;
        while (true) {
            const r = try decoder.feed(wire[pos..]);
            pos += r.consumed;
            sum +%= r.consumed;
            if (r.event) |event| switch (event) {
                .done => break,
                else => {},
            };
        }
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(sum);
    return elapsed;
}

fn benchFrameIncremental(io: Io, wire: []const u8, operations: u64) !i96 {
    var decoder = http.http2.FrameDecoder.init(http.http2.frame.default_max_frame_size);
    var sum: usize = 0;
    const start = now(io);
    for (0..operations) |_| {
        const h = try decoder.next(wire[0..9]);
        const p = try decoder.next(wire[9..]);
        sum +%= h.consumed + p.consumed;
        std.mem.doNotOptimizeAway(p.event);
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(sum);
    return elapsed;
}

fn benchFrameComplete(io: Io, wire: []const u8, operations: u64) !i96 {
    var sum: usize = 0;
    const start = now(io);
    for (0..operations) |_| {
        const r = (try http.http2.parseCompleteFrame(wire, http.http2.frame.default_max_frame_size)).?;
        sum +%= r.consumed;
        std.mem.doNotOptimizeAway(r.frame.payload.ptr);
    }
    const elapsed = now(io) - start;
    std.mem.doNotOptimizeAway(sum);
    return elapsed;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const entropy: u8 = @truncate(@as(u96, @bitCast(now(io))));

    var request = "POST /api/v1/items HTTP/1.1\r\nHost: example.com\r\nUser-Agent: benchmark/1.0\r\nAccept: application/json\r\nContent-Length: 123\r\nX-Request-Id: 0123456789abcdef\r\n\r\n".*;
    request[request.len - 5] = 'a' + entropy % 6;

    var chunked = "20\r\n0123456789abcdef0123456789abcdef\r\n0\r\n\r\n".*;
    chunked[4] = 'a' + entropy % 26;

    var frame_header: [9]u8 = undefined;
    const header: http.http2.FrameHeader = .{
        .length = 32,
        .type = .data,
        .flags = entropy & 1,
        .stream_id = 1,
    };
    try header.encode(&frame_header);
    const payload = "0123456789abcdef0123456789abcdef";
    var frame_wire: [41]u8 = undefined;
    @memcpy(frame_wire[0..9], &frame_header);
    @memcpy(frame_wire[9..], payload);

    const head_ops: u64 = 1_000_000;
    const chunk_ops: u64 = 2_000_000;
    const frame_ops: u64 = 10_000_000;

    try report(out, "http1 head legacy+framing", try benchHttp1Legacy(io, &request, head_ops), head_ops);
    try report(out, "http1 head incremental-fast", try benchHttp1IncrementalFast(io, &request, head_ops), head_ops);
    try report(out, "http1 head contiguous-fast", try benchHttp1Contiguous(io, &request, head_ops), head_ops);
    try report(out, "http1 chunk decode", try benchChunkDecode(io, &chunked, chunk_ops), chunk_ops);
    try report(out, "http2 frame incremental", try benchFrameIncremental(io, &frame_wire, frame_ops), frame_ops);
    try report(out, "http2 frame complete", try benchFrameComplete(io, &frame_wire, frame_ops), frame_ops);

    try out.print("state sizes: HeadParser={d} ChunkDecoder={d} FrameDecoder={d} FlowWindow={d} Guard={d} Collector={d}\n", .{
        @sizeOf(http.http1.HeadParser),
        @sizeOf(http.http1.ChunkDecoder),
        @sizeOf(http.http2.FrameDecoder),
        @sizeOf(http.http2.FlowWindow),
        @sizeOf(http.http2.continuation.Guard),
        @sizeOf(http.http2.header_block.Collector),
    });
}
