const std = @import("std");
const common = @import("../common.zig");

pub const Error = error{
    HeadTooLarge,
    InvalidStartLine,
    InvalidVersion,
    InvalidStatus,
    InvalidHeader,
    InvalidContentLength,
    ConflictingContentLength,
    AmbiguousFraming,
    InvalidTransferEncoding,
};

pub const Version = enum { http_1_0, http_1_1 };
pub const Mode = enum { request, response };

pub const RequestLine = struct {
    method: []const u8,
    target: []const u8,
};

pub const StatusLine = struct {
    status: u16,
    reason: []const u8,
};

pub const Head = struct {
    version: Version,
    start: union(Mode) {
        request: RequestLine,
        response: StatusLine,
    },
    headers: []const u8,

    pub fn headerIterator(self: Head) HeaderIterator {
        return .{ .remaining = self.headers };
    }
};

pub const HeaderIterator = struct {
    remaining: []const u8,

    pub fn next(self: *HeaderIterator) Error!?common.Header {
        if (self.remaining.len == 0) return null;
        const eol = std.mem.indexOf(u8, self.remaining, "\r\n") orelse return error.InvalidHeader;
        const line = self.remaining[0..eol];
        self.remaining = self.remaining[eol + 2 ..];
        if (line.len == 0) return null;
        if (line[0] == ' ' or line[0] == '\t') return error.InvalidHeader;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const name = line[0..colon];
        if (!common.isToken(name)) return error.InvalidHeader;
        const value = common.trimOws(line[colon + 1 ..]);
        for (value) |c| {
            if (c == '\r' or c == '\n' or c == 0) return error.InvalidHeader;
        }
        return .{ .name = name, .value = value };
    }
};

pub const FeedResult = struct {
    consumed: usize,
    head: ?Head = null,
};

/// Incremental HTTP/1 head parser. The caller owns the scratch storage; body bytes
/// are never copied into it. Returned slices remain valid until `reset` or reuse.
pub const HeadParser = struct {
    mode: Mode,
    scratch: []u8,
    used: usize = 0,
    complete: bool = false,

    pub fn init(mode: Mode, scratch: []u8) HeadParser {
        return .{ .mode = mode, .scratch = scratch };
    }

    pub fn reset(self: *HeadParser, mode: Mode) void {
        self.mode = mode;
        self.used = 0;
        self.complete = false;
    }

    pub fn feed(self: *HeadParser, input: []const u8) Error!FeedResult {
        if (self.complete) return .{ .consumed = 0, .head = try parseHead(self.mode, self.scratch[0..self.used]) };
        if (input.len == 0) return .{ .consumed = 0 };

        // First check the only three ways the delimiter can straddle two reads.
        const marker = "\r\n\r\n";
        inline for (1..4) |old_count| {
            if (self.used >= old_count and input.len >= marker.len - old_count and
                std.mem.eql(u8, self.scratch[self.used - old_count .. self.used], marker[0..old_count]) and
                std.mem.eql(u8, input[0 .. marker.len - old_count], marker[old_count..]))
            {
                const consumed = marker.len - old_count;
                if (self.used + consumed > self.scratch.len) return error.HeadTooLarge;
                @memcpy(self.scratch[self.used .. self.used + consumed], input[0..consumed]);
                self.used += consumed;
                self.complete = true;
                return .{ .consumed = consumed, .head = try parseHead(self.mode, self.scratch[0..self.used]) };
            }
        }

        // Then search the transport buffer directly so body bytes are never copied.
        if (std.mem.indexOf(u8, input, marker)) |pos| {
            const consumed = pos + marker.len;
            if (self.used + consumed > self.scratch.len) return error.HeadTooLarge;
            @memcpy(self.scratch[self.used .. self.used + consumed], input[0..consumed]);
            self.used += consumed;
            self.complete = true;
            return .{ .consumed = consumed, .head = try parseHead(self.mode, self.scratch[0..self.used]) };
        }

        if (input.len > self.scratch.len - self.used) return error.HeadTooLarge;
        @memcpy(self.scratch[self.used .. self.used + input.len], input);
        self.used += input.len;
        return .{ .consumed = input.len };
    }
};

fn parseVersion(bytes: []const u8) Error!Version {
    if (std.mem.eql(u8, bytes, "HTTP/1.1")) return .http_1_1;
    if (std.mem.eql(u8, bytes, "HTTP/1.0")) return .http_1_0;
    return error.InvalidVersion;
}

fn parseHead(mode: Mode, bytes: []const u8) Error!Head {
    const first_eol = std.mem.indexOf(u8, bytes, "\r\n") orelse return error.InvalidStartLine;
    const first = bytes[0..first_eol];
    const raw_headers = bytes[first_eol + 2 .. bytes.len - 2];

    var result: Head = undefined;
    result.headers = raw_headers;
    switch (mode) {
        .request => {
            const sp1 = std.mem.indexOfScalar(u8, first, ' ') orelse return error.InvalidStartLine;
            const sp2_rel = std.mem.indexOfScalar(u8, first[sp1 + 1 ..], ' ') orelse return error.InvalidStartLine;
            const sp2 = sp1 + 1 + sp2_rel;
            if (std.mem.indexOfScalar(u8, first[sp2 + 1 ..], ' ') != null) return error.InvalidStartLine;
            const method = first[0..sp1];
            const target = first[sp1 + 1 .. sp2];
            if (!common.isToken(method) or target.len == 0) return error.InvalidStartLine;
            result.version = try parseVersion(first[sp2 + 1 ..]);
            result.start = .{ .request = .{ .method = method, .target = target } };
        },
        .response => {
            const sp1 = std.mem.indexOfScalar(u8, first, ' ') orelse return error.InvalidStartLine;
            result.version = try parseVersion(first[0..sp1]);
            const rest = first[sp1 + 1 ..];
            if (rest.len < 3) return error.InvalidStatus;
            const code_bytes = rest[0..3];
            for (code_bytes) |c| if (!std.ascii.isDigit(c)) return error.InvalidStatus;
            const status = std.fmt.parseInt(u16, code_bytes, 10) catch return error.InvalidStatus;
            if (status < 100 or status > 999) return error.InvalidStatus;
            const reason = if (rest.len == 3) "" else blk: {
                if (rest[3] != ' ') return error.InvalidStartLine;
                break :blk rest[4..];
            };
            result.start = .{ .response = .{ .status = status, .reason = reason } };
        },
    }

    var it = result.headerIterator();
    while (try it.next()) |_| {}
    return result;
}

pub const BodyFraming = union(enum) {
    none,
    content_length: u64,
    chunked,
    close,
};

/// RFC 9112 request framing. Strictly rejects TE+CL to avoid request smuggling.
pub fn requestBodyFraming(head: Head) Error!BodyFraming {
    var it = head.headerIterator();
    var content_length: ?u64 = null;
    var has_te = false;
    var te: TransferEncodingState = .{};
    while (try it.next()) |h| {
        if (common.eqlHeaderName(h.name, "content-length")) {
            try mergeContentLength(&content_length, h.value);
        } else if (common.eqlHeaderName(h.name, "transfer-encoding")) {
            has_te = true;
            try te.add(h.value);
        }
    }
    if (has_te and content_length != null) return error.AmbiguousFraming;
    if (has_te) {
        if (!te.final_chunked) return error.InvalidTransferEncoding;
        return .chunked;
    }
    if (content_length) |n| return .{ .content_length = n };
    return .none;
}

/// Response framing requires request context for HEAD and CONNECT semantics.
pub fn responseBodyFraming(head: Head, request_method: []const u8) Error!BodyFraming {
    const status = switch (head.start) {
        .response => |r| r.status,
        else => return error.InvalidStartLine,
    };
    if (std.ascii.eqlIgnoreCase(request_method, "HEAD") or
        (status >= 100 and status < 200) or status == 204 or status == 304)
        return .none;
    if (std.ascii.eqlIgnoreCase(request_method, "CONNECT") and status >= 200 and status < 300)
        return .none;

    var it = head.headerIterator();
    var content_length: ?u64 = null;
    var has_te = false;
    var te: TransferEncodingState = .{};
    while (try it.next()) |h| {
        if (common.eqlHeaderName(h.name, "content-length")) {
            try mergeContentLength(&content_length, h.value);
        } else if (common.eqlHeaderName(h.name, "transfer-encoding")) {
            has_te = true;
            try te.add(h.value);
        }
    }
    if (has_te and content_length != null) return error.AmbiguousFraming;
    if (has_te) return if (te.final_chunked) .chunked else .close;
    if (content_length) |n| return .{ .content_length = n };
    return .close;
}

fn mergeContentLength(slot: *?u64, value: []const u8) Error!void {
    var rest = value;
    var saw = false;
    while (true) {
        const comma = std.mem.indexOfScalar(u8, rest, ',');
        const part = common.trimOws(if (comma) |i| rest[0..i] else rest);
        if (part.len == 0) return error.InvalidContentLength;
        for (part) |c| if (!std.ascii.isDigit(c)) return error.InvalidContentLength;
        const parsed = std.fmt.parseInt(u64, part, 10) catch return error.InvalidContentLength;
        if (slot.*) |old| {
            if (old != parsed) return error.ConflictingContentLength;
        } else slot.* = parsed;
        saw = true;
        if (comma) |i| rest = rest[i + 1 ..] else break;
    }
    if (!saw) return error.InvalidContentLength;
}

const TransferEncodingState = struct {
    saw_any: bool = false,
    saw_chunked: bool = false,
    final_chunked: bool = false,

    fn add(self: *TransferEncodingState, value: []const u8) Error!void {
        var rest = value;
        while (true) {
            const comma = std.mem.indexOfScalar(u8, rest, ',');
            const item0 = common.trimOws(if (comma) |i| rest[0..i] else rest);
            const semi = std.mem.indexOfScalar(u8, item0, ';');
            const item = common.trimOws(if (semi) |i| item0[0..i] else item0);
            if (!common.isToken(item)) return error.InvalidTransferEncoding;
            if (self.saw_chunked) return error.InvalidTransferEncoding;
            self.saw_any = true;
            self.final_chunked = std.ascii.eqlIgnoreCase(item, "chunked");
            if (self.final_chunked) self.saw_chunked = true;
            if (comma) |i| rest = rest[i + 1 ..] else break;
        }
        if (!self.saw_any) return error.InvalidTransferEncoding;
    }
};

test "incremental request head and body framing" {
    var scratch: [1024]u8 = undefined;
    var p = HeadParser.init(.request, &scratch);
    const a = try p.feed("POST /upload HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n");
    try std.testing.expect(a.head == null);
    const b = try p.feed("\r\nhello");
    try std.testing.expectEqual(@as(usize, 2), b.consumed);
    const h = b.head.?;
    try std.testing.expectEqualStrings("POST", h.start.request.method);
    const framing = try requestBodyFraming(h);
    try std.testing.expectEqual(@as(u64, 5), framing.content_length);
}

test "reject smuggling framing" {
    var scratch: [1024]u8 = undefined;
    var p = HeadParser.init(.request, &scratch);
    const r = try p.feed("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n");
    try std.testing.expectError(error.AmbiguousFraming, requestBodyFraming(r.head.?));
}

test "reject repeated or non-final chunked transfer coding" {
    var scratch: [1024]u8 = undefined;
    var p = HeadParser.init(.request, &scratch);
    const r = try p.feed("POST / HTTP/1.1\r\nTransfer-Encoding: chunked, gzip\r\n\r\n");
    try std.testing.expectError(error.InvalidTransferEncoding, requestBodyFraming(r.head.?));
}

test "request head survives one-byte transport fragmentation" {
    const wire = "GET /x HTTP/1.1\r\nHost: example.com\r\n\r\n";
    var scratch: [256]u8 = undefined;
    var p = HeadParser.init(.request, &scratch);
    var pos: usize = 0;
    var parsed: ?Head = null;
    while (pos < wire.len) {
        const r = try p.feed(wire[pos .. pos + 1]);
        try std.testing.expectEqual(@as(usize, 1), r.consumed);
        pos += 1;
        if (r.head) |h| parsed = h;
    }
    try std.testing.expectEqualStrings("/x", parsed.?.start.request.target);
}

test "head storage is a hard bound" {
    var scratch: [16]u8 = undefined;
    var p = HeadParser.init(.request, &scratch);
    try std.testing.expectError(error.HeadTooLarge, p.feed("GET / HTTP/1.1\r\nHost: too-long.example\r\n\r\n"));
}
