const std = @import("std");
const http = @import("http");

const h2 = http.http2;
const Store = h2.storage.FixedStreamStore(8);

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var decoder = h2.hpack.Decoder.init(allocator, 4096);
    defer decoder.deinit();
    var encoder = h2.hpack.Encoder.init(allocator, 4096);
    defer encoder.deinit();

    var header_storage: [16 * 1024]u8 = undefined;
    var session = h2.Session.init(.{
        .role = .client,
        .decoder = &decoder,
        .encoder = &encoder,
        .header_storage = &header_storage,
    });
    var bootstrap = h2.Bootstrap.init(.client);
    var settings_sync: h2.session.SettingsSync = .{};
    var store: Store = .{};

    var wire_storage: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&wire_storage);
    _ = try bootstrap.start(&session, &settings_sync, &out, &.{});
    var staging: [1024]u8 = undefined;
    const request = [_]h2.hpack.EncodedField{
        .{ .field = .{ .name = ":method", .value = "GET" } },
        .{ .field = .{ .name = ":scheme", .value = "https" } },
        .{ .field = .{ .name = ":authority", .value = "example.com" } },
        .{ .field = .{ .name = ":path", .value = "/" } },
        .{ .field = .{ .name = "priority", .value = "u=1, i" } },
    };

    _ = try session.sendHeaders(&store, &out, 1, true, &staging, &request);
    std.debug.assert(store.get(1) != null);
    std.debug.assert(out.buffered().len != 0);
}
