const std = @import("std");
const http = @import("http");
const common = @import("send_offer_real.zig");
const Io = std.Io;

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const fixture = common.Fixture.init();
    var chunks: u64 = 0;
    const start = now(io);
    var round: usize = 0;
    while (round < common.rounds) : (round += 1) {
        var store: common.Store = .{};
        var manager = http.http2.streams.Manager.init(.client, .{});
        var peer = http.http2.peer.State.init(.client);
        var stream_index: usize = 0;
        while (stream_index < common.streams_per_connection) : (stream_index += 1) {
            const id: u31 = @intCast(stream_index * 2 + 1);
            try manager.openLocal(&store, &peer, id, false);
            const existing = manager.existing(&store, id) orelse return error.MissingStream;
            if (existing.receiveHeaders(true) != .accepted) return error.Protocol;
            const detached = existing.detached();
            var left = common.body(&fixture, stream_index);
            while (left != 0) {
                const stream_credit = try detached.dataSendCredit(peer.settings.initial_window_size);
                const max_payload = @min(
                    stream_credit,
                    peer.send_window.available(),
                    @as(u31, @intCast(peer.settings.max_frame_size)),
                );
                if (max_payload == 0) return error.FlowControl;
                const amount: u31 = @intCast(@min(@as(u32, max_payload), left));
                left -= amount;
                try peer.consumeSend(amount);
                const effect = detached.localDataAssumeCredit(peer.settings.initial_window_size, amount, left == 0);
                if (!effect.empty()) manager.commitStreamEffect(id, effect);
                try peer.send_window.update(amount);
                if (left != 0) {
                    const update = detached.receiveWindowUpdate(peer.settings.initial_window_size, amount);
                    if (update.result != .accepted) return error.FlowControl;
                    if (!update.effect.empty()) manager.commitStreamEffect(id, update.effect);
                }
                chunks += 1;
            }
            store.remove(id);
        }
    }
    common.print("manual split DATA credit", @intCast(now(io) - start), chunks);
}
