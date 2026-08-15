const std = @import("std");
const hpack = @import("hpack");
const common = @import("../common.zig");
const connection = @import("connection.zig");
const fields = @import("fields.zig");
const frame = @import("frame.zig");
const header_block = @import("header_block.zig");
const payload = @import("payload.zig");
const peer_mod = @import("peer.zig");
const protocol = @import("protocol.zig");
const stream_mod = @import("stream.zig");
const streams_mod = @import("streams.zig");

pub const Fault = union(enum) {
    connection: protocol.ErrorCode,
    stream: struct { stream_id: u31, code: protocol.ErrorCode },
};

pub const HeaderSection = struct {
    stream_id: u31,
    kind: fields.Kind,
    end_stream: bool,
    field_count: u32,
    /// Non-zero only for response field sections.
    status_code: u16 = 0,
};

pub const PushPromise = struct {
    associated_stream_id: u31,
    promised_stream_id: u31,
    field_count: u32,
};

pub const Data = struct {
    stream_id: u31,
    bytes: []const u8,
    end_stream: bool,
};

pub const SettingsApplied = struct {
    ack: bool,
    count: u16,
};

pub const Event = union(enum) {
    ignored,
    pending,
    fault: Fault,
    data: Data,
    headers: HeaderSection,
    push_promise: PushPromise,
    settings: SettingsApplied,
    window_update: struct { stream_id: u31, increment: u31 },
    reset: struct { stream_id: u31, error_code: u32 },
    goaway: payload.GoAway,
    ping: struct { ack: bool, bytes: []const u8 },
};

pub const CompleteResult = struct {
    consumed: usize,
    event: Event,
};

pub const NullSink = struct {
    pub inline fn field(_: *NullSink, _: u31, _: fields.Kind, _: common.Header) void {}
};

const Pending = struct {
    stream_id: u31 = 0,
    detail: u32 = 0,

    const end_stream_bit: u32 = 0x8000_0000;

    inline fn headers(stream_id: u31, end_stream: bool) Pending {
        return .{ .stream_id = stream_id, .detail = if (end_stream) end_stream_bit else 0 };
    }

    inline fn pushPromise(stream_id: u31, promised_stream_id: u31) Pending {
        return .{ .stream_id = stream_id, .detail = promised_stream_id };
    }

    inline fn promisedStream(self: Pending) u31 {
        return @intCast(self.detail & 0x7fff_ffff);
    }

    inline fn endStream(self: Pending) bool {
        return (self.detail & end_stream_bit) != 0;
    }

    inline fn isPushPromise(self: Pending) bool {
        return self.promisedStream() != 0;
    }

    inline fn empty(self: Pending) bool {
        return self.stream_id == 0;
    }

    fn clear(self: *Pending) void {
        self.* = .{};
    }
};

/// High-level receive-side HTTP/2 session state over caller-owned stream and
/// header-block storage. HPACK codec objects remain caller-owned because they
/// own allocator-backed dynamic tables; this type merely holds stable pointers.
///
/// The stream store extends the `StreamManager` contract with one operation:
///
///     applyPeerInitialWindow(change: PeerState.InitialWindowChange) bool
///
/// It must apply the ordered SETTINGS_INITIAL_WINDOW_SIZE delta to every live
/// locally-sending stream and return false if any window would overflow.
pub const Session = struct {
    connection: connection.State = .{},
    streams: streams_mod.Manager,
    peer: peer_mod.State,
    decoder: *hpack.Decoder,
    encoder: *hpack.Encoder,
    collector: header_block.Collector,
    pending: Pending = .{},

    pub fn init(
        role: peer_mod.Role,
        local_limits: streams_mod.LocalLimits,
        decoder: *hpack.Decoder,
        encoder: *hpack.Encoder,
        header_storage: []u8,
    ) Session {
        return .{
            .streams = streams_mod.Manager.init(role, local_limits),
            .peer = peer_mod.State.init(role),
            .decoder = decoder,
            .encoder = encoder,
            .collector = header_block.Collector.init(header_storage),
        };
    }

    /// Parses and processes one complete frame directly from a transport buffer.
    /// Returns null when the buffer does not yet contain the full frame; the
    /// returned event may borrow payload bytes from `input`.
    pub inline fn receiveBytes(
        self: *Session,
        store: anytype,
        input: []const u8,
        receiver_max_frame_size: u32,
        scratch: []u8,
        sink: anytype,
    ) (hpack.codec.Error || error{ HeaderBlockTooLarge, FrameSize, Protocol })!?CompleteResult {
        const parsed = (try frame.parseComplete(input, receiver_max_frame_size)) orelse return null;
        return .{
            .consumed = parsed.consumed,
            .event = try self.receiveComplete(store, parsed.frame, scratch, sink),
        };
    }

    /// Processes one validated complete frame. The frame payload remains
    /// caller-owned and zero-copy. `sink.field()` is called synchronously for
    /// each HPACK field while it is valid; callers should commit side effects
    /// only after this function returns a successful `.headers` or
    /// `.push_promise` event because later fields can invalidate the section.
    pub inline fn receiveComplete(
        self: *Session,
        store: anytype,
        complete: frame.CompleteFrame,
        scratch: []u8,
        sink: anytype,
    ) (hpack.codec.Error || error{HeaderBlockTooLarge})!Event {
        switch (self.connection.check(complete.header)) {
            .none => {},
            .protocol => return .{ .fault = .{ .connection = .protocol_error } },
            .flow_control => return .{ .fault = .{ .connection = .flow_control_error } },
        }

        return switch (complete.header.type) {
            .data => self.receiveData(store, complete),
            .headers => try self.receiveHeaders(store, complete, scratch, sink),
            .continuation => try self.receiveContinuation(store, complete, scratch, sink),
            .push_promise => try self.receivePushPromise(store, complete, scratch, sink),
            .settings => self.receiveSettings(store, complete),
            .window_update => self.receiveWindowUpdate(store, complete),
            .rst_stream => self.receiveReset(store, complete),
            .goaway => self.receiveGoAway(complete),
            .ping => .{ .ping = .{ .ack = (complete.header.flags & 0x01) != 0, .bytes = complete.payload } },
            .priority => .ignored,
            else => .ignored,
        };
    }

    fn receiveData(self: *Session, store: anytype, complete: frame.CompleteFrame) Event {
        const bytes = payload.data(complete.header, complete.payload) catch |err| return switch (err) {
            error.FrameSize => .{ .fault = .{ .connection = .frame_size_error } },
            error.Protocol => .{ .fault = .{ .connection = .protocol_error } },
        };
        const end_stream = (complete.header.flags & 0x01) != 0;
        const result = self.streams.receiveData(store, complete.header.stream_id, complete.header.length, end_stream);
        if (receiveFault(complete.header.stream_id, result)) |fault| return .{ .fault = fault };
        if (result == .ignored_after_goaway) return .ignored;
        return .{ .data = .{ .stream_id = complete.header.stream_id, .bytes = bytes, .end_stream = end_stream } };
    }

    fn receiveHeaders(self: *Session, store: anytype, complete: frame.CompleteFrame, scratch: []u8, sink: anytype) (hpack.codec.Error || error{HeaderBlockTooLarge})!Event {
        const parsed = payload.headers(complete.header, complete.payload) catch |err| return switch (err) {
            error.FrameSize => .{ .fault = .{ .connection = .frame_size_error } },
            error.Protocol => .{ .fault = .{ .connection = .protocol_error } },
        };
        const end_headers = (complete.header.flags & 0x04) != 0;
        const end_stream = (complete.header.flags & 0x01) != 0;
        const pending = Pending.headers(complete.header.stream_id, end_stream);
        if (end_headers) return try self.finishBlock(store, pending, parsed.fragment, scratch, sink);
        self.pending = pending;
        _ = self.collector.begin(complete.header.stream_id, parsed.fragment, false) catch |err| switch (err) {
            error.Protocol => return .{ .fault = .{ .connection = .protocol_error } },
            error.HeaderBlockTooLarge => return error.HeaderBlockTooLarge,
        };
        return .pending;
    }

    fn receivePushPromise(self: *Session, store: anytype, complete: frame.CompleteFrame, scratch: []u8, sink: anytype) (hpack.codec.Error || error{HeaderBlockTooLarge})!Event {
        const parsed = payload.pushPromise(complete.header, complete.payload) catch |err| return switch (err) {
            error.FrameSize => .{ .fault = .{ .connection = .frame_size_error } },
            error.Protocol => .{ .fault = .{ .connection = .protocol_error } },
        };
        const end_headers = (complete.header.flags & 0x04) != 0;
        const pending = Pending.pushPromise(complete.header.stream_id, parsed.promised_stream_id);
        if (end_headers) return try self.finishBlock(store, pending, parsed.fragment, scratch, sink);
        self.pending = pending;
        _ = self.collector.begin(complete.header.stream_id, parsed.fragment, false) catch |err| switch (err) {
            error.Protocol => return .{ .fault = .{ .connection = .protocol_error } },
            error.HeaderBlockTooLarge => return error.HeaderBlockTooLarge,
        };
        return .pending;
    }

    fn receiveContinuation(self: *Session, store: anytype, complete: frame.CompleteFrame, scratch: []u8, sink: anytype) (hpack.codec.Error || error{HeaderBlockTooLarge})!Event {
        const end_headers = (complete.header.flags & 0x04) != 0;
        const block = self.collector.continuation(complete.header.stream_id, complete.payload, end_headers) catch |err| switch (err) {
            error.Protocol => return .{ .fault = .{ .connection = .protocol_error } },
            error.HeaderBlockTooLarge => return error.HeaderBlockTooLarge,
        };
        if (block) |ready| {
            const pending = self.pending;
            self.pending.clear();
            if (pending.empty()) return .{ .fault = .{ .connection = .protocol_error } };
            return try self.finishBlock(store, pending, ready, scratch, sink);
        }
        return .pending;
    }

    fn finishBlock(self: *Session, store: anytype, pending: Pending, block: []const u8, scratch: []u8, sink: anytype) hpack.codec.Error!Event {
        const field_kind: fields.Kind = if (pending.isPushPromise()) .request else self.headerKind(store, pending.stream_id);
        var validator = fields.Validator.init(field_kind);
        var it = self.decoder.iterator(block, scratch);
        var field_count: u32 = 0;
        var status_code: u16 = 0;
        var invalid = false;
        while (true) {
            const next_field = it.next() catch |err| switch (err) {
                error.HeaderListTooLarge => {
                    try it.finish();
                    return error.HeaderListTooLarge;
                },
                else => return err,
            };
            const field = next_field orelse break;
            const header: common.Header = .{ .name = field.name, .value = field.value };
            if (!invalid) {
                validator.field(header) catch {
                    invalid = true;
                    continue;
                };
                if (field_kind == .response and header.name.len == 7 and std.mem.eql(u8, header.name, ":status")) {
                    status_code = @as(u16, header.value[0] - '0') * 100 + @as(u16, header.value[1] - '0') * 10 + @as(u16, header.value[2] - '0');
                }
                sink.field(if (pending.isPushPromise()) pending.promisedStream() else pending.stream_id, field_kind, header);
                field_count +|= 1;
            }
        }
        if (!invalid) {
            validator.finish() catch {
                invalid = true;
            };
        }
        if (invalid) return .{ .fault = .{ .stream = .{ .stream_id = pending.stream_id, .code = .protocol_error } } };

        if (pending.isPushPromise()) return self.commitPushPromise(store, pending, field_count);
        return self.commitHeaders(store, pending, field_kind, status_code, field_count);
    }

    fn headerKind(self: *Session, store: anytype, stream_id: u31) fields.Kind {
        const tracked = store.get(stream_id) orelse return if (self.streams.local_role == .server) .request else .response;
        if (tracked.remote_headers != .initial) return .trailers;
        return if (self.streams.local_role == .server and self.streams.remoteInitiated(stream_id)) .request else .response;
    }

    fn commitHeaders(self: *Session, store: anytype, pending: Pending, field_kind: fields.Kind, status: u16, field_count: u32) Event {
        const end_stream = pending.endStream();
        const informational = field_kind == .response and status >= 100 and status < 200;
        if ((field_kind == .response and status == 101) or
            (informational and end_stream) or (field_kind == .trailers and !end_stream))
            return .{ .fault = .{ .stream = .{ .stream_id = pending.stream_id, .code = .protocol_error } } };

        const result = self.streams.receiveHeaders(store, &self.peer, pending.stream_id, end_stream);
        if (receiveFault(pending.stream_id, result)) |fault| return .{ .fault = fault };
        if (result == .ignored_after_goaway) return .ignored;

        if (store.get(pending.stream_id)) |tracked| {
            if (field_kind == .trailers) {
                tracked.remote_headers = .trailers;
            } else if (field_kind == .request or !informational) {
                tracked.remote_headers = .regular;
            }
        }
        return .{ .headers = .{
            .stream_id = pending.stream_id,
            .kind = field_kind,
            .end_stream = end_stream,
            .field_count = field_count,
            .status_code = status,
        } };
    }

    fn commitPushPromise(self: *Session, store: anytype, pending: Pending, field_count: u32) Event {
        const promised_stream_id = pending.promisedStream();
        const result = self.streams.receivePushPromise(store, &self.peer, pending.stream_id, promised_stream_id);
        if (receiveFault(pending.stream_id, result)) |fault| return .{ .fault = fault };
        if (result == .ignored_after_goaway) return .ignored;
        return .{ .push_promise = .{
            .associated_stream_id = pending.stream_id,
            .promised_stream_id = promised_stream_id,
            .field_count = field_count,
        } };
    }

    fn receiveSettings(self: *Session, store: anytype, complete: frame.CompleteFrame) Event {
        var parsed = self.peer.settingsFrame(complete.header, complete.payload) catch |err| return switch (err) {
            error.FrameSize => .{ .fault = .{ .connection = .frame_size_error } },
            error.Protocol => .{ .fault = .{ .connection = .protocol_error } },
        };
        var count: u16 = 0;
        while (parsed.effects.next() catch |err| return switch (err) {
            error.Protocol => .{ .fault = .{ .connection = .protocol_error } },
            error.FlowControl => .{ .fault = .{ .connection = .flow_control_error } },
        }) |effect| {
            count +|= 1;
            switch (effect) {
                .header_table_size => |size| self.encoder.setAllowedMaxSize(@intCast(size)),
                .initial_window => |change| if (!store.applyPeerInitialWindow(change))
                    return .{ .fault = .{ .connection = .flow_control_error } },
                else => {},
            }
        }
        return .{ .settings = .{ .ack = parsed.ack, .count = count } };
    }

    fn receiveWindowUpdate(self: *Session, store: anytype, complete: frame.CompleteFrame) Event {
        const routed = self.peer.windowUpdate(complete.header, complete.payload) catch |err| return switch (err) {
            error.FrameSize => .{ .fault = .{ .connection = .frame_size_error } },
            error.Protocol => .{ .fault = .{ .connection = .protocol_error } },
            error.FlowControl => .{ .fault = .{ .connection = .flow_control_error } },
        };
        if (routed) |update| {
            const result = self.streams.receiveWindowUpdate(store, update.stream_id, update.increment);
            if (receiveFault(update.stream_id, result)) |fault| return .{ .fault = fault };
            if (result == .ignored_after_goaway) return .ignored;
            return .{ .window_update = .{ .stream_id = update.stream_id, .increment = update.increment } };
        }
        const increment = payload.windowIncrement(complete.payload) catch unreachable;
        return .{ .window_update = .{ .stream_id = 0, .increment = increment } };
    }

    fn receiveReset(self: *Session, store: anytype, complete: frame.CompleteFrame) Event {
        const code = payload.rstErrorCode(complete.payload) catch return .{ .fault = .{ .connection = .frame_size_error } };
        const result = self.streams.receiveReset(store, complete.header.stream_id);
        if (receiveFault(complete.header.stream_id, result)) |fault| return .{ .fault = fault };
        if (result == .ignored_after_goaway) return .ignored;
        return .{ .reset = .{ .stream_id = complete.header.stream_id, .error_code = code } };
    }

    fn receiveGoAway(self: *Session, complete: frame.CompleteFrame) Event {
        const parsed = self.peer.goAway(complete.header, complete.payload) catch |err| return switch (err) {
            error.FrameSize => .{ .fault = .{ .connection = .frame_size_error } },
            error.Protocol => .{ .fault = .{ .connection = .protocol_error } },
        };
        return .{ .goaway = parsed };
    }
};

fn receiveFault(stream_id: u31, result: streams_mod.ReceiveResult) ?Fault {
    const code = result.errorCode() orelse return null;
    if (result.isConnectionError()) return .{ .connection = code };
    return .{ .stream = .{ .stream_id = stream_id, .code = code } };
}

const TestStore = struct {
    const Slot = struct { id: u31 = 0, used: bool = false, value: stream_mod.Tracked = undefined };
    slots: [8]Slot = [_]Slot{.{}} ** 8,

    fn slot(id: u31) usize {
        return (@as(usize, id) >> 1) % 8;
    }

    pub fn get(self: *TestStore, id: u31) ?*stream_mod.Tracked {
        const s = &self.slots[slot(id)];
        if (!s.used or s.id != id) return null;
        return &s.value;
    }

    pub fn insert(self: *TestStore, id: u31, value: stream_mod.Tracked) ?*stream_mod.Tracked {
        const s = &self.slots[slot(id)];
        if (s.used) return null;
        s.* = .{ .id = id, .used = true, .value = value };
        return &s.value;
    }

    pub fn applyPeerInitialWindow(self: *TestStore, change: peer_mod.State.InitialWindowChange) bool {
        for (&self.slots) |*slot_value| {
            if (!slot_value.used) continue;
            slot_value.value.windows.applyPeerInitialDelta(change.old, change.new) catch return false;
        }
        return true;
    }
};

fn encodedFields(allocator: std.mem.Allocator, encoder: *hpack.Encoder, values: []const common.Header) ![]u8 {
    var storage: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    for (values) |field| try encoder.field(&writer, .{ .name = field.name, .value = field.value }, .without);
    return try allocator.dupe(u8, writer.buffered());
}

test "session receiveBytes waits for a complete frame and dispatches it" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var wire_encoder = hpack.Encoder.init(allocator, 4096);
    defer wire_encoder.deinit();
    var block_storage: [256]u8 = undefined;
    var session = Session.init(.server, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};
    var sink: NullSink = .{};
    var scratch: [512]u8 = undefined;

    const request_fields = [_]common.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/bytes" },
    };
    const block = try encodedFields(allocator, &wire_encoder, &request_fields);
    defer allocator.free(block);

    var wire: [1024]u8 = undefined;
    var encoded_header: [9]u8 = undefined;
    try (frame.FrameHeader{
        .length = @intCast(block.len),
        .type = .headers,
        .flags = 0x05,
        .stream_id = 1,
    }).encode(&encoded_header);
    @memcpy(wire[0..9], &encoded_header);
    @memcpy(wire[9..][0..block.len], block);
    const bytes = wire[0 .. 9 + block.len];

    try std.testing.expect((try session.receiveBytes(
        &store,
        bytes[0 .. bytes.len - 1],
        frame.default_max_frame_size,
        &scratch,
        &sink,
    )) == null);
    try std.testing.expect(store.get(1) == null);

    const received = (try session.receiveBytes(
        &store,
        bytes,
        frame.default_max_frame_size,
        &scratch,
        &sink,
    )).?;
    try std.testing.expectEqual(bytes.len, received.consumed);
    try std.testing.expectEqual(fields.Kind.request, received.event.headers.kind);
    try std.testing.expect(received.event.headers.end_stream);
}

test "session decodes request response and trailers without growing Tracked" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(stream_mod.Tracked));
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var wire_encoder = hpack.Encoder.init(allocator, 4096);
    defer wire_encoder.deinit();
    var block_storage: [4096]u8 = undefined;
    var session = Session.init(.server, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};
    var sink: NullSink = .{};
    var scratch: [4096]u8 = undefined;

    const request_fields = [_]common.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
    };
    const request_block = try encodedFields(allocator, &wire_encoder, &request_fields);
    defer allocator.free(request_block);
    const request = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(request_block.len), .type = .headers, .flags = 0x04, .stream_id = 1 },
        .payload = request_block,
    }, &scratch, &sink);
    try std.testing.expectEqual(fields.Kind.request, request.headers.kind);
    try std.testing.expectEqual(stream_mod.RemoteHeaders.regular, store.get(1).?.remote_headers);

    const trailer_fields = [_]common.Header{.{ .name = "x-checksum", .value = "ok" }};
    const trailer_block = try encodedFields(allocator, &wire_encoder, &trailer_fields);
    defer allocator.free(trailer_block);
    const trailers = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(trailer_block.len), .type = .headers, .flags = 0x05, .stream_id = 1 },
        .payload = trailer_block,
    }, &scratch, &sink);
    try std.testing.expectEqual(fields.Kind.trailers, trailers.headers.kind);
    try std.testing.expectEqual(stream_mod.RemoteHeaders.trailers, store.get(1).?.remote_headers);
}

test "session preserves HPACK through continuation and validates 1xx response phase" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var wire_encoder = hpack.Encoder.init(allocator, 4096);
    defer wire_encoder.deinit();
    var block_storage: [4096]u8 = undefined;
    var session = Session.init(.client, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};
    try session.streams.openLocal(&store, &session.peer, 1, true);
    var sink: NullSink = .{};
    var scratch: [4096]u8 = undefined;

    const info_fields = [_]common.Header{.{ .name = ":status", .value = "103" }};
    const info = try encodedFields(allocator, &wire_encoder, &info_fields);
    defer allocator.free(info);
    const split = @max(@as(usize, 1), info.len / 2);
    _ = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(split), .type = .headers, .flags = 0, .stream_id = 1 },
        .payload = info[0..split],
    }, &scratch, &sink);
    const informational = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(info.len - split), .type = .continuation, .flags = 0x04, .stream_id = 1 },
        .payload = info[split..],
    }, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 103), informational.headers.status_code);
    try std.testing.expectEqual(stream_mod.RemoteHeaders.initial, store.get(1).?.remote_headers);

    const final_fields = [_]common.Header{.{ .name = ":status", .value = "200" }};
    const final = try encodedFields(allocator, &wire_encoder, &final_fields);
    defer allocator.free(final);
    const response = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(final.len), .type = .headers, .flags = 0x05, .stream_id = 1 },
        .payload = final,
    }, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 200), response.headers.status_code);
    try std.testing.expectEqual(stream_mod.RemoteHeaders.regular, store.get(1).?.remote_headers);
}

test "session decodes PUSH_PROMISE request fields before reserving the stream" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var wire_encoder = hpack.Encoder.init(allocator, 4096);
    defer wire_encoder.deinit();
    var block_storage: [4096]u8 = undefined;
    var session = Session.init(.client, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};
    try session.streams.openLocal(&store, &session.peer, 1, true);
    var sink: NullSink = .{};
    var scratch: [4096]u8 = undefined;

    const promised_fields = [_]common.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "example.com" },
        .{ .name = ":path", .value = "/style.css" },
    };
    const block = try encodedFields(allocator, &wire_encoder, &promised_fields);
    defer allocator.free(block);
    var payload_bytes: [4096]u8 = undefined;
    std.mem.writeInt(u32, payload_bytes[0..4], 2, .big);
    @memcpy(payload_bytes[4..][0..block.len], block);
    const event = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(4 + block.len), .type = .push_promise, .flags = 0x04, .stream_id = 1 },
        .payload = payload_bytes[0 .. 4 + block.len],
    }, &scratch, &sink);
    try std.testing.expectEqual(@as(u31, 2), event.push_promise.promised_stream_id);
    try std.testing.expectEqual(stream_mod.State.reserved_remote, store.get(2).?.stream.state);
}

test "session applies SETTINGS header table and stream window effects" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [256]u8 = undefined;
    var session = Session.init(.client, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};
    try session.streams.openLocal(&store, &session.peer, 1, false);
    var sink: NullSink = .{};
    var scratch: [64]u8 = undefined;

    var bytes: [12]u8 = undefined;
    @memcpy(bytes[0..6], &settingBytes(.{ .id = .header_table_size, .value = 2048 }));
    @memcpy(bytes[6..12], &settingBytes(.{ .id = .initial_window_size, .value = 32768 }));
    const event = try session.receiveComplete(&store, .{
        .header = .{ .length = 12, .type = .settings, .flags = 0, .stream_id = 0 },
        .payload = &bytes,
    }, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 2), event.settings.count);
    try std.testing.expectEqual(@as(u32, 2048), outbound.allowed_max_size);
    try std.testing.expectEqual(@as(u31, 32768), store.get(1).?.windows.send.available());
}

test "session drains oversized header list before returning the limit error" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    inbound.setMaxHeaderListSize(64);
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var wire_encoder = hpack.Encoder.init(allocator, 4096);
    defer wire_encoder.deinit();
    var block_storage: [4096]u8 = undefined;
    var session = Session.init(.client, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};
    try session.streams.openLocal(&store, &session.peer, 1, true);
    var sink: NullSink = .{};
    var scratch: [4096]u8 = undefined;

    var first_storage: [512]u8 = undefined;
    var first_writer = std.Io.Writer.fixed(&first_storage);
    try wire_encoder.field(&first_writer, .{ .name = ":status", .value = "200" }, .without);
    try wire_encoder.field(&first_writer, .{ .name = "x-dynamic", .value = "retained" }, .incremental);
    try std.testing.expectError(error.HeaderListTooLarge, session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(first_writer.buffered().len), .type = .headers, .flags = 0x04, .stream_id = 1 },
        .payload = first_writer.buffered(),
    }, &scratch, &sink));
    try std.testing.expectEqual(@as(usize, 1), inbound.dynamic.count());

    inbound.setMaxHeaderListSize(4096);
    var second_storage: [512]u8 = undefined;
    var second_writer = std.Io.Writer.fixed(&second_storage);
    try wire_encoder.field(&second_writer, .{ .name = ":status", .value = "200" }, .without);
    try wire_encoder.field(&second_writer, .{ .name = "x-dynamic", .value = "retained" }, .incremental);
    const second = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(second_writer.buffered().len), .type = .headers, .flags = 0x05, .stream_id = 1 },
        .payload = second_writer.buffered(),
    }, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 200), second.headers.status_code);
}

test "session drains malformed field section and preserves HPACK context" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var wire_encoder = hpack.Encoder.init(allocator, 4096);
    defer wire_encoder.deinit();
    var block_storage: [4096]u8 = undefined;
    var session = Session.init(.client, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};
    try session.streams.openLocal(&store, &session.peer, 1, true);
    var sink: NullSink = .{};
    var scratch: [4096]u8 = undefined;

    var first_storage: [512]u8 = undefined;
    var first_writer = std.Io.Writer.fixed(&first_storage);
    try wire_encoder.field(&first_writer, .{ .name = "x-dynamic", .value = "retained" }, .incremental);
    try wire_encoder.field(&first_writer, .{ .name = ":status", .value = "200" }, .without);
    const first = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(first_writer.buffered().len), .type = .headers, .flags = 0x04, .stream_id = 1 },
        .payload = first_writer.buffered(),
    }, &scratch, &sink);
    try std.testing.expectEqual(protocol.ErrorCode.protocol_error, first.fault.stream.code);
    try std.testing.expectEqual(@as(usize, 1), inbound.dynamic.count());

    var second_storage: [512]u8 = undefined;
    var second_writer = std.Io.Writer.fixed(&second_storage);
    try wire_encoder.field(&second_writer, .{ .name = ":status", .value = "200" }, .without);
    try wire_encoder.field(&second_writer, .{ .name = "x-dynamic", .value = "retained" }, .incremental);
    const second = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(second_writer.buffered().len), .type = .headers, .flags = 0x05, .stream_id = 1 },
        .payload = second_writer.buffered(),
    }, &scratch, &sink);
    try std.testing.expectEqual(@as(u16, 200), second.headers.status_code);
}

test "session rejects HTTP 101 over HTTP2" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var wire_encoder = hpack.Encoder.init(allocator, 4096);
    defer wire_encoder.deinit();
    var block_storage: [512]u8 = undefined;
    var session = Session.init(.client, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};
    try session.streams.openLocal(&store, &session.peer, 1, true);
    var sink: NullSink = .{};
    var scratch: [512]u8 = undefined;
    const response_fields = [_]common.Header{.{ .name = ":status", .value = "101" }};
    const block = try encodedFields(allocator, &wire_encoder, &response_fields);
    defer allocator.free(block);
    const event = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(block.len), .type = .headers, .flags = 0x04, .stream_id = 1 },
        .payload = block,
    }, &scratch, &sink);
    try std.testing.expectEqual(protocol.ErrorCode.protocol_error, event.fault.stream.code);
}

test "ignored post GOAWAY DATA still consumes connection credit" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.client, .{}, &inbound, &outbound, &block_storage);
    try session.streams.sentGoAway(0);
    var store: TestStore = .{};
    var sink: NullSink = .{};
    var scratch: [64]u8 = undefined;
    const bytes = "abcd";
    const event = try session.receiveComplete(&store, .{
        .header = .{ .length = bytes.len, .type = .data, .flags = 1, .stream_id = 2 },
        .payload = bytes,
    }, &scratch, &sink);
    try std.testing.expect(event == .ignored);
    try std.testing.expectEqual(@as(u31, 65_531), session.connection.receive_window.available());
}

fn settingBytes(setting: @import("settings.zig").Setting) [6]u8 {
    var bytes: [6]u8 = undefined;
    @import("settings.zig").encode(&bytes, setting);
    return bytes;
}
