const std = @import("std");
const http = @import("http");

pub fn main() !void {
    var head_storage: [1024]u8 = undefined;
    var chunk_storage: [128]u8 = undefined;
    var decoder = http.http1.ConnectionDecoder.initRequest(&head_storage, &chunk_storage, .{});

    const request = "GET /health HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const received = try decoder.feed(request);
    const event = received.event orelse return error.ExpectedRequestHead;
    const request_head = switch (event) {
        .head => |value| value,
        else => return error.ExpectedRequestHead,
    };
    std.debug.assert(request_head.message_done);

    var response_storage: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&response_storage);
    var message = http.http1.MessageWriter.init();
    const started = try message.beginResponse(
        &out,
        .http_1_1,
        200,
        "OK",
        "GET",
        &.{
            .{ .name = "content-length", .value = "2" },
            .{ .name = "content-type", .value = "text/plain" },
        },
    );
    std.debug.assert(!started.message_done);
    const sent = try message.writeData(&out, "ok");
    std.debug.assert(sent.message_done and message.ready());
}
