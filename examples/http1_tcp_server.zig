const std = @import("std");
const http = @import("http");

const net = std.Io.net;
const h1 = http.http1;

const listen_address = "127.0.0.1";
const listen_port = 18080;

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

fn handleEvent(server: *Conn, out: *std.Io.Writer, state: *RequestState, event: h1.Event) !bool {
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

fn serveConnection(io: std.Io, stream: *net.Stream) !void {
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
            if (result.event) |event| done = try handleEvent(&server, out, &request_state, event);
            if (result.consumed == 0 and result.event == null) break;
        }

        if (consumed != 0) {
            const remaining = used - consumed;
            std.mem.copyForwards(u8, wire[0..remaining], wire[consumed..used]);
            used = remaining;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const bind = try net.IpAddress.parse(listen_address, listen_port);
    var listener = try bind.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);

    std.log.info("HTTP/1.1 example server listening on {s}:{d}", .{ listen_address, listen_port });

    while (true) {
        var stream = try listener.accept(init.io);
        serveConnection(init.io, &stream) catch |err| {
            std.log.err("HTTP/1.1 connection failed: {t}", .{err});
        };
        stream.close(init.io);
    }
}
