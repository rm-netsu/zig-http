const std = @import("std");
const http = @import("http");

pub fn main() !void {
    const Conn = http.high_level.http1.Connection(.{
        .head_bytes = 1024,
        .chunk_line_bytes = 256,
        .max_in_flight = 8,
        .outbound_fields = 8,
    });

    var client_storage: Conn.Storage = undefined;
    var client = Conn.initClientInPlace(&client_storage);
    defer client.deinit();
    var server_storage: Conn.Storage = undefined;
    var server = Conn.initServerInPlace(&server_storage);
    defer server.deinit();

    var request_storage: [1024]u8 = undefined;
    var request_wire = std.Io.Writer.fixed(&request_storage);
    _ = try client.sendRequest(
        &request_wire,
        http.http1.message.RequestFields.origin("GET", "/status", "example.com"),
        &.{http.http1.message.header("accept", "text/plain")},
    );

    const request_bytes = request_wire.buffered();
    const received_request = try server.receive(request_bytes);
    const request_head = received_request.event.?.head;
    std.debug.assert(request_head.message_done);
    std.debug.assert(std.mem.eql(u8, request_head.effective_authority.?, "example.com"));

    var response_storage: [1024]u8 = undefined;
    var response_wire = std.Io.Writer.fixed(&response_storage);
    var response_length = http.http1.message.ContentLength.init(2);
    _ = try server.sendResponse(
        &response_wire,
        http.http1.message.ResponseFields.init(200, "OK"),
        &.{response_length.header()},
    );
    _ = try server.writeData(&response_wire, "ok");

    const Handler = struct {
        saw_head: bool = false,
        saw_body: bool = false,

        pub fn onEvent(self: *@This(), event: http.http1.Event) http.high_level.http1.DrainAction {
            switch (event) {
                .head => self.saw_head = true,
                .data => |data| if (data.message_done and std.mem.eql(u8, data.bytes, "ok")) {
                    self.saw_body = true;
                },
                else => {},
            }
            return .continue_;
        }
    };
    var handler: Handler = .{};
    const drained = try client.drain(response_wire.buffered(), &handler);
    std.debug.assert(drained.consumed == response_wire.buffered().len);
    std.debug.assert(handler.saw_head and handler.saw_body);
    std.debug.assert(client.pendingResponses() == 0);
}
