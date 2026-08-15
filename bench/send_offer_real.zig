const std = @import("std");
const common = @import("stream_real.zig");

pub const rounds: usize = 250_000;
pub const streams_per_connection: usize = common.streams_per_connection;
pub const data_chunk: u32 = common.data_chunk;
pub const Fixture = common.Fixture;
pub const Store = common.Store;

pub inline fn body(fixture: *const Fixture, index: usize) u32 {
    return @max(fixture.body(index), 1);
}

pub fn print(label: []const u8, elapsed_ns: u64, chunks: u64) void {
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const rate = @as(f64, @floatFromInt(chunks)) / seconds;
    std.debug.print("{s}: {d:.3} M chunks/s ({d} chunks, {d:.3} s)\n", .{ label, rate / 1_000_000.0, chunks, seconds });
}
