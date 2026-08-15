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
            const cursor = manager.existing(&store, id) orelse return error.MissingStream;
            const body = fixture.body(stream_index);
            if (body == 0) {
                if (cursor.receiveHeaders(true) != .accepted) return error.Protocol;
            } else {
                if (cursor.receiveHeaders(false) != .accepted) return error.Protocol;
                var left = body;
                while (left != 0) {
                    const n = @min(left, common.data_chunk);
                    left -= n;
                    if (cursor.receiveData(n, left == 0) != .accepted) return error.Protocol;
                    try cursor.tracked.windows.creditReceive(@intCast(n));
                }
            }
            store.remove(id);
            tx += 1;
        }
    }
    common.print("stream managed tracked lifecycle", @intCast(now(io) - start), tx);
    std.mem.doNotOptimizeAway(&peer);
}
