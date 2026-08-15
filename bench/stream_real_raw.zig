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
    const start = now(io);
    var tx: u64 = 0;
    var round: usize = 0;
    while (round < common.rounds) : (round += 1) {
        var store: common.Store = .{};
        var stream_index: usize = 0;
        while (stream_index < common.streams_per_connection) : (stream_index += 1) {
            const id: u31 = @intCast(stream_index * 2 + 1);
            var tracked = http.http2.stream.Tracked.init(65_535, 65_535);
            try tracked.stream.localHeaders(true);
            _ = store.insert(id, tracked) orelse return error.StoreFull;
            try common.consumeBodyRaw(&store, id, fixture.body(stream_index));
            store.remove(id);
            tx += 1;
        }
    }
    common.print("stream raw lifecycle", @intCast(now(io) - start), tx);
}
