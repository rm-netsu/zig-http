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
const send_mod = @import("send.zig");

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

pub const SendHeadersResult = send_mod.HeaderFrameStats;

pub const SendDataResult = struct {
    consumed: usize,
    blocked: bool,
    end_stream: bool,
};

pub const SendHeadersError = hpack.codec.Error || streams_mod.LocalError || error{ BufferTooSmall, SendPoisoned };
pub const SendDataError = std.Io.Writer.Error || streams_mod.LocalError || error{SendPoisoned};
pub const SendSimpleControlError = std.Io.Writer.Error || error{SendPoisoned};
pub const SendStreamControlError = std.Io.Writer.Error || streams_mod.LocalError || error{SendPoisoned};
pub const SendGoAwayError = std.Io.Writer.Error || streams_mod.LocalError || error{ FrameTooLarge, SendPoisoned };

pub const NullSink = struct {
    pub inline fn field(_: *NullSink, _: u31, _: fields.Kind, _: common.Header) void {}
};

const Pending = struct {
    // Bit 31 is impossible for a stream identifier and doubles as the send-side
    // poison flag without growing Session beyond 128 bytes.
    stream_bits: u32 = 0,
    detail: u32 = 0,

    const poison_bit: u32 = 0x8000_0000;
    const end_stream_bit: u32 = 0x8000_0000;

    inline fn headers(stream_id: u31, end_stream: bool) Pending {
        return .{ .stream_bits = stream_id, .detail = if (end_stream) end_stream_bit else 0 };
    }

    inline fn pushPromise(stream_id: u31, promised_stream_id: u31) Pending {
        return .{ .stream_bits = stream_id, .detail = promised_stream_id };
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

    inline fn streamId(self: Pending) u31 {
        return @intCast(self.stream_bits & 0x7fff_ffff);
    }

    inline fn empty(self: Pending) bool {
        return self.streamId() == 0;
    }

    inline fn poisoned(self: Pending) bool {
        return (self.stream_bits & poison_bit) != 0;
    }

    inline fn poison(self: *Pending) void {
        self.stream_bits |= poison_bit;
    }

    inline fn set(self: *Pending, value: Pending) void {
        const poison_mask = self.stream_bits & poison_bit;
        self.* = value;
        self.stream_bits |= poison_mask;
    }

    fn clear(self: *Pending) void {
        const poison_mask = self.stream_bits & poison_bit;
        self.* = .{ .stream_bits = poison_mask };
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

    /// Streams one local field section directly into HEADERS/CONTINUATION
    /// frames. `frame_staging.len - 1` bounds the payload retained in memory;
    /// it may be smaller than the peer-advertised maximum frame size.
    ///
    /// Header syntax/semantics and stream/store preconditions are checked before
    /// HPACK output starts. Once encoding begins, any HPACK allocation/codec or
    /// writer failure poisons the send side because the connection-scoped HPACK
    /// context and/or wire may already be partially advanced.
    pub fn sendHeaders(
        self: *Session,
        store: anytype,
        out: *std.Io.Writer,
        stream_id: u31,
        end_stream: bool,
        frame_staging: []u8,
        items: []const hpack.EncodedField,
    ) SendHeadersError!SendHeadersResult {
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (self.streams.unprocessedByPeer(&self.peer, stream_id)) return error.GoAway;

        const existing = store.get(stream_id);
        const kind = self.localHeaderKindTracked(existing, stream_id);
        const status = try validateLocalFields(kind, end_stream, items);
        var framer = send_mod.HeaderFramer.init(
            out,
            frame_staging,
            self.peer.settings.max_frame_size,
            stream_id,
            end_stream,
        ) catch return error.BufferTooSmall;

        var tracked = existing;
        if (tracked) |value| {
            try self.streams.localHeadersTracked(&self.peer, stream_id, value, end_stream);
        } else {
            try self.streams.openLocal(store, &self.peer, stream_id, end_stream);
            tracked = store.get(stream_id) orelse unreachable;
        }

        return self.finishSendHeaders(&framer, tracked.?, kind, status, items);
    }

    /// HEADERS fast path for a caller that already resolved a stable stream
    /// record. This is useful for server responses and trailers where the event
    /// loop commonly retains its stream cursor while producing output.
    pub fn sendHeadersExisting(
        self: *Session,
        out: *std.Io.Writer,
        existing: streams_mod.Existing,
        end_stream: bool,
        frame_staging: []u8,
        items: []const hpack.EncodedField,
    ) SendHeadersError!SendHeadersResult {
        if (existing.manager != &self.streams) return error.Protocol;
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (self.streams.unprocessedByPeer(&self.peer, existing.stream_id)) return error.GoAway;
        const kind = self.localHeaderKindTracked(existing.tracked, existing.stream_id);
        const status = try validateLocalFields(kind, end_stream, items);
        var framer = send_mod.HeaderFramer.init(
            out,
            frame_staging,
            self.peer.settings.max_frame_size,
            existing.stream_id,
            end_stream,
        ) catch return error.BufferTooSmall;
        try self.streams.localHeadersTracked(&self.peer, existing.stream_id, existing.tracked, end_stream);
        return self.finishSendHeaders(&framer, existing.tracked, kind, status, items);
    }

    fn finishSendHeaders(
        self: *Session,
        framer: *send_mod.HeaderFramer,
        tracked: *stream_mod.Tracked,
        kind: fields.Kind,
        status: u16,
        items: []const hpack.EncodedField,
    ) SendHeadersError!SendHeadersResult {
        for (items) |item| {
            self.encoder.field(&framer.writer, item.field, item.indexing) catch |err| {
                self.pending.poison();
                return err;
            };
        }
        const result = framer.finish() catch |err| {
            self.pending.poison();
            return err;
        };
        if (kind == .trailers) {
            tracked.local_headers = .trailers;
        } else if (kind == .request or !(status >= 100 and status < 200)) {
            tracked.local_headers = .regular;
        }
        return result;
    }

    /// Sends at most one DATA frame, bounded by the peer frame-size setting and
    /// both connection- and stream-level send windows. When credit is exhausted
    /// no bytes are written and `.blocked` is true. `END_STREAM` is emitted only
    /// when the returned `consumed` reaches the end of `bytes`.
    pub fn sendData(
        self: *Session,
        store: anytype,
        out: *std.Io.Writer,
        stream_id: u31,
        bytes: []const u8,
        end_stream: bool,
    ) SendDataError!SendDataResult {
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (self.streams.unprocessedByPeer(&self.peer, stream_id)) return error.GoAway;
        const tracked = store.get(stream_id) orelse return error.StreamClosed;
        return self.sendDataTracked(out, stream_id, tracked, bytes, end_stream);
    }

    /// DATA fast path for a caller that already resolved a stable stream record.
    /// The cursor must belong to this Session's StreamManager. Peer GOAWAY and
    /// current flow-control/frame-size limits are still checked on every call.
    pub fn sendDataExisting(
        self: *Session,
        out: *std.Io.Writer,
        existing: streams_mod.Existing,
        bytes: []const u8,
        end_stream: bool,
    ) SendDataError!SendDataResult {
        if (existing.manager != &self.streams) return error.Protocol;
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (self.streams.unprocessedByPeer(&self.peer, existing.stream_id)) return error.GoAway;
        return self.sendDataTracked(out, existing.stream_id, existing.tracked, bytes, end_stream);
    }

    /// Emits the mandatory acknowledgment for a received SETTINGS frame.
    /// Writer failure poisons the send side because the frame might have been
    /// partially placed on the transport.
    pub fn sendSettingsAck(self: *Session, out: *std.Io.Writer) SendSimpleControlError!void {
        if (self.pending.poisoned()) return error.SendPoisoned;
        send_mod.writeSettingsAck(out) catch |err| {
            self.pending.poison();
            return err;
        };
    }

    /// Emits a PING request or response. `sendPingAck()` is the common receive
    /// response path and preserves the peer's opaque eight-byte payload.
    pub fn sendPing(self: *Session, out: *std.Io.Writer, ack: bool, payload_bytes: *const [8]u8) SendSimpleControlError!void {
        if (self.pending.poisoned()) return error.SendPoisoned;
        send_mod.writePing(out, ack, payload_bytes) catch |err| {
            self.pending.poison();
            return err;
        };
    }

    pub inline fn sendPingAck(self: *Session, out: *std.Io.Writer, payload_bytes: *const [8]u8) SendSimpleControlError!void {
        try self.sendPing(out, true, payload_bytes);
    }

    /// Advertises newly freed receive credit and commits the matching local
    /// accounting only after the WINDOW_UPDATE bytes are successfully written.
    /// Stream-level updates remain valid for retained closed stream records,
    /// matching the race-tolerant HTTP/2 rules.
    pub fn sendWindowUpdate(
        self: *Session,
        store: anytype,
        out: *std.Io.Writer,
        stream_id: u31,
        increment: u31,
    ) SendStreamControlError!void {
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (increment == 0) return error.Protocol;

        if (stream_id == 0) {
            var next = self.connection.receive_window;
            next.update(increment) catch return error.FlowControl;
            send_mod.writeWindowUpdate(out, 0, increment) catch |err| switch (err) {
                error.Protocol => unreachable,
                error.WriteFailed => {
                    self.pending.poison();
                    return error.WriteFailed;
                },
            };
            self.connection.receive_window = next;
            return;
        }

        const tracked = store.get(stream_id) orelse return error.StreamClosed;
        try self.sendWindowUpdateTracked(out, stream_id, tracked, increment);
    }

    pub fn sendWindowUpdateExisting(
        self: *Session,
        out: *std.Io.Writer,
        existing: streams_mod.Existing,
        increment: u31,
    ) SendStreamControlError!void {
        if (existing.manager != &self.streams) return error.Protocol;
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (increment == 0) return error.Protocol;
        try self.sendWindowUpdateTracked(out, existing.stream_id, existing.tracked, increment);
    }

    fn sendWindowUpdateTracked(
        self: *Session,
        out: *std.Io.Writer,
        stream_id: u31,
        tracked: *stream_mod.Tracked,
        increment: u31,
    ) SendStreamControlError!void {
        var next = tracked.windows.receive;
        next.update(increment) catch return error.FlowControl;
        send_mod.writeWindowUpdate(out, stream_id, increment) catch |err| switch (err) {
            error.Protocol => unreachable,
            error.WriteFailed => {
                self.pending.poison();
                return error.WriteFailed;
            },
        };
        tracked.windows.receive = next;
    }

    /// Sends RST_STREAM and closes the retained local stream record only after
    /// the reset frame is committed to the writer.
    pub fn sendReset(
        self: *Session,
        store: anytype,
        out: *std.Io.Writer,
        stream_id: u31,
        code: protocol.ErrorCode,
    ) SendStreamControlError!void {
        if (self.pending.poisoned()) return error.SendPoisoned;
        const tracked = store.get(stream_id) orelse return error.StreamClosed;
        try self.sendResetTracked(out, stream_id, tracked, code);
    }

    pub fn sendResetExisting(
        self: *Session,
        out: *std.Io.Writer,
        existing: streams_mod.Existing,
        code: protocol.ErrorCode,
    ) SendStreamControlError!void {
        if (existing.manager != &self.streams) return error.Protocol;
        if (self.pending.poisoned()) return error.SendPoisoned;
        try self.sendResetTracked(out, existing.stream_id, existing.tracked, code);
    }

    fn sendResetTracked(
        self: *Session,
        out: *std.Io.Writer,
        stream_id: u31,
        tracked: *stream_mod.Tracked,
        code: protocol.ErrorCode,
    ) SendStreamControlError!void {
        if (tracked.stream.state == .closed) return error.StreamClosed;
        var manager_probe = self.streams;
        var tracked_probe = tracked.*;
        try manager_probe.localResetTracked(stream_id, &tracked_probe);

        send_mod.writeReset(out, stream_id, code) catch |err| switch (err) {
            error.Protocol => return error.Protocol,
            error.WriteFailed => {
                self.pending.poison();
                return error.WriteFailed;
            },
        };
        self.streams.localResetTracked(stream_id, tracked) catch {
            self.pending.poison();
            return error.Protocol;
        };
    }

    /// Starts or tightens graceful shutdown. The monotonic GOAWAY stream cutoff
    /// is preflighted before writing and committed only after the frame succeeds.
    pub fn sendGoAway(
        self: *Session,
        out: *std.Io.Writer,
        last_stream_id: u31,
        code: protocol.ErrorCode,
        debug_data: []const u8,
    ) SendGoAwayError!void {
        if (self.pending.poisoned()) return error.SendPoisoned;
        var manager_probe = self.streams;
        try manager_probe.sentGoAway(last_stream_id);

        send_mod.writeGoAway(out, self.peer.settings.max_frame_size, last_stream_id, code, debug_data) catch |err| switch (err) {
            error.FrameTooLarge => return error.FrameTooLarge,
            error.WriteFailed => {
                self.pending.poison();
                return error.WriteFailed;
            },
        };
        self.streams.sentGoAway(last_stream_id) catch {
            self.pending.poison();
            return error.Protocol;
        };
    }

    fn sendDataTracked(
        self: *Session,
        out: *std.Io.Writer,
        stream_id: u31,
        tracked: *stream_mod.Tracked,
        bytes: []const u8,
        end_stream: bool,
    ) SendDataError!SendDataResult {
        switch (tracked.stream.state) {
            .open, .half_closed_remote => {},
            .half_closed_local, .closed => return error.StreamClosed,
            else => return error.Protocol,
        }
        if (bytes.len == 0 and !end_stream)
            return .{ .consumed = 0, .blocked = false, .end_stream = false };

        const available = @min(
            @as(usize, self.peer.send_window.available()),
            @as(usize, tracked.windows.send.available()),
            @as(usize, self.peer.settings.max_frame_size),
        );
        if (bytes.len != 0 and available == 0)
            return .{ .consumed = 0, .blocked = true, .end_stream = false };

        const amount = @min(bytes.len, available);
        const will_end = end_stream and amount == bytes.len;
        const header: frame.FrameHeader = .{
            .length = @intCast(amount),
            .type = .data,
            .flags = @intFromBool(will_end),
            .stream_id = stream_id,
        };
        frame.writeFrame(out, header, bytes[0..amount]) catch |err| {
            self.pending.poison();
            return switch (err) {
                error.WriteFailed => error.WriteFailed,
                error.FrameTooLarge => unreachable,
            };
        };
        self.peer.consumeSend(@intCast(amount)) catch {
            self.pending.poison();
            return error.FlowControl;
        };
        self.streams.localDataTracked(stream_id, tracked, @intCast(amount), will_end) catch |err| {
            self.pending.poison();
            return err;
        };
        return .{
            .consumed = amount,
            .blocked = amount < bytes.len,
            .end_stream = will_end,
        };
    }

    pub inline fn sendPoisoned(self: Session) bool {
        return self.pending.poisoned();
    }

    fn localHeaderKindTracked(self: *Session, tracked: ?*stream_mod.Tracked, stream_id: u31) fields.Kind {
        if (tracked) |value| {
            if (value.local_headers != .initial) return .trailers;
            return if (self.streams.local_role == .server) .response else .request;
        }
        return if (self.streams.local_role == .client and self.streams.localInitiated(stream_id)) .request else .response;
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
        self.pending.set(pending);
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
        self.pending.set(pending);
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
        const field_kind: fields.Kind = if (pending.isPushPromise()) .request else self.headerKind(store, pending.streamId());
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
                sink.field(if (pending.isPushPromise()) pending.promisedStream() else pending.streamId(), field_kind, header);
                field_count +|= 1;
            }
        }
        if (!invalid) {
            validator.finish() catch {
                invalid = true;
            };
        }
        if (invalid) return .{ .fault = .{ .stream = .{ .stream_id = pending.streamId(), .code = .protocol_error } } };

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
            return .{ .fault = .{ .stream = .{ .stream_id = pending.streamId(), .code = .protocol_error } } };

        const result = self.streams.receiveHeaders(store, &self.peer, pending.streamId(), end_stream);
        if (receiveFault(pending.streamId(), result)) |fault| return .{ .fault = fault };
        if (result == .ignored_after_goaway) return .ignored;

        if (store.get(pending.streamId())) |tracked| {
            if (field_kind == .trailers) {
                tracked.remote_headers = .trailers;
            } else if (field_kind == .request or !informational) {
                tracked.remote_headers = .regular;
            }
        }
        return .{ .headers = .{
            .stream_id = pending.streamId(),
            .kind = field_kind,
            .end_stream = end_stream,
            .field_count = field_count,
            .status_code = status,
        } };
    }

    fn commitPushPromise(self: *Session, store: anytype, pending: Pending, field_count: u32) Event {
        const promised_stream_id = pending.promisedStream();
        const result = self.streams.receivePushPromise(store, &self.peer, pending.streamId(), promised_stream_id);
        if (receiveFault(pending.streamId(), result)) |fault| return .{ .fault = fault };
        if (result == .ignored_after_goaway) return .ignored;
        return .{ .push_promise = .{
            .associated_stream_id = pending.streamId(),
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

fn validateLocalFields(kind: fields.Kind, end_stream: bool, items: []const hpack.EncodedField) error{Protocol}!u16 {
    var validator = fields.Validator.init(kind);
    var status: u16 = 0;
    for (items) |item| {
        const header: common.Header = .{ .name = item.field.name, .value = item.field.value };
        validator.field(header) catch return error.Protocol;
        if (kind == .response and header.name.len == 7 and std.mem.eql(u8, header.name, ":status")) {
            status = @as(u16, header.value[0] - '0') * 100 + @as(u16, header.value[1] - '0') * 10 + @as(u16, header.value[2] - '0');
        }
    }
    validator.finish() catch return error.Protocol;
    if (kind == .trailers and !end_stream) return error.Protocol;
    if (kind == .response) {
        const informational = status >= 100 and status < 200;
        if (status == 101 or (informational and end_stream)) return error.Protocol;
    }
    return status;
}

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

test "send session remains compact with local header phase" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Session));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(stream_mod.Tracked));
}

test "session streams request HEADERS through continuations" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.client, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};

    const items = [_]hpack.EncodedField{
        .{ .field = .{ .name = ":method", .value = "GET" } },
        .{ .field = .{ .name = ":scheme", .value = "https" } },
        .{ .field = .{ .name = ":authority", .value = "example.com" } },
        .{ .field = .{ .name = ":path", .value = "/a/realistically/long/path" } },
        .{ .field = .{ .name = "accept", .value = "application/json" } },
    };
    var staging: [9]u8 = undefined; // eight HPACK bytes per frame
    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    const stats = try session.sendHeaders(&store, &wire, 1, false, &staging, &items);
    try std.testing.expect(stats.frame_count > 1);
    try std.testing.expectEqual(stream_mod.RemoteHeaders.regular, store.get(1).?.local_headers);
    try std.testing.expectEqual(stream_mod.State.open, store.get(1).?.stream.state);

    var it = frame.CompleteIterator.init(wire.buffered(), frame.default_max_frame_size);
    var encoded: [256]u8 = undefined;
    var encoded_len: usize = 0;
    var frames: u32 = 0;
    while ((try it.next())) |complete| {
        frames += 1;
        if (frames == 1) {
            try std.testing.expectEqual(frame.Type.headers, complete.header.type);
            try std.testing.expect((complete.header.flags & 0x04) == 0);
        } else {
            try std.testing.expectEqual(frame.Type.continuation, complete.header.type);
        }
        @memcpy(encoded[encoded_len..][0..complete.payload.len], complete.payload);
        encoded_len += complete.payload.len;
        if (frames == stats.frame_count) try std.testing.expect((complete.header.flags & 0x04) != 0);
    }
    try std.testing.expectEqual(stats.frame_count, frames);

    var verifier = hpack.Decoder.init(allocator, 4096);
    defer verifier.deinit();
    var scratch: [512]u8 = undefined;
    var fields_it = verifier.iterator(encoded[0..encoded_len], &scratch);
    var count: usize = 0;
    while (try fields_it.next()) |_| count += 1;
    try std.testing.expectEqual(items.len, count);
}

test "session DATA send obeys flow control and caller backpressure" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.client, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};

    const items = [_]hpack.EncodedField{
        .{ .field = .{ .name = ":method", .value = "POST" } },
        .{ .field = .{ .name = ":scheme", .value = "https" } },
        .{ .field = .{ .name = ":path", .value = "/upload" } },
    };
    var staging: [256]u8 = undefined;
    var head_wire_storage: [512]u8 = undefined;
    var head_wire = std.Io.Writer.fixed(&head_wire_storage);
    _ = try session.sendHeaders(&store, &head_wire, 1, false, &staging, &items);

    var body: [20_000]u8 = undefined;
    @memset(&body, 'x');
    var data_wire_storage: [24_000]u8 = undefined;
    var data_wire = std.Io.Writer.fixed(&data_wire_storage);
    const first = try session.sendData(&store, &data_wire, 1, &body, true);
    try std.testing.expectEqual(@as(usize, frame.default_max_frame_size), first.consumed);
    try std.testing.expect(first.blocked);
    try std.testing.expect(!first.end_stream);
    const second = try session.sendData(&store, &data_wire, 1, body[first.consumed..], true);
    try std.testing.expectEqual(body.len - first.consumed, second.consumed);
    try std.testing.expect(!second.blocked);
    try std.testing.expect(second.end_stream);
    try std.testing.expectEqual(stream_mod.State.half_closed_local, store.get(1).?.stream.state);

    // A new stream can close with an empty DATA frame even at zero credit.
    var session2 = Session.init(.client, .{}, &inbound, &outbound, &block_storage);
    var store2: TestStore = .{};
    var h2_storage: [512]u8 = undefined;
    var h2 = std.Io.Writer.fixed(&h2_storage);
    _ = try session2.sendHeaders(&store2, &h2, 1, false, &staging, &items);
    session2.peer.send_window.value = 0;
    store2.get(1).?.windows.send.value = 0;
    var d2_storage: [32]u8 = undefined;
    var d2 = std.Io.Writer.fixed(&d2_storage);
    const blocked = try session2.sendData(&store2, &d2, 1, "x", true);
    try std.testing.expect(blocked.blocked);
    try std.testing.expectEqual(@as(usize, 0), d2.buffered().len);
    const empty_end = try session2.sendData(&store2, &d2, 1, "", true);
    try std.testing.expect(empty_end.end_stream);
    try std.testing.expectEqual(@as(usize, 9), d2.buffered().len);
}

test "writer failure poisons session send side" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [32]u8 = undefined;
    var session = Session.init(.client, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};
    const items = [_]hpack.EncodedField{
        .{ .field = .{ .name = ":method", .value = "GET" } },
        .{ .field = .{ .name = ":scheme", .value = "https" } },
        .{ .field = .{ .name = ":path", .value = "/" } },
    };
    var staging: [8]u8 = undefined;
    var tiny: [4]u8 = undefined;
    var out = std.Io.Writer.fixed(&tiny);
    try std.testing.expectError(error.WriteFailed, session.sendHeaders(&store, &out, 1, true, &staging, &items));
    try std.testing.expect(session.sendPoisoned());
    try std.testing.expectError(error.SendPoisoned, session.sendHeaders(&store, &out, 3, true, &staging, &items));
}

test "send response tracks informational final and trailers phases" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var storage: [64]u8 = undefined;
    var session = Session.init(.server, .{}, &inbound, &outbound, &storage);
    var store: TestStore = .{};
    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, session.streams.receiveHeaders(&store, &session.peer, 1, true));

    var frame_staging: [256]u8 = undefined;
    var wire_storage: [1024]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    const early = [_]hpack.EncodedField{.{ .field = .{ .name = ":status", .value = "103" } }};
    _ = try session.sendHeaders(&store, &wire, 1, false, &frame_staging, &early);
    try std.testing.expectEqual(stream_mod.RemoteHeaders.initial, store.get(1).?.local_headers);
    try std.testing.expectEqual(stream_mod.State.half_closed_remote, store.get(1).?.stream.state);

    const final = [_]hpack.EncodedField{
        .{ .field = .{ .name = ":status", .value = "200" } },
        .{ .field = .{ .name = "content-type", .value = "text/plain" } },
    };
    _ = try session.sendHeaders(&store, &wire, 1, false, &frame_staging, &final);
    try std.testing.expectEqual(stream_mod.RemoteHeaders.regular, store.get(1).?.local_headers);

    const trailers = [_]hpack.EncodedField{.{ .field = .{ .name = "x-checksum", .value = "ok" } }};
    _ = try session.sendHeaders(&store, &wire, 1, true, &frame_staging, &trailers);
    try std.testing.expectEqual(stream_mod.RemoteHeaders.trailers, store.get(1).?.local_headers);
    try std.testing.expectEqual(stream_mod.State.closed, store.get(1).?.stream.state);
}

test "invalid local fields fail before stream or HPACK mutation" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var storage: [64]u8 = undefined;
    var session = Session.init(.server, .{}, &inbound, &outbound, &storage);
    var store: TestStore = .{};
    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, session.streams.receiveHeaders(&store, &session.peer, 1, true));
    const before_state = store.get(1).?.stream.state;
    const before_count = outbound.dynamic.count();
    const invalid = [_]hpack.EncodedField{.{ .field = .{ .name = "content-type", .value = "text/plain" }, .indexing = .incremental }};
    var staging: [128]u8 = undefined;
    var wire_storage: [128]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    try std.testing.expectError(error.Protocol, session.sendHeaders(&store, &wire, 1, false, &staging, &invalid));
    try std.testing.expectEqual(@as(usize, 0), wire.buffered().len);
    try std.testing.expectEqual(before_state, store.get(1).?.stream.state);
    try std.testing.expectEqual(before_count, outbound.dynamic.count());
    try std.testing.expect(!session.sendPoisoned());
}

test "session sends HTTP2 control frames with state-aware commits" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.server, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};

    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, session.streams.receiveHeaders(&store, &session.peer, 1, false));
    try std.testing.expectEqual(@as(u32, 1), session.streams.activeRemote());
    session.connection.receive_window.value = 60_000;
    store.get(1).?.windows.receive.value = 59_000;

    var wire_storage: [256]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    try session.sendSettingsAck(&wire);
    const ping_bytes = "pingpong".*;
    try session.sendPingAck(&wire, &ping_bytes);
    try session.sendWindowUpdate(&store, &wire, 0, 1000);
    try session.sendWindowUpdate(&store, &wire, 1, 2000);
    try std.testing.expectEqual(@as(u31, 61_000), session.connection.receive_window.available());
    try std.testing.expectEqual(@as(u31, 61_000), store.get(1).?.windows.receive.available());

    try session.sendReset(&store, &wire, 1, .cancel);
    try std.testing.expectEqual(stream_mod.State.closed, store.get(1).?.stream.state);
    try std.testing.expectEqual(@as(u32, 0), session.streams.activeRemote());

    try session.sendGoAway(&wire, 1, .no_error, "done");
    try std.testing.expect(session.streams.goAwaySent());
    try std.testing.expectEqual(@as(?u31, 1), session.streams.lastSentGoAwayStream());

    var frames = frame.CompleteIterator.init(wire.buffered(), frame.default_max_frame_size);
    const settings_ack = (try frames.next()).?;
    try std.testing.expectEqual(frame.Type.settings, settings_ack.header.type);
    try std.testing.expectEqual(@as(u8, 0x01), settings_ack.header.flags);

    const ping = (try frames.next()).?;
    try std.testing.expectEqual(frame.Type.ping, ping.header.type);
    try std.testing.expectEqual(@as(u8, 0x01), ping.header.flags);
    try std.testing.expectEqualStrings(&ping_bytes, ping.payload);

    const connection_update = (try frames.next()).?;
    try std.testing.expectEqual(@as(u31, 0), connection_update.header.stream_id);
    try std.testing.expectEqual(@as(u32, 1000), std.mem.readInt(u32, connection_update.payload[0..4], .big));

    const stream_update = (try frames.next()).?;
    try std.testing.expectEqual(@as(u31, 1), stream_update.header.stream_id);
    try std.testing.expectEqual(@as(u32, 2000), std.mem.readInt(u32, stream_update.payload[0..4], .big));

    const reset = (try frames.next()).?;
    try std.testing.expectEqual(frame.Type.rst_stream, reset.header.type);
    try std.testing.expectEqual(@as(u32, @intFromEnum(protocol.ErrorCode.cancel)), std.mem.readInt(u32, reset.payload[0..4], .big));

    const goaway = (try frames.next()).?;
    try std.testing.expectEqual(frame.Type.goaway, goaway.header.type);
    try std.testing.expectEqualStrings("done", goaway.payload[8..]);
    try std.testing.expect((try frames.next()) == null);
}

test "session control preflight is retry safe and writer failure poisons" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.server, .{}, &inbound, &outbound, &block_storage);
    var store: TestStore = .{};
    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, session.streams.receiveHeaders(&store, &session.peer, 1, false));

    var storage: [32]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    const before = out.buffered().len;
    try std.testing.expectError(error.Protocol, session.sendWindowUpdate(&store, &out, 1, 0));
    try std.testing.expectEqual(before, out.buffered().len);
    try std.testing.expect(!session.sendPoisoned());

    session.peer.settings.max_frame_size = 8;
    try std.testing.expectError(error.FrameTooLarge, session.sendGoAway(&out, 1, .no_error, "x"));
    try std.testing.expect(!session.streams.goAwaySent());
    try std.testing.expect(!session.sendPoisoned());
    session.peer.settings.max_frame_size = frame.default_max_frame_size;

    session.connection.receive_window.value = 60_000;
    var no_space: [0]u8 = .{};
    var failing = std.Io.Writer.fixed(&no_space);
    try std.testing.expectError(error.WriteFailed, session.sendWindowUpdate(&store, &failing, 0, 1000));
    try std.testing.expectEqual(@as(u31, 60_000), session.connection.receive_window.available());
    try std.testing.expect(session.sendPoisoned());
}
