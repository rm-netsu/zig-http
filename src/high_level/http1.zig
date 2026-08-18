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
        };

        pub const state_bytes = @sizeOf(Storage);

        pub const ReceiveError = h1.connection.Error || error{
            NoOutstandingRequest,
            RequestQueueFull,
            UnexpectedUpgrade,
        };
        pub const SendRequestError = h1.message.BuildError || h1.MessageWriter.MessageError || error{
            NotClient,
            RequestQueueFull,
            UpgradeOfferTooLarge,
            InvalidUpgradeRequest,
        };
        pub const SendResponseError = h1.MessageWriter.MessageError || error{
            NotServer,
            NoPendingRequest,
            ContinueRequiredBeforeUpgrade,
            UpgradeNotOffered,
            UpgradeOfferTooLarge,
        };
        pub const DataError = h1.MessageWriter.MessageError;

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
            return self.state.decoder.protocolSwitched() or self.state.writer.protocolSwitched();
        }

        pub inline fn mustClose(self: *const Self) bool {
            return self.state.writer.mustClose();
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
            if (self.state.pending.full()) return error.RequestQueueFull;
            const fields = try request.build(&self.state.outbound, regular_fields);
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
                if (!pending.upgrade_offered) return error.UpgradeNotOffered;
                if (pending.upgrade_offer_truncated) return error.UpgradeOfferTooLarge;
                if (pending.expect_continue and !pending.continue_sent) return error.ContinueRequiredBeforeUpgrade;
                try h1.semantics.validateUpgradeSelectionFields(pending.offer(), response.version, response.status, fields);
            }
            const result = try self.state.writer.beginResponse(
                out,
                response.version,
                response.status,
                response.reason,
                pending.kind.canonicalMethod(),
                fields,
            );

            if (response.status == 100) pending.continue_sent = true;
            const informational = response.status >= 100 and response.status < 200 and response.status != 101;
            if (!informational) {
                self.state.sending_final_response = !result.message_done;
                if (result.message_done) _ = self.state.pending.pop().?;
            }
            return result;
        }

        pub fn writeData(self: *Self, out: *std.Io.Writer, bytes: []const u8) DataError!h1.MessageWriter.DataResult {
            const result = try self.state.writer.writeData(out, bytes);
            if (self.role() == .server and self.state.sending_final_response and result.message_done) {
                _ = self.state.pending.pop() orelse unreachable;
                self.state.sending_final_response = false;
            }
            return result;
        }

        pub fn finish(self: *Self, out: *std.Io.Writer, trailers: []const common.Header) DataError!void {
            try self.state.writer.finish(out, trailers);
            self.finishServerResponseIfNeeded();
        }

        pub fn finishWithTrailerPolicy(self: *Self, out: *std.Io.Writer, trailers: []const common.Header, policy: anytype) DataError!void {
            try self.state.writer.finishWithTrailerPolicy(out, trailers, policy);
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
            switch (self.role()) {
                .client => {
                    if (!self.state.decoder.responsePending()) {
                        const pending = self.state.pending.peek() orelse return error.NoOutstandingRequest;
                        try self.state.decoder.beginResponse(pending.kind.canonicalMethod());
                    }
                },
                .server => {
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
                        if (response.status == 101) {
                            const pending = self.state.pending.peekPtr() orelse return error.NoOutstandingRequest;
                            if (!pending.upgrade_offered) return error.UnexpectedUpgrade;
                            try h1.semantics.validateRetainedUpgradeSelection(pending.offer(), head_event.head);
                        }
                    }
                    if (!self.state.decoder.responsePending()) _ = self.state.pending.pop() orelse unreachable;
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
                        };
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
            if (self.role() == .client and !self.state.decoder.responsePending()) {
                if (self.state.pending.peek()) |pending|
                    try self.state.decoder.beginResponse(pending.kind.canonicalMethod());
            }
            const event = try self.state.decoder.finish();
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
