const std = @import("std");
const http = @import("http");

const priority = http.http2.priority;

pub fn main() !void {
    const parameters = try priority.parseFieldValue("u=1, i, vendor=\"opaque\"");
    const effective = parameters.effective();
    std.debug.assert(effective.urgency == 1);
    std.debug.assert(effective.incremental);

    var field_storage: [64]u8 = undefined;
    var field_writer = std.Io.Writer.fixed(&field_storage);
    try priority.writeFieldValue(&field_writer, .{ .urgency = 2, .incremental = true });

    var frame_storage: [128]u8 = undefined;
    var frame_writer = std.Io.Writer.fixed(&frame_storage);
    try priority.writeUpdateParameters(&frame_writer, 1, .{ .urgency = 2, .incremental = true });
    std.debug.assert(frame_writer.buffered().len > 9);
}
