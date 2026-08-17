const std = @import("std");
const http = @import("http");

const h1 = http.http1;
const net = std.Io.net;

const ResponseResult = struct {
    status: u16,
    informational_count: u8,
    trailer_seen: bool,
    body: [64]u8,
    body_len: usize,
};

fn shiftInput(wire: []u8, used: *usize, consumed: usize) void {
    const remaining = used.* - consumed;
    if (consumed != 0) std.mem.copyForwards(u8, wire[0..remaining], wire[consumed..used.*]);
    used.* = remaining;
}

fn sendRequest(out: *std.Io.Writer, method: []const u8, path: []const u8, close: bool) !void {
    const headers: []const http.common.Header = if (close)
        &[_]http.common.Header{
            .{ .name = "Host", .value = "127.0.0.1" },
            .{ .name = "Connection", .value = "close" },
        }
    else
        &[_]http.common.Header{
            .{ .name = "Host", .value = "127.0.0.1" },
        };
    try h1.write.requestHead(out, .http_1_1, method, path, headers);
    try out.flush();
}

fn readResponse(
    decoder: *h1.ConnectionDecoder,
    in: *std.Io.Reader,
    wire: []u8,
    used: *usize,
    method: []const u8,
) !ResponseResult {
    try decoder.beginResponse(method);
    var result: ResponseResult = .{
        .status = 0,
        .informational_count = 0,
        .trailer_seen = false,
        .body = undefined,
        .body_len = 0,
    };
    var final_seen = false;
    var done = false;

    while (!done) {
        if (used.* == 0) {
            var destinations = [1][]u8{wire};
            const n = in.readVec(&destinations) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (n == 0) {
                const end = try decoder.finish();
                if (end == null or end.? != .message_end) return error.UnexpectedEof;
                done = true;
                break;
            }
            used.* = n;
        }

        const decoded = try decoder.feed(wire[0..used.*]);
        if (decoded.event) |event| switch (event) {
            .head => |head_event| {
                const status = head_event.head.start.response.status;
                if (head_event.informational) {
                    result.informational_count += 1;
                    if (head_event.message_done == false) return error.InvalidResponse;
                } else {
                    if (final_seen) return error.InvalidResponse;
                    result.status = status;
                    final_seen = true;
                    if (head_event.message_done) done = true;
                }
            },
            .data => |data| {
                if (!final_seen) return error.InvalidResponse;
                if (data.bytes.len > result.body.len - result.body_len) return error.ResponseTooLarge;
                @memcpy(result.body[result.body_len .. result.body_len + data.bytes.len], data.bytes);
                result.body_len += data.bytes.len;
                if (data.message_done) done = true;
            },
            .trailer => |trailer| {
                if (std.ascii.eqlIgnoreCase(trailer.name, "x-trailer") and std.mem.eql(u8, trailer.value, "done"))
                    result.trailer_seen = true;
            },
            .message_end => done = true,
        };
        shiftInput(wire, used, decoded.consumed);
        if (decoded.consumed == 0 and decoded.event == null) {
            if (used.* == wire.len) return error.BufferTooSmall;
            var destinations = [1][]u8{wire[used.*..]};
            const n = in.readVec(&destinations) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (n == 0) {
                const end = try decoder.finish();
                if (end == null or end.? != .message_end) return error.UnexpectedEof;
                done = true;
            } else used.* += n;
        }
    }
    if (!final_seen) return error.InvalidResponse;
    return result;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var port: ?u16 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else return error.InvalidArguments;
    }
    const target_port = port orelse return error.InvalidArguments;
    const address = try net.IpAddress.parse("127.0.0.1", target_port);
    var stream = try address.connect(init.io, .{ .mode = .stream });
    defer stream.close(init.io);

    var read_storage: [4096]u8 = undefined;
    var write_storage: [4096]u8 = undefined;
    var socket_reader = stream.reader(init.io, &read_storage);
    var socket_writer = stream.writer(init.io, &write_storage);
    const in = &socket_reader.interface;
    const out = &socket_writer.interface;

    var head_storage: [32 * 1024]u8 = undefined;
    var chunk_storage: [4096]u8 = undefined;
    var decoder = h1.ConnectionDecoder.initResponse(&head_storage, &chunk_storage, .{});
    var wire: [32 * 1024]u8 = undefined;
    var used: usize = 0;

    try sendRequest(out, "GET", "/early", false);
    const early = try readResponse(&decoder, in, &wire, &used, "GET");
    if (early.status != 200 or early.informational_count != 1 or
        !std.mem.eql(u8, early.body[0..early.body_len], "zig-http1")) return error.InvalidResponse;

    try sendRequest(out, "HEAD", "/head", false);
    const head_response = try readResponse(&decoder, in, &wire, &used, "HEAD");
    if (head_response.status != 200 or head_response.body_len != 0) return error.InvalidResponse;

    try sendRequest(out, "GET", "/chunked", false);
    const chunked = try readResponse(&decoder, in, &wire, &used, "GET");
    if (chunked.status != 200 or !chunked.trailer_seen or
        !std.mem.eql(u8, chunked.body[0..chunked.body_len], "zig-http1")) return error.InvalidResponse;

    try sendRequest(out, "GET", "/close", true);
    const close_response = try readResponse(&decoder, in, &wire, &used, "GET");
    if (close_response.status != 200 or
        !std.mem.eql(u8, close_response.body[0..close_response.body_len], "close-body")) return error.InvalidResponse;

    var stdout_storage: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_storage);
    try stdout.interface.writeAll("zig-http HTTP/1 client -> independent raw server interoperability: PASS\n");
    try stdout.interface.flush();
}
