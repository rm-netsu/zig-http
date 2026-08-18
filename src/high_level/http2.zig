const std = @import("std");
const h2 = @import("../http2.zig");
const common = @import("../common.zig");
const hl_common = @import("common.zig");

pub const DrainAction = hl_common.DrainAction;

/// SETTINGS advertised by the high-level endpoint. This is the single source
/// of truth for both the initial wire SETTINGS frame and the receive-side
/// limits enforced by the composed connection.
pub const LocalSettings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = true,
    max_concurrent_streams: u32 = std.math.maxInt(u32),
    initial_window_size: u31 = 65_535,
    max_frame_size: u32 = h2.frame.default_max_frame_size,
    max_header_list_size: ?u32 = null,
    enable_connect_protocol: bool = false,

    fn validate(comptime self: LocalSettings) void {
        if (self.max_frame_size < h2.frame.default_max_frame_size or self.max_frame_size > h2.frame.max_frame_size)
            @compileError("high_level.http2 local_settings.max_frame_size must be in 16384..16777215");
    }

    fn streamLimits(self: LocalSettings, role: h2.Role) h2.streams.LocalLimits {
        return .{
            .initial_window_size = self.initial_window_size,
            .max_concurrent_streams = self.max_concurrent_streams,
            .enable_push = role == .client and self.enable_push,
        };
    }

    fn encoded(self: LocalSettings, role: h2.Role, out: *[7]h2.settings.Setting) []const h2.settings.Setting {
        var n: usize = 0;
        if (self.header_table_size != 4096) {
            out[n] = .{ .id = .header_table_size, .value = self.header_table_size };
            n += 1;
        }
        if (role == .client and !self.enable_push) {
            out[n] = .{ .id = .enable_push, .value = 0 };
            n += 1;
        }
        if (self.max_concurrent_streams != std.math.maxInt(u32)) {
            out[n] = .{ .id = .max_concurrent_streams, .value = self.max_concurrent_streams };
            n += 1;
        }
        if (self.initial_window_size != 65_535) {
            out[n] = .{ .id = .initial_window_size, .value = self.initial_window_size };
            n += 1;
        }
        if (self.max_frame_size != h2.frame.default_max_frame_size) {
            out[n] = .{ .id = .max_frame_size, .value = self.max_frame_size };
            n += 1;
        }
        if (self.max_header_list_size) |limit| {
            out[n] = .{ .id = .max_header_list_size, .value = limit };
            n += 1;
        }
        if (self.enable_connect_protocol) {
            out[n] = .{ .id = .enable_connect_protocol, .value = 1 };
            n += 1;
        }
        return out[0..n];
    }
};

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
/// The wrapper performs one allocator allocation for its connection-owned
/// state so the public handle is safely movable even though Session contains
/// pointers into that state. Wire buffers and transports remain caller-owned.
pub fn Connection(comptime config: Config) type {
    if (config.max_streams == 0) @compileError("high_level.http2 Connection max_streams must be non-zero");
    if (config.header_block_bytes == 0) @compileError("high_level.http2 Connection header_block_bytes must be non-zero");
    if (config.scratch_bytes == 0) @compileError("high_level.http2 Connection scratch_bytes must be non-zero");
    if (config.frame_staging_bytes == 0) @compileError("high_level.http2 Connection frame_staging_bytes must be non-zero");
    if (config.outbound_fields < 5) @compileError("high_level.http2 Connection outbound_fields must be at least 5");
    config.local_settings.validate();

    return struct {
        const Self = @This();
        pub const StreamStore = h2.storage.FixedStreamStore(config.max_streams);
        pub const FieldCollector = h2.storage.FixedFieldCollector(config.collected_fields, config.collected_field_bytes);

        allocator: std.mem.Allocator,
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
            initial_settings_ticket: ?h2.session.SettingsTicket = null,
            local_settings_active: bool = false,
            store: StreamStore = .{},
            collector: FieldCollector = .{},
            next_request_stream_id: u32 = 1,
            connection_credit: h2.flow.ReceiveCredit = undefined,
            receive_failed: bool = false,
        };

        /// Size of the single fixed connection-state allocation for this
        /// configuration, excluding HPACK dynamic-table allocations.
        pub const state_bytes = @sizeOf(State);

        pub const FieldSection = struct {
            stream_id: u31,
            kind: h2.fields.Kind,
            headers: []const common.Header,
        };

        pub const ReceiveResult = struct {
            consumed: usize,
            event: ?h2.Event = null,
            /// Present only when this call committed a HEADERS/PUSH_PROMISE
            /// field section. Header slices borrow the connection collector and
            /// remain valid until the next successfully committed field section.
            fields: ?FieldSection = null,
            control: ControlAction = .none,
        };

        pub const ControlAction = union(enum) {
            none,
            settings_ack,
            ping_ack: [8]u8,
            reset_stream: struct { stream_id: u31, code: h2.protocol.ErrorCode },
            goaway: struct { last_stream_id: u31, code: h2.protocol.ErrorCode },
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

        pub const SendRequestError = h2.message.BuildError || h2.session.SendHeadersWithinPeerLimitError || error{
            NotClient,
            StreamIdExhausted,
        };
        pub const SendResponseError = h2.message.BuildError || h2.session.SendHeadersWithinPeerLimitError || error{NotServer};
        pub const ReceiveError = h2.bootstrap.Bootstrap.ReceiveError || error{ HeaderCollectionOverflow, LocalSettingsFlowControl, ReceiveFailed };
        pub const SendControlError = h2.session.SendSimpleControlError || h2.session.SendStreamControlError || h2.session.SendGoAwayError;

        pub fn initClient(allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            return initRole(allocator, .client);
        }

        pub fn initServer(allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            return initRole(allocator, .server);
        }

        fn initRole(allocator: std.mem.Allocator, endpoint_role: h2.Role) error{OutOfMemory}!Self {
            const state = try allocator.create(State);
            // A reduction is not enforceable until the peer ACKs the initial
            // SETTINGS; before that it may still legally encode with the RFC
            // default table size. Increases are safe to accept eagerly.
            state.decoder = h2.hpack.Decoder.init(allocator, @max(@as(u32, 4096), config.local_settings.header_table_size));
            if (config.local_settings.max_header_list_size) |limit| state.decoder.setMaxHeaderListSize(limit);
            state.encoder = h2.hpack.Encoder.init(allocator, 4096);
            state.bootstrap = h2.Bootstrap.init(endpoint_role);
            state.settings_sync = .{};
            state.store = .{};
            state.collector = .{};
            state.next_request_stream_id = 1;
            state.initial_settings_ticket = null;
            state.local_settings_active = false;
            state.connection_credit = h2.flow.ReceiveCredit.init(65_535, 32_767) catch unreachable;
            state.receive_failed = false;
            state.session = h2.Session.init(.{
                .role = endpoint_role,
                // Restrictions advertised by initial SETTINGS become binding
                // only after their ACK. Until then the peer is entitled to the
                // RFC defaults.
                .local_limits = .{},
                .decoder = &state.decoder,
                .encoder = &state.encoder,
                .header_storage = &state.header_storage,
            });
            return .{ .allocator = allocator, .state = state };
        }

        pub fn deinit(self: *Self) void {
            self.state.decoder.deinit();
            self.state.encoder.deinit();
            self.allocator.destroy(self.state);
            self.* = undefined;
        }

        pub inline fn role(self: *const Self) h2.Role {
            return self.state.session.role();
        }

        pub inline fn core(self: *Self) *h2.Session {
            return &self.state.session;
        }

        pub inline fn bootstrap(self: *Self) *h2.Bootstrap {
            return &self.state.bootstrap;
        }

        pub inline fn store(self: *Self) *StreamStore {
            return &self.state.store;
        }

        pub inline fn collector(self: *Self) *FieldCollector {
            return &self.state.collector;
        }

        pub inline fn settingsSync(self: *Self) *h2.session.SettingsSync {
            return &self.state.settings_sync;
        }

        pub inline fn peerHeaderListLimit(self: *const Self) ?u32 {
            return self.state.session.peerHeaderListLimit();
        }

        pub inline fn localSettings(self: *const Self) LocalSettings {
            _ = self;
            return config.local_settings;
        }

        /// Emits the local HTTP/2 connection preface and the initial SETTINGS
        /// derived from `Config.local_settings`. There is no second settings
        /// argument that can diverge from receive-side policy.
        pub fn start(self: *Self, out: *std.Io.Writer) h2.bootstrap.Bootstrap.StartError!h2.session.SettingsTicket {
            const items = config.local_settings.encoded(self.role(), &self.state.local_settings_wire);
            const ticket = try self.state.bootstrap.start(&self.state.session, &self.state.settings_sync, out, items);
            self.state.initial_settings_ticket = ticket;
            return ticket;
        }

        /// True once the peer has acknowledged the initial local SETTINGS and
        /// their restrictive receive-side policy has become active.
        pub inline fn localSettingsActive(self: *const Self) bool {
            return self.state.local_settings_active;
        }

        /// Processes at most one event using the bundled stream store, scratch
        /// space, and copying field collector.
        pub fn receive(self: *Self, input: []const u8) ReceiveError!?ReceiveResult {
            if (self.state.receive_failed) return error.ReceiveFailed;
            const result = (try self.state.bootstrap.receiveBytes(
                &self.state.session,
                &self.state.store,
                input,
                config.local_settings.max_frame_size,
                &self.state.scratch,
                &self.state.collector,
            )) orelse return null;

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
                            if (!self.state.local_settings_active and self.state.initial_settings_ticket == ticket)
                                self.activateLocalSettings() catch {
                                    self.state.receive_failed = true;
                                    return error.LocalSettingsFlowControl;
                                };
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
                    .connection => |code| .{ .goaway = .{ .last_stream_id = self.state.session.streams.highestRemoteStreamId(), .code = code } },
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
            if (self.role() != .client) return error.NotClient;
            if (self.state.next_request_stream_id > std.math.maxInt(u31)) return error.StreamIdExhausted;
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

        pub inline fn sendData(self: *Self, out: *std.Io.Writer, stream_id: u31, bytes: []const u8, end_stream: bool) h2.session.SendDataError!h2.session.SendDataResult {
            return self.state.session.sendData(&self.state.store, out, stream_id, bytes, end_stream);
        }

        /// Emit a control response suggested by `ReceiveResult.control`. The
        /// action is transport-neutral and never writes implicitly from receive().
        pub fn sendControl(self: *Self, out: *std.Io.Writer, action: ControlAction) SendControlError!void {
            switch (action) {
                .none => {},
                .settings_ack => try self.state.session.sendSettingsAck(out),
                .ping_ack => |bytes| try self.state.session.sendPingAck(out, &bytes),
                .reset_stream => |reset| try self.state.session.sendReset(&self.state.store, out, reset.stream_id, reset.code),
                .goaway => |goaway| try self.state.session.sendGoAway(out, goaway.last_stream_id, goaway.code, ""),
            }
        }

        pub inline fn sendPing(self: *Self, out: *std.Io.Writer, bytes: *const [8]u8) h2.session.SendSimpleControlError!void {
            return self.state.session.sendPing(out, false, bytes);
        }

        fn streamCreditPolicy(self: *const Self) struct { target: u31, low: u31 } {
            const target: u31 = if (self.state.local_settings_active)
                config.local_settings.initial_window_size
            else
                65_535;
            return .{ .target = target, .low = if (target == 0) 0 else target / 2 };
        }

        fn ensureStreamCredit(self: *Self, stream_id: u31) void {
            if (self.state.store.receiveCredit(stream_id) != null) return;
            const policy = self.streamCreditPolicy();
            const credit = h2.flow.ReceiveCredit.init(policy.target, policy.low) catch unreachable;
            _ = self.state.store.setReceiveCredit(stream_id, credit);
        }

        fn activateLocalSettings(self: *Self) error{FlowControl}!void {
            if (self.state.local_settings_active) return;
            const previous: u31 = 65_535;
            try self.state.store.applyLocalInitialWindow(previous, config.local_settings.initial_window_size);
            self.state.session.streams.local_limits = config.local_settings.streamLimits(self.role());
            self.state.decoder.setAllowedMaxSize(config.local_settings.header_table_size);
            const target = config.local_settings.initial_window_size;
            self.state.store.setReceiveCreditPolicy(target, if (target == 0) 0 else target / 2);
            self.state.local_settings_active = true;
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
        pub fn flushReceiveCredit(self: *Self, out: *std.Io.Writer, stream_id: u31) h2.session.SendStreamControlError!ReceiveCreditResult {
            var result: ReceiveCreditResult = .{};
            result.connection = try self.state.session.replenishConnectionReceive(out, &self.state.connection_credit);
            if (self.state.store.receiveCredit(stream_id)) |credit|
                result.stream = try self.state.session.replenishStreamReceive(&self.state.store, out, stream_id, credit);
            return result;
        }

        pub inline fn resetStream(self: *Self, out: *std.Io.Writer, stream_id: u31, code: h2.protocol.ErrorCode) h2.session.SendStreamControlError!void {
            return self.state.session.sendReset(&self.state.store, out, stream_id, code);
        }

        pub inline fn sendGoAway(self: *Self, out: *std.Io.Writer, last_stream_id: u31, code: h2.protocol.ErrorCode, debug_data: []const u8) h2.session.SendGoAwayError!void {
            return self.state.session.sendGoAway(out, last_stream_id, code, debug_data);
        }

        pub inline fn reclaimClosed(self: *Self) usize {
            return self.state.store.reclaimClosed();
        }
    };
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
    try std.testing.expect(conn.store().get(1) != null);
}

test "high-level HTTP2 drain processes multiple complete control frames" {
    const Conn = Connection(.{ .max_streams = 4, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    var settings_header: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&settings_header);
    var ping_header: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 8, .type = .ping, .flags = 0, .stream_id = 0 }).encode(&ping_header);
    const ping_payload = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const input = h2.preface.bytes.* ++ settings_header ++ ping_header ++ ping_payload;

    const Counter = struct {
        count: usize = 0,
        pub fn onEvent(self: *@This(), _: Conn.ReceiveResult) DrainAction {
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
    conn.core().peer.settings.max_header_list_size = 64;

    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    try std.testing.expectError(
        error.PeerHeaderListTooLarge,
        conn.sendRequest(
            &wire,
            h2.message.RequestFields.init("GET", "https", "example.com", "/"),
            &.{},
            true,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), wire.end);
    try std.testing.expect(conn.store().get(1) == null);
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
    try std.testing.expectEqual(@as(u32, 32_768), client.localSettings().max_frame_size);

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

    try std.testing.expect(!client.localSettingsActive());
    try std.testing.expectEqual(@as(i32, 65_535), client.store().get(sent.stream_id).?.windows.receive.value);
    try std.testing.expect(client.core().streams.local_limits.enable_push);
    try std.testing.expectEqual(std.math.maxInt(u32), client.core().streams.local_limits.max_concurrent_streams);

    var peer_settings: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&peer_settings);
    _ = (try client.receive(&peer_settings)).?;
    try std.testing.expect(!client.localSettingsActive());

    var ack: [9]u8 = undefined;
    try (h2.frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0x01, .stream_id = 0 }).encode(&ack);
    _ = (try client.receive(&ack)).?;
    try std.testing.expect(client.localSettingsActive());
    try std.testing.expectEqual(@as(i32, 32_768), client.store().get(sent.stream_id).?.windows.receive.value);
    try std.testing.expect(!client.core().streams.local_limits.enable_push);
    try std.testing.expectEqual(@as(u32, 0), client.core().streams.local_limits.max_concurrent_streams);
}

test "high-level HTTP2 reports and emits mandatory control responses" {
    const Conn = Connection(.{ .max_streams = 2, .header_block_bytes = 512, .scratch_bytes = 512, .frame_staging_bytes = 512, .collected_fields = 8, .collected_field_bytes = 256, .outbound_fields = 8 });
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

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
