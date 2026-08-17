const std = @import("std");
const http = @import("http");

const h1 = http.http1;
const net = std.Io.net;
const response_body = "zig-http1";

fn writeResponse(out: *std.Io.Writer, method: []const u8, close: bool) !void {
    const headers = if (close)
        [_]http.common.Header{
            .{ .name = "Content-Length", .value = "9" },
            .{ .name = "Content-Type", .value = "text/plain" },
            .{ .name = "Connection", .value = "close" },
        }
    else
        [_]http.common.Header{
            .{ .name = "Content-Length", .value = "9" },
            .{ .name = "Content-Type", .value = "text/plain" },
            .{ .name = "X-Engine", .value = "zig-http" },
        };
    try h1.write.responseHead(out, .http_1_1, 200, "OK", &headers);
    if (!std.ascii.eqlIgnoreCase(method, "HEAD")) try out.writeAll(response_body);
    try out.flush();
}

fn writeBadRequest(out: *std.Io.Writer) void {
    const headers = [_]http.common.Header{
        .{ .name = "Content-Length", .value = "0" },
        .{ .name = "Connection", .value = "close" },
    };
    h1.write.responseHead(out, .http_1_1, 400, "Bad Request", &headers) catch return;
    out.flush() catch {};
}

fn handleConnection(io: std.Io, stream_value: net.Stream) !void {
    var stream = stream_value;
    defer stream.close(io);

    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    const in = &reader.interface;
    const out = &writer.interface;

    var head_storage: [32 * 1024]u8 = undefined;
    var chunk_storage: [4096]u8 = undefined;
    var decoder = h1.ConnectionDecoder.initRequest(&head_storage, &chunk_storage, .{});
    var wire: [32 * 1024]u8 = undefined;
    var used: usize = 0;
    var current_method: []const u8 = "GET";
    var current_close = false;

    while (true) {
        if (used == wire.len) return error.BufferTooSmall;
        var destinations = [1][]u8{wire[used..]};
        const n = in.readVec(&destinations) catch return;
        if (n == 0) {
            _ = decoder.finish() catch {
                writeBadRequest(out);
            };
            return;
        }
        used += n;

        var consumed: usize = 0;
        while (consumed < used) {
            const result = decoder.feed(wire[consumed..used]) catch {
                writeBadRequest(out);
                return;
            };
            consumed += result.consumed;
            if (result.event) |event| switch (event) {
                .head => |head_event| {
                    current_method = head_event.head.start.request.method;
                    current_close = head_event.persistence == .close;
                    if (head_event.message_done) {
                        try writeResponse(out, current_method, current_close);
                        if (current_close) return;
                    }
                },
                .data => |data| if (data.message_done) {
                    try writeResponse(out, current_method, current_close);
                    if (current_close) return;
                },
                .trailer => {},
                .message_end => {
                    try writeResponse(out, current_method, current_close);
                    if (current_close) return;
                },
            };
            if (result.consumed == 0 and result.event == null) break;
        }

        if (consumed != 0) {
            const remaining = used - consumed;
            std.mem.copyForwards(u8, wire[0..remaining], wire[consumed..used]);
            used = remaining;
        }
    }
}

fn worker(io: std.Io, stream: net.Stream) void {
    handleConnection(io, stream) catch |err| std.log.err("HTTP/1 conformance connection failed: {t}", .{err});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var port: u16 = 18081;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else return error.InvalidArguments;
    }

    const address = try net.IpAddress.parse("127.0.0.1", port);
    var server = try address.listen(init.io, .{ .reuse_address = true });
    defer server.deinit(init.io);

    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.print("LISTEN {f}\n", .{server.socket.address});
    try stdout.interface.flush();

    while (true) {
        const stream = server.accept(init.io) catch continue;
        const thread = std.Thread.spawn(.{}, worker, .{ init.io, stream }) catch {
            var owned = stream;
            owned.close(init.io);
            continue;
        };
        thread.detach();
    }
}
