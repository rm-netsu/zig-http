const std = @import("std");
const bench = @import("frame_real.zig");

pub fn main(init: std.process.Init) !void {
    try bench.run(init, .connection_fragmented);
}
