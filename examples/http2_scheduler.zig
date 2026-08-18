const std = @import("std");
const http = @import("http");

pub fn main() !void {
    const h2 = http.http2;
    const Conn = http.high_level.http2.Connection(.{
        .max_streams = 8,
        .header_block_bytes = 1024,
        .scratch_bytes = 1024,
        .frame_staging_bytes = 1024,
        .collected_fields = 8,
        .collected_field_bytes = 512,
        .outbound_fields = 8,
    });

    var conn = try Conn.initClient(std.heap.page_allocator);
    defer conn.deinit();

    var wire_storage: [4096]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try conn.start(&wire);
    _ = try conn.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/critical"), &.{}, false);
    _ = try conn.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/background"), &.{}, false);

    const candidates = [_]h2.scheduler.PriorityCandidate{
        .{ .stream_id = 1, .remaining = 32 * 1024, .priority = .{ .urgency = 0, .incremental = false } },
        .{ .stream_id = 3, .remaining = 32 * 1024, .priority = .{ .urgency = 5, .incremental = true } },
    };
    var scheduler: h2.scheduler.Urgency = .{};
    const decision = try scheduler.next(conn.core(), conn.store(), &candidates);
    std.debug.assert(decision.ready.stream_id == 1);
}
