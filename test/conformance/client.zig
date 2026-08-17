const std = @import("std");
const http = @import("http");

const h2 = http.http2;
const net = std.Io.net;
const allocator = std.heap.page_allocator;

const Store = struct {
    const Entry = struct {
        id: u31 = 0,
        used: bool = false,
        value: h2.stream.Tracked = undefined,
    };
    entries: [16]Entry = [_]Entry{.{}} ** 16,

    pub fn get(self: *Store, id: u31) ?*h2.stream.Tracked {
        for (&self.entries) |*entry| if (entry.used and entry.id == id) return &entry.value;
        return null;
    }

    pub fn insert(self: *Store, id: u31, value: h2.stream.Tracked) ?*h2.stream.Tracked {
        if (self.get(id) != null) return null;
        for (&self.entries) |*entry| {
            if (!entry.used) {
                entry.* = .{ .id = id, .used = true, .value = value };
                return &entry.value;
            }
        }
        return null;
    }

    pub fn maxActiveSendAdjustment(self: *Store) i32 {
        var result: i32 = 0;
        for (&self.entries) |*entry| {
            if (!entry.used) continue;
            switch (entry.value.stream.state) {
                .open, .half_closed_remote => result = @max(result, entry.value.windows.send.adjustment),
                else => {},
            }
        }
        return result;
    }
};

const Observed = struct {
    stream1_info: bool = false,
    stream1_final: bool = false,
    stream1_done: bool = false,
    stream3_done: bool = false,
    stream5_final: bool = false,
    stream5_trailer: bool = false,
    stream5_done: bool = false,
    stream7_done: bool = false,
    ping_ack: bool = false,
    settings_ack: bool = false,
    body1: [16]u8 = undefined,
    body1_len: usize = 0,
    body5: [16]u8 = undefined,
    body5_len: usize = 0,

    fn complete(self: Observed) bool {
        return self.stream1_info and self.stream1_final and self.stream1_done and
            self.stream3_done and self.stream5_final and self.stream5_trailer and
            self.stream5_done and self.stream7_done and self.ping_ack and self.settings_ack;
    }
};

const Sink = struct {
    observed: *Observed,

    pub fn field(self: *Sink, stream_id: u31, kind: h2.fields.Kind, field_value: http.common.Header) void {
        if (stream_id == 5 and kind == .trailers and
            std.ascii.eqlIgnoreCase(field_value.name, "x-trailer") and
            std.mem.eql(u8, field_value.value, "done"))
        {
            self.observed.stream5_trailer = true;
        }
    }
};

fn appendBody(storage: []u8, used: *usize, bytes: []const u8) !void {
    if (bytes.len > storage.len - used.*) return error.ResponseTooLarge;
    @memcpy(storage[used.* .. used.* + bytes.len], bytes);
    used.* += bytes.len;
}

fn sendRequests(session: *h2.Session, store: *Store, out: *std.Io.Writer, staging: []u8) !void {
    const authority = "127.0.0.1";
    const request1 = [_]h2.hpack.EncodedField{
        .{ .field = .{ .name = ":method", .value = "GET" } },
        .{ .field = .{ .name = ":scheme", .value = "http" } },
        .{ .field = .{ .name = ":authority", .value = authority } },
        .{ .field = .{ .name = ":path", .value = "/early" } },
    };
    const request3 = [_]h2.hpack.EncodedField{
        .{ .field = .{ .name = ":method", .value = "HEAD" } },
        .{ .field = .{ .name = ":scheme", .value = "http" } },
        .{ .field = .{ .name = ":authority", .value = authority } },
        .{ .field = .{ .name = ":path", .value = "/head" } },
    };
    const request5 = [_]h2.hpack.EncodedField{
        .{ .field = .{ .name = ":method", .value = "GET" } },
        .{ .field = .{ .name = ":scheme", .value = "http" } },
        .{ .field = .{ .name = ":authority", .value = authority } },
        .{ .field = .{ .name = ":path", .value = "/trailers" } },
    };
    const request7 = [_]h2.hpack.EncodedField{
        .{ .field = .{ .name = ":method", .value = "CONNECT" } },
        .{ .field = .{ .name = ":protocol", .value = "websocket" } },
        .{ .field = .{ .name = ":scheme", .value = "http" } },
        .{ .field = .{ .name = ":authority", .value = authority } },
        .{ .field = .{ .name = ":path", .value = "/extended" } },
    };
    _ = try session.sendHeaders(store, out, 1, true, staging, &request1);
    _ = try session.sendHeaders(store, out, 3, true, staging, &request3);
    _ = try session.sendHeaders(store, out, 5, true, staging, &request5);
    _ = try session.sendHeaders(store, out, 7, true, staging, &request7);
}

fn handleEvent(
    session: *h2.Session,
    sync: *h2.SessionSettingsSync,
    out: *std.Io.Writer,
    observed: *Observed,
    event: h2.SessionEvent,
) !void {
    switch (event) {
        .ignored, .pending, .window_update => {},
        .fault => |fault| switch (fault) {
            .connection => |code| {
                std.log.err("client interoperability connection fault: {t}", .{code});
                return error.ProtocolFault;
            },
            .stream => |stream_fault| {
                std.log.err("client interoperability stream {d} fault: {t}", .{ stream_fault.stream_id, stream_fault.code });
                return error.ProtocolFault;
            },
        },
        .settings => |settings_event| {
            if (settings_event.ack) {
                if (settings_event.acknowledge(sync) == null) return error.UnexpectedSettingsAck;
                observed.settings_ack = true;
            } else {
                try session.sendSettingsAck(out);
                try out.flush();
            }
        },
        .ping => |ping| {
            if (!ping.ack) {
                if (ping.bytes.len != 8) return error.InvalidPing;
                const bytes: *const [8]u8 = ping.bytes[0..8];
                try session.sendPingAck(out, bytes);
                try out.flush();
            } else {
                if (!std.mem.eql(u8, ping.bytes, "zig-http")) return error.InvalidPing;
                observed.ping_ack = true;
            }
        },
        .headers => |headers| switch (headers.stream_id) {
            1 => {
                if (headers.status_code == 103) {
                    if (headers.end_stream) return error.InvalidResponse;
                    observed.stream1_info = true;
                } else if (headers.status_code == 200 and headers.kind == .response) {
                    if (headers.end_stream) return error.InvalidResponse;
                    if (headers.contentLength() != 8) return error.InvalidResponse;
                    observed.stream1_final = true;
                } else return error.InvalidResponse;
            },
            3 => {
                if (headers.status_code != 200 or headers.kind != .response or !headers.end_stream)
                    return error.InvalidResponse;
                if (headers.contentLength() != 8) return error.InvalidResponse;
                observed.stream3_done = true;
            },
            5 => {
                if (headers.kind == .response) {
                    if (headers.status_code != 200 or headers.end_stream) return error.InvalidResponse;
                    observed.stream5_final = true;
                } else if (headers.kind == .trailers) {
                    if (!headers.end_stream) return error.InvalidResponse;
                    observed.stream5_done = true;
                } else return error.InvalidResponse;
            },
            7 => {
                if (headers.status_code != 200 or headers.kind != .response or !headers.end_stream)
                    return error.InvalidResponse;
                observed.stream7_done = true;
            },
            else => return error.InvalidResponse,
        },
        .data => |data| switch (data.stream_id) {
            1 => {
                try appendBody(&observed.body1, &observed.body1_len, data.bytes);
                if (data.end_stream) observed.stream1_done = true;
            },
            5 => {
                try appendBody(&observed.body5, &observed.body5_len, data.bytes);
                if (data.end_stream) return error.InvalidResponse;
            },
            else => return error.InvalidResponse,
        },
        .reset, .goaway, .push_promise => return error.UnexpectedControlFrame,
    }
}

fn pump(
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    session: *h2.Session,
    store: *Store,
    sync: *h2.SessionSettingsSync,
    observed: *Observed,
    sink: *Sink,
    scratch: []u8,
    wire: []u8,
    used: *usize,
) !void {
    if (used.* == wire.len) return error.BufferTooSmall;
    var destinations = [1][]u8{wire[used.*..]};
    const n = try in.readVec(&destinations);
    if (n == 0) return error.UnexpectedEof;
    used.* += n;

    var consumed: usize = 0;
    while (used.* - consumed >= 9) {
        const header_ptr: *const [9]u8 = wire[consumed..][0..9];
        const frame_header = h2.FrameHeader.parse(header_ptr);
        const total = 9 + @as(usize, frame_header.length);
        if (total > wire.len) return error.BufferTooSmall;
        if (used.* - consumed < total) break;
        const result = try session.receiveBytes(
            store,
            wire[consumed .. consumed + total],
            h2.frame.default_max_frame_size,
            scratch,
            sink,
        );
        const complete = result orelse unreachable;
        try handleEvent(session, sync, out, observed, complete.event);
        consumed += complete.consumed;
    }
    if (consumed != 0) {
        const remaining = used.* - consumed;
        std.mem.copyForwards(u8, wire[0..remaining], wire[consumed..used.*]);
        used.* = remaining;
    }
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

    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var socket_reader = stream.reader(init.io, &read_buffer);
    var socket_writer = stream.writer(init.io, &write_buffer);
    const in = &socket_reader.interface;
    const out = &socket_writer.interface;

    try out.writeAll(h2.client_preface);

    var decoder = h2.hpack.Decoder.init(allocator, 4096);
    defer decoder.deinit();
    var encoder = h2.hpack.Encoder.init(allocator, 4096);
    defer encoder.deinit();
    var header_storage: [64 * 1024]u8 = undefined;
    var scratch: [64 * 1024]u8 = undefined;
    var session = h2.Session.init(.client, .{}, &decoder, &encoder, &header_storage);
    var store: Store = .{};
    var sync: h2.SessionSettingsSync = .{};
    _ = try session.sendSettings(&sync, out, &.{});
    try out.flush();

    var observed: Observed = .{};
    var sink: Sink = .{ .observed = &observed };
    var wire: [128 * 1024]u8 = undefined;
    var used: usize = 0;

    // RFC 8441 requires the client to wait until the server advertises the
    // capability before creating an Extended CONNECT stream.
    while (!session.peerSupportsExtendedConnect()) {
        try pump(in, out, &session, &store, &sync, &observed, &sink, &scratch, &wire, &used);
    }

    var staging: [4096]u8 = undefined;
    try sendRequests(&session, &store, out, &staging);
    const ping_payload: [8]u8 = "zig-http".*;
    try session.sendPing(out, false, &ping_payload);
    try out.flush();

    while (!observed.complete()) {
        try pump(in, out, &session, &store, &sync, &observed, &sink, &scratch, &wire, &used);
    }

    if (!std.mem.eql(u8, observed.body1[0..observed.body1_len], "zig-http")) return error.InvalidResponse;
    if (!std.mem.eql(u8, observed.body5[0..observed.body5_len], "payload")) return error.InvalidResponse;

    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.writeAll("zig-http client -> hyper-h2 server interoperability: PASS\n");
    try stdout.interface.flush();
}
