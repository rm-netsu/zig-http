const std = @import("std");
const hpack = @import("hpack");
const common = @import("../common.zig");
const connection = @import("connection.zig");
const contracts = @import("contracts.zig");
const dispatch = @import("dispatch.zig");
const fields = @import("fields.zig");
const frame = @import("frame.zig");
const flow = @import("flow.zig");
const header_block = @import("header_block.zig");
const payload = @import("payload.zig");
const peer_mod = @import("peer.zig");
const protocol = @import("protocol.zig");
const stream_mod = @import("stream.zig");
const streams_mod = @import("streams.zig");
const send_mod = @import("send.zig");
const settings = @import("settings.zig");

pub const Fault = union(enum) {
    connection: protocol.ErrorCode,
    stream: struct { stream_id: u31, code: protocol.ErrorCode },
};

pub const HeaderSection = struct {
    /// Parsed Content-Length value. Consult `contentLength()` rather than this
    /// field directly because zero is itself a valid Content-Length value.
    content_length: u64 = 0,
    stream_id: u31,
    field_count: u32,
    /// Non-zero only for response field sections.
    status_code: u16 = 0,
    kind: fields.Kind,
    end_stream: bool,
    has_content_length: bool = false,
    /// True for an RFC 8441 CONNECT request carrying the :protocol pseudo-header.
    extended_connect: bool = false,

    /// The caller can feed DATA byte counts into `fields.BodyLength` without
    /// Session retaining application-message state per stream.
    pub inline fn contentLength(self: HeaderSection) ?u64 {
        return if (self.has_content_length) self.content_length else null;
    }
};

pub const PushPromise = struct {
    associated_stream_id: u31,
    promised_stream_id: u31,
    field_count: u32,
};

pub const Data = dispatch.Data;

pub const SettingsTicket = u32;

/// Tiny caller-owned SETTINGS synchronization state. Session writes register a
/// ticket only after the frame is committed; received ACK events can then pop
/// the oldest outstanding ticket in RFC-required order without Session owning a
/// policy queue or allocator-backed state.
pub const SettingsSync = struct {
    sent: SettingsTicket = 0,
    acked: SettingsTicket = 0,

    fn recordSent(self: *SettingsSync) error{SettingsSequenceExhausted}!SettingsTicket {
        if (self.sent == std.math.maxInt(SettingsTicket)) return error.SettingsSequenceExhausted;
        self.sent += 1;
        return self.sent;
    }

    pub fn acknowledge(self: *SettingsSync) ?SettingsTicket {
        if (self.acked == self.sent) return null;
        self.acked += 1;
        return self.acked;
    }

    pub inline fn outstanding(self: SettingsSync) u32 {
        return self.sent - self.acked;
    }
};

pub const SettingsApplied = struct {
    /// Raw validated SETTINGS payload. It aliases caller-owned frame input and
    /// lets composed Session users inspect extension settings without forcing
    /// Session itself to understand or retain them. Empty for ACK frames.
    bytes: []const u8,
    ack: bool,
    count: u16,

    /// Matches this received ACK to the oldest SETTINGS frame successfully sent
    /// through the same caller-owned synchronization state.
    pub inline fn iterator(self: SettingsApplied) settings.Iterator {
        return settings.Iterator.init(self.bytes) catch unreachable;
    }

    pub inline fn acknowledge(self: SettingsApplied, sync: *SettingsSync) ?SettingsTicket {
        if (!self.ack) return null;
        return sync.acknowledge();
    }
};

/// Caller-owned helper for RFC 9113 graceful server shutdown. It performs only
/// HTTP/2 state transitions: the caller remains responsible for choosing the
/// grace interval and for supplying the final last-stream-id based on what its
/// application layer might have processed.
pub const GracefulGoAway = struct {
    phase: Phase = .open,

    pub const Phase = enum(u2) { open, announced, final };

    /// Sends the initial GOAWAY(MAX_STREAM_ID, NO_ERROR). No timer is started;
    /// the caller decides when enough time has passed before `finish()`.
    pub fn announce(
        self: *GracefulGoAway,
        session: *Session,
        out: *std.Io.Writer,
        debug_data: []const u8,
    ) SendGoAwayError!void {
        if (self.phase != .open or session.streams.local_role != .server) return error.Protocol;
        try session.sendGoAway(out, std.math.maxInt(u31), .no_error, debug_data);
        self.phase = .announced;
    }

    /// Sends the final NO_ERROR cutoff. The caller supplies the highest peer-
    /// initiated stream that might have been processed; Session deliberately
    /// does not infer application-level processing from protocol receipt.
    pub fn finish(
        self: *GracefulGoAway,
        session: *Session,
        out: *std.Io.Writer,
        last_stream_id: u31,
        debug_data: []const u8,
    ) SendGoAwayError!void {
        if (self.phase != .announced) return error.Protocol;
        try session.sendGoAway(out, last_stream_id, .no_error, debug_data);
        self.phase = .final;
    }
};

pub const ExtensionFrame = struct {
    /// Payload aliases caller-owned frame input. Unknown/unsupported frame
    /// semantics remain the caller's responsibility; Session intentionally does
    /// not mutate stream state for extension frames.
    payload: []const u8,
    stream_id: u31,
    type: u8,
    flags: u8,

    pub inline fn header(self: ExtensionFrame) frame.FrameHeader {
        return .{
            .length = @intCast(self.payload.len),
            .type = @enumFromInt(self.type),
            .flags = self.flags,
            .stream_id = self.stream_id,
        };
    }
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
    extension: ExtensionFrame,
};

pub const CompleteResult = struct {
    consumed: usize,
    event: Event,
};

pub const SendHeadersResult = send_mod.HeaderFrameStats;
pub const SendPushPromiseResult = send_mod.HeaderFrameStats;

pub const SendDataResult = struct {
    consumed: usize,
    blocked: bool,
    end_stream: bool,
};

pub const DataSendCredit = struct {
    /// Maximum DATA payload that can be emitted now after connection, stream,
    /// and peer frame-size limits are combined.
    max_payload: usize,
};

pub const SendHeadersError = hpack.codec.Error || streams_mod.LocalError || error{ BufferTooSmall, SendPoisoned, TrailerPolicyRequired, TrailerRejected };
pub const SendPushPromiseError = hpack.codec.Error || streams_mod.LocalError || error{ BufferTooSmall, SendPoisoned };
pub const SendDataError = std.Io.Writer.Error || streams_mod.LocalError || error{SendPoisoned};
pub const DataSendCreditError = streams_mod.LocalError || error{SendPoisoned};
pub const SendSettingsError = std.Io.Writer.Error || error{ FrameTooLarge, Protocol, FlowControl, SettingsSequenceExhausted, SendPoisoned };
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

/// Integrated HTTP/2 session state over caller-owned stream and header-block
/// storage. This remains protocol core: it owns HTTP/2 state transitions but no
/// sockets, TLS, event loop, timers, or application work queues. HPACK codec
/// objects remain caller-owned because they own allocator-backed dynamic tables;
/// this type merely holds stable pointers.
///
/// The stream store extends the `StreamManager` contract with one operation:
///
///     maxActiveSendAdjustment() i32
///
/// This is consulted only when a rare SETTINGS_INITIAL_WINDOW_SIZE increase
/// could overflow a stream according to the manager's conservative high-water
/// mark. Stores can scan, maintain an aggregate, or coordinate shards however
/// they choose; ordinary SETTINGS changes require no store-wide mutation.
pub const Session = struct {
    connection: connection.State = .{},
    streams: streams_mod.Manager,
    peer: peer_mod.State,
    decoder: *hpack.Decoder,
    encoder: *hpack.Encoder,
    collector: header_block.Collector,
    pending: Pending = .{},

    /// Named initialization form for consumers that prefer a stable, self-
    /// documenting configuration surface. All storage and HPACK ownership stays
    /// with the caller; this is configuration only, not a runtime wrapper.
    pub const Options = struct {
        role: peer_mod.Role,
        local_limits: streams_mod.LocalLimits = .{},
        decoder: *hpack.Decoder,
        encoder: *hpack.Encoder,
        header_storage: []u8,
    };

    pub fn init(options: Options) Session {
        return .{
            .streams = streams_mod.Manager.init(options.role, options.local_limits),
            .peer = peer_mod.State.init(options.role),
            .decoder = options.decoder,
            .encoder = options.encoder,
            .collector = header_block.Collector.init(options.header_storage),
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
        comptime contracts.assertStreamStore(@TypeOf(store));
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (self.streams.unprocessedByPeer(&self.peer, stream_id)) return error.GoAway;

        const existing = store.get(stream_id);
        const kind = self.localHeaderKindTracked(existing, stream_id);
        const field_info = try validateLocalFields(kind, end_stream, items);
        if (kind == .trailers and items.len != 0) return error.TrailerPolicyRequired;
        if (field_info.extended_connect and
            (self.streams.local_role != .client or !self.peer.settings.enable_connect_protocol))
            return error.Protocol;
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

        return self.finishSendHeaders(&framer, tracked.?, kind, field_info.status, items);
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
        const field_info = try validateLocalFields(kind, end_stream, items);
        if (kind == .trailers and items.len != 0) return error.TrailerPolicyRequired;
        if (field_info.extended_connect and
            (self.streams.local_role != .client or !self.peer.settings.enable_connect_protocol))
            return error.Protocol;
        var framer = send_mod.HeaderFramer.init(
            out,
            frame_staging,
            self.peer.settings.max_frame_size,
            existing.stream_id,
            end_stream,
        ) catch return error.BufferTooSmall;
        try self.streams.localHeadersTracked(&self.peer, existing.stream_id, existing.tracked, end_stream);
        return self.finishSendHeaders(&framer, existing.tracked, kind, field_info.status, items);
    }

    /// Streams a non-empty trailer field section after caller policy confirms
    /// that every field definition permits trailer placement. Trailer syntax,
    /// stream state, and the complete policy decision are preflighted before
    /// HPACK or wire mutation. Trailers always carry END_STREAM.
    ///
    /// `policy` must provide:
    ///
    ///     pub fn allows(self: @This(), name: []const u8) bool
    ///
    /// Empty trailers do not need a policy and may be sent with `sendHeaders`.
    pub fn sendTrailers(
        self: *Session,
        store: anytype,
        out: *std.Io.Writer,
        stream_id: u31,
        frame_staging: []u8,
        items: []const hpack.EncodedField,
        policy: anytype,
    ) SendHeadersError!SendHeadersResult {
        comptime contracts.assertStreamStore(@TypeOf(store));
        comptime contracts.assertTrailerPolicy(@TypeOf(policy));
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (self.streams.unprocessedByPeer(&self.peer, stream_id)) return error.GoAway;
        const tracked = store.get(stream_id) orelse return error.Protocol;
        if (self.localHeaderKindTracked(tracked, stream_id) != .trailers) return error.Protocol;
        _ = try validateLocalFields(.trailers, true, items);
        try validateTrailerPolicy(items, policy);

        var framer = send_mod.HeaderFramer.init(
            out,
            frame_staging,
            self.peer.settings.max_frame_size,
            stream_id,
            true,
        ) catch return error.BufferTooSmall;
        try self.streams.localHeadersTracked(&self.peer, stream_id, tracked, true);
        return self.finishSendHeaders(&framer, tracked, .trailers, 0, items);
    }

    /// Trailer fast path for a caller that already holds a stable stream record.
    /// The same full semantic preflight as `sendTrailers` occurs before mutation.
    pub fn sendTrailersExisting(
        self: *Session,
        out: *std.Io.Writer,
        existing: streams_mod.Existing,
        frame_staging: []u8,
        items: []const hpack.EncodedField,
        policy: anytype,
    ) SendHeadersError!SendHeadersResult {
        comptime contracts.assertTrailerPolicy(@TypeOf(policy));
        if (existing.manager != &self.streams) return error.Protocol;
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (self.streams.unprocessedByPeer(&self.peer, existing.stream_id)) return error.GoAway;
        if (self.localHeaderKindTracked(existing.tracked, existing.stream_id) != .trailers) return error.Protocol;
        _ = try validateLocalFields(.trailers, true, items);
        try validateTrailerPolicy(items, policy);

        var framer = send_mod.HeaderFramer.init(
            out,
            frame_staging,
            self.peer.settings.max_frame_size,
            existing.stream_id,
            true,
        ) catch return error.BufferTooSmall;
        try self.streams.localHeadersTracked(&self.peer, existing.stream_id, existing.tracked, true);
        return self.finishSendHeaders(&framer, existing.tracked, .trailers, 0, items);
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

    /// Streams one server PUSH_PROMISE field block and reserves the promised
    /// stream in caller-owned storage. The promised stream remains
    /// `reserved(local)` until its response HEADERS are sent.
    ///
    /// Field and stream preconditions are checked before HPACK output starts.
    /// Once encoding begins, HPACK/writer failure poisons the send side because
    /// the connection-scoped compression context or wire may have advanced.
    pub fn sendPushPromise(
        self: *Session,
        store: anytype,
        out: *std.Io.Writer,
        associated_stream_id: u31,
        promised_stream_id: u31,
        frame_staging: []u8,
        items: []const hpack.EncodedField,
    ) SendPushPromiseError!SendPushPromiseResult {
        comptime contracts.assertStreamStore(@TypeOf(store));
        if (self.pending.poisoned()) return error.SendPoisoned;
        const field_info = try validateLocalFields(.request, false, items);
        // Extended CONNECT is a client-created request stream, never a server
        // PUSH_PROMISE request template.
        if (field_info.extended_connect) return error.Protocol;
        var framer = send_mod.HeaderFramer.initPushPromise(
            out,
            frame_staging,
            self.peer.settings.max_frame_size,
            associated_stream_id,
            promised_stream_id,
        ) catch return error.BufferTooSmall;

        try self.streams.reserveLocal(store, &self.peer, associated_stream_id, promised_stream_id);
        for (items) |item| {
            self.encoder.field(&framer.writer, item.field, item.indexing) catch |err| {
                self.pending.poison();
                return err;
            };
        }
        return framer.finish() catch |err| {
            self.pending.poison();
            return err;
        };
    }

    /// Probes current DATA send credit without mutating protocol state. This is
    /// intended for caller-owned schedulers that want to choose a runnable
    /// stream before touching the transport writer.
    pub fn dataSendCredit(
        self: *const Session,
        store: anytype,
        stream_id: u31,
    ) DataSendCreditError!DataSendCredit {
        comptime contracts.assertStreamStore(@TypeOf(store));
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (self.streams.unprocessedByPeer(&self.peer, stream_id)) return error.GoAway;
        const tracked = store.get(stream_id) orelse return error.StreamClosed;
        return self.dataSendCreditTracked(tracked);
    }

    pub inline fn dataSendCreditExisting(
        self: *const Session,
        existing: streams_mod.Existing,
    ) DataSendCreditError!DataSendCredit {
        if (existing.manager != &self.streams) return error.Protocol;
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (self.streams.unprocessedByPeer(&self.peer, existing.stream_id)) return error.GoAway;
        return self.dataSendCreditTrackedFused(existing.tracked);
    }

    inline fn dataSendCreditTracked(self: *const Session, tracked: *const stream_mod.Tracked) streams_mod.LocalError!DataSendCredit {
        switch (tracked.stream.state) {
            .open, .half_closed_remote => {},
            .half_closed_local, .closed => return error.StreamClosed,
            else => return error.Protocol,
        }
        return .{ .max_payload = @min(
            @as(usize, self.peer.send_window.available()),
            @as(usize, tracked.windows.send.available(self.peer.settings.initial_window_size)),
            @as(usize, self.peer.settings.max_frame_size),
        ) };
    }

    inline fn dataSendCreditTrackedFused(self: *const Session, tracked: *const stream_mod.Tracked) streams_mod.LocalError!DataSendCredit {
        switch (tracked.stream.state) {
            .open, .half_closed_remote => {},
            .half_closed_local, .closed => return error.StreamClosed,
            else => return error.Protocol,
        }
        const stream_window = tracked.windows.send.adjustment + @as(i32, @intCast(self.peer.settings.initial_window_size));
        const bounded = @min(
            self.peer.send_window.value,
            stream_window,
            @as(i32, @intCast(self.peer.settings.max_frame_size)),
        );
        return .{ .max_payload = if (bounded <= 0) 0 else @intCast(bounded) };
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
        comptime contracts.assertStreamStore(@TypeOf(store));
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (self.streams.unprocessedByPeer(&self.peer, stream_id)) return error.GoAway;
        const tracked = store.get(stream_id) orelse return error.StreamClosed;
        return self.sendDataTracked(out, stream_id, tracked, bytes, end_stream, false);
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
        return self.sendDataTracked(out, existing.stream_id, existing.tracked, bytes, end_stream, true);
    }

    /// Sends one SETTINGS frame and returns a synchronization ticket. ACKs are
    /// matched to these tickets in send order by caller-owned `SettingsSync`.
    /// The tracker stores only frame order; applications remain free to attach
    /// arbitrary local policy snapshots to the returned ticket.
    pub fn sendSettings(
        self: *Session,
        sync: *SettingsSync,
        out: *std.Io.Writer,
        items: []const settings.Setting,
    ) SendSettingsError!SettingsTicket {
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (sync.sent == std.math.maxInt(SettingsTicket)) return error.SettingsSequenceExhausted;
        const next_connect_protocol = try validateLocalSettings(
            self.streams.local_role,
            self.streams.extendedConnectAdvertised(),
            items,
        );

        send_mod.writeSettings(out, items, self.peer.settings.max_frame_size) catch |err| switch (err) {
            error.FrameTooLarge => return error.FrameTooLarge,
            error.WriteFailed => {
                self.pending.poison();
                return error.WriteFailed;
            },
        };
        // Commit local SETTINGS state only after the complete frame write.
        self.streams.setExtendedConnectAdvertised(next_connect_protocol);
        return sync.recordSent() catch unreachable;
    }

    /// Whether this endpoint has committed SETTINGS_ENABLE_CONNECT_PROTOCOL=1.
    pub inline fn extendedConnectAdvertised(self: Session) bool {
        return self.streams.extendedConnectAdvertised();
    }

    /// Whether the peer has advertised RFC 8441 Extended CONNECT support.
    pub inline fn peerSupportsExtendedConnect(self: Session) bool {
        return self.peer.settings.enable_connect_protocol;
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
        comptime contracts.assertStreamStore(@TypeOf(store));
        if (self.pending.poisoned()) return error.SendPoisoned;
        if (increment == 0) return error.Protocol;

        if (stream_id == 0) {
            try self.sendConnectionWindowUpdate(out, increment);
            return;
        }

        const tracked = store.get(stream_id) orelse return error.StreamClosed;
        try self.sendWindowUpdateTracked(out, stream_id, tracked, increment);
    }

    /// Emits a connection WINDOW_UPDATE according to caller-owned receive-
    /// capacity accounting. Returns the advertised increment, or zero when the
    /// low watermark has not been reached.
    pub fn replenishConnectionReceive(
        self: *Session,
        out: *std.Io.Writer,
        credit: *flow.ReceiveCredit,
    ) SendStreamControlError!u31 {
        if (self.pending.poisoned()) return error.SendPoisoned;
        const increment = credit.proposal(self.connection.receive_window) orelse return 0;
        try self.sendConnectionWindowUpdate(out, increment);
        credit.commit(increment);
        return increment;
    }

    /// Stream-level receive-credit counterpart. Stream storage and the
    /// replenishment accumulator both remain caller-owned.
    pub fn replenishStreamReceive(
        self: *Session,
        store: anytype,
        out: *std.Io.Writer,
        stream_id: u31,
        credit: *flow.ReceiveCredit,
    ) SendStreamControlError!u31 {
        comptime contracts.assertStreamStore(@TypeOf(store));
        if (self.pending.poisoned()) return error.SendPoisoned;
        const tracked = store.get(stream_id) orelse return error.StreamClosed;
        const increment = credit.proposal(tracked.windows.receive) orelse return 0;
        try self.sendWindowUpdateTracked(out, stream_id, tracked, increment);
        credit.commit(increment);
        return increment;
    }

    pub fn replenishStreamReceiveExisting(
        self: *Session,
        out: *std.Io.Writer,
        existing: streams_mod.Existing,
        credit: *flow.ReceiveCredit,
    ) SendStreamControlError!u31 {
        if (existing.manager != &self.streams) return error.Protocol;
        if (self.pending.poisoned()) return error.SendPoisoned;
        const increment = credit.proposal(existing.tracked.windows.receive) orelse return 0;
        try self.sendWindowUpdateTracked(out, existing.stream_id, existing.tracked, increment);
        credit.commit(increment);
        return increment;
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

    fn sendConnectionWindowUpdate(
        self: *Session,
        out: *std.Io.Writer,
        increment: u31,
    ) SendStreamControlError!void {
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
        comptime contracts.assertStreamStore(@TypeOf(store));
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
        comptime fused_credit: bool,
    ) SendDataError!SendDataResult {
        const credit = if (fused_credit)
            try self.dataSendCreditTrackedFused(tracked)
        else
            try self.dataSendCreditTracked(tracked);
        const available = credit.max_payload;
        if (bytes.len == 0 and !end_stream)
            return .{ .consumed = 0, .blocked = false, .end_stream = false };

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
        self.streams.localDataTrackedAssumeCredit(&self.peer, stream_id, tracked, @intCast(amount), will_end);
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
        comptime contracts.assertSessionStore(@TypeOf(store));
        comptime contracts.assertFieldSink(@TypeOf(sink));
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
        comptime contracts.assertSessionStore(@TypeOf(store));
        comptime contracts.assertFieldSink(@TypeOf(sink));
        switch (self.connection.check(complete.header)) {
            .none => {},
            .protocol => return .{ .fault = .{ .connection = .protocol_error } },
            .flow_control => return .{ .fault = .{ .connection = .flow_control_error } },
        }
        return self.receiveCompleteAssumeConnectionChecked(store, complete, scratch, sink);
    }

    /// Processes a frame after the caller has already committed
    /// `connection.State.check()` for this exact wire position. This is the
    /// composed counterpart to `http2.dispatch.prepare()`: ordered frames can
    /// stay on Session while DATA/RST_STREAM/stream WINDOW_UPDATE are routed to
    /// detached stream owners without observing connection state twice.
    pub inline fn receiveCompleteAssumeConnectionChecked(
        self: *Session,
        store: anytype,
        complete: frame.CompleteFrame,
        scratch: []u8,
        sink: anytype,
    ) (hpack.codec.Error || error{HeaderBlockTooLarge})!Event {
        comptime contracts.assertSessionStore(@TypeOf(store));
        comptime contracts.assertFieldSink(@TypeOf(sink));
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
            .priority => self.receivePriority(complete),
            else => .{ .extension = .{
                .payload = complete.payload,
                .stream_id = complete.header.stream_id,
                .type = @intFromEnum(complete.header.type),
                .flags = complete.header.flags,
            } },
        };
    }

    fn receivePriority(self: *Session, complete: frame.CompleteFrame) Event {
        _ = self;
        _ = payload.priority(complete.header, complete.payload) catch |err| return switch (err) {
            error.FrameSize => .{ .fault = .{ .stream = .{ .stream_id = complete.header.stream_id, .code = .frame_size_error } } },
            error.StreamProtocol => .{ .fault = .{ .stream = .{ .stream_id = complete.header.stream_id, .code = .protocol_error } } },
        };
        return .ignored;
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
        return .{ .data = .{
            .stream_id = complete.header.stream_id,
            .end_stream = end_stream,
            ._flow_charge = .{
                @intCast((complete.header.length >> 16) & 0xff),
                @intCast((complete.header.length >> 8) & 0xff),
                @intCast(complete.header.length & 0xff),
            },
            .bytes = bytes,
        } };
    }

    fn receiveHeaders(self: *Session, store: anytype, complete: frame.CompleteFrame, scratch: []u8, sink: anytype) (hpack.codec.Error || error{HeaderBlockTooLarge})!Event {
        const parsed = payload.headers(complete.header, complete.payload) catch |err| return switch (err) {
            error.FrameSize => .{ .fault = .{ .connection = .frame_size_error } },
            error.Protocol => .{ .fault = .{ .connection = .protocol_error } },
            error.StreamProtocol => .{ .fault = .{ .stream = .{ .stream_id = complete.header.stream_id, .code = .protocol_error } } },
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
        const state_result: ?streams_mod.ReceiveResult = if (pending.isPushPromise()) null else self.streams.classifyHeaders(store, pending.streamId());
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
            // HPACK must still be consumed for a field block on a stream whose
            // state is already erroneous. Defer the stream-state result until
            // decompression completes, but do not let HTTP field semantics
            // replace STREAM_CLOSED/connection errors required by section 5.1.
            if ((state_result == null or state_result.? == .accepted) and !invalid) {
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
        if (state_result) |result| {
            if (result == .ignored_after_goaway) return .ignored;
            if (receiveFault(pending.streamId(), result)) |fault| return .{ .fault = fault };
        }
        if (!invalid) {
            validator.finish() catch {
                invalid = true;
            };
        }
        if (!invalid and validator.extendedConnect()) {
            // Only clients create Extended CONNECT streams, and only after the
            // server has advertised the RFC 8441 capability on this connection.
            if (self.streams.local_role != .server or !self.streams.extendedConnectAdvertised()) invalid = true;
        }
        if (invalid) {
            // A malformed field section still consumes the peer stream ID and
            // performs the corresponding state transition. Otherwise a peer
            // could provoke a stream error on a high identifier and later
            // open a numerically smaller stream as if the malformed HEADERS
            // had never existed. The eventual outbound RST_STREAM can then
            // close this caller-owned stream state normally.
            if (!pending.isPushPromise()) {
                const result = self.streams.receiveHeaders(store, pending.streamId(), pending.endStream());
                if (result == .ignored_after_goaway) return .ignored;
                if (receiveFault(pending.streamId(), result)) |fault| return .{ .fault = fault };
            }
            return .{ .fault = .{ .stream = .{ .stream_id = pending.streamId(), .code = .protocol_error } } };
        }

        if (pending.isPushPromise()) return self.commitPushPromise(store, pending, field_count);
        return self.commitHeaders(store, pending, field_kind, status_code, field_count, validator.content_length, validator.extendedConnect());
    }

    fn headerKind(self: *Session, store: anytype, stream_id: u31) fields.Kind {
        const tracked = store.get(stream_id) orelse return if (self.streams.local_role == .server) .request else .response;
        if (tracked.remote_headers != .initial) return .trailers;
        return if (self.streams.local_role == .server and self.streams.remoteInitiated(stream_id)) .request else .response;
    }

    fn commitHeaders(self: *Session, store: anytype, pending: Pending, field_kind: fields.Kind, status: u16, field_count: u32, content_length: ?u64, extended_connect: bool) Event {
        const end_stream = pending.endStream();
        const informational = field_kind == .response and status >= 100 and status < 200;
        if ((field_kind == .response and status == 101) or
            (informational and end_stream) or (field_kind == .trailers and !end_stream))
            return .{ .fault = .{ .stream = .{ .stream_id = pending.streamId(), .code = .protocol_error } } };

        const result = self.streams.receiveHeaders(store, pending.streamId(), end_stream);
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
            .content_length = content_length orelse 0,
            .has_content_length = content_length != null,
            .extended_connect = extended_connect,
            .status_code = status,
        } };
    }

    fn commitPushPromise(self: *Session, store: anytype, pending: Pending, field_count: u32) Event {
        const promised_stream_id = pending.promisedStream();
        const result = self.streams.receivePushPromise(store, pending.streamId(), promised_stream_id);
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
                .initial_window => |change| self.applyPeerInitialWindow(store, change) catch
                    return .{ .fault = .{ .connection = .flow_control_error } },
                else => {},
            }
        }
        return .{ .settings = .{ .bytes = complete.payload, .ack = parsed.ack, .count = count } };
    }

    fn applyPeerInitialWindow(
        self: *Session,
        store: anytype,
        change: peer_mod.State.InitialWindowChange,
    ) error{FlowControl}!void {
        self.streams.applyPeerInitialWindow(change, null) catch |err| switch (err) {
            error.FlowControl => return error.FlowControl,
            error.ExactWindowScanRequired => {
                const exact = store.maxActiveSendAdjustment();
                self.streams.applyPeerInitialWindow(change, exact) catch |exact_err| switch (exact_err) {
                    error.FlowControl => return error.FlowControl,
                    error.ExactWindowScanRequired => unreachable,
                };
            },
        };
    }

    fn receiveWindowUpdate(self: *Session, store: anytype, complete: frame.CompleteFrame) Event {
        const routed = self.peer.windowUpdate(complete.header, complete.payload) catch |err| return switch (err) {
            error.FrameSize => .{ .fault = .{ .connection = .frame_size_error } },
            error.Protocol => .{ .fault = .{ .connection = .protocol_error } },
            error.FlowControl => .{ .fault = .{ .connection = .flow_control_error } },
        };
        if (routed) |update| {
            const result = self.streams.receiveWindowUpdate(store, &self.peer, update.stream_id, update.increment);
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

fn validateLocalSettings(
    role: peer_mod.Role,
    connect_protocol_enabled: bool,
    items: []const settings.Setting,
) error{ Protocol, FlowControl }!bool {
    var next_connect_protocol = connect_protocol_enabled;
    for (items) |item| switch (item.id) {
        .enable_push => {
            if (item.value > 1 or (role == .server and item.value == 1)) return error.Protocol;
        },
        .enable_connect_protocol => switch (item.value) {
            0 => if (next_connect_protocol) return error.Protocol,
            1 => next_connect_protocol = true,
            else => return error.Protocol,
        },
        .initial_window_size => if (item.value > 0x7fff_ffff) return error.FlowControl,
        .max_frame_size => if (item.value < frame.default_max_frame_size or item.value > frame.max_frame_size)
            return error.Protocol,
        else => {},
    };
    return next_connect_protocol;
}

const LocalFieldInfo = struct {
    status: u16 = 0,
    extended_connect: bool = false,
};

fn validateLocalFields(kind: fields.Kind, end_stream: bool, items: []const hpack.EncodedField) error{Protocol}!LocalFieldInfo {
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
    return .{ .status = status, .extended_connect = validator.extendedConnect() };
}

fn validateTrailerPolicy(items: []const hpack.EncodedField, policy: anytype) error{TrailerRejected}!void {
    for (items) |item| {
        if (!policy.allows(item.field.name)) return error.TrailerRejected;
    }
}

fn receiveFault(stream_id: u31, result: streams_mod.ReceiveResult) ?Fault {
    const code = result.errorCode() orelse return null;
    if (result.isConnectionError()) return .{ .connection = code };
    return .{ .stream = .{ .stream_id = stream_id, .code = code } };
}

const TestStore = struct {
    const Slot = struct { id: u31 = 0, used: bool = false, value: stream_mod.Tracked = undefined };
    slots: [8]Slot = [_]Slot{.{}} ** 8,
    max_adjustment_scans: u32 = 0,

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

    pub fn maxActiveSendAdjustment(self: *TestStore) i32 {
        self.max_adjustment_scans += 1;
        var result: i32 = 0;
        for (&self.slots) |*slot_value| {
            if (!slot_value.used) continue;
            switch (slot_value.value.stream.state) {
                .open, .half_closed_remote => result = @max(result, slot_value.value.windows.send.adjustment),
                else => {},
            }
        }
        return result;
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
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
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
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
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

test "stream state error takes precedence without desynchronizing HPACK" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var wire_encoder = hpack.Encoder.init(allocator, 4096);
    defer wire_encoder.deinit();
    var block_storage: [4096]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var store: TestStore = .{};
    var sink: NullSink = .{};
    var scratch: [4096]u8 = undefined;

    const first_fields = [_]common.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/first" },
    };
    const first_block = try encodedFields(allocator, &wire_encoder, &first_fields);
    defer allocator.free(first_block);
    _ = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(first_block.len), .type = .headers, .flags = 0x05, .stream_id = 1 },
        .payload = first_block,
    }, &scratch, &sink);

    // This is both illegal on the half-closed(remote) stream and semantically
    // invalid as trailers because it contains pseudo-fields. STREAM_CLOSED has
    // precedence, but HPACK still has to consume the entire field block.
    const closed_fields = [_]common.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/closed" },
        .{ .name = "x-dynamic", .value = "retained-context" },
    };
    const closed_block = try encodedFields(allocator, &wire_encoder, &closed_fields);
    defer allocator.free(closed_block);
    const closed = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(closed_block.len), .type = .headers, .flags = 0x05, .stream_id = 1 },
        .payload = closed_block,
    }, &scratch, &sink);
    try std.testing.expectEqual(protocol.ErrorCode.stream_closed, closed.fault.stream.code);
    try std.testing.expectEqual(@as(u31, 1), closed.fault.stream.stream_id);

    // Reuse the peer encoder context on a fresh stream. If the rejected block
    // had not been decompressed, an indexed dynamic-table reference here would
    // fail with COMPRESSION_ERROR instead of yielding a normal request.
    const fresh_fields = [_]common.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/fresh" },
        .{ .name = "x-dynamic", .value = "retained-context" },
    };
    const fresh_block = try encodedFields(allocator, &wire_encoder, &fresh_fields);
    defer allocator.free(fresh_block);
    const fresh = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(fresh_block.len), .type = .headers, .flags = 0x05, .stream_id = 3 },
        .payload = fresh_block,
    }, &scratch, &sink);
    try std.testing.expectEqual(fields.Kind.request, fresh.headers.kind);
}

test "malformed HEADERS still consume remote stream identifier" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var wire_encoder = hpack.Encoder.init(allocator, 4096);
    defer wire_encoder.deinit();
    var block_storage: [4096]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var store: TestStore = .{};
    var sink: NullSink = .{};
    var scratch: [4096]u8 = undefined;

    const malformed_fields = [_]common.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "" },
    };
    const malformed_block = try encodedFields(allocator, &wire_encoder, &malformed_fields);
    defer allocator.free(malformed_block);
    const malformed = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(malformed_block.len), .type = .headers, .flags = 0x05, .stream_id = 5 },
        .payload = malformed_block,
    }, &scratch, &sink);
    try std.testing.expectEqual(protocol.ErrorCode.protocol_error, malformed.fault.stream.code);
    try std.testing.expect(store.get(5) != null);
    try std.testing.expectEqual(@as(u31, 5), session.streams.highest_remote_stream_id);

    const valid_fields = [_]common.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/regressed" },
    };
    const valid_block = try encodedFields(allocator, &wire_encoder, &valid_fields);
    defer allocator.free(valid_block);
    const regressed = try session.receiveComplete(&store, .{
        .header = .{ .length = @intCast(valid_block.len), .type = .headers, .flags = 0x05, .stream_id = 3 },
        .payload = valid_block,
    }, &scratch, &sink);
    try std.testing.expectEqual(protocol.ErrorCode.protocol_error, regressed.fault.connection);
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
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
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
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
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
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
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
    try std.testing.expectEqual(@as(u31, 32768), store.get(1).?.windows.send.available(session.peer.settings.initial_window_size));
    try std.testing.expectEqual(@as(u32, 0), store.max_adjustment_scans);
}

test "session requests exact stream scan only after positive send-window growth" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var store: TestStore = .{};
    try session.streams.openLocal(&store, &session.peer, 1, false);

    // A stream WINDOW_UPDATE beyond the initial window records only a packed
    // manager marker; no store-wide aggregate is maintained by Session.
    const update_result = session.streams.receiveWindowUpdate(&store, &session.peer, 1, 1024);
    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, update_result);
    try std.testing.expectEqual(@as(i32, 1024), store.get(1).?.windows.send.adjustment);

    var sink: NullSink = .{};
    var scratch: [32]u8 = undefined;
    const bytes = settingBytes(.{ .id = .initial_window_size, .value = 70_000 });
    const event = try session.receiveComplete(&store, .{
        .header = .{ .length = 6, .type = .settings, .flags = 0, .stream_id = 0 },
        .payload = &bytes,
    }, &scratch, &sink);
    try std.testing.expect(event == .settings);
    try std.testing.expectEqual(@as(u32, 1), store.max_adjustment_scans);
    try std.testing.expectEqual(@as(u31, 71_024), store.get(1).?.windows.send.available(session.peer.settings.initial_window_size));
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
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
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
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
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
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
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
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
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

test "session surfaces unknown extension frames without owning their semantics" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var store: TestStore = .{};
    var sink: NullSink = .{};
    var scratch: [64]u8 = undefined;

    const bytes = "extension-data";
    const event = try session.receiveComplete(&store, .{
        .header = .{ .length = bytes.len, .type = @enumFromInt(0xee), .flags = 0xa5, .stream_id = 77 },
        .payload = bytes,
    }, &scratch, &sink);
    try std.testing.expectEqual(@as(u8, 0xee), event.extension.type);
    try std.testing.expectEqual(@as(u8, 0xa5), event.extension.flags);
    try std.testing.expectEqual(@as(u31, 77), event.extension.stream_id);
    try std.testing.expectEqualStrings(bytes, event.extension.payload);
    try std.testing.expectEqual(@as(u32, bytes.len), event.extension.header().length);
}

test "session SETTINGS event preserves extension settings for caller inspection" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var store: TestStore = .{};
    var sink: NullSink = .{};
    var scratch: [64]u8 = undefined;

    var wire: [6]u8 = undefined;
    settings.encode(&wire, .{ .id = @enumFromInt(0xf00d), .value = 0x1234_5678 });
    const event = try session.receiveComplete(&store, .{
        .header = .{ .length = wire.len, .type = .settings, .flags = 0, .stream_id = 0 },
        .payload = &wire,
    }, &scratch, &sink);
    try std.testing.expectEqualStrings(&wire, event.settings.bytes);
    var it = event.settings.iterator();
    const extension = it.next().?;
    try std.testing.expectEqual(@as(u16, 0xf00d), @intFromEnum(extension.id));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), extension.value);
    try std.testing.expect(it.next() == null);
}

fn settingBytes(setting: @import("settings.zig").Setting) [6]u8 {
    var bytes: [6]u8 = undefined;
    @import("settings.zig").encode(&bytes, setting);
    return bytes;
}

test "send session remains compact with local header phase" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Session));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Data));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Event));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SettingsSync));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(stream_mod.Tracked));
}

test "session streams request HEADERS through continuations" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
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
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
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
    var session2 = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var store2: TestStore = .{};
    var h2_storage: [512]u8 = undefined;
    var h2 = std.Io.Writer.fixed(&h2_storage);
    _ = try session2.sendHeaders(&store2, &h2, 1, false, &staging, &items);
    session2.peer.send_window.value = 0;
    store2.get(1).?.windows.send.adjustment = -@as(i32, @intCast(session2.peer.settings.initial_window_size));
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
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
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
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &storage });
    var store: TestStore = .{};
    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, session.streams.receiveHeaders(&store, 1, true));

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
    const before_trailers = wire.buffered().len;
    try std.testing.expectError(error.TrailerPolicyRequired, session.sendHeaders(&store, &wire, 1, true, &frame_staging, &trailers));
    try std.testing.expectEqual(before_trailers, wire.buffered().len);

    const Reject = struct {
        pub fn allows(_: @This(), _: []const u8) bool {
            return false;
        }
    };
    const existing = session.streams.existing(&store, 1).?;
    try std.testing.expectError(error.TrailerRejected, session.sendTrailersExisting(&wire, existing, &frame_staging, &trailers, Reject{}));
    try std.testing.expectEqual(before_trailers, wire.buffered().len);
    try std.testing.expectEqual(stream_mod.RemoteHeaders.regular, store.get(1).?.local_headers);

    const AllowChecksum = struct {
        pub fn allows(_: @This(), name: []const u8) bool {
            return std.mem.eql(u8, name, "x-checksum");
        }
    };
    _ = try session.sendTrailers(&store, &wire, 1, &frame_staging, &trailers, AllowChecksum{});
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
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &storage });
    var store: TestStore = .{};
    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, session.streams.receiveHeaders(&store, 1, true));
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

test "session sends PUSH_PROMISE and opens promised response stream" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var store: TestStore = .{};
    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, session.streams.receiveHeaders(&store, 1, true));

    const promised_request = [_]hpack.EncodedField{
        .{ .field = .{ .name = ":method", .value = "GET" } },
        .{ .field = .{ .name = ":scheme", .value = "https" } },
        .{ .field = .{ .name = ":authority", .value = "example.com" } },
        .{ .field = .{ .name = ":path", .value = "/style.css" } },
        .{ .field = .{ .name = "accept", .value = "text/css" } },
    };
    var staging: [9]u8 = undefined;
    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    const stats = try session.sendPushPromise(&store, &wire, 1, 2, &staging, &promised_request);
    try std.testing.expect(stats.frame_count > 1);
    try std.testing.expectEqual(stream_mod.State.reserved_local, store.get(2).?.stream.state);
    try std.testing.expectEqual(@as(u32, 0), session.streams.activeLocal());

    var frames = frame.CompleteIterator.init(wire.buffered(), frame.default_max_frame_size);
    const first = (try frames.next()).?;
    try std.testing.expectEqual(frame.Type.push_promise, first.header.type);
    try std.testing.expectEqual(@as(u31, 1), first.header.stream_id);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, first.payload[0..4], .big));
    var last = first;
    while (try frames.next()) |next| last = next;
    try std.testing.expectEqual(frame.Type.continuation, last.header.type);
    try std.testing.expect((last.header.flags & 0x04) != 0);

    const response = [_]hpack.EncodedField{.{ .field = .{ .name = ":status", .value = "200" } }};
    _ = try session.sendHeaders(&store, &wire, 2, true, &staging, &response);
    try std.testing.expectEqual(stream_mod.State.closed, store.get(2).?.stream.state);
}

test "PUSH_PROMISE preflight respects role and peer push setting" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var store: TestStore = .{};
    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, session.streams.receiveHeaders(&store, 1, true));
    _ = try session.peer.applySetting(.{ .id = .enable_push, .value = 0 });

    const promised_request = [_]hpack.EncodedField{
        .{ .field = .{ .name = ":method", .value = "GET" } },
        .{ .field = .{ .name = ":scheme", .value = "https" } },
        .{ .field = .{ .name = ":path", .value = "/x" } },
    };
    var staging: [64]u8 = undefined;
    var wire_storage: [128]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    try std.testing.expectError(error.Protocol, session.sendPushPromise(&store, &wire, 1, 2, &staging, &promised_request));
    try std.testing.expectEqual(@as(usize, 0), wire.buffered().len);
    try std.testing.expect(store.get(2) == null);
    try std.testing.expect(!session.sendPoisoned());
}

test "Extended CONNECT is gated by negotiated SETTINGS" {
    const allocator = std.testing.allocator;

    // Client-side sends are rejected before the peer advertises RFC 8441.
    var client_decoder = hpack.Decoder.init(allocator, 4096);
    defer client_decoder.deinit();
    var client_encoder = hpack.Encoder.init(allocator, 4096);
    defer client_encoder.deinit();
    var client_storage: [256]u8 = undefined;
    var client = Session.init(.{ .role = .client, .decoder = &client_decoder, .encoder = &client_encoder, .header_storage = &client_storage });
    var client_store: TestStore = .{};
    const request = [_]hpack.EncodedField{
        .{ .field = .{ .name = ":method", .value = "CONNECT" } },
        .{ .field = .{ .name = ":protocol", .value = "websocket" } },
        .{ .field = .{ .name = ":scheme", .value = "https" } },
        .{ .field = .{ .name = ":path", .value = "/chat" } },
        .{ .field = .{ .name = ":authority", .value = "example.com" } },
    };
    var staging: [128]u8 = undefined;
    var client_wire_storage: [512]u8 = undefined;
    var client_wire = std.Io.Writer.fixed(&client_wire_storage);
    try std.testing.expectError(error.Protocol, client.sendHeaders(&client_store, &client_wire, 1, false, &staging, &request));
    try std.testing.expectEqual(@as(usize, 0), client_wire.buffered().len);

    _ = try client.peer.applySetting(.{ .id = .enable_connect_protocol, .value = 1 });
    try std.testing.expect(client.peerSupportsExtendedConnect());
    _ = try client.sendHeaders(&client_store, &client_wire, 1, false, &staging, &request);
    try std.testing.expect(client_wire.buffered().len != 0);

    // Server-side receive acceptance is tied to a SETTINGS value actually
    // committed by this Session, not merely to generic field syntax support.
    var server_decoder = hpack.Decoder.init(allocator, 4096);
    defer server_decoder.deinit();
    var server_encoder = hpack.Encoder.init(allocator, 4096);
    defer server_encoder.deinit();
    var wire_encoder = hpack.Encoder.init(allocator, 4096);
    defer wire_encoder.deinit();
    var server_storage: [256]u8 = undefined;
    var server = Session.init(.{ .role = .server, .decoder = &server_decoder, .encoder = &server_encoder, .header_storage = &server_storage });
    const request_fields = [_]common.Header{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":protocol", .value = "websocket" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/chat" },
        .{ .name = ":authority", .value = "example.com" },
    };
    const block = try encodedFields(allocator, &wire_encoder, &request_fields);
    defer allocator.free(block);
    var server_store: TestStore = .{};
    var sink: NullSink = .{};
    var scratch: [256]u8 = undefined;

    const rejected = try server.receiveComplete(&server_store, .{
        .header = .{ .length = @intCast(block.len), .type = .headers, .flags = 0x04, .stream_id = 1 },
        .payload = block,
    }, &scratch, &sink);
    try std.testing.expectEqual(protocol.ErrorCode.protocol_error, rejected.fault.stream.code);
    try std.testing.expectEqual(@as(u31, 1), rejected.fault.stream.stream_id);

    var sync: SettingsSync = .{};
    var settings_wire_storage: [64]u8 = undefined;
    var settings_wire = std.Io.Writer.fixed(&settings_wire_storage);
    const enable = [_]settings.Setting{.{ .id = .enable_connect_protocol, .value = 1 }};
    _ = try server.sendSettings(&sync, &settings_wire, &enable);
    try std.testing.expect(server.extendedConnectAdvertised());

    const disable = [_]settings.Setting{.{ .id = .enable_connect_protocol, .value = 0 }};
    const written = settings_wire.buffered().len;
    try std.testing.expectError(error.Protocol, server.sendSettings(&sync, &settings_wire, &disable));
    try std.testing.expectEqual(written, settings_wire.buffered().len);

    const event = try server.receiveComplete(&server_store, .{
        .header = .{ .length = @intCast(block.len), .type = .headers, .flags = 0x04, .stream_id = 3 },
        .payload = block,
    }, &scratch, &sink);
    try std.testing.expect(event.headers.extended_connect);
}

test "SETTINGS synchronization tickets follow ACK order" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var sync: SettingsSync = .{};
    var store: TestStore = .{};
    var sink: NullSink = .{};
    var scratch: [32]u8 = undefined;

    var wire_storage: [128]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    const one = [_]settings.Setting{.{ .id = .enable_push, .value = 0 }};
    const two = [_]settings.Setting{.{ .id = .max_concurrent_streams, .value = 32 }};
    try std.testing.expectEqual(@as(SettingsTicket, 1), try session.sendSettings(&sync, &wire, &one));
    try std.testing.expectEqual(@as(SettingsTicket, 2), try session.sendSettings(&sync, &wire, &two));
    try std.testing.expectEqual(@as(u32, 2), sync.outstanding());

    const ack_header: frame.FrameHeader = .{ .length = 0, .type = .settings, .flags = 0x01, .stream_id = 0 };
    var event = try session.receiveComplete(&store, .{ .header = ack_header, .payload = &.{} }, &scratch, &sink);
    try std.testing.expect(event.settings.ack);
    try std.testing.expectEqual(@as(?SettingsTicket, 1), event.settings.acknowledge(&sync));
    try std.testing.expectEqual(@as(u32, 1), sync.outstanding());

    event = try session.receiveComplete(&store, .{ .header = ack_header, .payload = &.{} }, &scratch, &sink);
    try std.testing.expectEqual(@as(?SettingsTicket, 2), event.settings.acknowledge(&sync));
    try std.testing.expectEqual(@as(u32, 0), sync.outstanding());

    event = try session.receiveComplete(&store, .{ .header = ack_header, .payload = &.{} }, &scratch, &sink);
    try std.testing.expect(event.settings.acknowledge(&sync) == null);
}

test "SETTINGS send preflight and writer failure preserve synchronization" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var sync: SettingsSync = .{};
    var storage: [32]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);

    const invalid = [_]settings.Setting{.{ .id = .enable_push, .value = 1 }};
    try std.testing.expectError(error.Protocol, session.sendSettings(&sync, &out, &invalid));
    try std.testing.expectEqual(@as(u32, 0), sync.outstanding());
    try std.testing.expectEqual(@as(usize, 0), out.buffered().len);
    try std.testing.expect(!session.sendPoisoned());

    var no_space: [0]u8 = .{};
    var failing = std.Io.Writer.fixed(&no_space);
    const valid = [_]settings.Setting{.{ .id = .max_concurrent_streams, .value = 10 }};
    try std.testing.expectError(error.WriteFailed, session.sendSettings(&sync, &failing, &valid));
    try std.testing.expectEqual(@as(u32, 0), sync.outstanding());
    try std.testing.expect(session.sendPoisoned());
}

test "session sends HTTP2 control frames with state-aware commits" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var store: TestStore = .{};

    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, session.streams.receiveHeaders(&store, 1, false));
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
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var store: TestStore = .{};
    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, session.streams.receiveHeaders(&store, 1, false));

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

test "DATA event exposes full flow-controlled payload length" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var store: TestStore = .{};
    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, session.streams.receiveHeaders(&store, 1, false));

    const padded = [_]u8{ 2, 'a', 'b', 'c', 0, 0 };
    var scratch: [1]u8 = undefined;
    var sink: NullSink = .{};
    const event = try session.receiveComplete(&store, .{
        .header = .{ .length = padded.len, .type = .data, .flags = 0x08, .stream_id = 1 },
        .payload = &padded,
    }, &scratch, &sink);
    try std.testing.expectEqualStrings("abc", event.data.bytes);
    try std.testing.expectEqual(@as(u32, padded.len), event.data.flowControlledBytes());
    try std.testing.expectEqual(@as(u31, 65_529), session.connection.receive_window.available());
    try std.testing.expectEqual(@as(u31, 65_529), store.get(1).?.windows.receive.available());
}

test "receive credit helpers replenish connection and stream after release" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var store: TestStore = .{};
    try std.testing.expectEqual(streams_mod.ReceiveResult.accepted, session.streams.receiveHeaders(&store, 1, false));

    session.connection.receive_window.value = 15_535;
    store.get(1).?.windows.receive.value = 15_535;
    var connection_credit = try flow.ReceiveCredit.init(65_535, 32_767);
    var stream_credit = try flow.ReceiveCredit.init(65_535, 32_767);
    connection_credit.release(50_000);
    stream_credit.release(50_000);

    var wire_storage: [64]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    try std.testing.expectEqual(@as(u31, 50_000), try session.replenishConnectionReceive(&wire, &connection_credit));
    try std.testing.expectEqual(@as(u31, 50_000), try session.replenishStreamReceive(&store, &wire, 1, &stream_credit));
    try std.testing.expectEqual(@as(u31, 65_535), session.connection.receive_window.available());
    try std.testing.expectEqual(@as(u31, 65_535), store.get(1).?.windows.receive.available());
    try std.testing.expectEqual(@as(u32, 0), connection_credit.released);
    try std.testing.expectEqual(@as(u32, 0), stream_credit.released);

    var frames = frame.CompleteIterator.init(wire.buffered(), frame.default_max_frame_size);
    const connection_update = (try frames.next()).?;
    try std.testing.expectEqual(frame.Type.window_update, connection_update.header.type);
    try std.testing.expectEqual(@as(u31, 0), connection_update.header.stream_id);
    try std.testing.expectEqual(@as(u32, 50_000), std.mem.readInt(u32, connection_update.payload[0..4], .big));
    const stream_update = (try frames.next()).?;
    try std.testing.expectEqual(@as(u31, 1), stream_update.header.stream_id);
    try std.testing.expectEqual(@as(u32, 50_000), std.mem.readInt(u32, stream_update.payload[0..4], .big));
    try std.testing.expect((try frames.next()) == null);
}

test "receive credit helper does not commit released bytes on writer failure" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    session.connection.receive_window.value = 15_535;
    var credit = try flow.ReceiveCredit.init(65_535, 32_767);
    credit.release(50_000);

    var no_space: [0]u8 = .{};
    var failing = std.Io.Writer.fixed(&no_space);
    try std.testing.expectError(error.WriteFailed, session.replenishConnectionReceive(&failing, &credit));
    try std.testing.expectEqual(@as(u31, 15_535), session.connection.receive_window.available());
    try std.testing.expectEqual(@as(u32, 50_000), credit.released);
    try std.testing.expect(session.sendPoisoned());
}

test "graceful GOAWAY helper performs only the two HTTP2 shutdown phases" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var drain: GracefulGoAway = .{};

    var wire_storage: [64]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    try drain.announce(&session, &wire, "drain");
    try std.testing.expectEqual(GracefulGoAway.Phase.announced, drain.phase);
    try drain.finish(&session, &wire, 1, "done");
    try std.testing.expectEqual(GracefulGoAway.Phase.final, drain.phase);
    try std.testing.expectEqual(@as(?u31, 1), session.streams.lastSentGoAwayStream());
    try std.testing.expectError(error.Protocol, drain.finish(&session, &wire, 1, ""));

    var frames = frame.CompleteIterator.init(wire.buffered(), frame.default_max_frame_size);
    const initial = (try frames.next()).?;
    const first = try payload.goAway(initial.payload);
    try std.testing.expectEqual(std.math.maxInt(u31), first.last_stream_id);
    try std.testing.expectEqual(@as(u32, @intFromEnum(protocol.ErrorCode.no_error)), first.error_code);
    const final = (try frames.next()).?;
    const second = try payload.goAway(final.payload);
    try std.testing.expectEqual(@as(u31, 1), second.last_stream_id);
    try std.testing.expectEqualStrings("done", second.debug_data);
    try std.testing.expect((try frames.next()) == null);
}

test "graceful GOAWAY helper is server-only and owns no timing policy" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var block_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .client, .decoder = &inbound, .encoder = &outbound, .header_storage = &block_storage });
    var drain: GracefulGoAway = .{};
    var wire_storage: [32]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    try std.testing.expectError(error.Protocol, drain.announce(&session, &wire, ""));
    try std.testing.expectEqual(@as(usize, 0), wire.buffered().len);
    try std.testing.expectEqual(GracefulGoAway.Phase.open, drain.phase);
}

test "session reports zero stream WINDOW_UPDATE as stream protocol error" {
    var decoder = hpack.Decoder.init(std.testing.allocator, 4096);
    defer decoder.deinit();
    var encoder = hpack.Encoder.init(std.testing.allocator, 4096);
    defer encoder.deinit();
    var continuation_storage: [256]u8 = undefined;
    var session = Session.init(.{ .role = .client, .decoder = &decoder, .encoder = &encoder, .header_storage = &continuation_storage });
    var store: TestStore = .{};

    var tracked = stream_mod.Tracked.init(65_535);
    try tracked.stream.localHeaders(false);
    _ = store.insert(1, tracked).?;
    session.streams.local_active = 1;

    const zero = [_]u8{ 0, 0, 0, 0 };
    const complete: frame.CompleteFrame = .{
        .header = .{ .length = 4, .type = .window_update, .flags = 0, .stream_id = 1 },
        .payload = &zero,
    };
    const event = try session.receiveComplete(&store, complete, &.{}, &NullSink{});
    try std.testing.expectEqual(protocol.ErrorCode.protocol_error, event.fault.stream.code);
    try std.testing.expectEqual(@as(u31, 1), event.fault.stream.stream_id);
}

test "prechecked Session path does not double-charge connection DATA window" {
    var decoder = hpack.Decoder.init(std.testing.allocator, 4096);
    defer decoder.deinit();
    var encoder = hpack.Encoder.init(std.testing.allocator, 4096);
    defer encoder.deinit();
    var continuation_storage: [256]u8 = undefined;
    var session = Session.init(.{ .role = .client, .decoder = &decoder, .encoder = &encoder, .header_storage = &continuation_storage });
    var store: TestStore = .{};

    var tracked = stream_mod.Tracked.init(65_535);
    try tracked.stream.localHeaders(true);
    try tracked.stream.remoteHeaders(false);
    _ = store.insert(1, tracked).?;
    session.streams.local_active = 1;

    const complete: frame.CompleteFrame = .{
        .header = .{ .length = 3, .type = .data, .flags = 1, .stream_id = 1 },
        .payload = "abc",
    };
    try std.testing.expectEqual(connection.Violation.none, session.connection.check(complete.header));
    try std.testing.expectEqual(@as(u31, 65_532), session.connection.receive_window.available());
    const event = try session.receiveCompleteAssumeConnectionChecked(&store, complete, &.{}, &NullSink{});
    try std.testing.expectEqualStrings("abc", event.data.bytes);
    try std.testing.expectEqual(@as(u31, 65_532), session.connection.receive_window.available());
}

test "session classifies PRIORITY self dependency as stream protocol error" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var header_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &header_storage });
    var store: TestStore = .{};
    var sink: NullSink = .{};
    var scratch: [64]u8 = undefined;
    const priority = [_]u8{ 0, 0, 0, 1, 255 };

    const event = try session.receiveComplete(&store, .{
        .header = .{ .length = 5, .type = .priority, .flags = 0, .stream_id = 1 },
        .payload = &priority,
    }, &scratch, &sink);
    try std.testing.expectEqual(protocol.ErrorCode.protocol_error, event.fault.stream.code);
    try std.testing.expectEqual(@as(u31, 1), event.fault.stream.stream_id);
}

test "session classifies HEADERS priority self dependency as stream protocol error" {
    const allocator = std.testing.allocator;
    var inbound = hpack.Decoder.init(allocator, 4096);
    defer inbound.deinit();
    var outbound = hpack.Encoder.init(allocator, 4096);
    defer outbound.deinit();
    var header_storage: [64]u8 = undefined;
    var session = Session.init(.{ .role = .server, .decoder = &inbound, .encoder = &outbound, .header_storage = &header_storage });
    var store: TestStore = .{};
    var sink: NullSink = .{};
    var scratch: [64]u8 = undefined;
    const priority = [_]u8{ 0, 0, 0, 1, 255 };

    const event = try session.receiveComplete(&store, .{
        .header = .{ .length = 5, .type = .headers, .flags = 0x24, .stream_id = 1 },
        .payload = &priority,
    }, &scratch, &sink);
    try std.testing.expectEqual(protocol.ErrorCode.protocol_error, event.fault.stream.code);
    try std.testing.expectEqual(@as(u31, 1), event.fault.stream.stream_id);
}
