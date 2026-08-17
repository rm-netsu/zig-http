const std = @import("std");
const common = @import("../common.zig");
const head = @import("head.zig");
const semantics = @import("semantics.zig");

pub const Error = std.Io.Writer.Error || error{InvalidHeader};

pub fn requestHead(w: *std.Io.Writer, version: head.Version, method: []const u8, target: []const u8, headers: []const common.Header) Error!void {
    if (!common.isToken(method) or !validTarget(target)) return error.InvalidHeader;
    try validateHeaders(headers);
    try requestHeadUnchecked(w, version, method, target, headers);
}

pub fn responseHead(w: *std.Io.Writer, version: head.Version, status: u16, reason: []const u8, headers: []const common.Header) Error!void {
    if (status < 100 or status > 999 or !validReason(reason)) return error.InvalidHeader;
    try validateHeaders(headers);
    try responseHeadUnchecked(w, version, status, reason, headers);
}

pub fn writeHeaders(w: *std.Io.Writer, headers: []const common.Header) Error!void {
    try validateHeaders(headers);
    try writeHeadersUnchecked(w, headers);
}

pub fn chunk(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    if (bytes.len == 0) return;
    try w.print("{x}\r\n", .{bytes.len});
    try w.writeAll(bytes);
    try w.writeAll("\r\n");
}

pub fn endChunks(w: *std.Io.Writer, trailers: []const common.Header) Error!void {
    try validateHeaders(trailers);
    try w.writeAll("0\r\n");
    try writeHeadersUnchecked(w, trailers);
}

/// Stateful, allocation-free HTTP/1 send-side message coordinator.
///
/// `MessageWriter` owns protocol state only; callers continue to own the
/// transport and pass a `std.Io.Writer` to each operation. All semantic and
/// framing checks happen before the first byte of a new head is written. If an
/// I/O error can leave a frame partially serialized, the coordinator becomes
/// poisoned and refuses further HTTP writes.
///
/// A message with no body or `Content-Length: 0` completes in `begin*`. Fixed
/// length messages complete when the declared number of bytes has been sent.
/// Chunked and close-delimited messages are completed explicitly with `finish`.
/// Close-delimited framing and `Connection: close` move the coordinator to
/// `must_close`, making accidental connection reuse impossible.
pub const MessageWriter = struct {
    remaining: u64 = 0,
    state: State = .idle,
    close_after_message: bool = false,

    const State = enum(u8) {
        idle,
        fixed,
        chunked,
        close_delimited,
        must_close,
        tunnel,
        poisoned,
    };

    pub const MessageError = Error || head.Error || semantics.RequestError || semantics.ConnectionError || error{
        InvalidState,
        ContentLengthMismatch,
        TrailersNotAllowed,
        TrailerPolicyRequired,
        TrailerRejected,
        InvalidTrailer,
        InvalidResponseFraming,
    };

    pub const BeginResult = struct {
        framing: head.BodyFraming,
        persistence: semantics.Persistence,
        message_done: bool,
        protocol_switched: bool = false,
    };

    pub const DataResult = struct {
        consumed: usize,
        message_done: bool = false,
    };

    pub fn init() MessageWriter {
        return .{};
    }

    pub fn failed(self: MessageWriter) bool {
        return self.state == .poisoned;
    }

    pub fn mustClose(self: MessageWriter) bool {
        return self.state == .must_close;
    }

    pub fn protocolSwitched(self: MessageWriter) bool {
        return self.state == .tunnel;
    }

    pub fn ready(self: MessageWriter) bool {
        return self.state == .idle;
    }

    /// Start and serialize a request after validating syntax, RFC 9112 framing,
    /// request-target/Host semantics, and persistence without touching `w`.
    pub fn beginRequest(self: *MessageWriter, w: *std.Io.Writer, version: head.Version, method: []const u8, target: []const u8, headers: []const common.Header) MessageError!BeginResult {
        if (self.state != .idle) return error.InvalidState;
        if (!common.isToken(method) or !validTarget(target)) return error.InvalidHeader;
        const framing = try head.requestBodyFramingFields(version, headers);
        _ = try semantics.validateRequestFields(version, method, target, headers);
        const persistence = try semantics.persistenceFields(version, headers);

        requestHeadUnchecked(w, version, method, target, headers) catch |err| {
            self.state = .poisoned;
            return err;
        };
        return self.beginBody(framing, persistence, false);
    }

    /// Start and serialize a response. `request_method` supplies the request
    /// context needed for HEAD and successful CONNECT response semantics.
    pub fn beginResponse(self: *MessageWriter, w: *std.Io.Writer, version: head.Version, status: u16, reason: []const u8, request_method: []const u8, headers: []const common.Header) MessageError!BeginResult {
        if (self.state != .idle) return error.InvalidState;
        if (status < 100 or status > 999 or !validReason(reason) or !common.isToken(request_method)) return error.InvalidHeader;
        try validateResponseFramingFields(status, request_method, headers);
        const framing = try head.responseBodyFramingFields(version, status, request_method, headers);
        const persistence = try semantics.persistenceFields(version, headers);
        const switched = status == 101 or
            (std.ascii.eqlIgnoreCase(request_method, "CONNECT") and status >= 200 and status < 300);

        responseHeadUnchecked(w, version, status, reason, headers) catch |err| {
            self.state = .poisoned;
            return err;
        };
        return self.beginBody(framing, persistence, switched);
    }

    /// Serialize body bytes according to the framing selected by `begin*`.
    /// Fixed-length overrun is rejected before touching the writer.
    pub fn writeData(self: *MessageWriter, w: *std.Io.Writer, bytes: []const u8) MessageError!DataResult {
        return switch (self.state) {
            .fixed => self.writeFixed(w, bytes),
            .chunked => self.writeChunked(w, bytes),
            .close_delimited => self.writeCloseDelimited(w, bytes),
            else => error.InvalidState,
        };
    }

    /// Complete a message without application-defined trailer fields.
    ///
    /// Non-empty trailers require `finishWithTrailerPolicy`: RFC 9110 permits
    /// a sender to generate a trailer field only when the corresponding field
    /// definition explicitly permits trailer placement. Core cannot know every
    /// registered or application-defined field, so the safe default is to
    /// require that semantic decision from the caller.
    ///
    /// Fixed-length messages finish automatically when their exact declared
    /// length is written; if a fixed body is still incomplete, this reports
    /// `ContentLengthMismatch` without poisoning the coordinator so the caller
    /// may supply the rest.
    pub fn finish(self: *MessageWriter, w: *std.Io.Writer, trailers: []const common.Header) MessageError!void {
        if (trailers.len != 0) {
            return switch (self.state) {
                .chunked => error.TrailerPolicyRequired,
                .fixed, .close_delimited => error.TrailersNotAllowed,
                else => error.InvalidState,
            };
        }
        try self.finishChecked(w, trailers);
    }

    /// Complete a chunked message after an application/domain policy confirms
    /// that every trailer field definition permits trailer placement.
    ///
    /// `policy` is caller-owned and must provide:
    ///
    ///     pub fn allows(self: @This(), name: []const u8) bool
    ///
    /// All trailer syntax, universally forbidden framing fields, and policy
    /// decisions are checked before the terminal chunk is emitted. A rejected
    /// trailer therefore leaves the writer reusable for another finish attempt.
    pub fn finishWithTrailerPolicy(self: *MessageWriter, w: *std.Io.Writer, trailers: []const common.Header, policy: anytype) MessageError!void {
        if (self.state != .chunked) {
            if (trailers.len != 0 and (self.state == .fixed or self.state == .close_delimited)) return error.TrailersNotAllowed;
            return error.InvalidState;
        }
        try validateTrailers(trailers);
        for (trailers) |field| {
            if (!policy.allows(field.name)) return error.TrailerRejected;
        }
        try self.finishChecked(w, trailers);
    }

    fn finishChecked(self: *MessageWriter, w: *std.Io.Writer, trailers: []const common.Header) MessageError!void {
        switch (self.state) {
            .fixed => {
                if (self.remaining != 0) return error.ContentLengthMismatch;
                self.completeMessage();
            },
            .chunked => {
                // `finish()` only reaches this with no trailers; the policy
                // variant has already completed semantic preflight.
                endChunksUnchecked(w, trailers) catch |err| {
                    self.state = .poisoned;
                    return err;
                };
                self.completeMessage();
            },
            .close_delimited => self.state = .must_close,
            else => return error.InvalidState,
        }
    }

    fn beginBody(self: *MessageWriter, framing: head.BodyFraming, persistence: semantics.Persistence, switched: bool) BeginResult {
        self.close_after_message = persistence == .close;
        if (switched) {
            self.state = .tunnel;
            return .{ .framing = framing, .persistence = persistence, .message_done = true, .protocol_switched = true };
        }

        const done = switch (framing) {
            .none => true,
            .content_length => |length| blk: {
                self.remaining = length;
                if (length == 0) break :blk true;
                self.state = .fixed;
                break :blk false;
            },
            .chunked => blk: {
                self.state = .chunked;
                break :blk false;
            },
            .close => blk: {
                self.state = .close_delimited;
                break :blk false;
            },
        };
        if (done) self.completeMessage();
        return .{ .framing = framing, .persistence = persistence, .message_done = done };
    }

    fn writeFixed(self: *MessageWriter, w: *std.Io.Writer, bytes: []const u8) MessageError!DataResult {
        if (bytes.len > self.remaining) return error.ContentLengthMismatch;
        if (bytes.len != 0) {
            w.writeAll(bytes) catch |err| {
                self.state = .poisoned;
                return err;
            };
            self.remaining -= @intCast(bytes.len);
        }
        const done = self.remaining == 0;
        if (done) self.completeMessage();
        return .{ .consumed = bytes.len, .message_done = done };
    }

    fn writeChunked(self: *MessageWriter, w: *std.Io.Writer, bytes: []const u8) MessageError!DataResult {
        if (bytes.len == 0) return .{ .consumed = 0 };
        chunk(w, bytes) catch |err| {
            self.state = .poisoned;
            return err;
        };
        return .{ .consumed = bytes.len };
    }

    fn writeCloseDelimited(self: *MessageWriter, w: *std.Io.Writer, bytes: []const u8) MessageError!DataResult {
        if (bytes.len != 0) {
            w.writeAll(bytes) catch |err| {
                self.state = .poisoned;
                return err;
            };
        }
        return .{ .consumed = bytes.len };
    }

    fn completeMessage(self: *MessageWriter) void {
        self.remaining = 0;
        self.state = if (self.close_after_message) .must_close else .idle;
        self.close_after_message = false;
    }
};

fn validateResponseFramingFields(status: u16, request_method: []const u8, headers: []const common.Header) error{InvalidResponseFraming}!void {
    const successful_connect = std.ascii.eqlIgnoreCase(request_method, "CONNECT") and status >= 200 and status < 300;
    const forbids_content_length = (status >= 100 and status < 200) or status == 204 or successful_connect;
    const forbids_transfer_encoding = (status >= 100 and status < 200) or status == 204 or successful_connect;
    if (!forbids_content_length and !forbids_transfer_encoding) return;

    for (headers) |field| {
        if (forbids_content_length and common.eqlHeaderName(field.name, "content-length")) return error.InvalidResponseFraming;
        if (forbids_transfer_encoding and common.eqlHeaderName(field.name, "transfer-encoding")) return error.InvalidResponseFraming;
    }
}

fn validateTrailers(trailers: []const common.Header) (error{ InvalidHeader, InvalidTrailer })!void {
    try validateHeaders(trailers);
    for (trailers) |field| {
        if (common.eqlHeaderName(field.name, "content-length") or
            common.eqlHeaderName(field.name, "transfer-encoding") or
            common.eqlHeaderName(field.name, "trailer")) return error.InvalidTrailer;
    }
}

fn validateHeaders(headers: []const common.Header) error{InvalidHeader}!void {
    for (headers) |h| {
        if (!common.isToken(h.name) or !common.isFieldValue(h.value)) return error.InvalidHeader;
    }
}

fn requestHeadUnchecked(w: *std.Io.Writer, version: head.Version, method: []const u8, target: []const u8, headers: []const common.Header) std.Io.Writer.Error!void {
    try w.writeAll(method);
    try w.writeByte(' ');
    try w.writeAll(target);
    try w.writeByte(' ');
    try writeVersion(w, version);
    try w.writeAll("\r\n");
    try writeHeadersUnchecked(w, headers);
}

fn responseHeadUnchecked(w: *std.Io.Writer, version: head.Version, status: u16, reason: []const u8, headers: []const common.Header) std.Io.Writer.Error!void {
    try writeVersion(w, version);
    try w.print(" {d} {s}\r\n", .{ status, reason });
    try writeHeadersUnchecked(w, headers);
}

fn writeHeadersUnchecked(w: *std.Io.Writer, headers: []const common.Header) std.Io.Writer.Error!void {
    for (headers) |h| {
        try w.writeAll(h.name);
        try w.writeAll(": ");
        try w.writeAll(h.value);
        try w.writeAll("\r\n");
    }
    try w.writeAll("\r\n");
}

fn endChunksUnchecked(w: *std.Io.Writer, trailers: []const common.Header) std.Io.Writer.Error!void {
    try w.writeAll("0\r\n");
    try writeHeadersUnchecked(w, trailers);
}

fn validTarget(target: []const u8) bool {
    if (target.len == 0) return false;
    for (target) |c| if (c <= 0x20 or c == 0x7f) return false;
    return true;
}

fn validReason(reason: []const u8) bool {
    return common.isFieldValue(reason);
}

fn writeVersion(w: *std.Io.Writer, version: head.Version) std.Io.Writer.Error!void {
    try w.writeAll(switch (version) {
        .http_1_0 => "HTTP/1.0",
        .http_1_1 => "HTTP/1.1",
    });
}

test "writers serialize explicit HTTP versions" {
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try requestHead(&writer, .http_1_0, "GET", "/", &.{});
    try std.testing.expectEqualStrings("GET / HTTP/1.0\r\n\r\n", writer.buffered());

    writer = std.Io.Writer.fixed(&storage);
    try responseHead(&writer, .http_1_1, 204, "No Content", &.{});
    try std.testing.expectEqualStrings("HTTP/1.1 204 No Content\r\n\r\n", writer.buffered());
}

test "head writers validate every header before emitting bytes" {
    var storage: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.InvalidHeader, requestHead(&writer, .http_1_1, "GET", "/", &.{
        .{ .name = "host", .value = "example.com" },
        .{ .name = "bad name", .value = "x" },
    }));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "message writer enforces request content length and supports reuse" {
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var message = MessageWriter.init();
    const headers = [_]common.Header{
        .{ .name = "host", .value = "example.com" },
        .{ .name = "content-length", .value = "5" },
    };
    const begin = try message.beginRequest(&writer, .http_1_1, "POST", "/upload", &headers);
    try std.testing.expectEqual(head.BodyFraming{ .content_length = 5 }, begin.framing);
    try std.testing.expect(!begin.message_done);
    try std.testing.expectError(error.ContentLengthMismatch, message.writeData(&writer, "123456"));
    try std.testing.expectEqual(@as(u64, 5), message.remaining);
    _ = try message.writeData(&writer, "12");
    const done = try message.writeData(&writer, "345");
    try std.testing.expect(done.message_done);
    try std.testing.expect(message.ready());

    const second = try message.beginRequest(&writer, .http_1_1, "GET", "/next", &.{.{ .name = "host", .value = "example.com" }});
    try std.testing.expect(second.message_done);
    try std.testing.expect(message.ready());
}

test "message writer requires semantic policy for trailers" {
    const ChecksumTrailers = struct {
        pub fn allows(_: @This(), name: []const u8) bool {
            return common.eqlHeaderName(name, "x-checksum");
        }
    };

    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var message = MessageWriter.init();
    const begin = try message.beginResponse(&writer, .http_1_1, 200, "OK", "GET", &.{
        .{ .name = "transfer-encoding", .value = "chunked" },
    });
    try std.testing.expectEqual(head.BodyFraming.chunked, begin.framing);
    _ = try message.writeData(&writer, "abc");

    const before = writer.buffered().len;
    try std.testing.expectError(error.TrailerPolicyRequired, message.finish(&writer, &.{
        .{ .name = "x-checksum", .value = "ok" },
    }));
    try std.testing.expectEqual(before, writer.buffered().len);

    try message.finishWithTrailerPolicy(&writer, &.{
        .{ .name = "x-checksum", .value = "ok" },
    }, ChecksumTrailers{});
    try std.testing.expect(message.ready());
    try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), "3\r\nabc\r\n0\r\nx-checksum: ok\r\n\r\n"));
}

test "message writer trailer policy rejects before terminal chunk" {
    const NoTrailers = struct {
        pub fn allows(_: @This(), _: []const u8) bool {
            return false;
        }
    };

    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var message = MessageWriter.init();
    _ = try message.beginResponse(&writer, .http_1_1, 200, "OK", "GET", &.{
        .{ .name = "transfer-encoding", .value = "chunked" },
    });
    _ = try message.writeData(&writer, "abc");
    const before = writer.buffered().len;
    try std.testing.expectError(error.TrailerRejected, message.finishWithTrailerPolicy(&writer, &.{
        .{ .name = "x-checksum", .value = "ok" },
    }, NoTrailers{}));
    try std.testing.expectEqual(before, writer.buffered().len);
    try message.finish(&writer, &.{});
}

test "message writer prevents reuse after close-delimited response" {
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var message = MessageWriter.init();
    const begin = try message.beginResponse(&writer, .http_1_1, 200, "OK", "GET", &.{});
    try std.testing.expectEqual(head.BodyFraming.close, begin.framing);
    _ = try message.writeData(&writer, "body");
    try message.finish(&writer, &.{});
    try std.testing.expect(message.mustClose());
    try std.testing.expectError(error.InvalidState, message.beginResponse(&writer, .http_1_1, 200, "OK", "GET", &.{}));
}

test "message writer handles HEAD and CONNECT response boundaries" {
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var message = MessageWriter.init();

    const head_response = try message.beginResponse(&writer, .http_1_1, 200, "OK", "HEAD", &.{
        .{ .name = "content-length", .value = "100" },
    });
    try std.testing.expectEqual(head.BodyFraming.none, head_response.framing);
    try std.testing.expect(head_response.message_done);
    try std.testing.expect(message.ready());

    const connect = try message.beginResponse(&writer, .http_1_1, 200, "Connection Established", "CONNECT", &.{});
    try std.testing.expect(connect.protocol_switched);
    try std.testing.expect(message.protocolSwitched());
    try std.testing.expectError(error.InvalidState, message.writeData(&writer, "not-http"));
}

test "message writer rejects forbidden bodyless response framing before output" {
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var message = MessageWriter.init();
    try std.testing.expectError(error.InvalidResponseFraming, message.beginResponse(&writer, .http_1_1, 204, "No Content", "GET", &.{
        .{ .name = "content-length", .value = "1" },
    }));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try std.testing.expect(message.ready());

    try std.testing.expectError(error.InvalidResponseFraming, message.beginResponse(&writer, .http_1_1, 200, "Connection Established", "CONNECT", &.{
        .{ .name = "transfer-encoding", .value = "chunked" },
    }));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "message writer rejects framing fields in trailers before terminal chunk" {
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var message = MessageWriter.init();
    _ = try message.beginResponse(&writer, .http_1_1, 200, "OK", "GET", &.{
        .{ .name = "transfer-encoding", .value = "chunked" },
    });
    _ = try message.writeData(&writer, "abc");
    const before = writer.buffered().len;
    const AllowAll = struct {
        pub fn allows(_: @This(), _: []const u8) bool {
            return true;
        }
    };
    try std.testing.expectError(error.InvalidTrailer, message.finishWithTrailerPolicy(&writer, &.{
        .{ .name = "content-length", .value = "3" },
    }, AllowAll{}));
    try std.testing.expectEqual(before, writer.buffered().len);
    try message.finish(&writer, &.{});
}

test "message writer poisons state after partial output failure" {
    var storage: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var message = MessageWriter.init();
    _ = message.beginRequest(&writer, .http_1_1, "GET", "/long-target", &.{
        .{ .name = "host", .value = "example.com" },
    }) catch {};
    try std.testing.expect(message.failed());
    try std.testing.expectError(error.InvalidState, message.beginRequest(&writer, .http_1_1, "GET", "/", &.{
        .{ .name = "host", .value = "example.com" },
    }));
}

test "message writer keeps compact persistent state" {
    try std.testing.expect(@sizeOf(MessageWriter) <= 16);
}
