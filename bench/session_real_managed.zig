const std = @import("std");
const http = @import("http");
const shared = @import("session_real.zig");

const Io = std.Io;

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.page_allocator;
    var fixture = try shared.Fixture.init(allocator);
    defer fixture.deinit();

    var decoder = http.http2.hpack.Decoder.init(allocator, 4096);
    defer decoder.deinit();
    var encoder = http.http2.hpack.Encoder.init(allocator, 4096);
    defer encoder.deinit();
    var header_storage: [16 * 1024]u8 = undefined;
    var scratch: [16 * 1024]u8 = undefined;
    var store: shared.Store = .{};
    var sink: shared.CountingSink = .{};
    var session = http.http2.Session.init(.{ .role = .client, .decoder = &decoder, .encoder = &encoder, .header_storage = &header_storage });

    var tx: u64 = 0;
    var checksum: u64 = 0;
    const start = now(io);
    for (0..shared.rounds) |round| {
        if (round % shared.batch_streams == 0) {
            store.reset();
            session.streams = http.http2.streams.Manager.init(.client, .{});
            session.connection = .{};
        }
        const id: u31 = @intCast((round % shared.batch_streams) * 2 + 1);
        try session.streams.openLocal(&store, &session.peer, id, true);
        const block = fixture.block(round);
        const end_on_headers = block.body == 0;
        const header = http.http2.frame.FrameHeader{
            .length = @intCast(block.bytes.len),
            .type = .headers,
            .flags = 0x04 | @as(u8, @intFromBool(end_on_headers)),
            .stream_id = id,
        };
        const event = try session.receiveComplete(&store, .{ .header = header, .payload = block.bytes }, &scratch, &sink);
        checksum +%= event.headers.field_count;

        var left = block.body;
        while (left != 0) {
            const n = @min(left, shared.data_chunk);
            left -= n;
            const data_event = try session.receiveComplete(&store, .{
                .header = .{ .length = n, .type = .data, .flags = @intFromBool(left == 0), .stream_id = id },
                .payload = shared.body_bytes[0..n],
            }, &scratch, &sink);
            checksum +%= data_event.data.bytes.len;
            try session.connection.creditReceive(@intCast(n));
            try session.streams.existing(&store, id).?.creditReceive(@intCast(n));
        }
        tx += 1;
    }
    const elapsed: u64 = @intCast(now(io) - start);
    std.mem.doNotOptimizeAway(checksum);
    shared.print("session managed", elapsed, tx, sink.fields);
    std.debug.print("Session={} B Tracked={} B\n", .{ @sizeOf(http.http2.Session), @sizeOf(http.http2.stream.Tracked) });
}
