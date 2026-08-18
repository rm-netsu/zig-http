const std = @import("std");
const http = @import("http");

const net = std.Io.net;
const h1 = http.http1;

const server_address = "127.0.0.1";
const server_port = 18080;
const server_authority = "127.0.0.1:18080";

const Conn = http.high_level.http1.Connection(.{
    .head_bytes = 8 * 1024,
    .chunk_line_bytes = 1024,
    .max_in_flight = 8,
    .outbound_fields = 16,
});

const hello_body = "hello from zig-http\n";

const ClientState = struct {
    response_index: usize = 0,
    hello: [64]u8 = undefined,
    hello_len: usize = 0,
    echo: [64]u8 = undefined,
    echo_len: usize = 0,

    fn append(self: *ClientState, bytes: []const u8) !void {
        const target, const len = if (self.response_index == 0)
            .{ self.hello[0..], &self.hello_len }
        else
            .{ self.echo[0..], &self.echo_len };
        if (bytes.len > target.len - len.*) return error.ResponseBodyTooLarge;
        @memcpy(target[len.* .. len.* + bytes.len], bytes);
        len.* += bytes.len;
    }

    fn onEvent(self: *ClientState, event: h1.Event) !void {
        switch (event) {
            .head => |head_event| {
                const response = switch (head_event.head.start) {
                    .response => |value| value,
                    else => unreachable,
                };
                if (!head_event.informational and response.status != 200) return error.UnexpectedStatus;
                if (!head_event.informational and head_event.message_done) self.response_index += 1;
            },
            .data => |data| {
                try self.append(data.bytes);
                if (data.message_done) self.response_index += 1;
            },
            .trailer => {},
            .message_end => self.response_index += 1,
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const address = try net.IpAddress.parse(server_address, server_port);
    var stream = try address.connect(init.io, .{ .mode = .stream });
    defer stream.close(init.io);

    var socket_read_storage: [8 * 1024]u8 = undefined;
    var socket_write_storage: [8 * 1024]u8 = undefined;
    var socket_reader = stream.reader(init.io, &socket_read_storage);
    var socket_writer = stream.writer(init.io, &socket_write_storage);
    const in = &socket_reader.interface;
    const out = &socket_writer.interface;

    var connection_storage: Conn.Storage = undefined;
    var client = Conn.initClientInPlace(&connection_storage);
    defer client.deinit();

    // Deliberately pipeline both requests before reading either response.
    _ = try client.sendRequest(
        out,
        h1.message.RequestFields.origin("GET", "/hello", server_authority),
        &.{},
    );

    var request_length = h1.message.ContentLength.init(5);
    _ = try client.sendRequest(
        out,
        h1.message.RequestFields.origin("POST", "/echo", server_authority),
        &.{ request_length.header(), h1.message.header("connection", "close") },
    );
    _ = try client.writeData(out, "hello");
    try out.flush();

    var wire: [16 * 1024]u8 = undefined;
    var used: usize = 0;
    var state: ClientState = .{};

    while (client.pendingResponses() != 0) {
        if (used == wire.len) return error.InputBufferTooSmall;
        var destinations = [1][]u8{wire[used..]};
        const n = in.readVec(&destinations) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (n == 0) {
            if (try client.finishReceive()) |event| try state.onEvent(event);
            break;
        }
        used += n;

        var consumed: usize = 0;
        while (consumed < used) {
            const result = try client.receive(wire[consumed..used]);
            consumed += result.consumed;
            if (result.event) |event| try state.onEvent(event);
            if (result.consumed == 0 and result.event == null) break;
        }
        if (consumed != 0) {
            const remaining = used - consumed;
            std.mem.copyForwards(u8, wire[0..remaining], wire[consumed..used]);
            used = remaining;
        }
    }

    if (!std.mem.eql(u8, state.hello[0..state.hello_len], hello_body)) return error.InvalidHelloBody;
    if (!std.mem.eql(u8, state.echo[0..state.echo_len], "hello")) return error.InvalidEchoBody;

    var stdout_storage: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_storage);
    try stdout.interface.writeAll("HTTP/1.1 client: PASS\n");
    try stdout.interface.flush();
}
