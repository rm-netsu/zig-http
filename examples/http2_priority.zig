const std = @import("std");
const http = @import("http");

const priority = http.http2.priority;

pub fn main() !void {
    const parameters = try priority.parseFieldValue("u=1, i, vendor=\"opaque\"");
    var state = priority.State.initRequest(parameters);
    std.debug.assert(state.effective().urgency == 1);
    std.debug.assert(state.effective().incremental);

    // Response omission preserves the corresponding client-provided parameter.
    try state.overlayResponseField("u=0");
    std.debug.assert(state.effective().urgency == 0);
    std.debug.assert(state.effective().incremental);

    // PRIORITY_UPDATE is a complete replacement; omitted `i` returns to false.
    try state.setUpdateField("u=2");
    std.debug.assert(state.effective().urgency == 2);
    std.debug.assert(!state.effective().incremental);

    var field_storage: [64]u8 = undefined;
    var field_writer = std.Io.Writer.fixed(&field_storage);
    try priority.writeFieldValue(&field_writer, .{ .urgency = 2, .incremental = true });

    var frame_storage: [128]u8 = undefined;
    var frame_writer = std.Io.Writer.fixed(&frame_storage);
    try priority.writeUpdateParameters(&frame_writer, 1, .{ .urgency = 2, .incremental = true });
    std.debug.assert(frame_writer.buffered().len > 9);
}
