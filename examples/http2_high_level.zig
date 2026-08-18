const std = @import("std");
const http = @import("http");

const h2 = http.http2;
const Connection = http.high_level.http2.Connection(.{
    .max_streams = 8,
    .header_block_bytes = 4096,
    .scratch_bytes = 4096,
    .frame_staging_bytes = 1024,
    .collected_fields = 16,
    .collected_field_bytes = 4096,
    .outbound_fields = 16,
});

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var client_storage: Connection.Storage = undefined;
    var client = Connection.initClientInPlace(&client_storage, allocator);
    defer client.deinit();
    var server_storage: Connection.Storage = undefined;
    var server = Connection.initServerInPlace(&server_storage, allocator);
    defer server.deinit();

    var c2s_storage: [8192]u8 = undefined;
    var c2s = std.Io.Writer.fixed(&c2s_storage);
    _ = try client.start(&c2s);
    const sent = try client.sendRequest(
        &c2s,
        h2.message.RequestFields.init("GET", "https", "example.com", "/status"),
        &.{h2.message.header("accept", "text/plain")},
        true,
    );

    var s2c_storage: [8192]u8 = undefined;
    var s2c = std.Io.Writer.fixed(&s2c_storage);
    _ = try server.start(&s2c);

    var offset: usize = 0;
    while (offset < c2s.buffered().len) {
        const received = (try server.receive(c2s.buffered()[offset..])) orelse break;
        if (received.consumed == 0) break;
        offset += received.consumed;
        if (received.event) |event| switch (event) {
            .settings => {},
            .headers => |section| {
                std.debug.assert(section.stream_id == sent.stream_id);
                const copied = received.fields orelse return error.MissingFields;
                std.debug.assert(copied.headers.len == 5);

                var response = try h2.message.ResponseFields.init(200);
                var response_length = h2.message.ContentLength.init(2);
                _ = try server.sendResponse(
                    &s2c,
                    section.stream_id,
                    &response,
                    &.{response_length.field()},
                    false,
                );
                _ = try server.sendData(&s2c, section.stream_id, "ok", true);
            },
            else => {},
        };
        try server.sendControl(&s2c, received.control);
    }

    std.debug.assert(s2c.buffered().len != 0);
}
