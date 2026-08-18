const std = @import("std");
const http = @import("http");
const counting_sink = @import("support/counting_field_sink.zig");

const h2 = http.http2;
const Store = h2.storage.FixedStreamStore(8);

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Produce one peer request in memory. In production these bytes come from
    // the caller-owned transport buffer after the HTTP/2 connection preface.
    var client_decoder = h2.hpack.Decoder.init(allocator, 4096);
    defer client_decoder.deinit();
    var client_encoder = h2.hpack.Encoder.init(allocator, 4096);
    defer client_encoder.deinit();
    var client_headers: [4096]u8 = undefined;
    var client = h2.Session.init(.{ .role = .client, .decoder = &client_decoder, .encoder = &client_encoder, .header_storage = &client_headers });
    var client_bootstrap = h2.Bootstrap.init(.client);
    var client_settings: h2.session.SettingsSync = .{};
    var client_store: Store = .{};
    var wire_storage: [4096]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client_bootstrap.start(&client, &client_settings, &wire, &.{});
    var staging: [1024]u8 = undefined;
    _ = try client.sendHeaders(&client_store, &wire, 1, true, &staging, &.{
        .{ .field = .{ .name = ":method", .value = "GET" } },
        .{ .field = .{ .name = ":scheme", .value = "https" } },
        .{ .field = .{ .name = ":authority", .value = "example.com" } },
        .{ .field = .{ .name = ":path", .value = "/" } },
    });

    var server_decoder = h2.hpack.Decoder.init(allocator, 4096);
    defer server_decoder.deinit();
    var server_encoder = h2.hpack.Encoder.init(allocator, 4096);
    defer server_encoder.deinit();
    var server_headers: [4096]u8 = undefined;
    var server = h2.Session.init(.{ .role = .server, .decoder = &server_decoder, .encoder = &server_encoder, .header_storage = &server_headers });
    var server_bootstrap = h2.Bootstrap.init(.server);
    var server_settings: h2.session.SettingsSync = .{};
    var server_store: Store = .{};
    var sink: counting_sink.CountingFieldSink = .{};
    var scratch: [4096]u8 = undefined;
    var response_storage: [4096]u8 = undefined;
    var response = std.Io.Writer.fixed(&response_storage);
    _ = try server_bootstrap.start(&server, &server_settings, &response, &.{});

    var offset: usize = 0;
    const initial = (try server_bootstrap.receiveBytes(
        &server,
        &server_store,
        wire.buffered(),
        h2.frame.default_max_frame_size,
        &scratch,
        &sink,
    )) orelse return error.IncompleteFrame;
    offset += initial.consumed;
    switch (initial.event orelse return error.ExpectedSettings) {
        .settings => |applied| if (!applied.ack) try server.sendSettingsAck(&response),
        else => return error.ExpectedSettings,
    }

    const received = (try server_bootstrap.receiveBytes(
        &server,
        &server_store,
        wire.buffered()[offset..],
        h2.frame.default_max_frame_size,
        &scratch,
        &sink,
    )) orelse return error.IncompleteFrame;
    switch (received.event orelse return error.ExpectedHeaders) {
        .headers => |headers| {
            std.debug.assert(headers.stream_id == 1);
            std.debug.assert(headers.end_stream);
        },
        else => return error.ExpectedHeaders,
    }
    std.debug.assert(sink.requests == 4);

    _ = try server.sendHeaders(&server_store, &response, 1, false, &staging, &.{
        .{ .field = .{ .name = ":status", .value = "200" } },
        .{ .field = .{ .name = "content-length", .value = "2" } },
    });
    const data = try server.sendData(&server_store, &response, 1, "ok", true);
    std.debug.assert(data.end_stream);
}
