const std = @import("std");
const common = @import("../common.zig");
const head = @import("head.zig");
const body = @import("body.zig");
const semantics = @import("semantics.zig");

pub const Error = head.Error || semantics.RequestError || semantics.ConnectionError ||
    error{ InvalidChunk, LineTooLong, ResponseContextRequired, InvalidResponseContext, UnexpectedEof };

pub const Options = struct {
    /// Apply RFC 9112 request-target and Host validation after syntax/framing.
    /// Disable only when the caller intentionally wants to inspect malformed or
    /// non-origin traffic and will apply equivalent semantics itself.
    validate_requests: bool = true,
};

pub const HeadEvent = struct {
    head: head.Head,
    framing: head.BodyFraming,
    persistence: semantics.Persistence,
    target_form: ?semantics.RequestTargetForm = null,
    informational: bool = false,
    message_done: bool = false,
    protocol_switched: bool = false,
};

pub const DataEvent = struct {
    bytes: []const u8,
    message_done: bool,
};

pub const Event = union(enum) {
    head: HeadEvent,
    data: DataEvent,
    trailer: common.Header,
    message_end,
};

pub const FeedResult = struct {
    consumed: usize,
    event: ?Event = null,
};

pub const Mode = enum { request, response };

/// Pure HTTP/1 receive-side connection/message coordinator.
///
/// The decoder owns no transport and performs no allocation. `head_storage`
/// and `chunk_line_storage` are caller-owned bounded scratch buffers. Event
/// slices remain valid until the next call that reuses the corresponding
/// storage. One `feed` call emits at most one event so event loops retain exact
/// control over backpressure and input ownership.
///
/// In response mode the caller supplies the method of the outstanding request
/// with `beginResponse`. Informational responses keep that context; a final
/// response releases it. This deliberately leaves pipelining queues and request
/// scheduling outside the protocol engine.
pub const Decoder = struct {
    head_parser: head.FramedHeadParser,
    chunk_decoder: body.ChunkDecoder,
    fixed: body.FixedBody = .{ .remaining = 0 },
    response_method: ?[]const u8 = null,
    current_persistence: semantics.Persistence = .persistent,
    mode: Mode,
    state: State = .head,
    options: Options,

    const State = enum {
        head,
        fixed,
        chunked,
        close_body,
        tunnel,
        failed,
    };

    pub fn initRequest(head_storage: []u8, chunk_line_storage: []u8, options: Options) Decoder {
        return .{
            .head_parser = head.FramedHeadParser.init(.request, head_storage),
            .chunk_decoder = body.ChunkDecoder.init(chunk_line_storage),
            .mode = .request,
            .options = options,
        };
    }

    pub fn initResponse(head_storage: []u8, chunk_line_storage: []u8, options: Options) Decoder {
        return .{
            .head_parser = head.FramedHeadParser.init(.response, head_storage),
            .chunk_decoder = body.ChunkDecoder.init(chunk_line_storage),
            .mode = .response,
            .options = options,
        };
    }

    /// Bind response parsing to the next outstanding request method. The slice
    /// is borrowed until the final response completes or switches protocols.
    pub fn beginResponse(self: *Decoder, request_method: []const u8) Error!void {
        if (self.mode != .response or self.state != .head or self.response_method != null or !common.isToken(request_method))
            return error.InvalidResponseContext;
        self.response_method = request_method;
    }

    pub fn responsePending(self: Decoder) bool {
        return self.mode == .response and self.response_method != null;
    }

    pub fn protocolSwitched(self: Decoder) bool {
        return self.state == .tunnel;
    }

    pub fn failed(self: Decoder) bool {
        return self.state == .failed;
    }

    pub fn feed(self: *Decoder, input: []const u8) Error!FeedResult {
        if (self.state == .failed) return error.InvalidResponseContext;
        return self.feedInner(input) catch |err| {
            switch (err) {
                error.ResponseContextRequired, error.InvalidResponseContext => {},
                else => self.state = .failed,
            }
            return err;
        };
    }

    fn feedInner(self: *Decoder, input: []const u8) Error!FeedResult {
        return switch (self.state) {
            .head => self.feedHead(input),
            .fixed => self.feedFixed(input),
            .chunked => self.feedChunked(input),
            .close_body => self.feedClose(input),
            .tunnel => .{ .consumed = 0 },
            .failed => error.InvalidResponseContext,
        };
    }

    fn feedHead(self: *Decoder, input: []const u8) Error!FeedResult {
        const framed_result = switch (self.mode) {
            .request => try self.head_parser.feedRequest(input),
            .response => blk: {
                const method = self.response_method orelse return error.ResponseContextRequired;
                break :blk try self.head_parser.feedResponse(input, method);
            },
        };
        const framed = framed_result.framed orelse return .{ .consumed = framed_result.consumed };

        var target_form: ?semantics.RequestTargetForm = null;
        if (self.mode == .request and self.options.validate_requests) {
            target_form = (try semantics.validateRequest(framed.head)).target_form;
        }

        var persistence = try semantics.persistence(framed.head);
        const status: ?u16 = switch (framed.head.start) {
            .response => |response| response.status,
            else => null,
        };
        const informational = status != null and status.? >= 100 and status.? < 200 and status.? != 101;
        const switched = if (status) |code|
            code == 101 or (self.response_method != null and
                std.ascii.eqlIgnoreCase(self.response_method.?, "CONNECT") and code >= 200 and code < 300)
        else
            false;

        if (framed.framing == .close) persistence = .close;
        self.current_persistence = persistence;

        var event: HeadEvent = .{
            .head = framed.head,
            .framing = framed.framing,
            .persistence = persistence,
            .target_form = target_form,
            .informational = informational,
            .protocol_switched = switched,
        };

        if (switched) {
            event.message_done = true;
            self.state = .tunnel;
            self.response_method = null;
            return .{ .consumed = framed_result.consumed, .event = .{ .head = event } };
        }

        if (informational) {
            event.message_done = true;
            self.resetHead(false);
            return .{ .consumed = framed_result.consumed, .event = .{ .head = event } };
        }

        switch (framed.framing) {
            .none => {
                event.message_done = true;
                self.completeMessage();
            },
            .content_length => |length| {
                if (length == 0) {
                    event.message_done = true;
                    self.completeMessage();
                } else {
                    self.fixed = body.FixedBody.init(length);
                    self.state = .fixed;
                }
            },
            .chunked => {
                self.chunk_decoder.reset();
                self.state = .chunked;
            },
            .close => self.state = .close_body,
        }
        return .{ .consumed = framed_result.consumed, .event = .{ .head = event } };
    }

    fn feedFixed(self: *Decoder, input: []const u8) Error!FeedResult {
        if (input.len == 0) return .{ .consumed = 0 };
        const bytes = self.fixed.take(input);
        const done = self.fixed.done();
        if (done) self.completeMessage();
        return .{
            .consumed = bytes.len,
            .event = .{ .data = .{ .bytes = bytes, .message_done = done } },
        };
    }

    fn feedChunked(self: *Decoder, input: []const u8) Error!FeedResult {
        const result = try self.chunk_decoder.feed(input);
        if (result.event) |chunk_event| switch (chunk_event) {
            .data => |bytes| return .{
                .consumed = result.consumed,
                .event = .{ .data = .{ .bytes = bytes, .message_done = false } },
            },
            .trailer => |trailer| return .{ .consumed = result.consumed, .event = .{ .trailer = trailer } },
            .trailers_done => {
                self.completeMessage();
                return .{ .consumed = result.consumed, .event = .message_end };
            },
            .done => unreachable,
        };
        return .{ .consumed = result.consumed };
    }

    fn feedClose(_: *Decoder, input: []const u8) Error!FeedResult {
        if (input.len == 0) return .{ .consumed = 0 };
        return .{
            .consumed = input.len,
            .event = .{ .data = .{ .bytes = input, .message_done = false } },
        };
    }

    /// Signal transport EOF. A close-delimited response completes here; EOF in
    /// fixed/chunked framing is a protocol truncation. EOF between messages is
    /// clean. Tunnel bytes are outside HTTP and therefore unaffected.
    pub fn finish(self: *Decoder) Error!?Event {
        return switch (self.state) {
            .head => if (self.head_parser.used == 0 and
                !(self.mode == .response and self.response_method != null)) null else error.UnexpectedEof,
            .fixed, .chunked => error.UnexpectedEof,
            .close_body => blk: {
                self.resetHead(true);
                break :blk .message_end;
            },
            .tunnel => null,
            .failed => error.UnexpectedEof,
        };
    }

    fn completeMessage(self: *Decoder) void {
        self.resetHead(self.mode == .response);
    }

    fn resetHead(self: *Decoder, clear_response: bool) void {
        const parser_mode: head.Mode = switch (self.mode) {
            .request => .request,
            .response => .response,
        };
        self.head_parser.reset(parser_mode);
        self.chunk_decoder.reset();
        self.fixed = body.FixedBody.init(0);
        self.state = .head;
        if (clear_response) self.response_method = null;
    }
};

test "request decoder composes head fixed body and pipelined messages" {
    var head_storage: [512]u8 = undefined;
    var chunk_storage: [128]u8 = undefined;
    var decoder = Decoder.initRequest(&head_storage, &chunk_storage, .{});

    const wire = "POST /a HTTP/1.1\r\nHost: example.com\r\nContent-Length: 3\r\n\r\nabcGET /b HTTP/1.1\r\nHost: example.com\r\n\r\n";
    var pos: usize = 0;

    var result = try decoder.feed(wire[pos..]);
    pos += result.consumed;
    try std.testing.expect(result.event.? == .head);
    try std.testing.expectEqual(semantics.RequestTargetForm.origin, result.event.?.head.target_form.?);
    try std.testing.expect(!result.event.?.head.message_done);

    result = try decoder.feed(wire[pos..]);
    pos += result.consumed;
    try std.testing.expectEqualStrings("abc", result.event.?.data.bytes);
    try std.testing.expect(result.event.?.data.message_done);

    result = try decoder.feed(wire[pos..]);
    pos += result.consumed;
    try std.testing.expect(result.event.?.head.message_done);
    try std.testing.expectEqualStrings("/b", result.event.?.head.head.start.request.target);
    try std.testing.expectEqual(wire.len, pos);
}

test "response decoder treats EOF with an outstanding request as truncation" {
    var head_storage: [128]u8 = undefined;
    var chunk_storage: [64]u8 = undefined;
    var decoder = Decoder.initResponse(&head_storage, &chunk_storage, .{});
    try decoder.beginResponse("GET");
    try std.testing.expectError(error.UnexpectedEof, decoder.finish());
}

test "response decoder preserves informational request context" {
    var head_storage: [512]u8 = undefined;
    var chunk_storage: [128]u8 = undefined;
    var decoder = Decoder.initResponse(&head_storage, &chunk_storage, .{});
    try decoder.beginResponse("GET");

    const wire = "HTTP/1.1 103 Early Hints\r\nLink: </a>; rel=preload\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    var pos: usize = 0;
    var result = try decoder.feed(wire[pos..]);
    pos += result.consumed;
    try std.testing.expect(result.event.?.head.informational);
    try std.testing.expect(decoder.responsePending());

    result = try decoder.feed(wire[pos..]);
    pos += result.consumed;
    try std.testing.expect(!result.event.?.head.informational);
    try std.testing.expect(!result.event.?.head.message_done);

    result = try decoder.feed(wire[pos..]);
    pos += result.consumed;
    try std.testing.expectEqualStrings("ok", result.event.?.data.bytes);
    try std.testing.expect(result.event.?.data.message_done);
    try std.testing.expect(!decoder.responsePending());
    try std.testing.expectEqual(wire.len, pos);
}

test "response decoder stops at CONNECT tunnel bytes" {
    var head_storage: [256]u8 = undefined;
    var chunk_storage: [64]u8 = undefined;
    var decoder = Decoder.initResponse(&head_storage, &chunk_storage, .{});
    try decoder.beginResponse("CONNECT");
    const wire = "HTTP/1.1 200 Connection Established\r\n\r\nTLS";
    const result = try decoder.feed(wire);
    try std.testing.expect(result.event.?.head.protocol_switched);
    try std.testing.expect(result.event.?.head.message_done);
    try std.testing.expectEqualStrings("TLS", wire[result.consumed..]);
    try std.testing.expect(decoder.protocolSwitched());
    try std.testing.expectEqual(@as(usize, 0), (try decoder.feed(wire[result.consumed..])).consumed);
}

test "close delimited response ends only at EOF" {
    var head_storage: [256]u8 = undefined;
    var chunk_storage: [64]u8 = undefined;
    var decoder = Decoder.initResponse(&head_storage, &chunk_storage, .{});
    try decoder.beginResponse("GET");

    var result = try decoder.feed("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nbody");
    try std.testing.expect(result.event.? == .head);
    const remaining = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nbody"[result.consumed..];
    result = try decoder.feed(remaining);
    try std.testing.expectEqualStrings("body", result.event.?.data.bytes);
    try std.testing.expect(!result.event.?.data.message_done);
    try std.testing.expect((try decoder.finish()).? == .message_end);
    try std.testing.expect(!decoder.responsePending());
}

test "chunked response emits trailers and completion" {
    var head_storage: [256]u8 = undefined;
    var chunk_storage: [64]u8 = undefined;
    var decoder = Decoder.initResponse(&head_storage, &chunk_storage, .{});
    try decoder.beginResponse("GET");
    const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\nDigest: x\r\n\r\n";
    var pos: usize = 0;
    var saw_data = false;
    var saw_trailer = false;
    var saw_end = false;
    while (pos < wire.len and !saw_end) {
        const result = try decoder.feed(wire[pos..]);
        pos += result.consumed;
        if (result.event) |event| switch (event) {
            .head => {},
            .data => |data| {
                try std.testing.expectEqualStrings("ok", data.bytes);
                saw_data = true;
            },
            .trailer => |trailer| {
                try std.testing.expectEqualStrings("Digest", trailer.name);
                saw_trailer = true;
            },
            .message_end => saw_end = true,
        };
        if (result.consumed == 0 and result.event == null) return error.TestUnexpectedResult;
    }
    try std.testing.expect(saw_data and saw_trailer and saw_end);
    try std.testing.expect(!decoder.responsePending());
}

test "strict request validation can be explicitly disabled" {
    var head_storage: [256]u8 = undefined;
    var chunk_storage: [64]u8 = undefined;
    var strict = Decoder.initRequest(&head_storage, &chunk_storage, .{});
    try std.testing.expectError(error.MissingHost, strict.feed("GET / HTTP/1.1\r\n\r\n"));

    var permissive_head: [256]u8 = undefined;
    var permissive_chunk: [64]u8 = undefined;
    var permissive = Decoder.initRequest(&permissive_head, &permissive_chunk, .{ .validate_requests = false });
    const result = try permissive.feed("GET / HTTP/1.1\r\n\r\n");
    try std.testing.expect(result.event.?.head.message_done);
}

test "truncated framed bodies fail at EOF" {
    var head_storage: [256]u8 = undefined;
    var chunk_storage: [64]u8 = undefined;
    var decoder = Decoder.initRequest(&head_storage, &chunk_storage, .{});
    _ = try decoder.feed("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\na");
    _ = try decoder.feed("a");
    try std.testing.expectError(error.UnexpectedEof, decoder.finish());
}
