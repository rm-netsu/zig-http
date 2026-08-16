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
        return try parseHeaderLine(line);
    }
};

pub const FeedResult = struct {
    consumed: usize,
    head: ?Head = null,
};

pub const FramedHead = struct {
    head: Head,
    framing: BodyFraming,
};

pub const FramedFeedResult = struct {
    consumed: usize,
    framed: ?FramedHead = null,
};

pub const ParseResult = struct {
    consumed: usize,
    head: Head,
};

/// Parse a complete HTTP/1 head directly from caller-owned input. This is the
/// zero-copy fast path for transports that retain their read buffer while the
/// returned `Head` is consumed. Returns `null` while another complete line is
/// needed; malformed complete lines may fail before the terminating empty line.
pub fn parse(mode: Mode, input: []const u8) Error!?ParseResult {
    const first_eol = std.mem.indexOf(u8, input, "\r\n") orelse return null;
    var head = try parseStartLine(mode, input[0..first_eol]);
    var cursor = first_eol + 2;
    while (true) {
        const rel = std.mem.indexOf(u8, input[cursor..], "\r\n") orelse return null;
        const line = input[cursor .. cursor + rel];
        cursor += rel + 2;
        if (line.len == 0) {
            head.headers = input[first_eol + 2 .. cursor - 2];
            return .{ .consumed = cursor, .head = head };
        }
        _ = try parseHeaderLine(line);
    }
}

pub const FramedParseResult = struct {
    consumed: usize,
    head: Head,
    framing: BodyFraming,
};

/// Zero-copy server fast path. Header syntax validation and request body framing
/// are performed in the same header traversal rather than validating twice.
pub fn parseRequest(input: []const u8) Error!?FramedParseResult {
    const first_eol = std.mem.indexOf(u8, input, "\r\n") orelse return null;
    var head = try parseStartLine(.request, input[0..first_eol]);
    var content_length: ?u64 = null;
    var has_te = false;
    var te: TransferEncodingState = .{};
    var cursor = first_eol + 2;

    while (true) {
        const rel = std.mem.indexOf(u8, input[cursor..], "\r\n") orelse return null;
        const line = input[cursor .. cursor + rel];
        cursor += rel + 2;
        if (line.len == 0) {
            head.headers = input[first_eol + 2 .. cursor - 2];
            if (has_te and head.version == .http_1_0) return error.InvalidTransferEncoding;
            const framing: BodyFraming = if (has_te and content_length != null)
                return error.AmbiguousFraming
            else if (has_te)
                if (te.final_chunked) .chunked else return error.InvalidTransferEncoding
            else if (content_length) |n|
                .{ .content_length = n }
            else
                .none;
            return .{ .consumed = cursor, .head = head, .framing = framing };
        }

        const h = try parseHeaderLine(line);
        switch (framingHeaderKind(h.name)) {
            .content_length => try mergeContentLength(&content_length, h.value),
            .transfer_encoding => {
                has_te = true;
                try te.add(h.value);
            },
            .other => {},
        }
    }
}

/// Zero-copy client fast path. `request_method` supplies the HEAD/CONNECT
/// context required to determine response body framing.
pub fn parseResponse(input: []const u8, request_method: []const u8) Error!?FramedParseResult {
    const first_eol = std.mem.indexOf(u8, input, "\r\n") orelse return null;
    var head = try parseStartLine(.response, input[0..first_eol]);
    const status = head.start.response.status;
    const bodyless = responseHasNoBody(status, request_method);
    var content_length: ?u64 = null;
    var has_te = false;
    var te: TransferEncodingState = .{};
    var cursor = first_eol + 2;

    while (true) {
        const rel = std.mem.indexOf(u8, input[cursor..], "\r\n") orelse return null;
        const line = input[cursor .. cursor + rel];
        cursor += rel + 2;
        if (line.len == 0) {
            head.headers = input[first_eol + 2 .. cursor - 2];
            if (has_te and head.version == .http_1_0) return error.InvalidTransferEncoding;
            const framing: BodyFraming = if (bodyless)
                .none
            else if (has_te and content_length != null)
                return error.AmbiguousFraming
            else if (has_te)
                if (te.final_chunked) .chunked else .close
            else if (content_length) |n|
                .{ .content_length = n }
            else
                .close;
            return .{ .consumed = cursor, .head = head, .framing = framing };
        }

        const h = try parseHeaderLine(line);
        switch (framingHeaderKind(h.name)) {
            .content_length => if (!bodyless) try mergeContentLength(&content_length, h.value),
            .transfer_encoding => {
                has_te = true;
                if (!bodyless) try te.add(h.value);
            },
            .other => {},
        }
    }
}

/// Incremental framed-head parser optimized for transports that fragment HTTP/1
/// heads frequently. Unlike `HeadParser.feedRequest` / `feedResponse`, it parses
/// complete lines as they arrive and carries body-framing state across reads, so
/// the completed head does not require another traversal of all field lines.
///
/// This intentionally spends a small amount of additional per-parser state for
/// lower fragmented-head CPU cost. The caller still owns all scratch storage and
/// body bytes are never copied into it.
pub const FramedHeadParser = struct {
    scratch: []u8,
    content_length: ?u64 = null,
    used: u32 = 0,
    line_start: u32 = 0,
    te: TransferEncodingState = .{},
    mode: Mode,
    version: Version = .http_1_1,
    has_te: bool = false,
    start_seen: bool = false,
    complete: bool = false,
    bodyless_response: bool = false,

    pub fn init(mode: Mode, scratch: []u8) FramedHeadParser {
        return .{ .mode = mode, .scratch = scratch };
    }

    pub fn reset(self: *FramedHeadParser, mode: Mode) void {
        self.mode = mode;
        self.content_length = null;
        self.used = 0;
        self.line_start = 0;
        self.te = .{};
        self.version = .http_1_1;
        self.has_te = false;
        self.start_seen = false;
        self.complete = false;
        self.bodyless_response = false;
    }

    pub fn feedRequest(self: *FramedHeadParser, input: []const u8) Error!FramedFeedResult {
        if (self.mode != .request) return error.InvalidStartLine;
        const consumed = try self.feedLines(input, null);
        if (!self.complete) return .{ .consumed = consumed };
        const head = try parseHeadStart(.request, self.scratch[0..self.used]);
        return .{
            .consumed = consumed,
            .framed = .{ .head = head, .framing = try self.requestFraming() },
        };
    }

    pub fn feedResponse(self: *FramedHeadParser, input: []const u8, request_method: []const u8) Error!FramedFeedResult {
        if (self.mode != .response) return error.InvalidStartLine;
        const consumed = try self.feedLines(input, request_method);
        if (!self.complete) return .{ .consumed = consumed };
        const head = try parseHeadStart(.response, self.scratch[0..self.used]);
        if (self.bodyless_response) {
            if (self.has_te and self.version == .http_1_0) return error.InvalidTransferEncoding;
            return .{ .consumed = consumed, .framed = .{ .head = head, .framing = .none } };
        }
        return .{
            .consumed = consumed,
            .framed = .{ .head = head, .framing = try self.responseFraming() },
        };
    }

    fn feedLines(self: *FramedHeadParser, input: []const u8, request_method: ?[]const u8) Error!usize {
        if (self.complete or input.len == 0) return 0;
        var pos: usize = 0;

        // Complete a CRLF split exactly at the read boundary without rescanning
        // the buffered prefix.
        if (self.used != 0 and self.scratch[self.used - 1] == '\r' and input[0] == '\n') {
            try self.append(input[0..1]);
            pos = 1;
            try self.finishLine(request_method);
            if (self.complete) return pos;
        }

        while (pos < input.len) {
            const rel = std.mem.indexOf(u8, input[pos..], "\r\n") orelse {
                try self.append(input[pos..]);
                return input.len;
            };
            const end = pos + rel + 2;
            try self.append(input[pos..end]);
            pos = end;
            try self.finishLine(request_method);
            if (self.complete) return pos;
        }
        return pos;
    }

    inline fn append(self: *FramedHeadParser, bytes: []const u8) Error!void {
        const used = @as(usize, self.used);
        if (used > self.scratch.len or bytes.len > self.scratch.len - used) return error.HeadTooLarge;
        if (bytes.len > std.math.maxInt(u32) - self.used) return error.HeadTooLarge;
        @memcpy(self.scratch[used .. used + bytes.len], bytes);
        self.used += @intCast(bytes.len);
    }

    fn finishLine(self: *FramedHeadParser, request_method: ?[]const u8) Error!void {
        const used = @as(usize, self.used);
        const start = @as(usize, self.line_start);
        if (used < start + 2 or self.scratch[used - 2] != '\r' or self.scratch[used - 1] != '\n')
            return error.InvalidHeader;
        const line = self.scratch[start .. used - 2];
        self.line_start = self.used;

        if (!self.start_seen) {
            const parsed_start = try parseStartLine(self.mode, line);
            self.version = parsed_start.version;
            if (self.mode == .response) {
                const method = request_method orelse return error.InvalidStartLine;
                self.bodyless_response = responseHasNoBody(parsed_start.start.response.status, method);
            }
            self.start_seen = true;
            return;
        }
        if (line.len == 0) {
            self.complete = true;
            return;
        }
        const h = try parseHeaderLine(line);
        switch (framingHeaderKind(h.name)) {
            .content_length => if (!self.bodyless_response) try mergeContentLength(&self.content_length, h.value),
            .transfer_encoding => {
                self.has_te = true;
                if (!self.bodyless_response) try self.te.add(h.value);
            },
            .other => {},
        }
    }

    fn requestFraming(self: FramedHeadParser) Error!BodyFraming {
        if (self.has_te and self.version == .http_1_0) return error.InvalidTransferEncoding;
        if (self.has_te and self.content_length != null) return error.AmbiguousFraming;
        if (self.has_te) return if (self.te.final_chunked) .chunked else error.InvalidTransferEncoding;
        if (self.content_length) |value| return .{ .content_length = value };
        return .none;
    }

    fn responseFraming(self: FramedHeadParser) Error!BodyFraming {
        if (self.has_te and self.version == .http_1_0) return error.InvalidTransferEncoding;
        if (self.has_te and self.content_length != null) return error.AmbiguousFraming;
        if (self.has_te) return if (self.te.final_chunked) .chunked else .close;
        if (self.content_length) |value| return .{ .content_length = value };
        return .close;
    }
};

fn headEnd(input: []const u8) ?usize {
    const marker = "\r\n\r\n";
    const pos = std.mem.indexOf(u8, input, marker) orelse return null;
    return pos + marker.len;
}

/// Incremental HTTP/1 head parser. The caller owns the scratch storage; body bytes
/// are never copied into it. Returned slices remain valid until `reset` or reuse.
pub const HeadParser = struct {
    scratch: []u8,
    used: u32 = 0,
    mode: Mode,
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
        const r = try self.accumulate(input);
        if (!r.complete) return .{ .consumed = r.consumed };
        return .{
            .consumed = r.consumed,
            .head = try parseHead(self.mode, self.scratch[0..self.used]),
        };
    }

    /// Incremental server fast path. As with `parseRequest`, syntax validation
    /// and request framing share one traversal once the head is complete.
    pub fn feedRequest(self: *HeadParser, input: []const u8) Error!FramedFeedResult {
        const r = try self.accumulate(input);
        if (!r.complete) return .{ .consumed = r.consumed };
        const head = try parseHeadStart(.request, self.scratch[0..self.used]);
        return .{
            .consumed = r.consumed,
            .framed = .{ .head = head, .framing = try requestBodyFraming(head) },
        };
    }

    /// Incremental client fast path with the request context needed for HEAD
    /// and successful CONNECT response framing.
    pub fn feedResponse(self: *HeadParser, input: []const u8, request_method: []const u8) Error!FramedFeedResult {
        const r = try self.accumulate(input);
        if (!r.complete) return .{ .consumed = r.consumed };
        const head = try parseHeadStart(.response, self.scratch[0..self.used]);
        return .{
            .consumed = r.consumed,
            .framed = .{ .head = head, .framing = try responseBodyFraming(head, request_method) },
        };
    }

    const AccumulateResult = struct {
        consumed: usize,
        complete: bool,
    };

    fn accumulate(self: *HeadParser, input: []const u8) Error!AccumulateResult {
        const used = @as(usize, self.used);
        if (self.complete) return .{ .consumed = 0, .complete = true };
        if (input.len == 0) return .{ .consumed = 0, .complete = false };

        // First check the only three ways the delimiter can straddle two reads.
        const marker = "\r\n\r\n";
        inline for (1..4) |old_count| {
            if (used >= old_count and input.len >= marker.len - old_count and
                std.mem.eql(u8, self.scratch[used - old_count .. used], marker[0..old_count]) and
                std.mem.eql(u8, input[0 .. marker.len - old_count], marker[old_count..]))
            {
                const consumed = marker.len - old_count;
                try self.append(input[0..consumed]);
                self.complete = true;
                return .{ .consumed = consumed, .complete = true };
            }
        }

        // Then search the transport buffer directly so body bytes are never copied.
        if (std.mem.indexOf(u8, input, marker)) |pos| {
            const consumed = pos + marker.len;
            try self.append(input[0..consumed]);
            self.complete = true;
            return .{ .consumed = consumed, .complete = true };
        }

        try self.append(input);
        return .{ .consumed = input.len, .complete = false };
    }

    inline fn append(self: *HeadParser, bytes: []const u8) Error!void {
        const used = @as(usize, self.used);
        if (used > self.scratch.len or bytes.len > self.scratch.len - used) return error.HeadTooLarge;
        if (bytes.len > std.math.maxInt(u32) - self.used) return error.HeadTooLarge;
        @memcpy(self.scratch[used .. used + bytes.len], bytes);
        self.used += @intCast(bytes.len);
    }
};

inline fn parseHeaderLine(line: []const u8) Error!common.Header {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return error.InvalidHeader;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
    const name = line[0..colon];
    if (!common.isToken(name)) return error.InvalidHeader;
    const value = common.trimOws(line[colon + 1 ..]);
    if (!common.isFieldValue(value)) return error.InvalidHeader;
    return .{ .name = name, .value = value };
}

const FramingHeaderKind = enum { other, content_length, transfer_encoding };

inline fn framingHeaderKind(name: []const u8) FramingHeaderKind {
    return switch (name.len) {
        14 => if (std.ascii.eqlIgnoreCase(name, "content-length")) .content_length else .other,
        17 => if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) .transfer_encoding else .other,
        else => .other,
    };
}

fn parseVersion(bytes: []const u8) Error!Version {
    if (std.mem.eql(u8, bytes, "HTTP/1.1")) return .http_1_1;
    if (std.mem.eql(u8, bytes, "HTTP/1.0")) return .http_1_0;
    return error.InvalidVersion;
}

fn parseHead(mode: Mode, bytes: []const u8) Error!Head {
    const result = try parseHeadStart(mode, bytes);
    var it = result.headerIterator();
    while (try it.next()) |_| {}
    return result;
}

fn parseHeadStart(mode: Mode, bytes: []const u8) Error!Head {
    const first_eol = std.mem.indexOf(u8, bytes, "\r\n") orelse return error.InvalidStartLine;
    var result = try parseStartLine(mode, bytes[0..first_eol]);
    result.headers = bytes[first_eol + 2 .. bytes.len - 2];
    return result;
}

inline fn parseStartLine(mode: Mode, first: []const u8) Error!Head {
    var result: Head = undefined;
    result.headers = &.{};
    switch (mode) {
        .request => {
            const sp1 = std.mem.indexOfScalar(u8, first, ' ') orelse return error.InvalidStartLine;
            const sp2_rel = std.mem.indexOfScalar(u8, first[sp1 + 1 ..], ' ') orelse return error.InvalidStartLine;
            const sp2 = sp1 + 1 + sp2_rel;
            if (std.mem.indexOfScalar(u8, first[sp2 + 1 ..], ' ') != null) return error.InvalidStartLine;
            const method = first[0..sp1];
            const target = first[sp1 + 1 .. sp2];
            if (!common.isToken(method) or target.len == 0) return error.InvalidStartLine;
            for (target) |c| if (c <= 0x20 or c == 0x7f) return error.InvalidStartLine;
            result.version = try parseVersion(first[sp2 + 1 ..]);
            result.start = .{ .request = .{ .method = method, .target = target } };
        },
        .response => {
            const sp1 = std.mem.indexOfScalar(u8, first, ' ') orelse return error.InvalidStartLine;
            result.version = try parseVersion(first[0..sp1]);
            const rest = first[sp1 + 1 ..];
            if (rest.len < 3) return error.InvalidStatus;
            const code_bytes = rest[0..3];
            if (!std.ascii.isDigit(code_bytes[0]) or !std.ascii.isDigit(code_bytes[1]) or !std.ascii.isDigit(code_bytes[2]))
                return error.InvalidStatus;
            const status = @as(u16, code_bytes[0] - '0') * 100 + @as(u16, code_bytes[1] - '0') * 10 + code_bytes[2] - '0';
            if (status < 100 or status > 999) return error.InvalidStatus;
            if (rest.len == 3 or rest[3] != ' ') return error.InvalidStartLine;
            const reason = rest[4..];
            if (!common.isFieldValue(reason)) return error.InvalidStartLine;
            result.start = .{ .response = .{ .status = status, .reason = reason } };
        },
    }

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
    if (has_te and head.version == .http_1_0) return error.InvalidTransferEncoding;
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
    if (responseHasNoBody(status, request_method)) {
        // The framing decision is known from request/status context, but field
        // syntax still has to be validated on the zero-copy fast path.
        var validation = head.headerIterator();
        while (try validation.next()) |_| {}
        return .none;
    }

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
    if (has_te and head.version == .http_1_0) return error.InvalidTransferEncoding;
    if (has_te and content_length != null) return error.AmbiguousFraming;
    if (has_te) return if (te.final_chunked) .chunked else .close;
    if (content_length) |n| return .{ .content_length = n };
    return .close;
}

fn responseHasNoBody(status: u16, request_method: []const u8) bool {
    return std.ascii.eqlIgnoreCase(request_method, "HEAD") or
        (status >= 100 and status < 200) or status == 204 or status == 304 or
        (std.ascii.eqlIgnoreCase(request_method, "CONNECT") and status >= 200 and status < 300);
}

fn mergeContentLength(slot: *?u64, value: []const u8) Error!void {
    var rest = value;
    var saw = false;
    while (true) {
        const comma = std.mem.indexOfScalar(u8, rest, ',');
        const part = common.trimOws(if (comma) |i| rest[0..i] else rest);
        if (part.len == 0) return error.InvalidContentLength;
        const parsed = try parseContentLength(part);
        if (slot.*) |old| {
            if (old != parsed) return error.ConflictingContentLength;
        } else slot.* = parsed;
        saw = true;
        if (comma) |i| rest = rest[i + 1 ..] else break;
    }
    if (!saw) return error.InvalidContentLength;
}

fn parseContentLength(bytes: []const u8) Error!u64 {
    if (bytes.len == 0) return error.InvalidContentLength;
    var value: u64 = 0;
    for (bytes) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidContentLength;
        const digit: u64 = c - '0';
        if (value > (std.math.maxInt(u64) - digit) / 10) return error.InvalidContentLength;
        value = value * 10 + digit;
    }
    return value;
}

const TransferEncodingState = struct {
    saw_any: bool = false,
    saw_chunked: bool = false,
    final_chunked: bool = false,

    fn add(self: *TransferEncodingState, value: []const u8) Error!void {
        if (value.len == "chunked".len and std.ascii.eqlIgnoreCase(value, "chunked")) {
            if (self.saw_chunked) return error.InvalidTransferEncoding;
            self.saw_any = true;
            self.saw_chunked = true;
            self.final_chunked = true;
            return;
        }

        var pos: usize = 0;
        var added = false;
        while (true) {
            skipTeOws(value, &pos);
            if (pos == value.len or self.saw_chunked) return error.InvalidTransferEncoding;

            const coding = try scanTeToken(value, &pos);
            skipTeOws(value, &pos);

            while (pos < value.len and value[pos] == ';') {
                pos += 1;
                skipTeOws(value, &pos);
                _ = try scanTeToken(value, &pos);
                skipTeOws(value, &pos);
                if (pos == value.len or value[pos] != '=') return error.InvalidTransferEncoding;
                pos += 1;
                skipTeOws(value, &pos);
                if (pos == value.len) return error.InvalidTransferEncoding;
                if (value[pos] == '"') try scanTeQuotedString(value, &pos) else _ = try scanTeToken(value, &pos);
                skipTeOws(value, &pos);
            }

            const is_chunked = std.ascii.eqlIgnoreCase(coding, "chunked");
            self.saw_any = true;
            added = true;
            self.final_chunked = is_chunked;
            if (is_chunked) self.saw_chunked = true;

            if (pos == value.len) break;
            if (value[pos] != ',') return error.InvalidTransferEncoding;
            pos += 1;
        }
        if (!added) return error.InvalidTransferEncoding;
    }
};

inline fn skipTeOws(value: []const u8, pos: *usize) void {
    while (pos.* < value.len and (value[pos.*] == ' ' or value[pos.*] == '\t')) pos.* += 1;
}

inline fn scanTeToken(value: []const u8, pos: *usize) Error![]const u8 {
    const start = pos.*;
    while (pos.* < value.len and common.isTchar(value[pos.*])) pos.* += 1;
    if (pos.* == start) return error.InvalidTransferEncoding;
    return value[start..pos.*];
}

fn scanTeQuotedString(value: []const u8, pos: *usize) Error!void {
    if (pos.* == value.len or value[pos.*] != '"') return error.InvalidTransferEncoding;
    pos.* += 1;
    while (pos.* < value.len) {
        const c = value[pos.*];
        if (c == '"') { pos.* += 1; return; }
        if (c == '\\') {
            pos.* += 1;
            if (pos.* == value.len or !isQuotedPairChar(value[pos.*])) return error.InvalidTransferEncoding;
            pos.* += 1;
            continue;
        }
        if (!isQdtext(c)) return error.InvalidTransferEncoding;
        pos.* += 1;
    }
    return error.InvalidTransferEncoding;
}

inline fn isQdtext(c: u8) bool {
    return c == '\t' or c == ' ' or c == 0x21 or (c >= 0x23 and c <= 0x5b) or (c >= 0x5d and c <= 0x7e) or c >= 0x80;
}

inline fn isQuotedPairChar(c: u8) bool {
    return c == '\t' or c == ' ' or (c >= 0x21 and c <= 0x7e) or c >= 0x80;
}

test "streaming framed parser handles fragmented request without final field rescan" {
    var scratch: [256]u8 = undefined;
    var p = FramedHeadParser.init(.request, &scratch);
    var r = try p.feedRequest("POST / HTTP/1.1\r\nHost: ex");
    try std.testing.expect(r.framed == null);
    r = try p.feedRequest("ample.com\r\nContent-Length: 7\r\n\r\npayload");
    try std.testing.expectEqual(@as(u64, 7), r.framed.?.framing.content_length);
    try std.testing.expectEqualStrings("POST", r.framed.?.head.start.request.method);
    try std.testing.expectEqual(@as(usize, 32), r.consumed);
}

test "streaming framed parser validates response fields and bodyless semantics" {
    var scratch: [256]u8 = undefined;
    var p = FramedHeadParser.init(.response, &scratch);
    const r = try p.feedResponse("HTTP/1.1 204 No Content\r\nContent-Length: 99\r\nX-Test: ok\r\n\r\nbody", "GET");
    try std.testing.expect(r.framed.?.framing == .none);
    p.reset(.response);
    try std.testing.expectError(error.InvalidHeader, p.feedResponse("HTTP/1.1 204 No Content\r\nX: bad\x01value\r\n\r\n", "GET"));
}

test "streaming framed parser survives one-byte fragmentation" {
    const request = "POST /x HTTP/1.1\r\nHost: example.com\r\nContent-Length: 3\r\n\r\n";
    var scratch: [256]u8 = undefined;
    var p = FramedHeadParser.init(.request, &scratch);
    var parsed: ?FramedHead = null;
    var pos: usize = 0;
    while (pos < request.len) {
        const r = try p.feedRequest(request[pos .. pos + 1]);
        try std.testing.expectEqual(@as(usize, 1), r.consumed);
        pos += 1;
        if (r.framed) |framed| parsed = framed;
    }
    try std.testing.expectEqualStrings("/x", parsed.?.head.start.request.target);
    try std.testing.expectEqual(@as(u64, 3), parsed.?.framing.content_length);
}

test "streaming framed parser preserves request smuggling rejection" {
    var scratch: [256]u8 = undefined;
    var p = FramedHeadParser.init(.request, &scratch);
    const wire = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n";
    try std.testing.expectError(error.AmbiguousFraming, p.feedRequest(wire));

    p.reset(.request);
    try std.testing.expectError(
        error.InvalidTransferEncoding,
        p.feedRequest("POST / HTTP/1.1\r\nTransfer-Encoding: chunked, gzip\r\n\r\n"),
    );
}

test "streaming framed parser matches bodyless response framing semantics" {
    var scratch: [256]u8 = undefined;
    var p = FramedHeadParser.init(.response, &scratch);
    // Transfer-Encoding grammar is irrelevant to a 204 response, but field syntax
    // remains validated exactly like the contiguous response parser.
    const wire = "HTTP/1.1 204 No Content\r\nTransfer-Encoding: ???\r\nContent-Length: 12\r\n\r\n";
    const r = try p.feedResponse(wire, "GET");
    try std.testing.expect(r.framed.?.framing == .none);
    try std.testing.expect((try parseResponse(wire, "GET")).?.framing == .none);
}

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

test "incremental framed request avoids a second header traversal" {
    var scratch: [256]u8 = undefined;
    var p = HeadParser.init(.request, &scratch);
    const first = try p.feedRequest("POST / HTTP/1.1\r\nHost: example.com\r\n");
    try std.testing.expect(first.framed == null);
    const second = try p.feedRequest("Content-Length: 7\r\n\r\npayload");
    try std.testing.expectEqual(@as(u64, 7), second.framed.?.framing.content_length);
    try std.testing.expectEqualStrings("POST", second.framed.?.head.start.request.method);
}

test "zero-copy parse leaves body in caller buffer" {
    const wire = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\nbody";
    const r = (try parse(.request, wire)).?;
    try std.testing.expectEqualStrings("GET", r.head.start.request.method);
    try std.testing.expectEqualStrings("body", wire[r.consumed..]);
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

test "reject control bytes in HTTP/1 field values" {
    var scratch: [128]u8 = undefined;
    var p = HeadParser.init(.request, &scratch);
    try std.testing.expectError(error.InvalidHeader, p.feed("GET / HTTP/1.1\r\nX-Test: bad\x01value\r\n\r\n"));
}

test "reject controls in HTTP/1 start lines" {
    try std.testing.expectError(error.InvalidStartLine, parse(.request, "GET /bad\x01path HTTP/1.1\r\n\r\n"));
    try std.testing.expectError(error.InvalidStartLine, parse(.response, "HTTP/1.1 200 bad\x01reason\r\n\r\n"));
}

test "bodyless response fast path still validates fields" {
    try std.testing.expectError(
        error.InvalidHeader,
        parseResponse("HTTP/1.1 204 No Content\r\nX-Test: bad\x01value\r\n\r\n", "GET"),
    );
}

test "one-pass request parser stops before body and handles incomplete heads" {
    const wire = "POST /x HTTP/1.1\r\nHost: example.com\r\nContent-Length: 3\r\n\r\nabc";
    const parsed = (try parseRequest(wire)).?;
    try std.testing.expectEqual(@as(u64, 3), parsed.framing.content_length);
    try std.testing.expectEqualStrings("abc", wire[parsed.consumed..]);
    try std.testing.expect((try parseRequest(wire[0 .. parsed.consumed - 1])) == null);
}

test "one-pass response parser preserves HEAD body semantics" {
    const parsed = (try parseResponse("HTTP/1.1 200 OK\r\nContent-Length: 99\r\nX-Test: ok\r\n\r\n", "HEAD")).?;
    try std.testing.expect(parsed.framing == .none);
}


test "transfer encoding handles quoted commas" {
    const r = (try parseRequest("POST / HTTP/1.1\r\nTransfer-Encoding: foo; p=\"a,b\", chunked\r\n\r\n")).?;
    try std.testing.expect(r.framing == .chunked);
    try std.testing.expectError(error.InvalidTransferEncoding, parseRequest("POST / HTTP/1.1\r\nTransfer-Encoding: foo; p=, chunked\r\n\r\n"));
}

test "HTTP/1.0 rejects transfer encoding" {
    try std.testing.expectError(error.InvalidTransferEncoding, parseRequest("POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n"));
    try std.testing.expectError(error.InvalidTransferEncoding, parseResponse("HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", "GET"));
}

test "response status line requires separator after status code" {
    try std.testing.expectError(error.InvalidStartLine, parse(.response, "HTTP/1.1 200\r\n\r\n"));
    const r = (try parse(.response, "HTTP/1.1 200 \r\n\r\n")).?;
    try std.testing.expectEqualStrings("", r.head.start.response.reason);
}
