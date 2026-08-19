const std = @import("std");
const http = @import("http");

const net = std.Io.net;
const h2 = http.http2;

const Conn = http.high_level.http2.Connection(.{
    .max_streams = 8,
    .header_block_bytes = 8 * 1024,
    .scratch_bytes = 8 * 1024,
    .frame_staging_bytes = 8 * 1024,
    .collected_fields = 32,
    .collected_field_bytes = 8 * 1024,
    .outbound_fields = 16,
    .local_settings = .{
        .max_concurrent_streams = 8,
        .max_header_list_size = 16 * 1024,
    },
});

const hello_body = "hello from zig-http/2\n";

const listen_address = "127.0.0.1";
const listen_port = 18081;

fn fieldValue(fields: []const http.common.Header, name: []const u8) ?[]const u8 {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

const ServerState = struct {
    echo_stream: ?u31 = null,
    echo_body: [256]u8 = undefined,
    echo_len: usize = 0,
    responses: usize = 0,
    last_stream_id: u31 = 0,
};

fn sendHello(server: *Conn, out: *std.Io.Writer, stream_id: u31) !void {
    var response = try h2.message.ResponseFields.init(200);
    var length = h2.message.ContentLength.init(hello_body.len);
    _ = try server.sendResponse(
        out,
        stream_id,
        &response,
        &.{
            h2.message.header("content-type", "text/plain; charset=utf-8"),
            length.field(),
        },
        false,
    );
    const sent = try server.sendData(out, stream_id, hello_body, true);
    if (sent.blocked or sent.consumed != hello_body.len) return error.UnexpectedFlowControlBlock;
}

fn sendEcho(server: *Conn, out: *std.Io.Writer, stream_id: u31, body: []const u8) !void {
    var response = try h2.message.ResponseFields.init(200);
    var length = h2.message.ContentLength.init(body.len);
    _ = try server.sendResponse(
        out,
        stream_id,
        &response,
        &.{
            h2.message.header("content-type", "application/octet-stream"),
            length.field(),
        },
        false,
    );
    const sent = try server.sendData(out, stream_id, body, true);
    if (sent.blocked or sent.consumed != body.len) return error.UnexpectedFlowControlBlock;
}

fn handleServerResult(server: *Conn, out: *std.Io.Writer, state: *ServerState, result: Conn.ReceiveResult) !void {
    // SETTINGS/PING/fault responses are explicit: receive() never performs I/O.
    try server.sendControl(out, result.control);

    const event = result.event orelse return;
    switch (event) {
        .headers => |headers| {
            if (headers.kind != .request) return error.UnexpectedHeaderSection;
            const copied = result.fields orelse return error.MissingHeaderFields;
            const path = fieldValue(copied.headers, ":path") orelse return error.MissingPath;
            state.last_stream_id = @max(state.last_stream_id, headers.stream_id);

            if (std.mem.eql(u8, path, "/hello")) {
                if (!headers.end_stream) return error.UnexpectedRequestBody;
                try sendHello(server, out, headers.stream_id);
                state.responses += 1;
            } else if (std.mem.eql(u8, path, "/echo")) {
                state.echo_stream = headers.stream_id;
                if (headers.end_stream) {
                    try sendEcho(server, out, headers.stream_id, "");
                    state.responses += 1;
                }
            } else {
                var response = try h2.message.ResponseFields.init(404);
                _ = try server.sendResponse(out, headers.stream_id, &response, &.{}, true);
                state.responses += 1;
            }
        },
        .data => |data| {
            if (state.echo_stream == null or data.stream_id != state.echo_stream.?) return error.UnexpectedRequestBody;
            if (data.bytes.len > state.echo_body.len - state.echo_len) return error.RequestBodyTooLarge;
            @memcpy(state.echo_body[state.echo_len .. state.echo_len + data.bytes.len], data.bytes);
            state.echo_len += data.bytes.len;

            // Application-owned body lifetime ends here; return receive credit.
            server.releaseData(data);
            _ = try server.flushReceiveCredit(out, data.stream_id);

            if (data.end_stream) {
                try sendEcho(server, out, data.stream_id, state.echo_body[0..state.echo_len]);
                state.responses += 1;
            }
        },
        .fault => return error.ProtocolFault,
        else => {},
    }
}

fn serveConnection(io: std.Io, stream: *net.Stream) !void {
    var socket_read_storage: [16 * 1024]u8 = undefined;
    var socket_write_storage: [16 * 1024]u8 = undefined;
    var socket_reader = stream.reader(io, &socket_read_storage);
    var socket_writer = stream.writer(io, &socket_write_storage);
    const in = &socket_reader.interface;
    const out = &socket_writer.interface;

    var connection_storage: Conn.Storage = undefined;
    var server = Conn.initServerInPlace(&connection_storage, std.heap.page_allocator);
    defer server.deinit();

    _ = try server.start(out);
    try out.flush();

    var state: ServerState = .{};
    var wire: [32 * 1024]u8 = undefined;
    var used: usize = 0;

    while (state.responses < 2) {
        if (used == wire.len) return error.InputBufferTooSmall;
        var destinations = [1][]u8{wire[used..]};
        const n = in.readVec(&destinations) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (n == 0) return error.UnexpectedEof;
        used += n;

        var consumed: usize = 0;
        while (consumed < used and state.responses < 2) {
            const result = (try server.receive(wire[consumed..used])) orelse break;
            if (result.consumed == 0 and result.event == null) break;
            consumed += result.consumed;
            try handleServerResult(&server, out, &state, result);
            try out.flush();
        }
        if (consumed != 0) {
            const remaining = used - consumed;
            std.mem.copyForwards(u8, wire[0..remaining], wire[consumed..used]);
            used = remaining;
        }
    }

    // A real long-lived server would keep accepting new streams. This finite
    // example closes the one connection explicitly with a clean GOAWAY.
    try server.sendGoAway(out, state.last_stream_id, .no_error, "example complete");
    try out.flush();

    // The client can still have SETTINGS ACK / WINDOW_UPDATE bytes in flight.
    // Keep parsing them until receive EOF rather than discarding protocol bytes;
    // then report the exact remaining transport-buffer suffix to finishReceive().
    while (true) {
        if (used == wire.len) return error.InputBufferTooSmall;
        var destinations = [1][]u8{wire[used..]};
        const n = in.readVec(&destinations) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (n == 0) {
            try server.finishReceive(wire[0..used]);
            break;
        }
        used += n;

        var consumed: usize = 0;
        while (consumed < used) {
            const result = (try server.receive(wire[consumed..used])) orelse break;
            if (result.consumed == 0 and result.event == null) break;
            consumed += result.consumed;
            try server.sendControl(out, result.control);
            if (result.event) |event| switch (event) {
                .fault => return error.ProtocolFault,
                else => {},
            };
            try out.flush();
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

    std.log.info("HTTP/2 prior-knowledge example server listening on {s}:{d}", .{ listen_address, listen_port });

    while (true) {
        var stream = try listener.accept(init.io);
        serveConnection(init.io, &stream) catch |err| {
            std.log.err("HTTP/2 connection failed: {t}", .{err});
        };
        stream.close(init.io);
    }
}
