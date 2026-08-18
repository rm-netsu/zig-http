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

const server_address = "127.0.0.1";
const server_port = 18081;
const server_authority = "127.0.0.1:18081";

const ResponseBody = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    done: bool = false,

    fn append(self: *ResponseBody, bytes: []const u8) !void {
        if (bytes.len > self.bytes.len - self.len) return error.ResponseBodyTooLarge;
        @memcpy(self.bytes[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }
};

const ClientState = struct {
    hello_stream: u31,
    echo_stream: u31,
    hello: ResponseBody = .{},
    echo: ResponseBody = .{},
    saw_goaway: bool = false,

    fn bodyFor(self: *ClientState, stream_id: u31) !*ResponseBody {
        if (stream_id == self.hello_stream) return &self.hello;
        if (stream_id == self.echo_stream) return &self.echo;
        return error.UnexpectedStream;
    }
};

fn handleClientResult(client: *Conn, out: *std.Io.Writer, state: *ClientState, result: Conn.ReceiveResult) !void {
    try client.sendControl(out, result.control);

    const event = result.event orelse return;
    switch (event) {
        .headers => |headers| {
            if (headers.kind != .response or headers.status_code != 200) return error.UnexpectedResponse;
            const body = try state.bodyFor(headers.stream_id);
            if (headers.end_stream) body.done = true;
        },
        .data => |data| {
            const body = try state.bodyFor(data.stream_id);
            try body.append(data.bytes);
            client.releaseData(data);
            _ = try client.flushReceiveCredit(out, data.stream_id);
            if (data.end_stream) body.done = true;
        },
        .goaway => |goaway| {
            if (goaway.error_code != @intFromEnum(h2.protocol.ErrorCode.no_error)) return error.UnexpectedGoAway;
            state.saw_goaway = true;
        },
        .fault => return error.ProtocolFault,
        else => {},
    }
}

fn runClient(io: std.Io, address: net.IpAddress) !void {
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var socket_read_storage: [16 * 1024]u8 = undefined;
    var socket_write_storage: [16 * 1024]u8 = undefined;
    var socket_reader = stream.reader(io, &socket_read_storage);
    var socket_writer = stream.writer(io, &socket_write_storage);
    const in = &socket_reader.interface;
    const out = &socket_writer.interface;

    var connection_storage: Conn.Storage = undefined;
    var client = Conn.initClientInPlace(&connection_storage, std.heap.page_allocator);
    defer client.deinit();

    _ = try client.start(out);
    const hello = try client.sendRequest(
        out,
        h2.message.RequestFields.init("GET", "http", server_authority, "/hello"),
        &.{},
        true,
    );

    var request_length = h2.message.ContentLength.init(5);
    const echo = try client.sendRequest(
        out,
        h2.message.RequestFields.init("POST", "http", server_authority, "/echo"),
        &.{request_length.field()},
        false,
    );
    const sent = try client.sendData(out, echo.stream_id, "hello", true);
    if (sent.blocked or sent.consumed != 5) return error.UnexpectedFlowControlBlock;
    try out.flush();

    var state: ClientState = .{ .hello_stream = hello.stream_id, .echo_stream = echo.stream_id };
    var wire: [32 * 1024]u8 = undefined;
    var used: usize = 0;

    while (!state.hello.done or !state.echo.done or !state.saw_goaway) {
        if (used == wire.len) return error.InputBufferTooSmall;
        var destinations = [1][]u8{wire[used..]};
        const n = in.readVec(&destinations) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (n == 0) return error.UnexpectedEof;
        used += n;

        var consumed: usize = 0;
        while (consumed < used) {
            const result = (try client.receive(wire[consumed..used])) orelse break;
            if (result.consumed == 0 and result.event == null) break;
            consumed += result.consumed;
            try handleClientResult(&client, out, &state, result);
            try out.flush();
        }
        if (consumed != 0) {
            const remaining = used - consumed;
            std.mem.copyForwards(u8, wire[0..remaining], wire[consumed..used]);
            used = remaining;
        }
    }

    if (!std.mem.eql(u8, state.hello.bytes[0..state.hello.len], hello_body)) return error.InvalidHelloBody;
    if (!std.mem.eql(u8, state.echo.bytes[0..state.echo.len], "hello")) return error.InvalidEchoBody;
    _ = client.reclaimClosed();
}

pub fn main(init: std.process.Init) !void {
    const address = try net.IpAddress.parse(server_address, server_port);
    try runClient(init.io, address);

    var stdout_storage: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_storage);
    try stdout.interface.writeAll("HTTP/2 client: PASS\n");
    try stdout.interface.flush();
}
