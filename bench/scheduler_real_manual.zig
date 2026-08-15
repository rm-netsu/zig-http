const std = @import("std");
const shared = @import("scheduler_real.zig");

pub fn main(init: std.process.Init) !void {
    const seed = try shared.runtimeSeed(init);
    var ctx: shared.Context = undefined;
    try ctx.init(std.heap.page_allocator, seed);
    defer ctx.deinit();

    var cursor = seed % shared.streams_per_connection;
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(init.io).nanoseconds;
    for (0..shared.rounds) |round| {
        shared.setConnectionPhase(&ctx, round);
        const connection_blocked = ctx.session.peer.send_window.available() == 0;
        var index = cursor;
        var visited: usize = 0;
        while (visited < ctx.candidates.len) : (visited += 1) {
            const candidate = ctx.candidates[index];
            if (candidate.remaining != 0 and !connection_blocked) {
                const tracked = ctx.store.get(candidate.stream_id) orelse return error.MissingStream;
                switch (tracked.stream.state) {
                    .open, .half_closed_remote => {},
                    else => return error.Protocol,
                }
                const available = @min(
                    @as(usize, ctx.session.peer.send_window.available()),
                    @as(usize, tracked.windows.send.available()),
                    @as(usize, ctx.session.peer.settings.max_frame_size),
                );
                if (available != 0) {
                    const amount = @min(candidate.remaining, available);
                    cursor = if (index + 1 == ctx.candidates.len) 0 else index + 1;
                    checksum +%= @as(u64, candidate.stream_id) *% 131 +% amount +% index;
                    break;
                }
            }
            index += 1;
            if (index == ctx.candidates.len) index = 0;
        }
    }
    const elapsed: u64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds - start);
    std.mem.doNotOptimizeAway(&ctx);
    std.mem.doNotOptimizeAway(checksum);
    shared.print("scheduler manual scan", elapsed, shared.rounds, checksum);
}
