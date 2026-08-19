const std = @import("std");
const h1 = @import("../http1.zig");
const common = @import("../common.zig");
const hl_common = @import("common.zig");

pub const Config = struct {
    head_bytes: usize = 16 * 1024,
    chunk_line_bytes: usize = 8 * 1024,
    max_in_flight: usize = 64,
    outbound_fields: usize = 64,
    upgrade_offer_bytes: usize = 128,
    decoder_options: h1.connection.Options = .{},
};

pub const Role = enum { client, server };
/// Coarse transport-facing lifecycle for the composed HTTP/1 connection.
/// `closing` means HTTP parsing/writing may finish the current message, but the
/// transport must not be reused for another HTTP message.
pub const Lifecycle = enum { active, closing, switched, failed };
pub const DrainAction = hl_common.DrainAction;

fn requestFramingHasContent(framing: h1.head.BodyFraming) bool {
    return switch (framing) {
        .content_length => |length| length != 0,
        .chunked, .close => true,
        .none => false,
    };
}

/// Transport-neutral bounded HTTP/1 convenience connection. The wrapper owns
/// composed receive/send protocol state and the response-order queue required by
/// HTTP/1 pipelining, but owns no socket, TLS session, timer, or event loop.
///
/// Only HEAD/CONNECT/other request semantics are retained in the queue, so
/// arbitrary extension methods require no copied string storage.
pub fn Connection(comptime config: Config) type {
    if (config.head_bytes == 0) @compileError("high_level.http1 Connection head_bytes must be non-zero");
    if (config.chunk_line_bytes == 0) @compileError("high_level.http1 Connection chunk_line_bytes must be non-zero");
    if (config.max_in_flight == 0) @compileError("high_level.http1 Connection max_in_flight must be non-zero");
    if (config.outbound_fields == 0) @compileError("high_level.http1 Connection outbound_fields must be non-zero");
    if (config.upgrade_offer_bytes == 0) @compileError("high_level.http1 Connection upgrade_offer_bytes must be non-zero");

    return struct {
        const Self = @This();
        const Kind = h1.message.RequestKind;
        const PendingRequest = struct {
            kind: Kind,
            expect_continue: bool = false,
            upgrade_offered: bool = false,
            upgrade_offer_truncated: bool = false,
            continue_sent: bool = false,
            close_after_response: bool = false,
            upgrade_len: usize = 0,
            upgrade_bytes: [config.upgrade_offer_bytes]u8 = undefined,

            fn offer(self: *const PendingRequest) []const u8 {
                return self.upgrade_bytes[0..self.upgrade_len];
            }
        };

        allocator: ?std.mem.Allocator = null,
        state: *Storage,

        const Queue = struct {
            items: [config.max_in_flight]PendingRequest = undefined,
            first: usize = 0,
            len: usize = 0,

            fn full(self: Queue) bool {
                return self.len == config.max_in_flight;
            }

            fn push(self: *Queue, item: PendingRequest) bool {
                if (self.full()) return false;
                self.items[(self.first + self.len) % config.max_in_flight] = item;
                self.len += 1;
                return true;
            }

            fn peek(self: *const Queue) ?PendingRequest {
                if (self.len == 0) return null;
                return self.items[self.first];
            }

            fn peekPtr(self: *Queue) ?*PendingRequest {
                if (self.len == 0) return null;
                return &self.items[self.first];
            }

            fn lastPtr(self: *Queue) ?*PendingRequest {
                if (self.len == 0) return null;
                return &self.items[(self.first + self.len - 1) % config.max_in_flight];
            }

            fn pop(self: *Queue) ?PendingRequest {
                const value = self.peek() orelse return null;
                self.first = (self.first + 1) % config.max_in_flight;
                self.len -= 1;
                if (self.len == 0) self.first = 0;
                return value;
            }
        };

        /// Caller-owned fixed storage for in-place initialization. Once bound
        /// to a Connection, its address must remain stable until `deinit`.
        pub const Storage = struct {
            role: Role,
            head_storage: [config.head_bytes]u8 = undefined,
            chunk_line_storage: [config.chunk_line_bytes]u8 = undefined,
            outbound: [config.outbound_fields]common.Header = undefined,
            decoder: h1.ConnectionDecoder = undefined,
            writer: h1.MessageWriter = h1.MessageWriter.init(),
            pending: Queue = .{},
            receive_at_message_start: bool = true,
            sending_final_response: bool = false,
            peer_close_required: bool = false,
            receive_failed: bool = false,
            client_continue_gate: ?h1.semantics.ContinueGate = null,
        };

        pub const state_bytes = @sizeOf(Storage);

        pub const ReceiveError = h1.connection.Error || error{
            NoOutstandingRequest,
            RequestQueueFull,
            UnexpectedUpgrade,
            ConnectionClosing,
            ReceiveFailed,
        };
        pub const SendRequestError = h1.message.BuildError || h1.MessageWriter.MessageError || error{
            NotClient,
            RequestQueueFull,
            UpgradeOfferTooLarge,
            InvalidUpgradeRequest,
            ConnectionClosing,
            ProtocolSwitched,
            ConnectionFailed,
        };
        pub const SendResponseError = h1.MessageWriter.MessageError || error{
            NotServer,
            NoPendingRequest,
            ContinueRequiredBeforeUpgrade,
            UpgradeNotOffered,
            UpgradeOfferTooLarge,
            ConnectionClosing,
            TooManyFields,
        };
        pub const DataError = h1.MessageWriter.MessageError || error{
            ContinuePending,
            RequestBodySuppressed,
            ConnectionClosing,
            ConnectionFailed,
        };

        pub const DrainResult = hl_common.DrainResult;

        pub fn initClient(allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            return initOwned(allocator, .client);
        }

        pub fn initServer(allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            return initOwned(allocator, .server);
        }

        /// Initialize a fully allocation-free high-level HTTP/1 connection in
        /// caller-owned storage. `storage` must not move until `deinit`.
        pub fn initClientInPlace(storage: *Storage) Self {
            return initInPlace(storage, .client);
        }

        /// Server counterpart to `initClientInPlace`.
        pub fn initServerInPlace(storage: *Storage) Self {
            return initInPlace(storage, .server);
        }

        fn initOwned(allocator: std.mem.Allocator, endpoint_role: Role) error{OutOfMemory}!Self {
            const storage = try allocator.create(Storage);
            var result = initInPlace(storage, endpoint_role);
            result.allocator = allocator;
            return result;
        }

        fn initInPlace(storage: *Storage, endpoint_role: Role) Self {
            storage.role = endpoint_role;
            storage.writer = h1.MessageWriter.init();
            storage.pending = .{};
            storage.receive_at_message_start = true;
            storage.sending_final_response = false;
            storage.peer_close_required = false;
            storage.receive_failed = false;
            storage.client_continue_gate = null;
            storage.decoder = switch (endpoint_role) {
                .client => h1.ConnectionDecoder.initResponse(&storage.head_storage, &storage.chunk_line_storage, config.decoder_options),
                .server => h1.ConnectionDecoder.initRequest(&storage.head_storage, &storage.chunk_line_storage, config.decoder_options),
            };
            return .{ .state = storage };
        }

        pub fn deinit(self: *Self) void {
            if (self.allocator) |allocator| allocator.destroy(self.state);
            self.* = undefined;
        }

        pub inline fn role(self: *const Self) Role {
            return self.state.role;
        }

        pub inline fn decoder(self: *Self) *h1.ConnectionDecoder {
            return &self.state.decoder;
        }

        pub inline fn writer(self: *Self) *h1.MessageWriter {
            return &self.state.writer;
        }

        pub inline fn pendingResponses(self: *const Self) usize {
            return self.state.pending.len;
        }

        pub inline fn protocolSwitched(self: *const Self) bool {
            if (self.state.receive_failed) return false;
            return self.state.decoder.protocolSwitched() or self.state.writer.protocolSwitched();
        }

        pub inline fn mustClose(self: *const Self) bool {
            return self.state.receive_failed or self.state.writer.mustClose() or self.state.peer_close_required;
        }

        /// Transport-facing lifecycle. A peer-selected close is surfaced even
        /// when the local MessageWriter has not yet serialized its final
        /// response, preventing accidental connection reuse.
        pub inline fn lifecycle(self: *const Self) Lifecycle {
            if (self.state.receive_failed or self.state.decoder.failed() or self.state.writer.failed()) return .failed;
            if (self.protocolSwitched()) return .switched;
            if (self.mustClose()) return .closing;
            return .active;
        }

        pub inline fn peerCloseRequired(self: *const Self) bool {
            return self.state.peer_close_required;
        }

        /// Current client-side `Expect: 100-continue` gate, when the active
        /// outbound request has content whose transmission is intentionally
        /// delayed. Informational responses other than 100 do not open it.
        pub inline fn continuePhase(self: *const Self) ?h1.semantics.ContinueGate.Phase {
            const gate = self.state.client_continue_gate orelse return null;
            return gate.phase;
        }

        /// Stop waiting for 100 Continue after an application-selected timeout.
        /// Returns false when no request is currently waiting on that gate.
        pub fn proceedWithoutContinue(self: *Self) bool {
            if (self.state.client_continue_gate) |*gate| {
                if (!gate.waiting()) return false;
                gate.proceedWithoutContinue();
                return true;
            }
            return false;
        }

        /// Serialize a typed client request and retain only the response-framing
        /// semantics needed when its ordered response arrives. Queue capacity is
        /// checked before any wire bytes are emitted.
        pub fn sendRequest(
            self: *Self,
            out: *std.Io.Writer,
            request: h1.message.RequestFields,
            regular_fields: []const common.Header,
        ) SendRequestError!h1.MessageWriter.BeginResult {
            if (self.role() != .client) return error.NotClient;
            switch (self.lifecycle()) {
                .active => {},
                .closing => return error.ConnectionClosing,
                .switched => return error.ProtocolSwitched,
                .failed => return error.ConnectionFailed,
            }
            if (self.state.pending.full()) return error.RequestQueueFull;
            const fields = try request.build(&self.state.outbound, regular_fields);
            const expectation = try h1.semantics.requestExpectationFields(request.version, fields);
            var pending: PendingRequest = .{ .kind = request.kind() };
            const maybe_offer = h1.semantics.copyUpgradeOfferFields(request.version, fields, &pending.upgrade_bytes) catch |err| switch (err) {
                error.BufferTooSmall => return error.UpgradeOfferTooLarge,
                error.InvalidUpgradeRequest => return error.InvalidUpgradeRequest,
                error.InvalidConnectionHeader => return error.InvalidConnectionHeader,
            };
            if (maybe_offer) |offer| {
                pending.upgrade_offered = true;
                pending.upgrade_len = offer.len;
            }
            const result = try self.state.writer.beginRequest(out, request.version, request.method, request.target, fields);
            if (!self.state.pending.push(pending)) unreachable;
            self.state.client_continue_gate = if (!result.message_done and expectation == .continue_100)
                h1.semantics.ContinueGate.init(expectation)
            else
                null;
            return result;
        }

        /// Serialize an informational or final server response for the oldest
        /// outstanding request. Final response order is therefore enforced by
        /// construction for pipelined HTTP/1 requests.
        pub fn sendResponse(
            self: *Self,
            out: *std.Io.Writer,
            response: h1.message.ResponseFields,
            fields: []const common.Header,
        ) SendResponseError!h1.MessageWriter.BeginResult {
            if (self.role() != .server) return error.NotServer;
            const pending = self.state.pending.peekPtr() orelse return error.NoPendingRequest;
            if (response.status == 101) {
                if (pending.close_after_response) return error.ConnectionClosing;
                if (!pending.upgrade_offered) return error.UpgradeNotOffered;
                if (pending.upgrade_offer_truncated) return error.UpgradeOfferTooLarge;
                if (pending.expect_continue and !pending.continue_sent) return error.ContinueRequiredBeforeUpgrade;
                try h1.semantics.validateUpgradeSelectionFields(pending.offer(), response.version, response.status, fields);
            }
            const informational = response.status >= 100 and response.status < 200 and response.status != 101;
            const response_fields = if (!informational and pending.close_after_response and
                try h1.semantics.persistenceFields(response.version, fields) != .close)
            blk: {
                if (fields.len >= self.state.outbound.len) return error.TooManyFields;
                @memcpy(self.state.outbound[0..fields.len], fields);
                self.state.outbound[fields.len] = .{ .name = "connection", .value = "close" };
                break :blk self.state.outbound[0 .. fields.len + 1];
            } else fields;
            const result = try self.state.writer.beginResponse(
                out,
                response.version,
                response.status,
                response.reason,
                pending.kind.canonicalMethod(),
                response_fields,
            );

            if (response.status == 100) pending.continue_sent = true;
            if (!informational) {
                self.state.sending_final_response = !result.message_done;
                if (result.message_done) _ = self.state.pending.pop().?;
            }
            return result;
        }

        pub fn writeData(self: *Self, out: *std.Io.Writer, bytes: []const u8) DataError!h1.MessageWriter.DataResult {
            if (self.role() == .client) {
                if (self.state.receive_failed or self.state.decoder.failed()) return error.ConnectionFailed;
                if (self.state.peer_close_required) return error.ConnectionClosing;
                if (self.state.client_continue_gate) |gate| switch (gate.phase) {
                    .waiting => return error.ContinuePending,
                    .final_received => return error.RequestBodySuppressed,
                    .bypass, .body_allowed => {},
                };
            }
            const result = try self.state.writer.writeData(out, bytes);
            if (self.role() == .client and result.message_done) self.state.client_continue_gate = null;
            if (self.role() == .server and self.state.sending_final_response and result.message_done) {
                _ = self.state.pending.pop() orelse unreachable;
                self.state.sending_final_response = false;
            }
            return result;
        }

        pub fn finish(self: *Self, out: *std.Io.Writer, trailers: []const common.Header) DataError!void {
            if (self.role() == .client and (self.state.receive_failed or self.state.decoder.failed())) return error.ConnectionFailed;
            if (self.role() == .client and self.state.client_continue_gate) |gate| switch (gate.phase) {
                .waiting => return error.ContinuePending,
                .final_received => return error.RequestBodySuppressed,
                .bypass, .body_allowed => {},
            };
            try self.state.writer.finish(out, trailers);
            if (self.role() == .client) self.state.client_continue_gate = null;
            self.finishServerResponseIfNeeded();
        }

        pub fn finishWithTrailerPolicy(self: *Self, out: *std.Io.Writer, trailers: []const common.Header, policy: anytype) DataError!void {
            if (self.role() == .client and (self.state.receive_failed or self.state.decoder.failed())) return error.ConnectionFailed;
            if (self.role() == .client and self.state.client_continue_gate) |gate| switch (gate.phase) {
                .waiting => return error.ContinuePending,
                .final_received => return error.RequestBodySuppressed,
                .bypass, .body_allowed => {},
            };
            try self.state.writer.finishWithTrailerPolicy(out, trailers, policy);
            if (self.role() == .client) self.state.client_continue_gate = null;
            self.finishServerResponseIfNeeded();
        }

        fn finishServerResponseIfNeeded(self: *Self) void {
            if (self.role() != .server or !self.state.sending_final_response) return;
            if (self.state.writer.ready() or self.state.writer.mustClose() or self.state.writer.protocolSwitched()) {
                _ = self.state.pending.pop() orelse unreachable;
                self.state.sending_final_response = false;
            }
        }

        /// Process at most one receive event. The client automatically binds the
        /// next response to the oldest sent request method. The server applies
        /// bounded pipeline backpressure before consuming the next request head
        /// when its outstanding-response queue is full.
        pub fn receive(self: *Self, input: []const u8) ReceiveError!h1.connection.FeedResult {
            if (self.state.receive_failed) return error.ReceiveFailed;
            switch (self.role()) {
                .client => {
                    if (!self.state.decoder.responsePending()) {
                        if (self.state.peer_close_required) return error.ConnectionClosing;
                        const pending = self.state.pending.peek() orelse return error.NoOutstandingRequest;
                        try self.state.decoder.beginResponse(pending.kind.canonicalMethod());
                    }
                },
                .server => {
                    if (self.state.receive_at_message_start and self.state.peer_close_required) return error.ConnectionClosing;
                    if (self.state.receive_at_message_start and self.state.pending.full()) return error.RequestQueueFull;
                },
            }

            const result = try self.state.decoder.feed(input);
            if (result.event) |event| switch (self.role()) {
                .client => {
                    if (event == .head) {
                        const head_event = event.head;
                        const response = switch (head_event.head.start) {
                            .response => |value| value,
                            else => unreachable,
                        };
                        const current_body_response = !head_event.informational and self.state.pending.len == 1;
                        if (self.state.client_continue_gate) |*gate| {
                            if (self.state.pending.len == 1) gate.observeStatus(response.status);
                        }
                        if (!head_event.informational and head_event.persistence == .close) {
                            self.state.peer_close_required = true;
                            _ = self.state.writer.abandonBody();
                        } else if (current_body_response and self.state.writer.abandonBody()) {
                            // A final response arrived before the request body
                            // completed. Do not emit the missing bytes and make
                            // the transport non-reusable to preserve framing.
                        }
                        if (response.status == 101) {
                            const pending = self.state.pending.peekPtr() orelse {
                                self.state.receive_failed = true;
                                return error.NoOutstandingRequest;
                            };
                            if (!pending.upgrade_offered) {
                                self.state.receive_failed = true;
                                return error.UnexpectedUpgrade;
                            }
                            h1.semantics.validateRetainedUpgradeSelection(pending.offer(), head_event.head) catch |err| {
                                self.state.receive_failed = true;
                                return err;
                            };
                        }
                    }
                    if (!self.state.decoder.responsePending()) {
                        _ = self.state.pending.pop() orelse unreachable;
                        if (self.state.pending.len == 0 and self.state.writer.ready())
                            self.state.client_continue_gate = null;
                    }
                },
                .server => switch (event) {
                    .head => |head_event| {
                        const request = switch (head_event.head.start) {
                            .request => |request| request,
                            else => unreachable,
                        };
                        const expectation = h1.semantics.requestExpectation(head_event.head) catch .unsupported;
                        const expect_continue = expectation == .continue_100 and requestFramingHasContent(head_event.framing);
                        var pending: PendingRequest = .{
                            .kind = Kind.from(request.method),
                            .expect_continue = expect_continue,
                            .close_after_response = head_event.persistence == .close,
                        };
                        if (pending.close_after_response) self.state.peer_close_required = true;
                        if (h1.semantics.copyUpgradeOffer(head_event.head, &pending.upgrade_bytes)) |offer| {
                            pending.upgrade_offered = true;
                            pending.upgrade_len = offer.len;
                        } else |err| switch (err) {
                            error.BufferTooSmall => {
                                pending.upgrade_offered = true;
                                pending.upgrade_offer_truncated = true;
                            },
                            else => {},
                        }
                        if (!self.state.pending.push(pending)) unreachable;
                        self.state.receive_at_message_start = head_event.message_done;
                    },
                    .data => |data| self.state.receive_at_message_start = data.message_done,
                    .message_end => self.state.receive_at_message_start = true,
                    .trailer => {},
                },
            };
            return result;
        }

        /// Complete receive-side close-delimited framing at transport EOF.
        pub fn finishReceive(self: *Self) ReceiveError!?h1.Event {
            if (self.state.receive_failed) return error.ReceiveFailed;
            if (self.role() == .client and !self.state.decoder.responsePending()) {
                if (self.state.pending.peek()) |pending|
                    self.state.decoder.beginResponse(pending.kind.canonicalMethod()) catch |err| {
                        self.state.receive_failed = true;
                        return err;
                    };
            }
            const event = self.state.decoder.finish() catch |err| {
                // Transport EOF during a head or framed body is terminal. The
                // low-level decoder intentionally does not mutate itself from
                // finish(), so the composed layer must latch this boundary to
                // prevent accidental reuse after a truncated peer message.
                self.state.receive_failed = true;
                return err;
            };

            // A clean receive EOF still makes this transport non-reusable even
            // when it arrived exactly between messages. Servers may finish
            // responses for requests already parsed before the FIN, but the
            // final queued response must carry close semantics.
            self.state.peer_close_required = true;
            if (self.role() == .server) {
                if (self.state.pending.lastPtr()) |pending| pending.close_after_response = true;
            }

            if (self.role() == .client and !self.state.decoder.responsePending() and self.state.pending.len != 0)
                _ = self.state.pending.pop().?;
            if (self.role() == .server and event != null) self.state.receive_at_message_start = true;
            return event;
        }

        /// Drain as many immediately parseable events as possible while calling
        /// `handler.onEvent(event)` synchronously. The handler must return
        /// `DrainAction`; `.stop` preserves all unconsumed input for the caller.
        /// Borrowed event slices are valid only during the callback / until the
        /// next receive call, matching ConnectionDecoder's normal lifetime.
        pub fn drain(self: *Self, input: []const u8, handler: anytype) ReceiveError!DrainResult {
            var consumed: usize = 0;
            var events: usize = 0;
            while (consumed < input.len) {
                const result = try self.receive(input[consumed..]);
                if (result.consumed == 0 and result.event == null) break;
                consumed += result.consumed;
                if (result.event) |event| {
                    events += 1;
                    if (handler.onEvent(event) == .stop) return .{ .consumed = consumed, .events = events, .stopped = true };
                }
            }
            return .{ .consumed = consumed, .events = events };
        }
    };
}

test "high-level HTTP1 supports allocation-free in-place state" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var storage: Conn.Storage = undefined;
    var conn = Conn.initClientInPlace(&storage);
    defer conn.deinit();

    try std.testing.expectEqual(Role.client, conn.role());
    var wire_storage: [256]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try conn.sendRequest(&wire, h1.message.RequestFields.origin("GET", "/", "example.com"), &.{});
    try std.testing.expectEqual(@as(usize, 1), conn.pendingResponses());
}

test "high-level HTTP1 client pipelines response semantics without borrowed methods" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 4, .outbound_fields = 8 });
    var conn = try Conn.initClient(std.testing.allocator);
    defer conn.deinit();

    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try conn.sendRequest(&wire, h1.message.RequestFields.origin("HEAD", "/a", "example.com"), &.{});
    _ = try conn.sendRequest(&wire, h1.message.RequestFields.origin("GET", "/b", "example.com"), &.{});
    try std.testing.expectEqual(@as(usize, 2), conn.pendingResponses());

    var result = try conn.receive("HTTP/1.1 200 OK\r\nContent-Length: 123\r\n\r\n");
    try std.testing.expect(result.event.?.head.message_done);
    try std.testing.expectEqual(@as(usize, 1), conn.pendingResponses());

    result = try conn.receive("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
    try std.testing.expect(!result.event.?.head.message_done);
    const body = try conn.receive("ok");
    try std.testing.expect(body.event.?.data.message_done);
    try std.testing.expectEqual(@as(usize, 0), conn.pendingResponses());
}

test "high-level HTTP1 bounded client queue reuses slots across many cycles" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 3, .outbound_fields = 8 });
    var storage: Conn.Storage = undefined;
    var conn = Conn.initClientInPlace(&storage);
    defer conn.deinit();

    var wire_storage: [16 * 1024]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    var cycle: usize = 0;
    while (cycle < 12) : (cycle += 1) {
        for (0..3) |index| {
            const method = if ((cycle + index) % 3 == 0) "HEAD" else "GET";
            _ = try conn.sendRequest(&wire, h1.message.RequestFields.origin(method, "/", "example.com"), &.{});
        }
        try std.testing.expectEqual(@as(usize, 3), conn.pendingResponses());
        for (0..3) |_| {
            const result = try conn.receive("HTTP/1.1 204 No Content\r\n\r\n");
            try std.testing.expect(result.event.? == .head);
        }
        try std.testing.expectEqual(@as(usize, 0), conn.pendingResponses());
    }
}

test "high-level HTTP1 server enforces response order and queue backpressure" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 1, .outbound_fields = 8 });
    var conn = try Conn.initServer(std.testing.allocator);
    defer conn.deinit();

    const first = try conn.receive("GET /a HTTP/1.1\r\nHost: example.com\r\n\r\nGET /b HTTP/1.1\r\nHost: example.com\r\n\r\n");
    try std.testing.expect(first.event.? == .head);
    try std.testing.expectEqual(@as(usize, 1), conn.pendingResponses());
    try std.testing.expectError(error.RequestQueueFull, conn.receive("GET /b HTTP/1.1\r\nHost: example.com\r\n\r\n"));

    var wire_storage: [256]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    const sent = try conn.sendResponse(&wire, h1.message.ResponseFields.init(204, "No Content"), &.{});
    try std.testing.expect(sent.message_done);
    try std.testing.expectEqual(@as(usize, 0), conn.pendingResponses());
}

test "high-level HTTP1 drain invokes events synchronously" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 4, .outbound_fields = 8 });
    var conn = try Conn.initServer(std.testing.allocator);
    defer conn.deinit();

    const Counter = struct {
        count: usize = 0,
        pub fn onEvent(self: *@This(), _: h1.Event) DrainAction {
            self.count += 1;
            return .continue_;
        }
    };
    var counter: Counter = .{};
    const input = "GET /a HTTP/1.1\r\nHost: example.com\r\n\r\nGET /b HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const drained = try conn.drain(input, &counter);
    try std.testing.expectEqual(input.len, drained.consumed);
    try std.testing.expectEqual(@as(usize, 2), drained.events);
    try std.testing.expectEqual(@as(usize, 2), counter.count);
}

test "high-level HTTP1 informational response retains pipeline context" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    var request_storage: [256]u8 = undefined;
    var request_wire = std.Io.Writer.fixed(&request_storage);
    _ = try client.sendRequest(&request_wire, h1.message.RequestFields.origin("GET", "/", "example.com"), &.{});
    _ = try server.receive(request_wire.buffered());

    var response_storage: [512]u8 = undefined;
    var response_wire = std.Io.Writer.fixed(&response_storage);
    const early = try server.sendResponse(&response_wire, h1.message.ResponseFields.init(103, "Early Hints"), &.{
        h1.message.header("link", "</style.css>; rel=preload"),
    });
    try std.testing.expect(early.message_done);
    try std.testing.expectEqual(@as(usize, 1), server.pendingResponses());
    const final = try server.sendResponse(&response_wire, h1.message.ResponseFields.init(204, "No Content"), &.{});
    try std.testing.expect(final.message_done);
    try std.testing.expectEqual(@as(usize, 0), server.pendingResponses());

    var pos: usize = 0;
    var received = try client.receive(response_wire.buffered()[pos..]);
    pos += received.consumed;
    try std.testing.expect(received.event.?.head.informational);
    try std.testing.expectEqual(@as(usize, 1), client.pendingResponses());
    received = try client.receive(response_wire.buffered()[pos..]);
    pos += received.consumed;
    try std.testing.expect(!received.event.?.head.informational);
    try std.testing.expectEqual(@as(usize, 0), client.pendingResponses());
    try std.testing.expectEqual(response_wire.buffered().len, pos);
}

test "high-level HTTP1 CONNECT switches both sides without retaining request context" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    var request_storage: [256]u8 = undefined;
    var request_wire = std.Io.Writer.fixed(&request_storage);
    _ = try client.sendRequest(&request_wire, h1.message.RequestFields.connect("example.com:443"), &.{});
    _ = try server.receive(request_wire.buffered());

    var response_storage: [256]u8 = undefined;
    var response_wire = std.Io.Writer.fixed(&response_storage);
    const sent = try server.sendResponse(&response_wire, h1.message.ResponseFields.init(200, "Connection Established"), &.{});
    try std.testing.expect(sent.protocol_switched);
    try std.testing.expect(server.writer().protocolSwitched());
    try std.testing.expectEqual(@as(usize, 0), server.pendingResponses());

    const received = try client.receive(response_wire.buffered());
    try std.testing.expect(received.event.?.head.protocol_switched);
    try std.testing.expect(client.decoder().protocolSwitched());
    try std.testing.expectEqual(@as(usize, 0), client.pendingResponses());
}

test "high-level HTTP1 drain stop preserves remaining pipelined input" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 4, .outbound_fields = 8 });
    var conn = try Conn.initServer(std.testing.allocator);
    defer conn.deinit();

    const Stopper = struct {
        pub fn onEvent(_: *@This(), _: h1.Event) DrainAction {
            return .stop;
        }
    };
    var stopper: Stopper = .{};
    const first_wire = "GET /a HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const input = first_wire ++ "GET /b HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const drained = try conn.drain(input, &stopper);
    try std.testing.expect(drained.stopped);
    try std.testing.expectEqual(first_wire.len, drained.consumed);
    try std.testing.expect(drained.consumed < input.len);
}

test "high-level HTTP1 client treats EOF before an outstanding response as truncation" {
    const Conn = Connection(.{ .head_bytes = 256, .chunk_line_bytes = 64, .max_in_flight = 2, .outbound_fields = 4 });
    var conn = try Conn.initClient(std.testing.allocator);
    defer conn.deinit();

    var request_storage: [256]u8 = undefined;
    var request_wire = std.Io.Writer.fixed(&request_storage);
    _ = try conn.sendRequest(&request_wire, h1.message.RequestFields.origin("GET", "/", "example.com"), &.{});
    try std.testing.expectError(error.UnexpectedEof, conn.finishReceive());
    try std.testing.expectEqual(@as(usize, 1), conn.pendingResponses());
}

test "high-level HTTP1 client gates Expect 100 request content" {
    const Conn = Connection(.{ .head_bytes = 1024, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var length = h1.message.ContentLength.init(4);
    var request_storage: [512]u8 = undefined;
    var request_wire = std.Io.Writer.fixed(&request_storage);
    _ = try client.sendRequest(&request_wire, h1.message.RequestFields.origin("POST", "/upload", "example.com"), &.{
        length.header(),
        h1.message.expectContinue(),
    });
    try std.testing.expectEqual(h1.semantics.ContinueGate.Phase.waiting, client.continuePhase().?);
    const before = request_wire.end;
    try std.testing.expectError(error.ContinuePending, client.writeData(&request_wire, "data"));
    try std.testing.expectEqual(before, request_wire.end);

    _ = try client.receive("HTTP/1.1 103 Early Hints\r\n\r\n");
    try std.testing.expectEqual(h1.semantics.ContinueGate.Phase.waiting, client.continuePhase().?);
    _ = try client.receive("HTTP/1.1 100 Continue\r\n\r\n");
    try std.testing.expectEqual(h1.semantics.ContinueGate.Phase.body_allowed, client.continuePhase().?);
    const data = try client.writeData(&request_wire, "data");
    try std.testing.expect(data.message_done);
    try std.testing.expect(client.continuePhase() == null);

    _ = try client.receive("HTTP/1.1 204 No Content\r\n\r\n");
    try std.testing.expectEqual(@as(usize, 0), client.pendingResponses());
    try std.testing.expectEqual(Lifecycle.active, client.lifecycle());
}

test "high-level HTTP1 client can time out Expect wait explicitly" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var length = h1.message.ContentLength.init(1);
    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.sendRequest(&wire, h1.message.RequestFields.origin("POST", "/", "example.com"), &.{
        length.header(),
        h1.message.expectContinue(),
    });
    try std.testing.expect(client.proceedWithoutContinue());
    try std.testing.expect(!client.proceedWithoutContinue());
    try std.testing.expectEqual(h1.semantics.ContinueGate.Phase.body_allowed, client.continuePhase().?);
    const data = try client.writeData(&wire, "x");
    try std.testing.expect(data.message_done);
}

test "high-level HTTP1 early final suppresses unsent request body and closes" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var length = h1.message.ContentLength.init(4);
    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.sendRequest(&wire, h1.message.RequestFields.origin("POST", "/", "example.com"), &.{
        length.header(),
        h1.message.expectContinue(),
    });
    _ = try client.receive("HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n");
    try std.testing.expectEqual(Lifecycle.closing, client.lifecycle());
    try std.testing.expect(client.writer().mustClose());
    try std.testing.expectEqual(h1.semantics.ContinueGate.Phase.final_received, client.continuePhase().?);
    const before = wire.end;
    try std.testing.expectError(error.RequestBodySuppressed, client.writeData(&wire, "data"));
    try std.testing.expectEqual(before, wire.end);
    try std.testing.expectError(
        error.ConnectionClosing,
        client.sendRequest(&wire, h1.message.RequestFields.origin("GET", "/later", "example.com"), &.{}),
    );
}

test "high-level HTTP1 server requires 100 before 101 when Expect and Upgrade are combined" {
    const Conn = Connection(.{ .head_bytes = 1024, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    const request = try server.receive(
        "POST /chat HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "Content-Length: 4\r\n" ++
            "Expect: 100-continue\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Upgrade: websocket\r\n\r\n",
    );
    try std.testing.expect(request.event.? == .head);

    const upgrade_fields = h1.message.upgrade("websocket");
    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    try std.testing.expectError(
        error.ContinueRequiredBeforeUpgrade,
        server.sendResponse(&wire, h1.message.ResponseFields.init(101, "Switching Protocols"), &upgrade_fields),
    );
    try std.testing.expectEqual(@as(usize, 0), wire.end);

    const continued = try server.sendResponse(&wire, h1.message.ResponseFields.init(100, "Continue"), &.{});
    try std.testing.expect(continued.message_done);
    _ = try server.sendResponse(&wire, h1.message.ResponseFields.init(101, "Switching Protocols"), &upgrade_fields);
    try std.testing.expect(server.protocolSwitched());
}

test "high-level HTTP1 rejects unoffered Upgrade selection on both sides" {
    const Conn = Connection(.{ .head_bytes = 1024, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    const offered = h1.message.upgrade("websocket");
    var request_storage: [512]u8 = undefined;
    var request_wire = std.Io.Writer.fixed(&request_storage);
    _ = try client.sendRequest(&request_wire, h1.message.RequestFields.origin("GET", "/", "example.com"), &offered);
    _ = try server.receive(request_wire.buffered());

    const wrong = h1.message.upgrade("h2c");
    var response_storage: [512]u8 = undefined;
    var response_wire = std.Io.Writer.fixed(&response_storage);
    try std.testing.expectError(
        error.InvalidUpgradeResponse,
        server.sendResponse(&response_wire, h1.message.ResponseFields.init(101, "Switching Protocols"), &wrong),
    );
    try std.testing.expectEqual(@as(usize, 0), response_wire.end);

    const selected = h1.message.upgrade("WebSocket");
    _ = try server.sendResponse(&response_wire, h1.message.ResponseFields.init(101, "Switching Protocols"), &selected);
    const received = try client.receive(response_wire.buffered());
    try std.testing.expect(received.event.?.head.protocol_switched);
}

test "high-level HTTP1 client rejects unsolicited 101" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 1, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();
    var wire_storage: [256]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.sendRequest(&wire, h1.message.RequestFields.origin("GET", "/", "example.com"), &.{});
    try std.testing.expectError(
        error.UnexpectedUpgrade,
        client.receive("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"),
    );
}

test "high-level HTTP1 honors peer close and prevents pipeline reuse" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 4, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var request_a_storage: [256]u8 = undefined;
    var request_a = std.Io.Writer.fixed(&request_a_storage);
    _ = try client.sendRequest(&request_a, h1.message.RequestFields.origin("GET", "/one", "example.com"), &.{});
    var request_b_storage: [256]u8 = undefined;
    var request_b = std.Io.Writer.fixed(&request_b_storage);
    _ = try client.sendRequest(&request_b, h1.message.RequestFields.origin("GET", "/two", "example.com"), &.{});
    try std.testing.expectEqual(@as(usize, 2), client.pendingResponses());

    const response = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n";
    const received = try client.receive(response);
    try std.testing.expect(received.event != null);
    try std.testing.expectEqual(@as(usize, 1), client.pendingResponses());
    try std.testing.expectEqual(Lifecycle.closing, client.lifecycle());
    try std.testing.expect(client.peerCloseRequired());

    var blocked_storage: [256]u8 = undefined;
    var blocked = std.Io.Writer.fixed(&blocked_storage);
    try std.testing.expectError(
        error.ConnectionClosing,
        client.sendRequest(&blocked, h1.message.RequestFields.origin("GET", "/three", "example.com"), &.{}),
    );
    try std.testing.expectEqual(@as(usize, 0), blocked.end);
    try std.testing.expectError(error.ConnectionClosing, client.receive("HTTP/1.1 204 No Content\r\n\r\n"));
}

test "high-level HTTP1 close response suppresses a later pipelined request body" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 3, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var length = h1.message.ContentLength.init(4);
    var wire_storage: [1024]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.sendRequest(&wire, h1.message.RequestFields.origin("GET", "/first", "example.com"), &.{});
    _ = try client.sendRequest(&wire, h1.message.RequestFields.origin("POST", "/second", "example.com"), &.{length.header()});
    try std.testing.expectEqual(@as(usize, 2), client.pendingResponses());

    _ = try client.receive("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    try std.testing.expectEqual(Lifecycle.closing, client.lifecycle());
    try std.testing.expect(client.writer().mustClose());
    try std.testing.expectEqual(@as(usize, 1), client.pendingResponses());
    const before = wire.end;
    try std.testing.expectError(error.ConnectionClosing, client.writeData(&wire, "data"));
    try std.testing.expectEqual(before, wire.end);
}

test "high-level HTTP1 server forces close response and stops parsing next request" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 4, .outbound_fields = 8 });
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    const first = "GET /one HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n";
    const received = try server.receive(first);
    try std.testing.expect(received.event != null);
    try std.testing.expectEqual(Lifecycle.closing, server.lifecycle());
    try std.testing.expectError(
        error.ConnectionClosing,
        server.receive("GET /two HTTP/1.1\r\nHost: example.com\r\n\r\n"),
    );

    const length = h1.message.ContentLength.init(0);
    var response_storage: [256]u8 = undefined;
    var response = std.Io.Writer.fixed(&response_storage);
    _ = try server.sendResponse(&response, h1.message.ResponseFields.init(200, "OK"), &.{length.header()});
    try std.testing.expect(std.mem.indexOf(u8, response.buffered(), "connection: close\r\n") != null);
    try std.testing.expect(server.mustClose());
}

test "high-level HTTP1 bounded pipeline follows deterministic queue model" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 3, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var model_count: usize = 0;
    var seed: u32 = 0x51f0_1234;
    const response = "HTTP/1.1 204 No Content\r\n\r\n";
    var step: usize = 0;
    while (step < 256) : (step += 1) {
        seed = seed *% 1_664_525 +% 1_013_904_223;
        const should_send = model_count == 0 or (model_count < 3 and (seed & 1) == 0);
        if (should_send) {
            var wire_storage: [256]u8 = undefined;
            var wire = std.Io.Writer.fixed(&wire_storage);
            const method: []const u8 = if ((seed & 2) == 0) "GET" else "HEAD";
            _ = try client.sendRequest(&wire, h1.message.RequestFields.origin(method, "/model", "example.com"), &.{});
            model_count += 1;
        } else {
            const result = try client.receive(response);
            try std.testing.expect(result.event != null);
            model_count -= 1;
        }
        try std.testing.expectEqual(model_count, client.pendingResponses());
        try std.testing.expectEqual(Lifecycle.active, client.lifecycle());
    }
    while (model_count != 0) {
        _ = try client.receive(response);
        model_count -= 1;
        try std.testing.expectEqual(model_count, client.pendingResponses());
    }
}

test "high-level HTTP1 closing request still drains its current body" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    const head_bytes = "POST /upload HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\nContent-Length: 3\r\n\r\n";
    const head_result = try server.receive(head_bytes);
    try std.testing.expect(head_result.event.? == .head);
    try std.testing.expectEqual(Lifecycle.closing, server.lifecycle());

    const body_result = try server.receive("abc");
    try std.testing.expect(body_result.event.? == .data);
    try std.testing.expect(body_result.event.?.data.message_done);
    try std.testing.expectError(error.ConnectionClosing, server.receive("GET /later HTTP/1.1\r\nHost: example.com\r\n\r\n"));
}

test "high-level HTTP1 unoffered 101 latches terminal receive failure" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var length = h1.message.ContentLength.init(4);
    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.sendRequest(&wire, h1.message.RequestFields.origin("POST", "/", "example.com"), &.{length.header()});

    const response = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n";
    try std.testing.expectError(error.UnexpectedUpgrade, client.receive(response));
    try std.testing.expectEqual(Lifecycle.failed, client.lifecycle());
    try std.testing.expect(!client.protocolSwitched());
    try std.testing.expect(client.mustClose());
    const body_before = wire.end;
    try std.testing.expectError(error.ConnectionFailed, client.writeData(&wire, "data"));
    try std.testing.expectEqual(body_before, wire.end);
    try std.testing.expectError(error.ReceiveFailed, client.receive(""));
    try std.testing.expectError(
        error.ConnectionFailed,
        client.sendRequest(&wire, h1.message.RequestFields.origin("GET", "/later", "example.com"), &.{}),
    );
}

test "high-level HTTP1 mismatched 101 selection latches terminal receive failure" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    const offered = h1.message.upgrade("websocket");
    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.sendRequest(&wire, h1.message.RequestFields.origin("GET", "/", "example.com"), &offered);

    const response = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n";
    try std.testing.expectError(error.InvalidUpgradeResponse, client.receive(response));
    try std.testing.expectEqual(Lifecycle.failed, client.lifecycle());
    try std.testing.expect(!client.protocolSwitched());
    try std.testing.expectError(error.ReceiveFailed, client.finishReceive());
}

test "high-level HTTP1 partial request write does not publish pipeline state" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var tiny_storage: [8]u8 = undefined;
    var tiny = std.Io.Writer.fixed(&tiny_storage);
    try std.testing.expectError(
        error.WriteFailed,
        client.sendRequest(&tiny, h1.message.RequestFields.origin("GET", "/long-target", "example.com"), &.{}),
    );
    try std.testing.expectEqual(@as(usize, 0), client.pendingResponses());
    try std.testing.expectEqual(Lifecycle.failed, client.lifecycle());

    var retry_storage: [256]u8 = undefined;
    var retry = std.Io.Writer.fixed(&retry_storage);
    try std.testing.expectError(
        error.ConnectionFailed,
        client.sendRequest(&retry, h1.message.RequestFields.origin("GET", "/", "example.com"), &.{}),
    );
    try std.testing.expectEqual(@as(usize, 0), retry.end);
}

test "high-level HTTP1 latches truncated transport EOF" {
    const Conn = Connection(.{ .head_bytes = 512, .chunk_line_bytes = 128, .max_in_flight = 2, .outbound_fields = 8 });
    var client = try Conn.initClient(std.testing.allocator);
    defer client.deinit();

    var wire_storage: [512]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try client.sendRequest(&wire, h1.message.RequestFields.origin("GET", "/", "example.com"), &.{});

    try std.testing.expectError(error.UnexpectedEof, client.finishReceive());
    try std.testing.expectEqual(Lifecycle.failed, client.lifecycle());
    try std.testing.expectError(error.ReceiveFailed, client.finishReceive());
    try std.testing.expectError(
        error.ConnectionFailed,
        client.sendRequest(&wire, h1.message.RequestFields.origin("GET", "/again", "example.com"), &.{}),
    );
}

test "high-level HTTP1 clean server EOF closes only final queued response" {
    const Conn = Connection(.{ .head_bytes = 1024, .chunk_line_bytes = 128, .max_in_flight = 4, .outbound_fields = 8 });
    var server = try Conn.initServer(std.testing.allocator);
    defer server.deinit();

    const requests =
        "GET /one HTTP/1.1\r\nHost: example.com\r\n\r\n" ++
        "GET /two HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const Sink = struct {
        pub fn onEvent(_: *@This(), _: h1.Event) DrainAction {
            return .continue_;
        }
    };
    var sink: Sink = .{};
    const drained = try server.drain(requests, &sink);
    try std.testing.expectEqual(requests.len, drained.consumed);
    try std.testing.expectEqual(@as(usize, 2), server.pendingResponses());

    try std.testing.expect((try server.finishReceive()) == null);
    try std.testing.expect(server.peerCloseRequired());
    try std.testing.expectEqual(Lifecycle.closing, server.lifecycle());

    var wire_storage: [1024]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);
    _ = try server.sendResponse(&wire, .{ .status = 204, .reason = "No Content" }, &.{});
    try std.testing.expectEqual(@as(usize, 1), server.pendingResponses());
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, wire.buffered(), "connection: close"));

    _ = try server.sendResponse(&wire, .{ .status = 204, .reason = "No Content" }, &.{});
    try std.testing.expectEqual(@as(usize, 0), server.pendingResponses());
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, wire.buffered(), "connection: close"));
    try std.testing.expect(server.mustClose());
}
