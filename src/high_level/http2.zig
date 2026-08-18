const std = @import("std");
const h2 = @import("../http2.zig");
const common = @import("../common.zig");
const hl_common = @import("common.zig");

pub const DrainAction = hl_common.DrainAction;

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
    hpack_table_size: u32 = 4096,
    local_limits: h2.streams.LocalLimits = .{},
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
            store: StreamStore = .{},
            collector: FieldCollector = .{},
            next_request_stream_id: u32 = 1,
        };

        /// Size of the single fixed connection-state allocation for this
        /// configuration, excluding HPACK dynamic-table allocations.
        pub const state_bytes = @sizeOf(State);

        pub const FieldSection = struct {
            stream_id: u31,
            kind: h2.fields.Kind,
            headers: []const common.Header,
            overflowed: bool,
        };

        pub const ReceiveResult = struct {
            consumed: usize,
            event: ?h2.Event = null,
            /// Present only when this call committed a HEADERS/PUSH_PROMISE
            /// field section. Header slices borrow the connection collector and
            /// remain valid until the next successfully committed field section.
            fields: ?FieldSection = null,
        };

        pub const SendRequestResult = struct {
            stream_id: u31,
            headers: h2.session.SendHeadersResult,
        };

        pub const DrainResult = hl_common.DrainResult;

        pub const SendRequestError = h2.message.BuildError || h2.session.SendHeadersError || error{
            NotClient,
            StreamIdExhausted,
        };
        pub const SendResponseError = h2.message.BuildError || h2.session.SendHeadersError || error{NotServer};
        pub const ReceiveError = h2.bootstrap.Bootstrap.ReceiveError;

        pub fn initClient(allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            return initRole(allocator, .client);
        }

        pub fn initServer(allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            return initRole(allocator, .server);
        }

        fn initRole(allocator: std.mem.Allocator, endpoint_role: h2.Role) error{OutOfMemory}!Self {
            const state = try allocator.create(State);
            state.decoder = h2.hpack.Decoder.init(allocator, config.hpack_table_size);
            state.encoder = h2.hpack.Encoder.init(allocator, config.hpack_table_size);
            state.bootstrap = h2.Bootstrap.init(endpoint_role);
            state.settings_sync = .{};
            state.store = .{};
            state.collector = .{};
            state.next_request_stream_id = 1;
            state.session = h2.Session.init(.{
                .role = endpoint_role,
                .local_limits = config.local_limits,
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

        /// Emits the local HTTP/2 connection preface and initial SETTINGS.
        pub fn start(self: *Self, out: *std.Io.Writer, settings: []const h2.settings.Setting) h2.bootstrap.Bootstrap.StartError!h2.session.SettingsTicket {
            return self.state.bootstrap.start(&self.state.session, &self.state.settings_sync, out, settings);
        }

        /// Processes at most one event using the bundled stream store, scratch
        /// space, and copying field collector.
        pub fn receive(self: *Self, input: []const u8, receiver_max_frame_size: u32) ReceiveError!?ReceiveResult {
            const result = (try self.state.bootstrap.receiveBytes(
                &self.state.session,
                &self.state.store,
                input,
                receiver_max_frame_size,
                &self.state.scratch,
                &self.state.collector,
            )) orelse return null;

            var field_section: ?FieldSection = null;
            if (result.event) |event| switch (event) {
                .headers, .push_promise => {
                    field_section = .{
                        .stream_id = self.state.collector.streamId() orelse unreachable,
                        .kind = self.state.collector.kind() orelse unreachable,
                        .headers = self.state.collector.headers(),
                        .overflowed = self.state.collector.overflowed(),
                    };
                },
                else => {},
            };
            return .{ .consumed = result.consumed, .event = result.event, .fields = field_section };
        }

        /// Drain as many immediately parseable events as possible while
        /// invoking `handler.onEvent(result)` synchronously. Returning `.stop`
        /// leaves all remaining input unconsumed. Header slices in `result` are
        /// safe during the callback and follow the collector lifetime described
        /// by `receive` afterwards.
        pub fn drain(
            self: *Self,
            input: []const u8,
            receiver_max_frame_size: u32,
            handler: anytype,
        ) ReceiveError!DrainResult {
            var consumed: usize = 0;
            var events: usize = 0;
            while (consumed < input.len) {
                const maybe = try self.receive(input[consumed..], receiver_max_frame_size);
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
            const stats = try self.state.session.sendHeaders(
                &self.state.store,
                out,
                stream_id,
                end_stream,
                &self.state.frame_staging,
                items,
            );
            self.state.next_request_stream_id += 2;
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
            return self.state.session.sendHeaders(
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

        pub inline fn sendSettings(self: *Self, out: *std.Io.Writer, items: []const h2.settings.Setting) h2.session.SendSettingsError!h2.session.SettingsTicket {
            return self.state.session.sendSettings(&self.state.settings_sync, out, items);
        }

        pub inline fn sendSettingsAck(self: *Self, out: *std.Io.Writer) h2.session.SendSimpleControlError!void {
            return self.state.session.sendSettingsAck(out);
        }

        pub inline fn sendPing(self: *Self, out: *std.Io.Writer, ack: bool, bytes: *const [8]u8) h2.session.SendSimpleControlError!void {
            return self.state.session.sendPing(out, ack, bytes);
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
    _ = try conn.start(&wire, &.{});
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
    const drained = try server.drain(&input, h2.frame.default_max_frame_size, &counter);
    try std.testing.expectEqual(input.len, drained.consumed);
    try std.testing.expectEqual(@as(usize, 2), drained.events);
    try std.testing.expectEqual(@as(usize, 2), counter.count);
}
