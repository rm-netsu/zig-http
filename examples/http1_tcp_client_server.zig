const std = @import("std");
const http = @import("http");

const net = std.Io.net;
const h1 = http.http1;

const Conn = http.high_level.http1.Connection(.{
    .head_bytes = 8 * 1024,
    .chunk_line_bytes = 1024,
    .max_in_flight = 8,
    .outbound_fields = 16,
});

const hello_body = "hello from zig-http\n";

const RequestState = union(enum) {
    none,
    echo: struct {
        body: [256]u8 = undefined,
        len: usize = 0,
    },
};

fn writeHello(server: *Conn, out: *std.Io.Writer) !void {
    var length = h1.message.ContentLength.init(hello_body.len);
    _ = try server.sendResponse(
        out,
        h1.message.ResponseFields.init(200, "OK"),
        &.{
            h1.message.header("content-type", "text/plain; charset=utf-8"),
            length.header(),
        },
    );
    _ = try server.writeData(out, hello_body);
}

fn writeEcho(server: *Conn, out: *std.Io.Writer, body: []const u8) !void {
    var length = h1.message.ContentLength.init(body.len);
    _ = try server.sendResponse(
        out,
        h1.message.ResponseFields.init(200, "OK"),
        &.{
            h1.message.header("content-type", "application/octet-stream"),
            length.header(),
            h1.message.header("connection", "close"),
        },
    );
    _ = try server.writeData(out, body);
}

fn handleServerEvent(server: *Conn, out: *std.Io.Writer, state: *RequestState, event: h1.Event) !bool {
    switch (event) {
        .head => |head_event| {
            const request = switch (head_event.head.start) {
                .request => |value| value,
                else => unreachable,
            };

            if (std.mem.eql(u8, request.target, "/hello")) {
                if (!head_event.message_done) return error.UnexpectedRequestBody;
                try writeHello(server, out);
                try out.flush();
                return false;
            }

            if (std.mem.eql(u8, request.target, "/echo")) {
                state.* = .{ .echo = .{} };
                if (head_event.message_done) {
                    try writeEcho(server, out, "");
                    try out.flush();
                    return true;
                }
                return false;
            }

            var length = h1.message.ContentLength.init(0);
            _ = try server.sendResponse(
                out,
                h1.message.ResponseFields.init(404, "Not Found"),
                &.{ length.header(), h1.message.header("connection", "close") },
            );
            try out.flush();
            return true;
        },
        .data => |data| switch (state.*) {
            .echo => |*echo| {
                if (data.bytes.len > echo.body.len - echo.len) return error.RequestBodyTooLarge;
                @memcpy(echo.body[echo.len .. echo.len + data.bytes.len], data.bytes);
                echo.len += data.bytes.len;
                if (data.message_done) {
                    try writeEcho(server, out, echo.body[0..echo.len]);
                    try out.flush();
                    state.* = .none;
                    return true;
                }
            },
            .none => return error.UnexpectedRequestBody,
        },
        .trailer => {},
        .message_end => switch (state.*) {
            .echo => |*echo| {
                try writeEcho(server, out, echo.body[0..echo.len]);
                try out.flush();
                state.* = .none;
                return true;
            },
            .none => {},
        },
    }
    return false;
}

fn serveOne(io: std.Io, listener: *net.Server) !void {
    var stream = try listener.accept(io);
    defer stream.close(io);

    var socket_read_storage: [8 * 1024]u8 = undefined;
    var socket_write_storage: [8 * 1024]u8 = undefined;
    var socket_reader = stream.reader(io, &socket_read_storage);
    var socket_writer = stream.writer(io, &socket_write_storage);
    const in = &socket_reader.interface;
    const out = &socket_writer.interface;

    var connection_storage: Conn.Storage = undefined;
    var server = Conn.initServerInPlace(&connection_storage);
    defer server.deinit();

    var wire: [16 * 1024]u8 = undefined;
    var used: usize = 0;
    var request_state: RequestState = .none;
    var done = false;

    while (!done) {
        if (used == wire.len) return error.InputBufferTooSmall;
        var destinations = [1][]u8{wire[used..]};
        const n = in.readVec(&destinations) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (n == 0) {
            _ = try server.finishReceive();
            return;
        }
        used += n;

        var consumed: usize = 0;
        while (consumed < used and !done) {
            const result = try server.receive(wire[consumed..used]);
            consumed += result.consumed;
            if (result.event) |event| done = try handleServerEvent(&server, out, &request_state, event);
            if (result.consumed == 0 and result.event == null) break;
        }

        if (consumed != 0) {
            const remaining = used - consumed;
            std.mem.copyForwards(u8, wire[0..remaining], wire[consumed..used]);
            used = remaining;
        }
    }
}

fn serverThread(io: std.Io, listener: *net.Server) void {
    serveOne(io, listener) catch |err| std.debug.panic("HTTP/1 example server failed: {t}", .{err});
}

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

fn runClient(io: std.Io, address: net.IpAddress) !void {
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var socket_read_storage: [8 * 1024]u8 = undefined;
    var socket_write_storage: [8 * 1024]u8 = undefined;
    var socket_reader = stream.reader(io, &socket_read_storage);
    var socket_writer = stream.writer(io, &socket_write_storage);
    const in = &socket_reader.interface;
    const out = &socket_writer.interface;

    var connection_storage: Conn.Storage = undefined;
    var client = Conn.initClientInPlace(&connection_storage);
    defer client.deinit();

    // Two requests are deliberately pipelined before either response is read.
    _ = try client.sendRequest(
        out,
        h1.message.RequestFields.origin("GET", "/hello", "127.0.0.1"),
        &.{},
    );

    var request_length = h1.message.ContentLength.init(5);
    _ = try client.sendRequest(
        out,
        h1.message.RequestFields.origin("POST", "/echo", "127.0.0.1"),
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
}

pub fn main(init: std.process.Init) !void {
    const bind = try net.IpAddress.parse("127.0.0.1", 0);
    var listener = try bind.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);

    const thread = try std.Thread.spawn(.{}, serverThread, .{ init.io, &listener });
    try runClient(init.io, listener.socket.address);
    thread.join();

    var stdout_storage: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_storage);
    try stdout.interface.writeAll("HTTP/1 loopback client/server example: PASS\n");
    try stdout.interface.flush();
}
