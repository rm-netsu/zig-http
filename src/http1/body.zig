const std = @import("std");
const common = @import("../common.zig");

pub const FixedBody = struct {
    remaining: u64,

    pub fn init(length: u64) FixedBody {
        return .{ .remaining = length };
    }

    pub fn take(self: *FixedBody, input: []const u8) []const u8 {
        const n: usize = @intCast(@min(self.remaining, input.len));
        self.remaining -= n;
        return input[0..n];
    }

    pub fn done(self: FixedBody) bool {
        return self.remaining == 0;
    }
};

pub const ChunkEvent = union(enum) {
    data: []const u8,
    trailer: common.Header,
    trailers_done,
    done,
};

pub const ChunkResult = struct {
    consumed: usize,
    event: ?ChunkEvent = null,
};

/// Zero-copy decoder for HTTP/1.1 chunked transfer coding. Complete size and
/// trailer lines are parsed directly from caller input. Only lines fragmented
/// across transport reads are copied into the bounded `line_storage` buffer.
pub const ChunkDecoder = struct {
    line_storage: []u8,
    remaining: u64 = 0,
    line_used: u32 = 0,
    state: State = .size,

    const State = enum { size, data, data_cr, data_lf, trailers, done };

    pub fn init(line_storage: []u8) ChunkDecoder {
        return .{ .line_storage = line_storage };
    }

    pub fn reset(self: *ChunkDecoder) void {
        self.state = .size;
        self.remaining = 0;
        self.line_used = 0;
    }

    pub fn feed(self: *ChunkDecoder, input: []const u8) error{ InvalidChunk, LineTooLong }!ChunkResult {
        var i: usize = 0;
        while (true) switch (self.state) {
            .done => return .{ .consumed = i, .event = .done },
            .data => {
                if (self.remaining == 0) {
                    self.state = .data_cr;
                    continue;
                }
                if (i == input.len) return .{ .consumed = i };
                const n: usize = @intCast(@min(self.remaining, input.len - i));
                const out = input[i .. i + n];
                self.remaining -= n;
                i += n;
                return .{ .consumed = i, .event = .{ .data = out } };
            },
            .data_cr => {
                if (i == input.len) return .{ .consumed = i };
                if (input[i] != '\r') return error.InvalidChunk;
                i += 1;
                self.state = .data_lf;
            },
            .data_lf => {
                if (i == input.len) return .{ .consumed = i };
                if (input[i] != '\n') return error.InvalidChunk;
                i += 1;
                self.state = .size;
            },
            .size, .trailers => {
                const line_result = try self.takeLine(input, &i);
                switch (line_result) {
                    .need_more => return .{ .consumed = i },
                    .line => |line| {
                        if (self.state == .size) {
                            self.remaining = try parseChunkSize(line);
                            self.state = if (self.remaining == 0) .trailers else .data;
                            continue;
                        }
                        if (line.len == 0) {
                            self.state = .done;
                            return .{ .consumed = i, .event = .trailers_done };
                        }
                        return .{ .consumed = i, .event = .{ .trailer = try parseTrailer(line) } };
                    },
                }
            },
        };
    }

    const LineResult = union(enum) {
        need_more,
        line: []const u8,
    };

    fn takeLine(self: *ChunkDecoder, input: []const u8, pos: *usize) error{LineTooLong}!LineResult {
        var i = pos.*;
        const buffered = @as(usize, self.line_used);

        // Handle CRLF split exactly between transport reads.
        if (buffered != 0 and self.line_storage[buffered - 1] == '\r' and i < input.len and input[i] == '\n') {
            i += 1;
            pos.* = i;
            self.line_used = 0;
            return .{ .line = self.line_storage[0 .. buffered - 1] };
        }

        if (std.mem.indexOf(u8, input[i..], "\r\n")) |rel| {
            if (buffered == 0) {
                if (rel > self.line_storage.len) return error.LineTooLong;
                const line = input[i .. i + rel];
                pos.* = i + rel + 2;
                return .{ .line = line };
            }
            if (rel > self.line_storage.len - buffered) return error.LineTooLong;
            @memcpy(self.line_storage[buffered .. buffered + rel], input[i .. i + rel]);
            const line_len = buffered + rel;
            self.line_used = 0;
            pos.* = i + rel + 2;
            return .{ .line = self.line_storage[0..line_len] };
        }

        const available = input.len - i;
        if (available > self.line_storage.len - buffered) return error.LineTooLong;
        if (available > std.math.maxInt(u32) - buffered) return error.LineTooLong;
        @memcpy(self.line_storage[buffered .. buffered + available], input[i..]);
        self.line_used = @intCast(buffered + available);
        pos.* = input.len;
        return .need_more;
    }
};

fn parseChunkSize(line: []const u8) error{InvalidChunk}!u64 {
    if (line.len == 0) return error.InvalidChunk;
    var pos: usize = 0;
    var value: u64 = 0;
    while (pos < line.len) : (pos += 1) {
        const digit: u8 = switch (line[pos]) {
            '0'...'9' => line[pos] - '0',
            'a'...'f' => line[pos] - 'a' + 10,
            'A'...'F' => line[pos] - 'A' + 10,
            else => break,
        };
        if (value > (std.math.maxInt(u64) - @as(u64, digit)) / 16) return error.InvalidChunk;
        value = value * 16 + digit;
    }
    if (pos == 0) return error.InvalidChunk;
    try validateChunkExtensions(line[pos..]);
    return value;
}

/// RFC 9112 chunk-ext validator. Extension metadata remains intentionally
/// unmaterialized: the transfer decoder only needs to validate framing and can
/// therefore stay zero-allocation. Callers that need application-specific chunk
/// extensions can inspect the original size line in a lower-level decoder.
fn validateChunkExtensions(tail: []const u8) error{InvalidChunk}!void {
    var pos: usize = 0;
    skipBws(tail, &pos);
    while (pos < tail.len) {
        if (tail[pos] != ';') return error.InvalidChunk;
        pos += 1;
        skipBws(tail, &pos);
        try scanChunkToken(tail, &pos);
        skipBws(tail, &pos);
        if (pos < tail.len and tail[pos] == '=') {
            pos += 1;
            skipBws(tail, &pos);
            if (pos == tail.len) return error.InvalidChunk;
            if (tail[pos] == '"')
                try scanChunkQuotedString(tail, &pos)
            else
                try scanChunkToken(tail, &pos);
            skipBws(tail, &pos);
        }
        if (pos < tail.len and tail[pos] != ';') return error.InvalidChunk;
    }
}

inline fn skipBws(bytes: []const u8, pos: *usize) void {
    while (pos.* < bytes.len and (bytes[pos.*] == ' ' or bytes[pos.*] == '\t')) pos.* += 1;
}

fn scanChunkToken(bytes: []const u8, pos: *usize) error{InvalidChunk}!void {
    const start = pos.*;
    while (pos.* < bytes.len and common.isTchar(bytes[pos.*])) pos.* += 1;
    if (pos.* == start) return error.InvalidChunk;
}

fn scanChunkQuotedString(bytes: []const u8, pos: *usize) error{InvalidChunk}!void {
    if (bytes[pos.*] != '"') return error.InvalidChunk;
    pos.* += 1;
    while (pos.* < bytes.len) {
        const c = bytes[pos.*];
        if (c == '"') {
            pos.* += 1;
            return;
        }
        if (c == '\\') {
            pos.* += 1;
            if (pos.* == bytes.len or !isQuotedPairChar(bytes[pos.*])) return error.InvalidChunk;
            pos.* += 1;
            continue;
        }
        if (!isQdtext(c)) return error.InvalidChunk;
        pos.* += 1;
    }
    return error.InvalidChunk;
}

inline fn isQdtext(c: u8) bool {
    return c == '\t' or c == ' ' or c == 0x21 or (c >= 0x23 and c <= 0x5b) or (c >= 0x5d and c <= 0x7e) or c >= 0x80;
}

inline fn isQuotedPairChar(c: u8) bool {
    return c == '\t' or c == ' ' or (c >= 0x21 and c <= 0x7e) or c >= 0x80;
}

fn parseTrailer(line: []const u8) error{InvalidChunk}!common.Header {
    if (line[0] == ' ' or line[0] == '\t') return error.InvalidChunk;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidChunk;
    const name = line[0..colon];
    if (!common.isToken(name)) return error.InvalidChunk;
    const value = common.trimOws(line[colon + 1 ..]);
    if (!common.isFieldValue(value)) return error.InvalidChunk;
    return .{ .name = name, .value = value };
}

test "chunk decoder streams body" {
    var line: [128]u8 = undefined;
    var d = ChunkDecoder.init(&line);
    var pos: usize = 0;
    const wire = "4\r\nWiki\r\n5\r\npedia\r\n0\r\nX-T: y\r\n\r\n";
    var out: [9]u8 = undefined;
    var used: usize = 0;
    while (pos < wire.len or d.state != .done) {
        const r = try d.feed(wire[pos..]);
        pos += r.consumed;
        if (r.event) |ev| switch (ev) {
            .data => |bytes| {
                @memcpy(out[used .. used + bytes.len], bytes);
                used += bytes.len;
            },
            .trailer => |h| try std.testing.expectEqualStrings("X-T", h.name),
            .trailers_done => {},
            .done => break,
        };
        if (r.consumed == 0 and r.event == null) return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings("Wikipedia", out[0..used]);
}

test "chunk decoder handles fragmented lines without copying complete lines" {
    var line: [32]u8 = undefined;
    var d = ChunkDecoder.init(&line);
    var r = try d.feed("a\r");
    try std.testing.expect(r.event == null);
    const second = "\n0123456789\r\n0\r\n\r\n";
    r = try d.feed(second);
    try std.testing.expectEqualStrings("0123456789", r.event.?.data);

    r = try d.feed(second[r.consumed..]);
    try std.testing.expect(r.event.? == .trailers_done);
}

test "chunk size rejects overflow and invalid extension grammar" {
    var line: [128]u8 = undefined;
    var d = ChunkDecoder.init(&line);
    try std.testing.expectError(error.InvalidChunk, d.feed("10000000000000000\r\n"));
    d.reset();
    try std.testing.expectError(error.InvalidChunk, d.feed("1;bad\x00ext\r\n"));
    d.reset();
    try std.testing.expectError(error.InvalidChunk, d.feed("1;=value\r\n"));
    d.reset();
    try std.testing.expectError(error.InvalidChunk, d.feed("1;name=\r\n"));
    d.reset();
    try std.testing.expectError(error.InvalidChunk, d.feed("1;name=bad value\r\n"));
    d.reset();
    try std.testing.expectError(error.InvalidChunk, d.feed("1;name=\"unterminated\r\n"));
}

test "chunk extensions accept RFC 9112 BWS tokens and quoted strings" {
    var line: [128]u8 = undefined;
    var d = ChunkDecoder.init(&line);
    const wire = "1 \t; foo = bar ; sig = \"a,b\\\"c\"\r\nx\r\n0 ; end\r\n\r\n";
    var result = try d.feed(wire);
    try std.testing.expectEqualStrings("x", result.event.?.data);
    result = try d.feed(wire[result.consumed..]);
    try std.testing.expect(result.event.? == .trailers_done);
}

test "line storage length remains a hard limit on zero-copy lines" {
    var line: [4]u8 = undefined;
    var d = ChunkDecoder.init(&line);
    try std.testing.expectError(error.LineTooLong, d.feed("12345\r\n"));
}
