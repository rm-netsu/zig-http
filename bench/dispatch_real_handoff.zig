const std = @import("std");
const http = @import("http");
const common = @import("dispatch_real.zig");
const Io = std.Io;

const Work = struct {
    stream_id: u31,
    end_stream: bool,
    flow_charge: [3]u8,
    bytes: []const u8,

    inline fn charged(self: Work) u32 {
        return (@as(u32, self.flow_charge[0]) << 16) |
            (@as(u32, self.flow_charge[1]) << 8) |
            self.flow_charge[2];
    }
};

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
                    const bytes = try http.http2.payload.data(complete.header, complete.payload);
                    const work: Work = .{
                        .stream_id = id,
                        .end_stream = left == 0,
                        .flow_charge = .{
                            @intCast((complete.header.length >> 16) & 0xff),
                            @intCast((complete.header.length >> 8) & 0xff),
                            @intCast(complete.header.length & 0xff),
                        },
                        .bytes = bytes,
                    };
                    std.mem.doNotOptimizeAway(work.bytes.ptr);
                    const applied = detached.receiveData(work.charged(), work.end_stream);
                    if (applied.result != .accepted) return error.Protocol;
                    if (!applied.effect.empty()) manager.commitStreamEffect(id, applied.effect);
                    const charge = work.charged();
                    try conn.creditReceive(@intCast(charge));
                    try detached.tracked.windows.creditReceive(@intCast(charge));
                    frames += 1;
                }
            }
            store.remove(id);
        }
        std.mem.doNotOptimizeAway(&peer);
    }
    common.print("manual 24-byte handoff DATA", @intCast(now(io) - start), frames);
}
