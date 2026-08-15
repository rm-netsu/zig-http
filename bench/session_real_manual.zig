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
    var peer = http.http2.PeerState.init(.client);
    var manager = http.http2.StreamManager.init(.client, .{});
    var connection: http.http2.ConnectionState = .{};
    var scratch: [16 * 1024]u8 = undefined;
    var store: shared.Store = .{};
    var sink: shared.CountingSink = .{};

    var tx: u64 = 0;
    var checksum: u64 = 0;
    const start = now(io);
    for (0..shared.rounds) |round| {
        if (round % shared.batch_streams == 0) {
            store.reset();
            manager = http.http2.StreamManager.init(.client, .{});
            connection = .{};
        }
        const id: u31 = @intCast((round % shared.batch_streams) * 2 + 1);
        try manager.openLocal(&store, &peer, id, true);
        const block = fixture.block(round);
        const end_on_headers = block.body == 0;
        const header = http.http2.FrameHeader{
            .length = @intCast(block.bytes.len),
            .type = .headers,
            .flags = 0x04 | @as(u8, @intFromBool(end_on_headers)),
            .stream_id = id,
        };
        if (connection.check(header) != .none) return error.Protocol;
        var validator = http.http2.fields.Validator.init(.response);
        var it = decoder.iterator(block.bytes, &scratch);
        var fields_count: u32 = 0;
        while (try it.next()) |field| {
            const h: http.common.Header = .{ .name = field.name, .value = field.value };
            try validator.field(h);
            sink.field(id, .response, h);
            fields_count += 1;
        }
        try validator.finish();
        if (manager.receiveHeaders(&store, &peer, id, end_on_headers) != .accepted) return error.Protocol;
        store.get(id).?.remote_headers = .regular;
        checksum +%= fields_count;

        var left = block.body;
        while (left != 0) {
            const n = @min(left, shared.data_chunk);
            left -= n;
            const data_header = http.http2.FrameHeader{ .length = n, .type = .data, .flags = @intFromBool(left == 0), .stream_id = id };
            if (connection.check(data_header) != .none) return error.Protocol;
            if (manager.receiveData(&store, id, n, left == 0) != .accepted) return error.Protocol;
            checksum +%= n;
            try connection.creditReceive(@intCast(n));
            try manager.existing(&store, id).?.creditReceive(@intCast(n));
        }
        tx += 1;
    }
    const elapsed: u64 = @intCast(now(io) - start);
    std.mem.doNotOptimizeAway(checksum);
    shared.print("session manual", elapsed, tx, sink.fields);
}
