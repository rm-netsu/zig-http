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
        var manager = http.http2.streams.Manager.init(.client, .{});
        var stream_index: usize = 0;
        while (stream_index < common.streams_per_connection) : (stream_index += 1) {
            const id: u31 = @intCast(stream_index * 2 + 1);
            try manager.openLocal(&store, &peer, id, true);
            const body = fixture.body(stream_index);
            if (body == 0) {
                const headers = manager.receiveHeaders(&store, id, true);
                if (headers != .accepted) return error.Protocol;
            } else {
                const headers = manager.receiveHeaders(&store, id, false);
                if (headers != .accepted) return error.Protocol;
                var left = body;
                while (left != 0) {
                    const n = @min(left, common.data_chunk);
                    left -= n;
                    const result = manager.receiveData(&store, id, n, left == 0);
                    if (result != .accepted) return error.Protocol;
                    try store.get(id).?.windows.creditReceive(@intCast(n));
                }
            }
            store.remove(id);
            tx += 1;
        }
    }
    common.print("stream managed lifecycle", @intCast(now(io) - start), tx);
    std.debug.print("stream state sizes: Manager={} B, Existing={} B, Tracked={} B, ReceiveResult={} B\n", .{
        @sizeOf(http.http2.streams.Manager),
        @sizeOf(http.http2.streams.Existing),
        @sizeOf(http.http2.stream.Tracked),
        @sizeOf(http.http2.streams.ReceiveResult),
    });
    std.mem.doNotOptimizeAway(&peer);
}
