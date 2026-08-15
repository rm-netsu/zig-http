const std = @import("std");
const http = @import("http");
const shared = @import("scheduler_real.zig");

pub fn main(init: std.process.Init) !void {
    const seed = try shared.runtimeSeed(init);
    var ctx: shared.Context = undefined;
    try ctx.init(std.heap.page_allocator, seed);
    defer ctx.deinit();

    var scheduler: http.http2.scheduler.RoundRobin = .{ .cursor = seed % shared.streams_per_connection };
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(init.io).nanoseconds;
    for (0..shared.rounds) |round| {
        shared.setConnectionPhase(&ctx, round);
        if (scheduler.nextAssumeValid(&ctx.session, &ctx.store, &ctx.candidates)) |ready| {
            checksum +%= @as(u64, ready.stream_id) *% 131 +% ready.amount +% ready.index;
        } else {
            checksum +%= 17;
        }
    }
    const elapsed: u64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds - start);
    std.mem.doNotOptimizeAway(&ctx);
    std.mem.doNotOptimizeAway(checksum);
    shared.print("scheduler round robin", elapsed, shared.rounds, checksum);
}
