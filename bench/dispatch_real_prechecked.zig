const std = @import("std");
const http = @import("http");
const common = @import("dispatch_real.zig");
const Io = std.Io;

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const seed: u64 = @bitCast(@as(i64, @truncate(now(io))));
    const fixture = common.Fixture.init(seed);
    var frames: u64 = 0;
    const start = now(io);
    var round: usize = 0;
    while (round < common.rounds) : (round += 1) {
        var store: common.Store = .{};
        var manager = http.http2.streams.Manager.init(.client, .{});
        var peer = http.http2.peer.State.init(.client);
        var conn: http.http2.connection.State = .{};
        var stream_index: usize = 0;
        while (stream_index < common.streams_per_connection) : (stream_index += 1) {
            const id: u31 = @intCast(stream_index * 2 + 1);
            try manager.openLocal(&store, &peer, id, true);
            const existing = manager.existing(&store, id) orelse return error.MissingStream;
            const body = fixture.body(stream_index);
            if (body == 0) {
                if (existing.receiveHeaders(true) != .accepted) return error.Protocol;
            } else {
                if (existing.receiveHeaders(false) != .accepted) return error.Protocol;
                const detached = existing.detached();
                var left = body;
                while (left != 0) {
                    const n = @min(left, common.data_chunk);
                    left -= n;
                    const complete = common.dataFrame(fixture.payload[0..n], id, left == 0);
                    switch (conn.check(complete.header)) {
                        .none => {},
                        else => return error.Protocol,
                    }
                    const work = try http.http2.dispatch.prepareDataAssumeConnectionChecked(complete);
                    const applied = work.apply(detached);
                    if (applied.result != .accepted) return error.Protocol;
                    if (!applied.effect.empty()) manager.commitStreamEffect(id, applied.effect);
                    const charge = work.flowControlledBytes();
                    try conn.creditReceive(@intCast(charge));
                    try detached.tracked.windows.creditReceive(@intCast(charge));
                    frames += 1;
                }
            }
            store.remove(id);
        }
        std.mem.doNotOptimizeAway(&peer);
    }
    common.print("prechecked typed dispatch DATA", @intCast(now(io) - start), frames);
}
