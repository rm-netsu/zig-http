const std = @import("std");
const http = @import("http");
const common = @import("stream_real.zig");
const Io = std.Io;

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const fixture = common.Fixture.init();
    var peer = http.http2.peer.State.init(.client);
    const start = now(io);
    var tx: u64 = 0;
    var round: usize = 0;
    while (round < common.rounds) : (round += 1) {
        var store: common.Store = .{};

        var stream_index: usize = 0;
        while (stream_index < common.streams_per_connection) : (stream_index += 1) {
            const id: u31 = @intCast(stream_index * 2 + 1);
            const tracked = http.http2.stream.Tracked.init(peer.settings.initial_window_size, 65_535);
            const slot = store.insert(id, tracked) orelse return error.StoreFull;
            try slot.stream.localHeaders(true);
        }

        var order: usize = 0;
        while (order < common.streams_per_connection) : (order += 1) {
            // A coprime stride permutes all 64 streams and avoids making close
            // order identical to creation order.
            const stream_index_perm = (order * 17) % common.streams_per_connection;
            const id: u31 = @intCast(stream_index_perm * 2 + 1);
            const body = fixture.body(stream_index_perm);
            if (body == 0) {
                try store.get(id).?.stream.remoteHeaders(true);
            } else {
                try store.get(id).?.stream.remoteHeaders(false);
                var left = body;
                while (left != 0) {
                    const n = @min(left, common.data_chunk);
                    left -= n;
                    const slot = store.get(id).?;
                    try slot.windows.receiveData(n);
                    try slot.stream.remoteData(left == 0);
                    try slot.windows.creditReceive(@intCast(n));
                }
            }
            store.remove(id);
            tx += 1;
        }
    }
    common.print("stream raw multiplex lifecycle", @intCast(now(io) - start), tx);
    std.mem.doNotOptimizeAway(&peer);
}
