const std = @import("std");
const http = @import("http");

/// Demonstrates only the protocol core. A real client owns the socket/TLS layer
/// and feeds its transport writer/reader into these objects.
pub fn main() !void {
    var request_storage: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&request_storage);
    var message = http.http1.MessageWriter.init();

    const started = try message.beginRequest(
        &out,
        .http_1_1,
        "POST",
        "/items",
        &.{
            .{ .name = "host", .value = "example.com" },
            .{ .name = "content-length", .value = "5" },
            .{ .name = "content-type", .value = "text/plain" },
        },
    );
    std.debug.assert(!started.message_done);
    const sent = try message.writeData(&out, "hello");
    std.debug.assert(sent.message_done and message.ready());

    // Response parsing needs the outstanding request method so HEAD/CONNECT
    // semantics remain correct without the decoder owning a request queue.
    var head_storage: [1024]u8 = undefined;
    var chunk_storage: [128]u8 = undefined;
    var decoder = http.http1.ConnectionDecoder.initResponse(&head_storage, &chunk_storage, .{});
    try decoder.beginResponse("POST");

    const response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    var offset: usize = 0;
    var body_bytes: usize = 0;
    while (offset < response.len) {
        const result = try decoder.feed(response[offset..]);
        offset += result.consumed;
        if (result.event) |event| switch (event) {
            .data => |data| body_bytes += data.bytes.len,
            else => {},
        };
        if (result.consumed == 0 and result.event == null) break;
    }
    std.debug.assert(body_bytes == 2);
}
