const std = @import("std");
const http = @import("http");

const h2 = http.http2;
const net = std.Io.net;
const allocator = std.heap.page_allocator;

const max_concurrent_streams: u32 = 32;
const header_storage_size = 256 * 1024;
const scratch_size = 256 * 1024;
const wire_buffer_size = 128 * 1024;
const response_body = "zig-http";

const Store = struct {
    const Entry = struct {
        id: u31 = 0,
        used: bool = false,
        value: h2.stream.Tracked = undefined,
        body_length: h2.fields.BodyLength = .{},
        response_headers_sent: bool = false,
        response_body_sent: u4 = 0,
    };

    entries: [128]Entry = [_]Entry{.{}} ** 128,

    fn entry(self: *Store, id: u31) ?*Entry {
        for (&self.entries) |*item| {
            if (item.used and item.id == id) return item;
        }
        return null;
    }

    pub fn get(self: *Store, id: u31) ?*h2.stream.Tracked {
        const item = self.entry(id) orelse return null;
        return &item.value;
    }

    pub fn insert(self: *Store, id: u31, value: h2.stream.Tracked) ?*h2.stream.Tracked {
        if (self.get(id) != null) return null;
        for (&self.entries) |*item| {
            if (!item.used) {
                item.* = .{ .id = id, .used = true, .value = value };
                return &item.value;
            }
        }
        return null;
    }

    pub fn maxActiveSendAdjustment(self: *Store) i32 {
        var result: i32 = 0;
        for (&self.entries) |*item| {
            if (!item.used) continue;
            switch (item.value.stream.state) {
                .open, .half_closed_remote => result = @max(result, item.value.windows.send.adjustment),
                else => {},
            }
        }
        return result;
    }
};

fn sendConnectionError(out: *std.Io.Writer, code: h2.protocol.ErrorCode) !void {
    try h2.send.writeGoAway(out, h2.frame.default_max_frame_size, 0, code, "");
    try out.flush();
}

fn sendStreamError(session: *h2.Session, store: *Store, out: *std.Io.Writer, stream_id: u31, code: h2.protocol.ErrorCode) !void {
    if (store.get(stream_id)) |_| {
        session.sendReset(store, out, stream_id, code) catch |err| switch (err) {
            error.StreamClosed => try h2.send.writeReset(out, stream_id, code),
            else => return err,
        };
    } else {
        try h2.send.writeReset(out, stream_id, code);
    }
    try out.flush();
}

fn respond(session: *h2.Session, store: *Store, out: *std.Io.Writer, stream_id: u31, staging: []u8) !void {
    const entry = store.entry(stream_id) orelse return error.Protocol;
    const response = [_]h2.hpack.EncodedField{
        .{ .field = .{ .name = ":status", .value = "200" } },
        .{ .field = .{ .name = "content-length", .value = "8" } },
        .{ .field = .{ .name = "content-type", .value = "text/plain" } },
    };
    if (!entry.response_headers_sent) {
        _ = try session.sendHeaders(store, out, stream_id, false, staging, &response);
        entry.response_headers_sent = true;
    }

    const offset: usize = entry.response_body_sent;
    if (offset < response_body.len) {
        const sent = try session.sendData(store, out, stream_id, response_body[offset..], true);
        entry.response_body_sent += @intCast(sent.consumed);
    }
    try out.flush();
}

fn handleEvent(session: *h2.Session, store: *Store, out: *std.Io.Writer, event: h2.SessionEvent, staging: []u8) !bool {
    switch (event) {
        .ignored, .pending, .reset, .goaway, .push_promise, .extension => {},
        .window_update => |update| {
            if (update.stream_id != 0) {
                if (store.entry(update.stream_id)) |entry| {
                    if (entry.response_headers_sent and entry.response_body_sent < response_body.len) {
                        try respond(session, store, out, update.stream_id, staging);
                    }
                }
            }
        },
        .fault => |fault| switch (fault) {
            .connection => |code| {
                try sendConnectionError(out, code);
                return false;
            },
            .stream => |stream_fault| try sendStreamError(session, store, out, stream_fault.stream_id, stream_fault.code),
        },
        .settings => |settings_event| {
            if (!settings_event.ack) {
                try session.sendSettingsAck(out);
                for (&store.entries) |*entry| {
                    if (entry.used and entry.response_headers_sent and entry.response_body_sent < response_body.len) {
                        try respond(session, store, out, entry.id, staging);
                    }
                }
                try out.flush();
            }
        },
        .ping => |ping| {
            if (!ping.ack) {
                if (ping.bytes.len != 8) return error.Protocol;
                const bytes: *const [8]u8 = ping.bytes[0..8];
                try session.sendPingAck(out, bytes);
                try out.flush();
            }
        },
        .headers => |headers| {
            const entry = store.entry(headers.stream_id) orelse return error.Protocol;
            switch (headers.kind) {
                .request => {
                    entry.body_length = h2.fields.BodyLength.init(headers.contentLength());
                    if (headers.end_stream) {
                        entry.body_length.finish() catch {
                            try sendStreamError(session, store, out, headers.stream_id, .protocol_error);
                            return true;
                        };
                        try respond(session, store, out, headers.stream_id, staging);
                    }
                },
                .trailers => if (headers.end_stream) {
                    entry.body_length.finish() catch {
                        try sendStreamError(session, store, out, headers.stream_id, .protocol_error);
                        return true;
                    };
                    try respond(session, store, out, headers.stream_id, staging);
                },
                .response => {},
            }
        },
        .data => |data| {
            const entry = store.entry(data.stream_id) orelse return error.Protocol;
            entry.body_length.receive(data.bytes.len, data.end_stream) catch {
                try sendStreamError(session, store, out, data.stream_id, .protocol_error);
                return true;
            };
            if (data.end_stream) try respond(session, store, out, data.stream_id, staging);
        },
    }
    return true;
}

fn handleConnection(io: std.Io, stream: net.Stream) !void {
    var owned_stream = stream;
    defer owned_stream.close(io);
    // Half-close the write side before releasing the socket. h2spec 2.6.0's
    // old Go runtime recognizes EOF as a clean connection close but can report
    // a Linux ECONNRESET wrapped in os.SyscallError as a generic test error.
    // Sending FIN first also better models HTTP/2's GOAWAY-then-close sequence.
    defer owned_stream.shutdown(io, .send) catch {};

    var socket_read_buffer: [16 * 1024]u8 = undefined;
    var socket_write_buffer: [16 * 1024]u8 = undefined;
    var reader = owned_stream.reader(io, &socket_read_buffer);
    var writer = owned_stream.writer(io, &socket_write_buffer);
    const in = &reader.interface;
    const out = &writer.interface;

    var preface: [h2.client_preface.len]u8 = undefined;
    in.readSliceAll(&preface) catch return;
    if (!std.mem.eql(u8, &preface, h2.client_preface)) {
        sendConnectionError(out, .protocol_error) catch {};
        return;
    }

    var decoder = h2.hpack.Decoder.init(allocator, 4096);
    defer decoder.deinit();
    var encoder = h2.hpack.Encoder.init(allocator, 4096);
    defer encoder.deinit();
    const header_storage = try allocator.alloc(u8, header_storage_size);
    defer allocator.free(header_storage);
    const scratch = try allocator.alloc(u8, scratch_size);
    defer allocator.free(scratch);
    const wire = try allocator.alloc(u8, wire_buffer_size);
    defer allocator.free(wire);

    var session = h2.Session.init(.server, .{ .max_concurrent_streams = max_concurrent_streams }, &decoder, &encoder, header_storage);
    var store: Store = .{};
    var settings_sync: h2.SessionSettingsSync = .{};
    const local_settings = [_]h2.settings.Setting{
        .{ .id = .max_concurrent_streams, .value = max_concurrent_streams },
        .{ .id = .enable_connect_protocol, .value = 1 },
    };
    _ = try session.sendSettings(&settings_sync, out, &local_settings);
    try out.flush();

    var staging: [h2.frame.default_max_frame_size + 1]u8 = undefined;
    var used: usize = 0;
    var first_peer_frame = true;

    while (true) {
        if (used == wire.len) return error.BufferTooSmall;
        var destinations = [1][]u8{wire[used..]};
        const n = in.readVec(&destinations) catch return;
        if (n == 0) return;
        used += n;

        var consumed: usize = 0;
        while (used - consumed >= 9) {
            const header_ptr: *const [9]u8 = wire[consumed..][0..9];
            const header = h2.FrameHeader.parse(header_ptr);
            header.validate(h2.frame.default_max_frame_size) catch |validation_error| {
                const code: h2.protocol.ErrorCode = switch (validation_error) {
                    error.FrameSize => .frame_size_error,
                    error.Protocol => .protocol_error,
                };
                if (header.validationErrorScope(validation_error) == .connection) {
                    try sendConnectionError(out, code);
                    return;
                }
                const total = 9 + @as(usize, header.length);
                if (total > wire.len) {
                    try sendStreamError(&session, &store, out, header.stream_id, code);
                    return;
                }
                if (used - consumed < total) break;
                try sendStreamError(&session, &store, out, header.stream_id, code);
                consumed += total;
                continue;
            };

            const total = 9 + @as(usize, header.length);
            if (used - consumed < total) break;

            if (first_peer_frame) {
                if (header.type != .settings or (header.flags & 0x01) != 0) {
                    try sendConnectionError(out, .protocol_error);
                    return;
                }
                first_peer_frame = false;
            }

            var sink: h2.session.NullSink = .{};
            const result = session.receiveBytes(
                &store,
                wire[consumed .. consumed + total],
                h2.frame.default_max_frame_size,
                scratch,
                &sink,
            ) catch |err| switch (err) {
                error.FrameSize => {
                    try sendConnectionError(out, .frame_size_error);
                    return;
                },
                error.Protocol => {
                    try sendConnectionError(out, .protocol_error);
                    return;
                },
                error.HeaderBlockTooLarge => {
                    try sendConnectionError(out, .enhance_your_calm);
                    return;
                },
                else => {
                    try sendConnectionError(out, .compression_error);
                    return;
                },
            };
            const complete = result orelse unreachable;
            std.debug.assert(complete.consumed == total);
            if (!try handleEvent(&session, &store, out, complete.event, &staging)) return;
            consumed += total;
        }

        if (consumed != 0) {
            const remaining = used - consumed;
            std.mem.copyForwards(u8, wire[0..remaining], wire[consumed..used]);
            used = remaining;
        }
    }
}

fn connectionWorker(io: std.Io, stream: net.Stream) void {
    handleConnection(io, stream) catch |err| std.log.err("conformance connection failed: {t}", .{err});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var port: u16 = 18080;
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
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.print("LISTEN {f}\n", .{server.socket.address});
    try stdout_writer.interface.flush();

    while (true) {
        const stream = server.accept(init.io) catch continue;
        const thread = std.Thread.spawn(.{}, connectionWorker, .{ init.io, stream }) catch |err| {
            var owned_stream = stream;
            owned_stream.close(init.io);
            std.log.err("conformance worker spawn failed: {t}", .{err});
            continue;
        };
        thread.detach();
    }
}
