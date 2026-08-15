const std = @import("std");
const http = @import("http");

const Io = std.Io;
const ns_per_s: u64 = 1_000_000_000;
const max_wire = 1024 * 1024;
const fragment_sizes = [_]usize{ 1, 3, 7, 17, 43, 127, 509, 1536 };

/// Frame layout derived from the offline real-world corpus using hpack 0.4.1.
/// Payload contents are deterministic noise because frame parsing depends on
/// lengths/type/flags/stream ids; HPACK and HTTP payload work are not timed here.
const Desc = struct { length: u32, type: http.http2.frame.Type, flags: u8, stream_id: u31 };
const descs = [_]Desc{
    .{ .length = 306, .type = .headers, .flags = 0x05, .stream_id = 1 },
    .{ .length = 76, .type = .headers, .flags = 0x04, .stream_id = 1 },
    .{ .length = 8145, .type = .data, .flags = 0x01, .stream_id = 1 },
    .{ .length = 85, .type = .headers, .flags = 0x05, .stream_id = 3 },
    .{ .length = 36, .type = .headers, .flags = 0x04, .stream_id = 3 },
    .{ .length = 11001, .type = .data, .flags = 0x01, .stream_id = 3 },
    .{ .length = 377, .type = .headers, .flags = 0x05, .stream_id = 1 },
    .{ .length = 153, .type = .headers, .flags = 0x04, .stream_id = 1 },
    .{ .length = 1913, .type = .data, .flags = 0x01, .stream_id = 1 },
    .{ .length = 458, .type = .headers, .flags = 0x05, .stream_id = 1 },
    .{ .length = 289, .type = .headers, .flags = 0x05, .stream_id = 1 },
    .{ .length = 265, .type = .headers, .flags = 0x05, .stream_id = 1 },
    .{ .length = 261, .type = .headers, .flags = 0x04, .stream_id = 1 },
    .{ .length = 16384, .type = .data, .flags = 0x00, .stream_id = 1 },
    .{ .length = 16384, .type = .data, .flags = 0x00, .stream_id = 1 },
    .{ .length = 1524, .type = .data, .flags = 0x01, .stream_id = 1 },
    .{ .length = 280, .type = .headers, .flags = 0x05, .stream_id = 1 },
    .{ .length = 278, .type = .headers, .flags = 0x04, .stream_id = 1 },
    .{ .length = 16384, .type = .data, .flags = 0x00, .stream_id = 1 },
    .{ .length = 6327, .type = .data, .flags = 0x01, .stream_id = 1 },
    .{ .length = 54, .type = .headers, .flags = 0x05, .stream_id = 3 },
    .{ .length = 158, .type = .headers, .flags = 0x04, .stream_id = 3 },
    .{ .length = 10947, .type = .data, .flags = 0x01, .stream_id = 3 },
    .{ .length = 93, .type = .headers, .flags = 0x05, .stream_id = 5 },
    .{ .length = 173, .type = .headers, .flags = 0x04, .stream_id = 5 },
    .{ .length = 753, .type = .data, .flags = 0x01, .stream_id = 5 },
    .{ .length = 31, .type = .headers, .flags = 0x05, .stream_id = 7 },
    .{ .length = 173, .type = .headers, .flags = 0x04, .stream_id = 7 },
    .{ .length = 1112, .type = .data, .flags = 0x01, .stream_id = 7 },
    .{ .length = 263, .type = .headers, .flags = 0x05, .stream_id = 1 },
    .{ .length = 478, .type = .headers, .flags = 0x05, .stream_id = 1 },
    .{ .length = 282, .type = .headers, .flags = 0x05, .stream_id = 1 },
    .{ .length = 40, .type = .headers, .flags = 0x05, .stream_id = 1 },
    .{ .length = 123, .type = .headers, .flags = 0x05, .stream_id = 1 },
    .{ .length = 648, .type = .headers, .flags = 0x05, .stream_id = 1 },
    .{ .length = 98, .type = .headers, .flags = 0x05, .stream_id = 3 },
    .{ .length = 271, .type = .headers, .flags = 0x04, .stream_id = 3 },
    .{ .length = 16384, .type = .data, .flags = 0x01, .stream_id = 3 },
    .{ .length = 98, .type = .headers, .flags = 0x05, .stream_id = 5 },
    .{ .length = 209, .type = .headers, .flags = 0x04, .stream_id = 5 },
    .{ .length = 6780, .type = .data, .flags = 0x01, .stream_id = 5 },
};

const Range = struct { first: u8, count: u8 };
const ranges = [_]Range{
    .{ .first = 0, .count = 6 },
    .{ .first = 6, .count = 3 },
    .{ .first = 9, .count = 2 },
    .{ .first = 11, .count = 5 },
    .{ .first = 16, .count = 13 },
    .{ .first = 29, .count = 2 },
    .{ .first = 31, .count = 2 },
    .{ .first = 33, .count = 8 },
};

const Wire = struct {
    bytes: [max_wire]u8 = undefined,
    len: usize = 0,
    offsets: [descs.len + 1]u32 = undefined,
};

fn buildWire(wire: *Wire) !void {
    var pos: usize = 0;
    for (descs, 0..) |d, ordinal| {
        wire.offsets[ordinal] = @intCast(pos);
        if (pos + 9 + d.length > wire.bytes.len) return error.TraceTooLarge;
        var encoded: [9]u8 = undefined;
        try (http.http2.FrameHeader{
            .length = d.length,
            .type = d.type,
            .flags = d.flags,
            .stream_id = d.stream_id,
        }).encode(&encoded);
        @memcpy(wire.bytes[pos..][0..9], &encoded);
        for (wire.bytes[pos + 9 .. pos + 9 + d.length], 0..) |*b, i|
            b.* = @truncate(ordinal * 29 + i * 17 + 3);
        pos += 9 + d.length;
    }
    wire.offsets[descs.len] = @intCast(pos);
    wire.len = pos;
}

fn rangeBytes(wire: *const Wire, range: Range) []const u8 {
    const first: usize = range.first;
    const end = first + range.count;
    return wire.bytes[wire.offsets[first]..wire.offsets[end]];
}

pub const Result = struct { elapsed: i96, frames: u64, checksum: usize };
fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

pub fn rawComplete(io: Io, wire: *const Wire, target: u64) !Result {
    const cycles = @max(@as(u64, 1), target / descs.len);
    var frames: u64 = 0;
    var checksum: usize = 0;
    const start = now(io);
    for (0..cycles) |_| {
        for (ranges) |range| {
            var guard: http.http2.continuation.Guard = .{};
            const bytes = rangeBytes(wire, range);
            var it = http.http2.CompleteFrameIterator.init(bytes, http.http2.frame.default_max_frame_size);
            while (try it.next()) |complete| {
                try guard.observe(complete.header);
                frames += 1;
                checksum +%= complete.payload.len + complete.header.stream_id;
            }
            if (it.consumed() != bytes.len) return error.IncompleteFrame;
        }
    }
    return .{ .elapsed = now(io) - start, .frames = frames, .checksum = checksum };
}

pub fn connectionComplete(io: Io, wire: *const Wire, target: u64) !Result {
    const cycles = @max(@as(u64, 1), target / descs.len);
    var frames: u64 = 0;
    var checksum: usize = 0;
    const start = now(io);
    for (0..cycles) |_| {
        for (ranges) |range| {
            var decoder = http.http2.ConnectionDecoder.init(http.http2.frame.default_max_frame_size);
            const bytes = rangeBytes(wire, range);
            var it = try decoder.complete(bytes);
            while (try it.next()) |complete| {
                frames += 1;
                checksum +%= complete.payload.len + complete.header.stream_id;
            }
            if (it.consumed() != bytes.len) return error.IncompleteFrame;
        }
    }
    return .{ .elapsed = now(io) - start, .frames = frames, .checksum = checksum };
}

pub fn rawFragmented(io: Io, wire: *const Wire, target: u64) !Result {
    const cycles = @max(@as(u64, 1), target / descs.len);
    var frames: u64 = 0;
    var checksum: usize = 0;
    const start = now(io);
    for (0..cycles) |cycle| {
        for (ranges, 0..) |range, range_index| {
            var decoder = http.http2.FrameDecoder.init(http.http2.frame.default_max_frame_size);
            const bytes = rangeBytes(wire, range);
            var pos: usize = 0;
            var step: usize = @intCast(cycle + range_index * 3);
            while (pos < bytes.len) : (step += 1) {
                const end = @min(bytes.len, pos + fragment_sizes[step % fragment_sizes.len]);
                while (pos < end) {
                    const result = try decoder.next(bytes[pos..end]);
                    pos += result.consumed;
                    if (result.event) |event| switch (event) {
                        .header => |header| {
                            frames += 1;
                            checksum +%= header.length + header.stream_id;
                        },
                        .payload => |chunk| checksum +%= chunk.bytes.len + @intFromBool(chunk.end_frame),
                    };
                    if (result.consumed == 0) return error.NoProgress;
                }
            }
        }
    }
    return .{ .elapsed = now(io) - start, .frames = frames, .checksum = checksum };
}

pub fn connectionFragmented(io: Io, wire: *const Wire, target: u64) !Result {
    const cycles = @max(@as(u64, 1), target / descs.len);
    var frames: u64 = 0;
    var checksum: usize = 0;
    const start = now(io);
    for (0..cycles) |cycle| {
        for (ranges, 0..) |range, range_index| {
            var decoder = http.http2.ConnectionDecoder.init(http.http2.frame.default_max_frame_size);
            const bytes = rangeBytes(wire, range);
            var pos: usize = 0;
            var step: usize = @intCast(cycle + range_index * 3);
            while (pos < bytes.len) : (step += 1) {
                const end = @min(bytes.len, pos + fragment_sizes[step % fragment_sizes.len]);
                while (pos < end) {
                    const result = try decoder.frames.next(bytes[pos..end]);
                    pos += result.consumed;
                    if (result.event) |event| switch (event) {
                        .header => |header| {
                            if (decoder.checkHeader(header) != .none) return error.InvalidConnectionTrace;
                            frames += 1;
                            checksum +%= header.length + header.stream_id;
                        },
                        .payload => |chunk| checksum +%= chunk.bytes.len + @intFromBool(chunk.end_frame),
                    };
                    if (result.consumed == 0) return error.NoProgress;
                }
            }
        }
    }
    return .{ .elapsed = now(io) - start, .frames = frames, .checksum = checksum };
}

pub fn report(out: *Io.Writer, name: []const u8, result: Result) !void {
    const ns: u64 = @intCast(result.elapsed);
    std.mem.doNotOptimizeAway(result.checksum);
    try out.print("{s}: {d} frames/s ({d} ns)\n", .{
        name,
        result.frames * ns_per_s / @max(ns, 1),
        ns,
    });
}

pub const Case = enum { raw_complete, connection_complete, raw_fragmented, connection_fragmented };

pub fn run(init: std.process.Init, comptime which: Case) !void {
    const io = init.io;
    var output_storage: [1024]u8 = undefined;
    var output_writer = Io.File.stdout().writer(io, &output_storage);
    const out = &output_writer.interface;
    defer out.flush() catch {};

    var wire: Wire = .{};
    try buildWire(&wire);
    const name, const result = switch (which) {
        .raw_complete => .{ "http2 per-connection complete raw", try rawComplete(io, &wire, 40_000_000) },
        .connection_complete => .{ "http2 connection complete state", try connectionComplete(io, &wire, 40_000_000) },
        .raw_fragmented => .{ "http2 per-connection fragmented raw", try rawFragmented(io, &wire, 10_000_000) },
        .connection_fragmented => .{ "http2 connection fragmented state", try connectionFragmented(io, &wire, 10_000_000) },
    };
    try report(out, name, result);
    try out.print("state sizes: FrameDecoder={d} ConnectionState={d} ConnectionDecoder={d} ConnectionCompleteIterator={d}\n", .{
        @sizeOf(http.http2.FrameDecoder),
        @sizeOf(http.http2.ConnectionState),
        @sizeOf(http.http2.ConnectionDecoder),
        @sizeOf(http.http2.ConnectionCompleteIterator),
    });
}
