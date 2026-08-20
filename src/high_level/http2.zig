const std = @import("std");
const h2 = @import("../http2.zig");
const common = @import("../common.zig");
const hl_common = @import("common.zig");

pub const DrainAction = hl_common.DrainAction;

/// Coarse transport-facing lifecycle for the composed HTTP/2 connection.
/// `draining` means either endpoint has entered GOAWAY shutdown; existing
/// streams can still complete, but no new request stream should be scheduled on
/// this transport.
pub const Lifecycle = enum { handshaking, active, draining, failed };

/// Why a client cannot open another locally initiated request stream. This is
/// deliberately more precise than a lifecycle query: bounded store capacity,
/// peer concurrency policy, and stream-ID exhaustion can block new work while
/// the connection itself remains healthy.
pub const RequestAvailability = enum {
    ready,
    not_client,
    not_started,
    failed,
    draining,
    stream_id_exhausted,
    peer_limit,
    store_full,
};

/// SETTINGS advertised by the high-level endpoint. This is the single source
/// of truth for both the initial wire SETTINGS frame and the receive-side
/// limits enforced by the composed connection.
pub const LocalSettings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = true,
    max_concurrent_streams: u32 = std.math.maxInt(u32),
    initial_window_size: u31 = 65_535,
    max_frame_size: u32 = h2.frame.default_max_frame_size,
    /// Effective unlimited/default value. Unlike an optional representation,
    /// this can also be restored by a later SETTINGS update on the wire.
    max_header_list_size: u32 = std.math.maxInt(u32),
    enable_connect_protocol: bool = false,

    pub const defaults: LocalSettings = .{};

    fn validate(comptime self: LocalSettings) void {
        if (self.max_frame_size < h2.frame.default_max_frame_size or self.max_frame_size > h2.frame.max_frame_size)
            @compileError("high_level.http2 local_settings.max_frame_size must be in 16384..16777215");
    }

    fn validateRuntime(self: LocalSettings) error{Protocol}!void {
        if (self.max_frame_size < h2.frame.default_max_frame_size or self.max_frame_size > h2.frame.max_frame_size)
            return error.Protocol;
    }

    fn normalized(self: LocalSettings, role: h2.Role) LocalSettings {
        var result = self;
        // RFC 9113 gives SETTINGS_ENABLE_PUSH no server-side enabling meaning;
        // an explicit server value may only be zero. Canonicalize that role so
        // high-level snapshots compare the actual wire/effective semantics.
        if (role == .server) result.enable_push = false;
        return result;
    }

    fn streamLimits(self: LocalSettings, role: h2.Role) h2.streams.LocalLimits {
        const value = self.normalized(role);
        return .{
            .initial_window_size = value.initial_window_size,
            .max_concurrent_streams = value.max_concurrent_streams,
            .enable_push = role == .client and value.enable_push,
        };
    }

    fn encodedInitial(self: LocalSettings, role: h2.Role, out: *[7]h2.settings.Setting) []const h2.settings.Setting {
        return diff(defaults.normalized(role), self.normalized(role), role, out) catch unreachable;
    }

    fn diff(
        previous_raw: LocalSettings,
        next_raw: LocalSettings,
        role: h2.Role,
        out: *[7]h2.settings.Setting,
    ) error{Protocol}![]const h2.settings.Setting {
        const previous = previous_raw.normalized(role);
        const next = next_raw.normalized(role);
        try next.validateRuntime();
        if (previous.enable_connect_protocol and !next.enable_connect_protocol) return error.Protocol;

        var n: usize = 0;
        if (next.header_table_size != previous.header_table_size) {
            out[n] = .{ .id = .header_table_size, .value = next.header_table_size };
            n += 1;
        }
        if (role == .client and next.enable_push != previous.enable_push) {
            out[n] = .{ .id = .enable_push, .value = @intFromBool(next.enable_push) };
            n += 1;
        }
        if (next.max_concurrent_streams != previous.max_concurrent_streams) {
            out[n] = .{ .id = .max_concurrent_streams, .value = next.max_concurrent_streams };
            n += 1;
        }
        if (next.initial_window_size != previous.initial_window_size) {
            out[n] = .{ .id = .initial_window_size, .value = next.initial_window_size };
            n += 1;
        }
        if (next.max_frame_size != previous.max_frame_size) {
            out[n] = .{ .id = .max_frame_size, .value = next.max_frame_size };
            n += 1;
        }
        if (next.max_header_list_size != previous.max_header_list_size) {
            out[n] = .{ .id = .max_header_list_size, .value = next.max_header_list_size };
            n += 1;
        }
        if (next.enable_connect_protocol != previous.enable_connect_protocol) {
            out[n] = .{ .id = .enable_connect_protocol, .value = @intFromBool(next.enable_connect_protocol) };
            n += 1;
        }
        return out[0..n];
    }

    /// The receive-side policy that is safe while `next` is in flight. A peer
    /// can apply a SETTINGS increase before its ACK reaches us, so expansions
    /// must be accepted immediately; restrictions become authoritative only at
    /// the synchronization point.
    fn permissiveMerge(acknowledged_raw: LocalSettings, next_raw: LocalSettings, role: h2.Role) LocalSettings {
        const acknowledged = acknowledged_raw.normalized(role);
        const next = next_raw.normalized(role);
        return .{
            // HPACK table-size changes are explicitly synchronized at the
            // SETTINGS ACK boundary (RFC 9113 Section 4.3.1), unlike ordinary
            // receive-capacity expansions.
            .header_table_size = acknowledged.header_table_size,
            .enable_push = acknowledged.enable_push or next.enable_push,
            .max_concurrent_streams = @max(acknowledged.max_concurrent_streams, next.max_concurrent_streams),
            .initial_window_size = @max(acknowledged.initial_window_size, next.initial_window_size),
            .max_frame_size = @max(acknowledged.max_frame_size, next.max_frame_size),
            .max_header_list_size = @max(acknowledged.max_header_list_size, next.max_header_list_size),
            .enable_connect_protocol = acknowledged.enable_connect_protocol or next.enable_connect_protocol,
        };
    }
};

pub const FieldSection = struct {
    stream_id: u31,
    kind: h2.fields.Kind,
    headers: []const common.Header,
};

pub const ControlAction = union(enum) {
    none,
    settings_ack,
    ping_ack: [8]u8,
    reset_stream: struct { stream_id: u31, code: h2.protocol.ErrorCode },
    goaway: struct { last_stream_id: u31, code: h2.protocol.ErrorCode },
};

pub const ReceiveResult = struct {
    consumed: usize,
    event: ?h2.Event = null,
    /// Present only when this call committed a HEADERS/PUSH_PROMISE field
    /// section. Header slices borrow the connection collector and remain valid
    /// until the next successfully committed field section.
    fields: ?FieldSection = null,
    control: ControlAction = .none,
};

pub const SendRequestResult = struct {
    stream_id: u31,
    headers: h2.session.SendHeadersResult,
};

pub const ReceiveCreditResult = struct {
    connection: u31 = 0,
    stream: u31 = 0,
};

pub const DrainResult = hl_common.DrainResult;

/// Stable subset of HPACK failures surfaced through the composed API. It is
/// declared independently from `hpack.codec.Error` so future low-level codec
/// evolution must be mapped deliberately rather than silently changing 1.x.
pub const HpackError = error{
    Truncated,
    IntegerOverflow,
    InvalidPrefix,
    InvalidIndex,
    InvalidHuffman,
    ScratchTooSmall,
    InvalidTableSizeUpdate,
    TableSizeTooLarge,
    TableSizeUpdateRequired,
    HeaderListTooLarge,
    HeaderBlockTooLarge,
    StringLiteralTooLarge,
    OutOfMemory,
    WriteFailed,
};

pub const StreamError = error{
    Protocol,
    StreamClosed,
    FlowControl,
    PeerLimit,
    StoreFull,
    GoAway,
};

pub const HeaderSendError = HpackError || StreamError || error{
    BufferTooSmall,
    SendPoisoned,
    TrailerPolicyRequired,
    TrailerRejected,
    PeerHeaderListTooLarge,
};

pub const SendRequestError = HeaderSendError || error{
    InvalidRequest,
    InvalidResponse,
    NotClient,
    NotStarted,
    ConnectionDraining,
    ConnectionFailed,
    StreamIdExhausted,
};

pub const SendResponseError = HeaderSendError || error{
    InvalidRequest,
    InvalidResponse,
    NotServer,
    NotStarted,
    ConnectionFailed,
};

pub const SendDataError = StreamError || error{
    WriteFailed,
    SendPoisoned,
    NotStarted,
    ConnectionFailed,
};

pub const SendTrailersError = HeaderSendError || error{
    NotStarted,
    ConnectionFailed,
};

pub const SendPingError = error{
    WriteFailed,
    SendPoisoned,
    NotStarted,
    ConnectionFailed,
};

pub const SendLocalSettingsError = error{
    WriteFailed,
    FrameTooLarge,
    Protocol,
    FlowControl,
    SettingsSequenceExhausted,
    SendPoisoned,
    SettingsPending,
    NotStarted,
    ConnectionDraining,
    ConnectionFailed,
    LocalSettingsFlowControl,
};

pub const ReceiveError = HpackError || error{
    FrameSize,
    Protocol,
    InvalidPreface,
    RoleMismatch,
    HeaderCollectionOverflow,
    LocalSettingsFlowControl,
    ReceiveFailed,
    ConnectionClosed,
};

pub const FinishReceiveError = error{ ReceiveFailed, UnexpectedEof };

pub const SendControlError = StreamError || error{
    WriteFailed,
    SendPoisoned,
    FrameTooLarge,
    NotStarted,
};

pub const ReceiveCreditError = StreamError || error{
    WriteFailed,
    SendPoisoned,
    NotStarted,
    ConnectionFailed,
};

pub const ResetStreamError = ReceiveCreditError;

pub const CancelRequestError = ReceiveCreditError || error{
    NotClient,
    NotLocalRequest,
};

pub const SendGoAwayError = StreamError || error{
    WriteFailed,
    SendPoisoned,
    FrameTooLarge,
    NotStarted,
};

pub const GracefulGoAwayError = SendGoAwayError || error{ConnectionFailed};

/// Bounded defaults for the optional transport-neutral HTTP/2 connection
/// wrapper. Applications with different storage/scheduling requirements should
/// use `http2.Session` directly; no core API depends on this type.
pub const Config = struct {
    max_streams: usize = 128,
    header_block_bytes: usize = 16 * 1024,
    scratch_bytes: usize = 16 * 1024,
    frame_staging_bytes: usize = 16 * 1024,
    collected_fields: usize = 64,
    collected_field_bytes: usize = 16 * 1024,
    outbound_fields: usize = 64,
    local_settings: LocalSettings = .{},
    /// Treat the peer's advisory SETTINGS_MAX_HEADER_LIST_SIZE as a hard
    /// local send preflight. Disable only when application policy intentionally
    /// allows sections the peer has said it might refuse.
    enforce_peer_header_list_size: bool = true,
};

/// Transport-neutral HTTP/2 convenience connection. It bundles Bootstrap,
/// Session, HPACK contexts, a bounded stream store, a copying transactional
/// field collector, SETTINGS synchronization, and common scratch buffers.
///
/// By default the wrapper performs one allocator allocation for its fixed
/// connection state so the public handle is safely movable even though Session
/// contains pointers into that state. `init*InPlace` removes that allocation by
/// binding the handle to stable caller-owned Storage. Wire buffers and transports
/// remain caller-owned.
pub fn Connection(comptime config: Config) type {
    if (config.max_streams == 0) @compileError("high_level.http2 Connection max_streams must be non-zero");
    if (config.header_block_bytes == 0) @compileError("high_level.http2 Connection header_block_bytes must be non-zero");
    if (config.scratch_bytes == 0) @compileError("high_level.http2 Connection scratch_bytes must be non-zero");
    if (config.frame_staging_bytes == 0) @compileError("high_level.http2 Connection frame_staging_bytes must be non-zero");
    if (config.collected_fields == 0) @compileError("high_level.http2 Connection collected_fields must be non-zero");
    if (config.collected_field_bytes == 0) @compileError("high_level.http2 Connection collected_field_bytes must be non-zero");
    if (config.outbound_fields < 5) @compileError("high_level.http2 Connection outbound_fields must be at least 5");
    config.local_settings.validate();

    return struct {
        const Self = @This();
        const StreamStore = h2.storage.FixedStreamStore(config.max_streams);
        const FieldCollector = h2.storage.FixedFieldCollector(config.collected_fields, config.collected_field_bytes);

        allocator: std.mem.Allocator,
        owns_storage: bool = true,
        state: *State,

        const State = struct {
            decoder: h2.hpack.Decoder,
            encoder: h2.hpack.Encoder,
            header_storage: [config.header_block_bytes]u8 = undefined,
            scratch: [config.scratch_bytes]u8 = undefined,
            frame_staging: [config.frame_staging_bytes]u8 = undefined,
            outbound: [config.outbound_fields]h2.hpack.EncodedField = undefined,
            session: h2.Session = undefined,
            bootstrap: h2.Bootstrap,
            settings_sync: h2.session.SettingsSync = .{},
            local_settings_wire: [7]h2.settings.Setting = undefined,
            acknowledged_local_settings: LocalSettings = .{},
            effective_local_settings: LocalSettings = .{},
            pending_local_settings: ?LocalSettings = null,
            pending_settings_ticket: ?h2.session.SettingsTicket = null,
            initial_settings_acknowledged: bool = false,
            store: StreamStore = .{},
            collector: FieldCollector = .{},
            next_request_stream_id: u32 = 1,
            connection_credit: h2.flow.ReceiveCredit = undefined,
            receive_failed: bool = false,
            peer_receive_closed: bool = false,
            graceful_goaway: h2.session.GracefulGoAway = .{},
        };

        /// Caller-owned opaque storage for in-place initialization. The high-
        /// level wrapper may change its internal Session/HPACK/store composition
        /// in compatible 1.x releases without exposing those implementation
        /// fields. Keep an initialized value at a stable address until `deinit`.
        pub const Storage = struct {
            _opaque: [@sizeOf(State)]u8 align(@alignOf(State)) = undefined,
        };

        /// Size of the fixed connection state for this configuration, excluding
        /// HPACK dynamic-table allocations.
        pub const state_bytes = @sizeOf(Storage);

        inline fn stateFromStorage(storage: *Storage) *State {
            return @ptrCast(&storage._opaque);
        }

        pub fn initClient(allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            return initOwned(allocator, .client);
        }

        pub fn initServer(allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            return initOwned(allocator, .server);
        }

        /// Bind the high-level client to stable caller-owned fixed storage. HPACK
        /// dynamic-table allocations still use `allocator`.
        pub fn initClientInPlace(storage: *Storage, allocator: std.mem.Allocator) Self {
            return initState(stateFromStorage(storage), allocator, .client, false);
        }

        /// Server counterpart to `initClientInPlace`.
        pub fn initServerInPlace(storage: *Storage, allocator: std.mem.Allocator) Self {
            return initState(stateFromStorage(storage), allocator, .server, false);
        }

        fn initOwned(allocator: std.mem.Allocator, endpoint_role: h2.Role) error{OutOfMemory}!Self {
            const state = try allocator.create(State);
            return initState(state, allocator, endpoint_role, true);
        }

        fn initState(state: *State, allocator: std.mem.Allocator, endpoint_role: h2.Role, owns_storage: bool) Self {
            const defaults = LocalSettings.defaults.normalized(endpoint_role);
            state.decoder = h2.hpack.Decoder.init(allocator, defaults.header_table_size);
            state.decoder.setMaxHeaderListSize(defaults.max_header_list_size);
            state.encoder = h2.hpack.Encoder.init(allocator, 4096);
            state.bootstrap = h2.Bootstrap.init(endpoint_role);
            state.settings_sync = .{};
            state.acknowledged_local_settings = defaults;
            state.effective_local_settings = defaults;
            state.pending_local_settings = null;
            state.pending_settings_ticket = null;
            state.initial_settings_acknowledged = false;
            state.store = .{};
            state.collector = .{};
            state.next_request_stream_id = 1;
            state.connection_credit = h2.flow.ReceiveCredit.init(65_535, 32_767) catch unreachable;
            state.receive_failed = false;
            state.peer_receive_closed = false;
            state.graceful_goaway = .{};
            state.session = h2.Session.init(.{
                .role = endpoint_role,
                .local_limits = defaults.streamLimits(endpoint_role),
                .decoder = &state.decoder,
                .encoder = &state.encoder,
                .header_storage = &state.header_storage,
            });
            return .{ .allocator = allocator, .owns_storage = owns_storage, .state = state };
        }

        pub fn deinit(self: *Self) void {
            self.state.decoder.deinit();
            self.state.encoder.deinit();
            if (self.owns_storage) self.allocator.destroy(self.state);
            self.* = undefined;
        }

        pub inline fn role(self: *const Self) h2.Role {
            return self.state.session.role();
        }

        pub inline fn peerHeaderListLimit(self: *const Self) ?u32 {
            return self.state.session.peerHeaderListLimit();
        }

        /// Initial SETTINGS target configured for this Connection type.
        pub inline fn configuredInitialSettings(self: *const Self) LocalSettings {
            return config.local_settings.normalized(self.role());
        }

        /// Oldest local SETTINGS snapshot whose application is confirmed by a
        /// peer ACK. This is distinct from `effectiveLocalSettings()`: permissive
        /// increases can become safe to receive before the synchronization ACK.
        pub inline fn acknowledgedLocalSettings(self: *const Self) LocalSettings {
            return self.state.acknowledged_local_settings;
        }

        /// Receive-side policy currently accepted by the high-level wrapper.
        /// While one SETTINGS frame is pending this is the permissive envelope
        /// of the acknowledged and pending snapshots.
        pub inline fn effectiveLocalSettings(self: *const Self) LocalSettings {
            return self.state.effective_local_settings;
        }

        pub inline fn pendingLocalSettings(self: *const Self) ?LocalSettings {
            return self.state.pending_local_settings;
        }

        /// Transport-facing connection lifecycle. Receive-side terminal faults
        /// and send poisoning are latched as `.failed`; either received or sent
        /// GOAWAY transitions the composed connection to `.draining`.
        pub inline fn lifecycle(self: *const Self) Lifecycle {
            if (self.state.receive_failed or self.state.bootstrap.sendPoisoned() or self.state.session.sendPoisoned())
                return .failed;
            if (self.state.peer_receive_closed or self.state.session.peer.goAwayReceived() or self.state.session.streams.goAwaySent() or self.state.graceful_goaway.phase != .open)
                return .draining;
            if (!self.state.bootstrap.active()) return .handshaking;
            return .active;
        }

        fn applicationSendFailed(self: *const Self) bool {
            return self.state.receive_failed or self.state.bootstrap.sendPoisoned() or self.state.session.sendPoisoned();
        }

        fn requireStarted(self: *const Self) error{NotStarted}!void {
            if (!self.state.bootstrap.localPrefaceSent()) return error.NotStarted;
        }

        fn requireApplicationSend(self: *const Self) error{ NotStarted, ConnectionFailed }!void {
            try self.requireStarted();
            if (self.applicationSendFailed()) return error.ConnectionFailed;
        }

        /// Exact reason a new client request stream can or cannot be opened.
        /// This includes bounded-store and peer-concurrency backpressure in
        /// addition to coarse connection lifecycle state.
        pub inline fn requestAvailability(self: *const Self) RequestAvailability {
            if (self.role() != .client) return .not_client;
            if (self.applicationSendFailed()) return .failed;
            if (!self.state.bootstrap.localPrefaceSent()) return .not_started;
            if (self.state.peer_receive_closed or self.state.session.peer.goAwayReceived() or self.state.session.streams.goAwaySent() or self.state.graceful_goaway.phase != .open)
                return .draining;
            if (self.state.next_request_stream_id > std.math.maxInt(u31)) return .stream_id_exhausted;
            if (self.state.session.streams.activeLocal() >= self.state.session.peer.settings.max_concurrent_streams)
                return .peer_limit;
            if (self.state.store.remainingCapacity() == 0) return .store_full;
            return .ready;
        }

        pub inline fn canOpenRequest(self: *const Self) bool {
            return self.requestAvailability() == .ready;
        }

        /// True after the transport owner reports peer receive EOF with no
        /// truncated HTTP/2 frame/header block. Existing locally writable
        /// streams may still be completed on a half-closed transport, but no
        /// new request stream should be opened.
        pub inline fn peerReceiveClosed(self: *const Self) bool {
            return self.state.peer_receive_closed;
        }

        /// Number of currently active locally initiated streams. Closed and
        /// reserved records retained by the bounded store are not counted.
        pub inline fn activeLocalStreams(self: *const Self) u32 {
            return self.state.session.streams.activeLocal();
        }

        /// Number of currently active peer-initiated streams. This is the exact
        /// protocol counter used for SETTINGS_MAX_CONCURRENT_STREAMS enforcement.
        pub inline fn activeRemoteStreams(self: *const Self) u32 {
            return self.state.session.streams.activeRemote();
        }

        pub inline fn activeStreams(self: *const Self) u32 {
            return self.activeLocalStreams() + self.activeRemoteStreams();
        }

        /// Number of bounded stream records still retained, including closed
        /// records that the application has not reclaimed yet.
        pub inline fn retainedStreams(self: *const Self) usize {
            return self.state.store.count();
        }

        /// Snapshot predicate for graceful-drain loops. This reports only
        /// current protocol activity; an announced first-stage graceful GOAWAY
        /// can still admit a later peer stream until the final cutoff is sent.
        pub inline fn streamsDrained(self: *const Self) bool {
            return self.activeStreams() == 0;
        }

        pub inline fn peerGoAwayLastStreamId(self: *const Self) ?u31 {
            return self.state.session.peer.lastGoAwayStream();
        }

        pub inline fn localGoAwayLastStreamId(self: *const Self) ?u31 {
            return self.state.session.streams.lastSentGoAwayStream();
        }

        /// Classify a locally initiated stream after receiving GOAWAY. `true`
        /// means the peer's last-stream-id proves that this stream was not
        /// processed and application semantics may retry it on a new connection.
        pub inline fn unprocessedByPeer(self: *const Self, stream_id: u31) bool {
            return self.state.session.streams.unprocessedByPeer(&self.state.session.peer, stream_id);
        }

        /// Emits the local HTTP/2 connection preface and initial SETTINGS from
        /// `Config.local_settings`. Expansions become receive-safe immediately;
        /// restrictions become authoritative at the matching SETTINGS ACK.
        pub fn start(self: *Self, out: *std.Io.Writer) h2.bootstrap.Bootstrap.StartError!h2.session.SettingsTicket {
            const target = config.local_settings.normalized(self.role());
            const items = config.local_settings.encodedInitial(self.role(), &self.state.local_settings_wire);
            const permissive = LocalSettings.permissiveMerge(self.state.acknowledged_local_settings, target, self.role());
            self.state.store.validateLocalInitialWindow(self.state.effective_local_settings.initial_window_size, permissive.initial_window_size) catch unreachable;
            const ticket = try self.state.bootstrap.start(&self.state.session, &self.state.settings_sync, out, items);
            self.applyEffectiveLocalSettings(permissive) catch unreachable;
            self.state.pending_local_settings = target;
            self.state.pending_settings_ticket = ticket;
            return ticket;
        }

        /// Send a complete replacement snapshot after the previous local
        /// SETTINGS has been acknowledged. Returns null when `next` is already
        /// the acknowledged snapshot and therefore no wire frame is needed.
        /// High-level composition deliberately serializes local SETTINGS updates;
        /// use Session directly when multiple unacknowledged policy snapshots are
        /// a requirement.
        pub fn sendLocalSettings(
            self: *Self,
            out: *std.Io.Writer,
            next_raw: LocalSettings,
        ) SendLocalSettingsError!?h2.session.SettingsTicket {
            if (!self.state.bootstrap.localPrefaceSent()) return error.NotStarted;
            if (self.applicationSendFailed()) return error.ConnectionFailed;
            if (self.state.peer_receive_closed or self.state.session.peer.goAwayReceived() or self.state.session.streams.goAwaySent() or self.state.graceful_goaway.phase != .open)
                return error.ConnectionDraining;
            if (self.state.pending_local_settings != null or self.state.settings_sync.outstanding() != 0)
                return error.SettingsPending;

            const next = next_raw.normalized(self.role());
            const items = LocalSettings.diff(self.state.acknowledged_local_settings, next, self.role(), &self.state.local_settings_wire) catch
                return error.Protocol;
            if (items.len == 0) return null;

            const permissive = LocalSettings.permissiveMerge(self.state.acknowledged_local_settings, next, self.role());
            self.state.store.validateLocalInitialWindow(self.state.effective_local_settings.initial_window_size, permissive.initial_window_size) catch
                return error.LocalSettingsFlowControl;
            // Also preflight the eventual synchronized restriction against the
            // current records. DATA can still move windows while ACK is in
            // flight; an impossible later transition remains fail-closed.
            self.state.store.validateLocalInitialWindow(permissive.initial_window_size, next.initial_window_size) catch
                return error.LocalSettingsFlowControl;

            const ticket = try self.state.session.sendSettings(&self.state.settings_sync, out, items);
            self.applyEffectiveLocalSettings(permissive) catch unreachable;
            self.state.pending_local_settings = next;
            self.state.pending_settings_ticket = ticket;
            return ticket;
        }

        /// True once the initial connection-preface SETTINGS frame has been
        /// acknowledged. Later runtime SETTINGS updates do not clear this flag.
        pub inline fn initialSettingsAcknowledged(self: *const Self) bool {
            return self.state.initial_settings_acknowledged;
        }

        /// Processes at most one event using the bundled stream store, scratch
        /// space, and copying field collector.
        pub fn receive(self: *Self, input: []const u8) ReceiveError!?ReceiveResult {
            if (self.state.receive_failed) return error.ReceiveFailed;
            if (self.state.peer_receive_closed) return error.ConnectionClosed;
            const result = (self.state.bootstrap.receiveBytes(
                &self.state.session,
                &self.state.store,
                input,
                self.state.effective_local_settings.max_frame_size,
                &self.state.scratch,
                &self.state.collector,
            ) catch |err| {
                // A high-level connection cannot prove that HPACK/connection
                // receive state remains retry-safe after a decode/resource
                // failure. Latch the receive side closed and require a new
                // transport instead of permitting accidental continuation.
                self.state.receive_failed = true;
                return err;
            }) orelse return null;

            var field_section: ?FieldSection = null;
            var control: ControlAction = .none;
            if (result.event) |event| switch (event) {
                .headers, .push_promise => {
                    field_section = .{
                        .stream_id = self.state.collector.streamId() orelse unreachable,
                        .kind = self.state.collector.kind() orelse unreachable,
                        .headers = self.state.collector.headers(),
                    };
                    if (self.state.collector.overflowed()) {
                        self.state.receive_failed = true;
                        return error.HeaderCollectionOverflow;
                    }
                },
                .settings => |applied| {
                    if (applied.ack) {
                        if (applied.acknowledge(&self.state.settings_sync)) |ticket| {
                            if (self.state.pending_settings_ticket == ticket) {
                                const target = self.state.pending_local_settings orelse unreachable;
                                self.applyEffectiveLocalSettings(target) catch {
                                    self.state.receive_failed = true;
                                    return error.LocalSettingsFlowControl;
                                };
                                self.state.acknowledged_local_settings = target;
                                self.state.pending_local_settings = null;
                                self.state.pending_settings_ticket = null;
                                self.state.initial_settings_acknowledged = true;
                            }
                        }
                    } else control = .settings_ack;
                },
                .ping => |ping| if (!ping.ack) {
                    var bytes: [8]u8 = undefined;
                    @memcpy(&bytes, ping.bytes[0..8]);
                    control = .{ .ping_ack = bytes };
                },
                .fault => |fault| control = switch (fault) {
                    .stream => |stream_fault| .{ .reset_stream = .{ .stream_id = stream_fault.stream_id, .code = stream_fault.code } },
                    .connection => |code| blk: {
                        // A connection error is terminal for further receive
                        // processing, but sendControl() remains available so the
                        // transport owner can serialize the required GOAWAY.
                        self.state.receive_failed = true;
                        break :blk .{ .goaway = .{ .last_stream_id = self.state.session.streams.highestRemoteStreamId(), .code = code } };
                    },
                },
                else => {},
            };
            if (result.event) |event| switch (event) {
                .headers => |headers| self.ensureStreamCredit(headers.stream_id),
                .push_promise => |promise| self.ensureStreamCredit(promise.promised_stream_id),
                else => {},
            };
            return .{ .consumed = result.consumed, .event = result.event, .fields = field_section, .control = control };
        }

        /// Signal transport receive EOF after the caller has drained every
        /// complete frame. `pending_input` must contain any bytes that receive()
        /// could not consume from the final transport read. A partial client
        /// preface, partial frame, or open HEADERS/CONTINUATION block is a
        /// truncated HTTP/2 connection and latches terminal receive failure.
        /// Clean EOF enters draining state: existing streams can still be
        /// finished on a half-closed transport, but new requests are forbidden.
        pub fn finishReceive(self: *Self, pending_input: []const u8) FinishReceiveError!void {
            if (self.state.receive_failed) return error.ReceiveFailed;
            if (self.state.peer_receive_closed) return;
            if (!self.state.bootstrap.peerPrefaceReceived() or
                pending_input.len != 0 or
                self.state.session.connection.continuation_guard.stream_id != 0)
            {
                self.state.receive_failed = true;
                return error.UnexpectedEof;
            }
            self.state.peer_receive_closed = true;
        }

        /// Drain as many immediately parseable events as possible while
        /// invoking `handler.onEvent(result)` synchronously. Returning `.stop`
        /// leaves all remaining input unconsumed. Header slices in `result` are
        /// safe during the callback and follow the collector lifetime described
        /// by `receive` afterwards.
        pub fn drain(
            self: *Self,
            input: []const u8,
            handler: anytype,
        ) ReceiveError!DrainResult {
            var consumed: usize = 0;
            var events: usize = 0;
            while (consumed < input.len) {
                const maybe = try self.receive(input[consumed..]);
                const result = maybe orelse break;
                if (result.consumed == 0 and result.event == null) break;
                consumed += result.consumed;
                if (result.event != null) {
                    events += 1;
                    if (handler.onEvent(result) == .stop)
                        return .{ .consumed = consumed, .events = events, .stopped = true };
                }
            }
            return .{ .consumed = consumed, .events = events };
        }

        /// Allocates the next client request stream ID and serializes a typed
        /// request section. The stream ID advances only after Session accepted
        /// the send; a poisoned partial wire write makes the connection
        /// unusable in the usual Session way.
        pub fn sendRequest(
            self: *Self,
            out: *std.Io.Writer,
            request: h2.message.RequestFields,
            regular_fields: []const h2.hpack.EncodedField,
            end_stream: bool,
        ) SendRequestError!SendRequestResult {
            switch (self.requestAvailability()) {
                .ready => {},
                .not_client => return error.NotClient,
                .not_started => return error.NotStarted,
                .failed => return error.ConnectionFailed,
                .draining => return error.ConnectionDraining,
                .stream_id_exhausted => return error.StreamIdExhausted,
                .peer_limit => return error.PeerLimit,
                .store_full => return error.StoreFull,
            }
            const stream_id: u31 = @intCast(self.state.next_request_stream_id);
            const items = try request.build(&self.state.outbound, regular_fields);
            const stats = if (config.enforce_peer_header_list_size)
                try self.state.session.sendHeadersWithinPeerLimit(
                    &self.state.store,
                    out,
                    stream_id,
                    end_stream,
                    &self.state.frame_staging,
                    items,
                )
            else
                try self.state.session.sendHeaders(
                    &self.state.store,
                    out,
                    stream_id,
                    end_stream,
                    &self.state.frame_staging,
                    items,
                );
            self.state.next_request_stream_id += 2;
            self.ensureStreamCredit(stream_id);
            return .{ .stream_id = stream_id, .headers = stats };
        }

        /// Serializes a typed server response for an existing request stream.
        pub fn sendResponse(
            self: *Self,
            out: *std.Io.Writer,
            stream_id: u31,
            response: *const h2.message.ResponseFields,
            regular_fields: []const h2.hpack.EncodedField,
            end_stream: bool,
        ) SendResponseError!h2.session.SendHeadersResult {
            if (self.role() != .server) return error.NotServer;
            try self.requireApplicationSend();
            const items = try response.build(&self.state.outbound, regular_fields);
            return if (config.enforce_peer_header_list_size)
                self.state.session.sendHeadersWithinPeerLimit(
                    &self.state.store,
                    out,
                    stream_id,
                    end_stream,
                    &self.state.frame_staging,
                    items,
                )
            else
                self.state.session.sendHeaders(
                    &self.state.store,
                    out,
                    stream_id,
                    end_stream,
                    &self.state.frame_staging,
                    items,
                );
        }

        pub fn sendData(self: *Self, out: *std.Io.Writer, stream_id: u31, bytes: []const u8, end_stream: bool) SendDataError!h2.session.SendDataResult {
            try self.requireApplicationSend();
            return self.state.session.sendData(&self.state.store, out, stream_id, bytes, end_stream);
        }

        /// Serialize a final trailer section with the same bounded staging and
        /// optional peer header-list preflight used by ordinary high-level sends.
        pub fn sendTrailers(
            self: *Self,
            out: *std.Io.Writer,
            stream_id: u31,
            items: []const h2.hpack.EncodedField,
            policy: anytype,
        ) SendTrailersError!h2.session.SendHeadersResult {
            try self.requireApplicationSend();
            if (config.enforce_peer_header_list_size and self.state.session.diagnosePeerHeaderList(items) != null)
                return error.PeerHeaderListTooLarge;
            return self.state.session.sendTrailers(&self.state.store, out, stream_id, &self.state.frame_staging, items, policy);
        }

        /// Translate a terminal receive error into a peer-visible connection
        /// control action when the error has an RFC-defined connection code.
        /// Local resource/configuration failures deliberately map to `.none`;
        /// callers should close the transport without blaming the peer.
        pub fn controlForReceiveError(self: *const Self, err: ReceiveError) ControlAction {
            // The first locally emitted HTTP/2 frame must be the initial
            // SETTINGS frame. If receive fails before `start()`, no recovery
            // control frame can be serialized without violating connection
            // preface ordering; close the transport instead.
            if (!self.state.bootstrap.localPrefaceSent()) return .none;
            const code: ?h2.protocol.ErrorCode = switch (err) {
                error.FrameSize => .frame_size_error,
                error.Protocol, error.InvalidPreface => .protocol_error,
                error.Truncated,
                error.IntegerOverflow,
                error.InvalidPrefix,
                error.InvalidIndex,
                error.InvalidHuffman,
                error.InvalidTableSizeUpdate,
                error.TableSizeTooLarge,
                error.TableSizeUpdateRequired,
                => .compression_error,
                else => null,
            };
            return if (code) |value| .{ .goaway = .{
                .last_stream_id = self.state.session.streams.highestRemoteStreamId(),
                .code = value,
            } } else .none;
        }

        /// Emit a control response suggested by `ReceiveResult.control`. The
        /// action is transport-neutral and never writes implicitly from receive().
        pub fn sendControl(self: *Self, out: *std.Io.Writer, action: ControlAction) SendControlError!void {
            switch (action) {
                .none => return,
                else => try self.requireStarted(),
            }
            switch (action) {
                .none => unreachable,
                .settings_ack => try self.state.session.sendSettingsAck(out),
                .ping_ack => |bytes| try self.state.session.sendPingAck(out, &bytes),
                .reset_stream => |reset| try self.state.session.sendReset(&self.state.store, out, reset.stream_id, reset.code),
                .goaway => |goaway| try self.state.session.sendGoAway(out, goaway.last_stream_id, goaway.code, ""),
            }
        }

        pub fn sendPing(self: *Self, out: *std.Io.Writer, bytes: *const [8]u8) SendPingError!void {
            try self.requireApplicationSend();
            return self.state.session.sendPing(out, false, bytes);
        }

        fn streamCreditPolicy(self: *const Self) struct { target: u31, low: u31 } {
            const target = self.state.effective_local_settings.initial_window_size;
            return .{ .target = target, .low = if (target == 0) 0 else target / 2 };
        }

        fn ensureStreamCredit(self: *Self, stream_id: u31) void {
            if (self.state.store.receiveCredit(stream_id) != null) return;
            const policy = self.streamCreditPolicy();
            const credit = h2.flow.ReceiveCredit.init(policy.target, policy.low) catch unreachable;
            _ = self.state.store.setReceiveCredit(stream_id, credit);
        }

        fn applyEffectiveLocalSettings(self: *Self, next_raw: LocalSettings) error{FlowControl}!void {
            const next = next_raw.normalized(self.role());
            const previous = self.state.effective_local_settings;
            if (previous.initial_window_size != next.initial_window_size)
                try self.state.store.applyLocalInitialWindow(previous.initial_window_size, next.initial_window_size);
            self.state.session.streams.local_limits = next.streamLimits(self.role());
            self.state.decoder.setAllowedMaxSize(next.header_table_size);
            self.state.decoder.setMaxHeaderListSize(next.max_header_list_size);
            const target = next.initial_window_size;
            self.state.store.setReceiveCreditPolicy(target, if (target == 0) 0 else target / 2);
            self.state.effective_local_settings = next;
        }

        /// Report DATA capacity released by the application after it has finished
        /// using the receive bytes. Both connection and stream accounting use the
        /// full flow-controlled DATA payload length, including padding.
        pub fn releaseData(self: *Self, data: h2.session.Data) void {
            const amount = data.flowControlledBytes();
            self.state.connection_credit.release(amount);
            self.ensureStreamCredit(data.stream_id);
            if (self.state.store.receiveCredit(data.stream_id)) |credit| credit.release(amount);
        }

        /// Emit any WINDOW_UPDATE frames made ready by prior `releaseData` calls.
        /// The transport remains caller-owned and no control bytes are emitted by
        /// receive() itself.
        pub fn flushReceiveCredit(self: *Self, out: *std.Io.Writer, stream_id: u31) ReceiveCreditError!ReceiveCreditResult {
            try self.requireApplicationSend();
            var result: ReceiveCreditResult = .{};
            result.connection = try self.state.session.replenishConnectionReceive(out, &self.state.connection_credit);
            if (self.state.store.receiveCredit(stream_id)) |credit|
                result.stream = try self.state.session.replenishStreamReceive(&self.state.store, out, stream_id, credit);
            return result;
        }

        pub fn resetStream(self: *Self, out: *std.Io.Writer, stream_id: u31, code: h2.protocol.ErrorCode) ResetStreamError!void {
            try self.requireApplicationSend();
            return self.state.session.sendReset(&self.state.store, out, stream_id, code);
        }

        /// Cancel one locally initiated client request with RST_STREAM(CANCEL).
        /// On a successful wire write the stream is already closed in Session;
        /// the high-level bounded store is reclaimed immediately because no
        /// further application event is needed for a locally initiated cancel.
        /// Late peer frames remain classifiable from StreamManager high-water
        /// state, so reclamation does not make the identifier look idle again.
        pub fn cancelRequest(self: *Self, out: *std.Io.Writer, stream_id: u31) CancelRequestError!void {
            if (self.role() != .client) return error.NotClient;
            if (!self.state.session.streams.localInitiated(stream_id)) return error.NotLocalRequest;
            try self.requireApplicationSend();
            try self.state.session.sendReset(&self.state.store, out, stream_id, .cancel);
            const reclaimed = self.state.store.removeClosed(stream_id);
            std.debug.assert(reclaimed);
        }

        pub fn sendGoAway(self: *Self, out: *std.Io.Writer, last_stream_id: u31, code: h2.protocol.ErrorCode, debug_data: []const u8) SendGoAwayError!void {
            try self.requireStarted();
            return self.state.session.sendGoAway(out, last_stream_id, code, debug_data);
        }

        /// Start the RFC 9113 two-phase graceful server shutdown sequence. No
        /// timer is owned; the caller decides when to call `finishGracefulGoAway`.
        pub fn announceGracefulGoAway(self: *Self, out: *std.Io.Writer, debug_data: []const u8) GracefulGoAwayError!void {
            try self.requireApplicationSend();
            return self.state.graceful_goaway.announce(&self.state.session, out, debug_data);
        }

        /// Send the final graceful GOAWAY cutoff after the caller-selected grace
        /// interval. `last_stream_id` is application-processed, not merely parsed.
        pub fn finishGracefulGoAway(self: *Self, out: *std.Io.Writer, last_stream_id: u31, debug_data: []const u8) GracefulGoAwayError!void {
            try self.requireApplicationSend();
            return self.state.graceful_goaway.finish(&self.state.session, out, last_stream_id, debug_data);
        }

        pub inline fn gracefulGoAwayPhase(self: *const Self) h2.session.GracefulGoAway.Phase {
            return self.state.graceful_goaway.phase;
        }

        /// Reclaim one known-closed bounded stream slot without scanning the
        /// whole store. Returns false when the stream is absent or not closed.
        pub inline fn reclaimStream(self: *Self, stream_id: u31) bool {
            return self.state.store.removeClosed(stream_id);
        }

        pub inline fn reclaimClosed(self: *Self) usize {
            return self.state.store.reclaimClosed();
        }
    };
}

test "high-level HTTP2 supports caller-owned fixed storage" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var storage: Conn.Storage = undefined;
    var conn = Conn.initClientInPlace(&storage, std.testing.allocator);
    defer conn.deinit();

    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try conn.start(&wire);
    const sent = try conn.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/"), &.{}, true);
    try std.testing.expectEqual(@as(u31, 1), sent.stream_id);
}

test "high-level HTTP2 forwards trailers and graceful GOAWAY" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();
    var wire_storage: [2048]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.start(&wire);
    const sent = try client.sendRequest(&wire, h2.message.RequestFields.init("POST", "https", "example.com", "/"), &.{}, false);
    const Allow = struct {
        pub fn allows(_: @This(), _: []const u8) bool {
            return true;
        }
    };
    _ = try client.sendTrailers(&wire, sent.stream_id, &.{h2.message.header("x-checksum", "ok")}, Allow{});

    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();
    var server_wire_storage: [512]u8 = undefined;
    var server_wire = std.Io.Writer.fixed(&server_wire_storage);
    _ = try server.start(&server_wire);
    try server.announceGracefulGoAway(&server_wire, "drain");
    try std.testing.expectEqual(h2.session.GracefulGoAway.Phase.announced, server.gracefulGoAwayPhase());
    try server.finishGracefulGoAway(&server_wire, 0, "done");
    try std.testing.expectEqual(h2.session.GracefulGoAway.Phase.final, server.gracefulGoAwayPhase());
}

test "high-level HTTP2 connection owns defaults and emits typed request" {
    const Conn = Connection(.{ .max_streams = 4, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var conn = try Conn.initClient(std.testing.allocator);
    defer conn.deinit();

    var wire_storage: [1024]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try conn.start(&wire);
    const sent = try conn.sendRequest(
        &wire,
        h2.message.RequestFields.init("GET", "https", "example.com", "/"),
        &.{h2.message.header("accept", "*/*")},
        true,
    );
    try std.testing.expectEqual(@as(u31, 1), sent.stream_id);
    try std.testing.expect(conn.state.store.get(1) != null);
}

test "high-level HTTP2 reclaims closed bounded stream slots" {
    const Conn = Connection(.{ .max_streams = 1, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var storage: Conn.Storage = undefined;
    var conn = Conn.initClientInPlace(&storage, std.testing.allocator);
    defer conn.deinit();

    var wire_storage: [2048]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try conn.start(&wire);
    const first = try conn.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/one"), &.{}, false);
    try conn.resetStream(&wire, first.stream_id, .cancel);
    try std.testing.expectEqual(@as(usize, 1), conn.reclaimClosed());
    const second = try conn.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/two"), &.{}, true);
    try std.testing.expectEqual(@as(u31, 3), second.stream_id);
}

test "high-level HTTP2 drain processes multiple complete control frames" {
    const Conn = Connection(.{ .max_streams = 4, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();
    var server_start_storage: [64]u8 = undefined;
    var server_start = std.Io.Writer.fixed(&server_start_storage);
    _ = try server.start(&server_start);

    var settings_header: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&settings_header);
    var ping_header: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 8, .type = .ping, .flags = 0, .stream_id = 0 }).encode(&ping_header);
    const ping_payload = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const input = h2.preface.bytes.* ++ settings_header ++ ping_header ++ ping_payload;

    const Counter = struct {
        count: usize = 0,
        pub fn onEvent(self: *@This(), _: ReceiveResult) DrainAction {
            self.count += 1;
            return .continue_;
        }
    };
    var counter: Counter = .{};
    const drained = try server.drain(&input, &counter);
    try std.testing.expectEqual(input.len, drained.consumed);
    try std.testing.expectEqual(@as(usize, 2), drained.events);
    try std.testing.expectEqual(@as(usize, 2), counter.count);
}

test "high-level HTTP2 honors peer header list limit before wire mutation" {
    const Conn = Connection(.{ .max_streams = 4, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var conn = try Conn.initClient(std.testing.allocator);
    defer conn.deinit();
    conn.state.session.peer.settings.max_header_list_size = 64;

    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try conn.start(&wire);
    const before = wire.end;
    try std.testing.expectError(
        error.PeerHeaderListTooLarge,
        conn.sendRequest(
            &wire,
            h2.message.RequestFields.init("GET", "https", "example.com", "/"),
            &.{},
            true,
        ),
    );
    try std.testing.expectEqual(before, wire.end);
    try std.testing.expect(conn.state.store.get(1) == null);
}

test "high-level HTTP2 derives initial SETTINGS and receive limit from config" {
    const Conn = Connection(.{
        .max_streams = 2,
        .header_block_bytes = 512,
        .scratch_bytes = 512,
        .frame_staging_bytes = 512,
        .collected_fields = 8,
        .collected_field_bytes = 256,
        .outbound_fields = 8,
        .local_settings = .{ .max_frame_size = 32_768, .max_header_list_size = 1024, .enable_push = false },
    });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectEqual(@as(u32, 32_768), client.configuredInitialSettings().max_frame_size);

    var storage: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    _ = try client.start(&out);
    const wire = out.buffered();
    try std.testing.expect(std.mem.startsWith(u8, wire, h2.preface.bytes));
    const parsed = (try h2.frame.parseComplete(wire[h2.preface.bytes.len..], h2.frame.default_max_frame_size)).?;
    try std.testing.expectEqual(h2.frame.Type.settings, parsed.frame.header.type);
    var it = try h2.settings.Iterator.init(parsed.frame.payload);
    var saw_frame = false;
    var saw_header = false;
    while (it.next()) |setting| switch (setting.id) {
        .max_frame_size => {
            saw_frame = setting.value == 32_768;
        },
        .max_header_list_size => {
            saw_header = setting.value == 1024;
        },
        .enable_push => try std.testing.expectEqual(@as(u32, 0), setting.value),
        else => {},
    };
    try std.testing.expect(saw_frame and saw_header);
}

test "high-level HTTP2 activates restrictive local settings only after ACK" {
    const Conn = Connection(.{
        .max_streams = 4,
        .header_block_bytes = 512,
        .scratch_bytes = 512,
        .frame_staging_bytes = 512,
        .collected_fields = 8,
        .collected_field_bytes = 256,
        .outbound_fields = 8,
        .local_settings = .{
            .header_table_size = 1024,
            .enable_push = false,
            .max_concurrent_streams = 0,
            .initial_window_size = 32_768,
        },
    });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var outbound_storage: [1024]u8 = undefined;
    var outbound = std.Io.Writer.fixed(&outbound_storage);
    _ = try client.start(&outbound);
    const sent = try client.sendRequest(
        &outbound,
        h2.message.RequestFields.init("GET", "https", "example.com", "/"),
        &.{},
        true,
    );

    try std.testing.expect(!client.initialSettingsAcknowledged());
    try std.testing.expectEqual(@as(i32, 65_535), client.state.store.get(sent.stream_id).?.windows.receive.value);
    try std.testing.expect(client.state.session.streams.local_limits.enable_push);
    try std.testing.expectEqual(std.math.maxInt(u32), client.state.session.streams.local_limits.max_concurrent_streams);

    var peer_settings: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&peer_settings);
    _ = (try client.receive(&peer_settings)).?;
    try std.testing.expect(!client.initialSettingsAcknowledged());

    var ack: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0x01, .stream_id = 0 }).encode(&ack);
    _ = (try client.receive(&ack)).?;
    try std.testing.expect(client.initialSettingsAcknowledged());
    try std.testing.expectEqual(@as(i32, 32_768), client.state.store.get(sent.stream_id).?.windows.receive.value);
    try std.testing.expect(!client.state.session.streams.local_limits.enable_push);
    try std.testing.expectEqual(@as(u32, 0), client.state.session.streams.local_limits.max_concurrent_streams);
}

test "high-level HTTP2 accepts permissive initial SETTINGS before ACK" {
    const Conn = Connection(.{
        .max_streams = 4,
        .header_block_bytes = 512,
        .scratch_bytes = 512,
        .frame_staging_bytes = 512,
        .collected_fields = 8,
        .collected_field_bytes = 256,
        .outbound_fields = 8,
        .local_settings = .{
            .header_table_size = 8192,
            .enable_push = false,
            .max_concurrent_streams = 0,
            .initial_window_size = 131_070,
            .max_frame_size = 32_768,
            .max_header_list_size = 1024,
        },
    });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var outbound_storage: [2048]u8 = undefined;
    var outbound = std.Io.Writer.fixed(&outbound_storage);
    _ = try client.start(&outbound);

    const acknowledged = client.acknowledgedLocalSettings();
    const effective = client.effectiveLocalSettings();
    try std.testing.expectEqual(@as(u31, 65_535), acknowledged.initial_window_size);
    try std.testing.expectEqual(@as(u31, 131_070), effective.initial_window_size);
    try std.testing.expectEqual(@as(u32, 32_768), effective.max_frame_size);
    // HPACK maximum changes are synchronized specifically at ACK, while these
    // restrictive settings remain at their defaults until then.
    try std.testing.expectEqual(@as(u32, 4096), effective.header_table_size);
    try std.testing.expectEqual(std.math.maxInt(u32), effective.max_concurrent_streams);
    try std.testing.expectEqual(std.math.maxInt(u32), effective.max_header_list_size);
    try std.testing.expect(effective.enable_push);

    const request = try client.sendRequest(
        &outbound,
        h2.message.RequestFields.init("GET", "https", "example.com", "/"),
        &.{},
        true,
    );
    try std.testing.expectEqual(@as(i32, 131_070), client.state.store.get(request.stream_id).?.windows.receive.value);

    var peer_settings: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&peer_settings);
    _ = (try client.receive(&peer_settings)).?;
    var ack: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0x01, .stream_id = 0 }).encode(&ack);
    _ = (try client.receive(&ack)).?;

    try std.testing.expect(client.initialSettingsAcknowledged());
    try std.testing.expectEqual(@as(u32, 8192), client.acknowledgedLocalSettings().header_table_size);
    try std.testing.expectEqual(@as(u32, 0), client.acknowledgedLocalSettings().max_concurrent_streams);
    try std.testing.expectEqual(@as(u32, 1024), client.effectiveLocalSettings().max_header_list_size);
    try std.testing.expect(!client.effectiveLocalSettings().enable_push);
}

test "high-level HTTP2 serializes runtime local SETTINGS updates" {
    const Conn = Connection(.{
        .max_streams = 4,
        .header_block_bytes = 512,
        .scratch_bytes = 512,
        .frame_staging_bytes = 512,
        .collected_fields = 8,
        .collected_field_bytes = 256,
        .outbound_fields = 8,
    });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var startup_storage: [1024]u8 = undefined;
    var startup = std.Io.Writer.fixed(&startup_storage);
    _ = try client.start(&startup);

    var peer_settings: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&peer_settings);
    _ = (try client.receive(&peer_settings)).?;
    var ack: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0x01, .stream_id = 0 }).encode(&ack);
    _ = (try client.receive(&ack)).?;
    try std.testing.expect(client.initialSettingsAcknowledged());
    try std.testing.expect(client.pendingLocalSettings() == null);

    const request = try client.sendRequest(
        &startup,
        h2.message.RequestFields.init("GET", "https", "example.com", "/settings"),
        &.{},
        false,
    );
    try std.testing.expectEqual(@as(i32, 65_535), client.state.store.get(request.stream_id).?.windows.receive.value);

    const restrictive: LocalSettings = .{
        .header_table_size = 2048,
        .enable_push = false,
        .max_concurrent_streams = 4,
        .initial_window_size = 131_070,
        .max_frame_size = 32_768,
        .max_header_list_size = 1024,
    };
    var update_storage: [256]u8 = undefined;
    var update = std.Io.Writer.fixed(&update_storage);
    const ticket = (try client.sendLocalSettings(&update, restrictive)).?;
    try std.testing.expect(ticket > 0);
    try std.testing.expect(client.pendingLocalSettings() != null);

    const before_ack = client.effectiveLocalSettings();
    try std.testing.expectEqual(@as(u31, 131_070), before_ack.initial_window_size);
    try std.testing.expectEqual(@as(u32, 32_768), before_ack.max_frame_size);
    try std.testing.expectEqual(@as(u32, 4096), before_ack.header_table_size);
    try std.testing.expectEqual(std.math.maxInt(u32), before_ack.max_concurrent_streams);
    try std.testing.expectEqual(std.math.maxInt(u32), before_ack.max_header_list_size);
    try std.testing.expect(before_ack.enable_push);
    try std.testing.expectEqual(@as(i32, 131_070), client.state.store.get(request.stream_id).?.windows.receive.value);

    var blocked_storage: [64]u8 = undefined;
    var blocked = std.Io.Writer.fixed(&blocked_storage);
    try std.testing.expectError(error.SettingsPending, client.sendLocalSettings(&blocked, .{}));
    try std.testing.expectEqual(@as(usize, 0), blocked.end);

    _ = (try client.receive(&ack)).?;
    try std.testing.expect(client.pendingLocalSettings() == null);
    try std.testing.expectEqual(restrictive, client.acknowledgedLocalSettings());
    try std.testing.expectEqual(restrictive, client.effectiveLocalSettings());

    const relaxed: LocalSettings = .{
        .header_table_size = 8192,
        .enable_push = true,
        .max_concurrent_streams = 100,
        .initial_window_size = 65_535,
        .max_frame_size = 32_768,
        .max_header_list_size = std.math.maxInt(u32),
    };
    var relax_storage: [256]u8 = undefined;
    var relax = std.Io.Writer.fixed(&relax_storage);
    _ = (try client.sendLocalSettings(&relax, relaxed)).?;
    const relaxed_pending = client.effectiveLocalSettings();
    // Relaxations are receive-safe immediately. HPACK and the smaller stream
    // window remain synchronized at ACK.
    try std.testing.expectEqual(@as(u32, 100), relaxed_pending.max_concurrent_streams);
    try std.testing.expectEqual(std.math.maxInt(u32), relaxed_pending.max_header_list_size);
    try std.testing.expect(relaxed_pending.enable_push);
    try std.testing.expectEqual(@as(u32, 2048), relaxed_pending.header_table_size);
    try std.testing.expectEqual(@as(u31, 131_070), relaxed_pending.initial_window_size);

    var frames = h2.frame.CompleteIterator.init(relax.buffered(), h2.frame.default_max_frame_size);
    const update_frame = (try frames.next()).?;
    var settings_it = try h2.settings.Iterator.init(update_frame.payload);
    var restored_header_limit = false;
    while (settings_it.next()) |setting| {
        if (setting.id == .max_header_list_size)
            restored_header_limit = setting.value == std.math.maxInt(u32);
    }
    try std.testing.expect(restored_header_limit);

    _ = (try client.receive(&ack)).?;
    try std.testing.expectEqual(relaxed, client.effectiveLocalSettings());
    try std.testing.expectEqual(@as(i32, 65_535), client.state.store.get(request.stream_id).?.windows.receive.value);

    var noop_storage: [32]u8 = undefined;
    var noop = std.Io.Writer.fixed(&noop_storage);
    try std.testing.expect((try client.sendLocalSettings(&noop, relaxed)) == null);
    try std.testing.expectEqual(@as(usize, 0), noop.end);
}

test "high-level HTTP2 reports and emits mandatory control responses" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();
    var server_start_storage: [64]u8 = undefined;
    var server_start = std.Io.Writer.fixed(&server_start_storage);
    _ = try server.start(&server_start);

    var settings_header: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&settings_header);
    const input = h2.preface.bytes.* ++ settings_header;
    const received = (try server.receive(&input)).?;
    try std.testing.expect(received.control == .settings_ack);

    var wire_storage: [32]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    try server.sendControl(&wire, received.control);
    const parsed = (try h2.frame.parseComplete(wire.buffered(), h2.frame.default_max_frame_size)).?;
    try std.testing.expectEqual(h2.frame.Type.settings, parsed.frame.header.type);
    try std.testing.expect((parsed.frame.header.flags & 0x01) != 0);
}

test "high-level HTTP2 field collector overflow fails closed" {
    const Client = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    const Server = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 1, .collected_field_bytes = 32, .outbound_fields = 8 });
    var client = try Client.initClient(std.testing.allocator);
    defer client.deinit();
    var server = try Server.initServer(std.testing.allocator);
    defer server.deinit();

    var wire_storage: [2048]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.start(&wire);
    _ = try client.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/"), &.{}, true);

    var offset: usize = 0;
    const first = (try server.receive(wire.buffered()[offset..])).?;
    offset += first.consumed;
    try std.testing.expect(first.event.? == .settings);
    try std.testing.expectError(error.HeaderCollectionOverflow, server.receive(wire.buffered()[offset..]));
    try std.testing.expectError(error.ReceiveFailed, server.receive(""));
}

test "high-level HTTP2 composes receive-credit release and WINDOW_UPDATE" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 1024, .scratch_bytes = 1024, .frame_staging_bytes = 1024, .collected_fields = 8, .collected_field_bytes = 512, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();
    var server_start_storage: [64]u8 = undefined;
    var server_start = std.Io.Writer.fixed(&server_start_storage);
    _ = try server.start(&server_start);

    var c2s_storage: [64 * 1024]u8 = undefined;
    var c2s = std.Io.Writer.fixed(&c2s_storage);
    _ = try client.start(&c2s);
    const request = try client.sendRequest(&c2s, h2.message.RequestFields.init("POST", "https", "example.com", "/upload"), &.{}, false);

    var offset: usize = 0;
    while (offset < c2s.buffered().len) {
        const received = (try server.receive(c2s.buffered()[offset..])) orelse break;
        offset += received.consumed;
    }

    const payload_bytes = [_]u8{'x'} ** 16_384;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const before = c2s.end;
        const sent = try client.sendData(&c2s, request.stream_id, &payload_bytes, false);
        try std.testing.expectEqual(@as(usize, payload_bytes.len), sent.consumed);
        while (offset < c2s.end) {
            const received = (try server.receive(c2s.buffered()[offset..])) orelse break;
            offset += received.consumed;
            if (received.event) |event| switch (event) {
                .data => |data| server.releaseData(data),
                else => {},
            };
        }
        try std.testing.expect(c2s.end > before);
    }

    var control_storage: [64]u8 = undefined;
    var control = std.Io.Writer.fixed(&control_storage);
    const credited = try server.flushReceiveCredit(&control, request.stream_id);
    try std.testing.expect(credited.connection != 0);
    try std.testing.expect(credited.stream != 0);
    var frames = h2.frame.CompleteIterator.init(control.buffered(), h2.frame.default_max_frame_size);
    var count: usize = 0;
    while (try frames.next()) |frame_value| {
        try std.testing.expectEqual(h2.frame.Type.window_update, frame_value.header.type);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "high-level HTTP2 request lifecycle is fail-closed before start and after local GOAWAY" {
    const Conn = Connection(.{ .max_streams = 4, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var wire_storage: [2048]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    try std.testing.expect(!client.canOpenRequest());
    try std.testing.expectError(
        error.NotStarted,
        client.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/early"), &.{}, true),
    );
    try std.testing.expectEqual(@as(usize, 0), wire.end);

    _ = try client.start(&wire);
    try std.testing.expect(client.canOpenRequest());
    // RFC 9113 permits request frames immediately after the client preface;
    // waiting for the server's initial SETTINGS is not required.
    const request = try client.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/ok"), &.{}, true);
    try std.testing.expectEqual(@as(u31, 1), request.stream_id);

    try client.sendGoAway(&wire, 0, .no_error, "done");
    try std.testing.expectEqual(Lifecycle.draining, client.lifecycle());
    try std.testing.expect(!client.canOpenRequest());
    const before = wire.end;
    try std.testing.expectError(
        error.ConnectionDraining,
        client.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/blocked"), &.{}, true),
    );
    try std.testing.expectEqual(before, wire.end);
    try std.testing.expectError(error.ConnectionDraining, client.sendLocalSettings(&wire, .{}));
}

test "high-level HTTP2 exposes GOAWAY retry classification and lifecycle" {
    const Conn = Connection(.{ .max_streams = 8, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var wire_storage: [4096]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.start(&wire);
    try std.testing.expectEqual(Lifecycle.handshaking, client.lifecycle());

    var peer_settings: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&peer_settings);
    _ = (try client.receive(&peer_settings)).?;
    try std.testing.expectEqual(Lifecycle.active, client.lifecycle());

    const one = try client.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/one"), &.{}, true);
    const three = try client.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/three"), &.{}, true);
    const five = try client.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/five"), &.{}, true);
    try std.testing.expectEqual(@as(u31, 1), one.stream_id);
    try std.testing.expectEqual(@as(u31, 3), three.stream_id);
    try std.testing.expectEqual(@as(u31, 5), five.stream_id);

    var goaway: [17]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 8, .type = .goaway, .flags = 0, .stream_id = 0 }).encode(goaway[0..9]);
    std.mem.writeInt(u32, goaway[9..13], 3, .big);
    std.mem.writeInt(u32, goaway[13..17], 0, .big);
    const received = (try client.receive(&goaway)).?;
    try std.testing.expect(received.event.? == .goaway);
    try std.testing.expectEqual(Lifecycle.draining, client.lifecycle());
    try std.testing.expectEqual(@as(?u31, 3), client.peerGoAwayLastStreamId());
    try std.testing.expect(!client.unprocessedByPeer(one.stream_id));
    try std.testing.expect(!client.unprocessedByPeer(three.stream_id));
    try std.testing.expect(client.unprocessedByPeer(five.stream_id));

    var blocked_storage: [256]u8 = undefined;
    var blocked = std.Io.Writer.fixed(&blocked_storage);
    try std.testing.expectError(
        error.ConnectionDraining,
        client.sendRequest(&blocked, h2.message.RequestFields.init("GET", "https", "example.com", "/new"), &.{}, true),
    );
    try std.testing.expectEqual(@as(usize, 0), blocked.end);
}

test "high-level HTTP2 connection faults latch receive terminal state" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    var outbound_storage: [512]u8 = undefined;
    var outbound = std.Io.Writer.fixed(&outbound_storage);
    _ = try server.start(&outbound);

    var peer_settings: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&peer_settings);
    const preface = h2.preface.bytes.* ++ peer_settings;
    _ = (try server.receive(&preface)).?;
    try std.testing.expectEqual(Lifecycle.active, server.lifecycle());

    var invalid_data: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .data, .flags = 0, .stream_id = 0 }).encode(&invalid_data);
    var receive_error: ?ReceiveError = null;
    const maybe_result = server.receive(&invalid_data) catch |err| blk: {
        receive_error = err;
        break :blk null;
    };
    try std.testing.expect(maybe_result == null);
    try std.testing.expectEqual(error.Protocol, receive_error.?);
    try std.testing.expectEqual(Lifecycle.failed, server.lifecycle());
    try std.testing.expectError(error.ReceiveFailed, server.receive(""));

    const control_action = server.controlForReceiveError(receive_error.?);
    try std.testing.expect(control_action == .goaway);
    var control_storage: [64]u8 = undefined;
    var control = std.Io.Writer.fixed(&control_storage);
    try server.sendControl(&control, control_action);
    const parsed = (try h2.frame.parseComplete(control.buffered(), h2.frame.default_max_frame_size)).?;
    try std.testing.expectEqual(h2.frame.Type.goaway, parsed.frame.header.type);

    var blocked_storage: [256]u8 = undefined;
    var blocked = std.Io.Writer.fixed(&blocked_storage);
    var response = try h2.message.ResponseFields.init(204);
    try std.testing.expectError(error.ConnectionFailed, server.sendResponse(&blocked, 1, &response, &.{}, true));
    try std.testing.expectError(error.ConnectionFailed, server.sendData(&blocked, 1, "x", true));
    const ping_bytes = [_]u8{0} ** 8;
    try std.testing.expectError(error.ConnectionFailed, server.sendPing(&blocked, &ping_bytes));
    try std.testing.expectError(error.ConnectionFailed, server.sendLocalSettings(&blocked, .{}));
    try std.testing.expectEqual(@as(usize, 0), blocked.end);
}

test "high-level HTTP2 bounded stream store survives repeated open reset reclaim cycles" {
    const Conn = Connection(.{ .max_streams = 1, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var wire_storage: [64 * 1024]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.start(&wire);
    var expected_stream_id: u31 = 1;
    var cycle: usize = 0;
    while (cycle < 128) : (cycle += 1) {
        const request = try client.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/"), &.{}, false);
        try std.testing.expectEqual(expected_stream_id, request.stream_id);
        try client.cancelRequest(&wire, request.stream_id);
        try std.testing.expect(client.state.store.get(request.stream_id) == null);
        try std.testing.expectEqual(@as(usize, 0), client.retainedStreams());
        expected_stream_id += 2;
    }
    try std.testing.expect(client.canOpenRequest());
}

test "high-level HTTP2 reclaims one closed stream without full-store scan" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var wire_storage: [1024]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.start(&wire);
    const request = try client.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/"), &.{}, false);
    try client.resetStream(&wire, request.stream_id, .cancel);
    try std.testing.expect(client.reclaimStream(request.stream_id));
    try std.testing.expect(!client.reclaimStream(request.stream_id));
}

test "high-level HTTP2 rejects all non-preface local frames before start" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var wire_storage: [2048]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    const empty_ping = [_]u8{0} ** 8;
    try std.testing.expectError(error.NotStarted, client.sendPing(&wire, &empty_ping));
    try std.testing.expectError(error.NotStarted, client.sendControl(&wire, .settings_ack));
    try std.testing.expectError(error.NotStarted, client.sendData(&wire, 1, "x", false));
    try std.testing.expectError(error.NotStarted, client.resetStream(&wire, 1, .cancel));
    try std.testing.expectError(error.NotStarted, client.flushReceiveCredit(&wire, 1));
    try std.testing.expectError(error.NotStarted, client.sendGoAway(&wire, 0, .no_error, ""));
    try std.testing.expectError(error.NotStarted, client.announceGracefulGoAway(&wire, ""));
    try std.testing.expectError(error.NotStarted, client.finishGracefulGoAway(&wire, 0, ""));
    try std.testing.expectEqual(@as(usize, 0), wire.end);
}

test "high-level HTTP2 server can receive early but cannot answer before local start" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 1024, .scratch_bytes = 1024, .frame_staging_bytes = 1024, .collected_fields = 8, .collected_field_bytes = 512, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    var c2s_storage: [4096]u8 = undefined;
    var c2s = std.Io.Writer.fixed(&c2s_storage);
    _ = try client.start(&c2s);
    const request = try client.sendRequest(&c2s, h2.message.RequestFields.init("GET", "https", "example.com", "/"), &.{}, true);

    var offset: usize = 0;
    while (offset < c2s.end) {
        const result = (try server.receive(c2s.buffered()[offset..])) orelse break;
        offset += result.consumed;
        if (result.event) |event| if (event == .headers) break;
    }
    try std.testing.expect(server.state.store.get(request.stream_id) != null);

    var response = try h2.message.ResponseFields.init(204);
    var s2c_storage: [4096]u8 = undefined;
    var s2c = std.Io.Writer.fixed(&s2c_storage);
    try std.testing.expectError(error.NotStarted, server.sendResponse(&s2c, request.stream_id, &response, &.{}, true));
    try std.testing.expectEqual(@as(usize, 0), s2c.end);

    _ = try server.start(&s2c);
    _ = try server.sendResponse(&s2c, request.stream_id, &response, &.{}, true);
    try std.testing.expect(s2c.end > 0);
}

test "high-level HTTP2 partial request write latches application send failure" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var preface_storage: [128]u8 = undefined;
    var preface = std.Io.Writer.fixed(&preface_storage);
    _ = try client.start(&preface);

    var tiny_storage: [4]u8 = undefined;
    var tiny = std.Io.Writer.fixed(&tiny_storage);
    try std.testing.expectError(
        error.WriteFailed,
        client.sendRequest(&tiny, h2.message.RequestFields.init("GET", "https", "example.com", "/"), &.{}, true),
    );
    try std.testing.expectEqual(Lifecycle.failed, client.lifecycle());
    try std.testing.expect(!client.canOpenRequest());

    var retry_storage: [512]u8 = undefined;
    var retry = std.Io.Writer.fixed(&retry_storage);
    try std.testing.expectError(
        error.ConnectionFailed,
        client.sendRequest(&retry, h2.message.RequestFields.init("GET", "https", "example.com", "/later"), &.{}, true),
    );
    try std.testing.expectEqual(@as(usize, 0), retry.end);
}

test "high-level HTTP2 pre-start receive failure never suggests an out-of-order GOAWAY" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    try std.testing.expectError(error.InvalidPreface, server.receive("not-an-http2-preface"));
    try std.testing.expect(server.controlForReceiveError(error.InvalidPreface) == .none);
    try std.testing.expectEqual(Lifecycle.failed, server.lifecycle());
}

test "high-level HTTP2 finishReceive enters draining on clean peer EOF" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var outbound_storage: [512]u8 = undefined;
    var outbound = std.Io.Writer.fixed(&outbound_storage);
    _ = try client.start(&outbound);

    var peer_settings: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&peer_settings);
    _ = (try client.receive(&peer_settings)).?;

    try client.finishReceive(&.{});
    try std.testing.expect(client.peerReceiveClosed());
    try std.testing.expectEqual(Lifecycle.draining, client.lifecycle());
    try std.testing.expectEqual(RequestAvailability.draining, client.requestAvailability());
    try std.testing.expect(!client.canOpenRequest());
    try std.testing.expectError(error.ConnectionClosed, client.receive(&.{}));
    try std.testing.expectError(
        error.ConnectionDraining,
        client.sendRequest(
            &outbound,
            h2.message.RequestFields.init("GET", "https", "example.com", "/after-eof"),
            &.{},
            true,
        ),
    );
}

test "high-level HTTP2 finishReceive rejects truncated transport state" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var outbound_storage: [512]u8 = undefined;
    var outbound = std.Io.Writer.fixed(&outbound_storage);
    _ = try client.start(&outbound);

    var peer_settings: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&peer_settings);
    _ = (try client.receive(&peer_settings)).?;

    try std.testing.expectError(error.UnexpectedEof, client.finishReceive("partial-frame"));
    try std.testing.expectEqual(Lifecycle.failed, client.lifecycle());
    try std.testing.expectError(error.ReceiveFailed, client.finishReceive(&.{}));
}

test "high-level HTTP2 finishReceive rejects open continuation block" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var outbound_storage: [512]u8 = undefined;
    var outbound = std.Io.Writer.fixed(&outbound_storage);
    _ = try client.start(&outbound);
    var peer_settings: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&peer_settings);
    _ = (try client.receive(&peer_settings)).?;

    client.state.session.connection.continuation_guard.stream_id = 1;
    try std.testing.expectError(error.UnexpectedEof, client.finishReceive(&.{}));
    try std.testing.expectEqual(Lifecycle.failed, client.lifecycle());
}

test "high-level HTTP2 request availability exposes bounded backpressure" {
    const Conn = Connection(.{ .max_streams = 1, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    try std.testing.expectEqual(RequestAvailability.not_started, client.requestAvailability());
    var outbound_storage: [2048]u8 = undefined;
    var outbound = std.Io.Writer.fixed(&outbound_storage);
    _ = try client.start(&outbound);
    try std.testing.expectEqual(RequestAvailability.ready, client.requestAvailability());

    client.state.session.peer.settings.max_concurrent_streams = 0;
    try std.testing.expectEqual(RequestAvailability.peer_limit, client.requestAvailability());
    try std.testing.expectError(
        error.PeerLimit,
        client.sendRequest(&outbound, h2.message.RequestFields.init("GET", "https", "example.com", "/blocked"), &.{}, true),
    );

    client.state.session.peer.settings.max_concurrent_streams = std.math.maxInt(u32);
    const first = try client.sendRequest(
        &outbound,
        h2.message.RequestFields.init("GET", "https", "example.com", "/one"),
        &.{},
        false,
    );
    try client.resetStream(&outbound, first.stream_id, .cancel);
    try std.testing.expectEqual(RequestAvailability.store_full, client.requestAvailability());
    try std.testing.expectError(
        error.StoreFull,
        client.sendRequest(&outbound, h2.message.RequestFields.init("GET", "https", "example.com", "/two"), &.{}, true),
    );
    try std.testing.expect(client.reclaimStream(first.stream_id));
    try std.testing.expectEqual(RequestAvailability.ready, client.requestAvailability());
}

test "high-level HTTP2 server may finish accepted streams after clean peer EOF" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 1024, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 512, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    var c2s_storage: [2048]u8 = undefined;
    var c2s = std.Io.Writer.fixed(&c2s_storage);
    _ = try client.start(&c2s);
    const request = try client.sendRequest(
        &c2s,
        h2.message.RequestFields.init("GET", "https", "example.com", "/"),
        &.{},
        true,
    );

    var s2c_storage: [2048]u8 = undefined;
    var s2c = std.Io.Writer.fixed(&s2c_storage);
    _ = try server.start(&s2c);

    const Sink = struct {
        pub fn onEvent(_: *@This(), _: ReceiveResult) DrainAction {
            return .continue_;
        }
    };
    var sink: Sink = .{};
    const drained = try server.drain(c2s.buffered(), &sink);
    try std.testing.expectEqual(c2s.end, drained.consumed);
    try server.finishReceive(&.{});
    try std.testing.expectEqual(Lifecycle.draining, server.lifecycle());

    var response = try h2.message.ResponseFields.init(204);
    _ = try server.sendResponse(&s2c, request.stream_id, &response, &.{}, true);
}

test "high-level HTTP2 cancelRequest sends CANCEL and immediately reclaims bounded state" {
    const Conn = Connection(.{ .max_streams = 1, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var wire_storage: [4096]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.start(&wire);
    const request = try client.sendRequest(&wire, h2.message.RequestFields.init("POST", "https", "example.com", "/cancel"), &.{}, false);
    try std.testing.expectEqual(@as(u32, 1), client.activeLocalStreams());
    try std.testing.expectEqual(@as(u32, 0), client.activeRemoteStreams());
    try std.testing.expectEqual(@as(u32, 1), client.activeStreams());
    try std.testing.expectEqual(@as(usize, 1), client.retainedStreams());
    try std.testing.expectEqual(RequestAvailability.store_full, client.requestAvailability());

    try client.cancelRequest(&wire, request.stream_id);
    try std.testing.expectEqual(@as(u32, 0), client.activeLocalStreams());
    try std.testing.expectEqual(@as(u32, 0), client.activeStreams());
    try std.testing.expectEqual(@as(usize, 0), client.retainedStreams());
    try std.testing.expectEqual(RequestAvailability.ready, client.requestAvailability());
    try std.testing.expect(client.state.store.get(request.stream_id) == null);

    const next = try client.sendRequest(&wire, h2.message.RequestFields.init("GET", "https", "example.com", "/next"), &.{}, true);
    try std.testing.expectEqual(@as(u31, 3), next.stream_id);
}

test "high-level HTTP2 cancelRequest rejects server role without wire mutation" {
    const Conn = Connection(.{ .max_streams = 1, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try server.start(&wire);
    const before = wire.end;
    try std.testing.expectError(error.NotClient, server.cancelRequest(&wire, 1));
    try std.testing.expectEqual(before, wire.end);
}

test "high-level HTTP2 failed cancel write preserves stream record and poisons sends" {
    const Conn = Connection(.{ .max_streams = 1, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var setup_storage: [2048]u8 = undefined;
    var setup = std.Io.Writer.fixed(&setup_storage);
    _ = try client.start(&setup);
    const request = try client.sendRequest(&setup, h2.message.RequestFields.init("POST", "https", "example.com", "/cancel"), &.{}, false);
    try std.testing.expect(!client.streamsDrained());

    var short_storage: [8]u8 = undefined;
    var short = std.Io.Writer.fixed(&short_storage);
    try std.testing.expectError(error.WriteFailed, client.cancelRequest(&short, request.stream_id));
    try std.testing.expect(client.state.store.get(request.stream_id) != null);
    try std.testing.expectEqual(@as(usize, 1), client.retainedStreams());
    try std.testing.expectEqual(@as(u32, 1), client.activeStreams());
    try std.testing.expectEqual(Lifecycle.failed, client.lifecycle());
    try std.testing.expectError(error.ConnectionFailed, client.sendData(&setup, request.stream_id, "x", false));
}
