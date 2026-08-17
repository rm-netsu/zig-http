const std = @import("std");
const http = @import("http");
const fixed_store = @import("support/fixed_stream_store.zig");

const h2 = http.http2;
const Store = fixed_store.FixedStreamStore(4);

const ApplicationTrailers = struct {
    pub fn allows(_: @This(), name: []const u8) bool {
        return std.mem.eql(u8, name, "x-checksum");
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var decoder = h2.hpack.Decoder.init(allocator, 4096);
    defer decoder.deinit();
    var encoder = h2.hpack.Encoder.init(allocator, 4096);
    defer encoder.deinit();
    var header_storage: [4096]u8 = undefined;
    var session = h2.Session.init(.{
        .role = .server,
        .decoder = &decoder,
        .encoder = &encoder,
        .header_storage = &header_storage,
    });
    var store: Store = .{};

    // Model a request whose peer side is already closed so the server can send
    // a response followed by trailers.
    std.debug.assert(session.streams.receiveHeaders(&store, 1, true) == .accepted);

    var wire_storage: [4096]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    var staging: [1024]u8 = undefined;

    _ = try session.sendHeaders(&store, &wire, 1, false, &staging, &.{
        .{ .field = .{ .name = ":status", .value = "200" } },
        .{ .field = .{ .name = "content-type", .value = "text/plain" } },
    });
    _ = try session.sendData(&store, &wire, 1, "ok", false);

    const trailers = [_]h2.hpack.EncodedField{
        .{ .field = .{ .name = "x-checksum", .value = "demo" } },
    };

    // Composed sending is fail-closed. Non-empty trailers need an explicit
    // application/domain policy because core cannot know every field's
    // registered trailer semantics.
    const before = wire.buffered().len;
    if (session.sendHeaders(&store, &wire, 1, true, &staging, &trailers)) |_| {
        return error.ExpectedTrailerPolicyRequired;
    } else |err| switch (err) {
        error.TrailerPolicyRequired => {},
        else => return err,
    }
    std.debug.assert(wire.buffered().len == before);

    _ = try session.sendTrailers(
        &store,
        &wire,
        1,
        &staging,
        &trailers,
        ApplicationTrailers{},
    );
    std.debug.assert(store.get(1).?.stream.state == .closed);
}
