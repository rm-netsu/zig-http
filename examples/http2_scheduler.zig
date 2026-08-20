const std = @import("std");
const http = @import("http");

pub fn main() !void {
    const h2 = http.http2;

    var decoder = h2.hpack.Decoder.init(std.heap.page_allocator, 4096);
    defer decoder.deinit();
    var encoder = h2.hpack.Encoder.init(std.heap.page_allocator, 4096);
    defer encoder.deinit();
    var header_storage: [1024]u8 = undefined;
    var session = h2.Session.init(.{
        .role = .client,
        .decoder = &decoder,
        .encoder = &encoder,
        .header_storage = &header_storage,
    });
    var store: h2.storage.FixedStreamStore(8) = .{};
    var staging: [1024]u8 = undefined;
    var fields_storage: [8]h2.hpack.EncodedField = undefined;

    var wire_storage: [4096]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    const critical = try h2.message.RequestFields.init("GET", "https", "example.com", "/critical").build(&fields_storage, &.{});
    _ = try session.sendHeaders(&store, &wire, 1, false, &staging, critical);
    const background = try h2.message.RequestFields.init("GET", "https", "example.com", "/background").build(&fields_storage, &.{});
    _ = try session.sendHeaders(&store, &wire, 3, false, &staging, background);

    const candidates = [_]h2.scheduler.PriorityCandidate{
        .{ .stream_id = 1, .remaining = 32 * 1024, .priority = .{ .urgency = 0, .incremental = false } },
        .{ .stream_id = 3, .remaining = 32 * 1024, .priority = .{ .urgency = 5, .incremental = true } },
    };
    var scheduler: h2.scheduler.Urgency = .{};
    const decision = try scheduler.next(&session, &store, &candidates);
    std.debug.assert(decision.ready.stream_id == 1);
}
