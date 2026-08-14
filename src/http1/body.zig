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

/// Zero-copy decoder for HTTP/1.1 chunked transfer coding. Only chunk-size
/// lines are buffered (bounded by `line_storage`); chunk data is returned as
/// slices of caller input.
pub const ChunkDecoder = struct {
    state: State = .size,
    remaining: u64 = 0,
    line_storage: []u8,
    line_used: usize = 0,

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
                while (i < input.len) : (i += 1) {
                    if (self.line_used == self.line_storage.len) return error.LineTooLong;
                    self.line_storage[self.line_used] = input[i];
                    self.line_used += 1;
                    if (self.line_used >= 2 and self.line_storage[self.line_used - 2] == '\r' and self.line_storage[self.line_used - 1] == '\n') {
                        i += 1;
                        const line = self.line_storage[0 .. self.line_used - 2];
                        self.line_used = 0;
                        if (self.state == .size) {
                            const semi = std.mem.indexOfScalar(u8, line, ';');
                            const number = if (semi) |p| line[0..p] else line;
                            if (number.len == 0) return error.InvalidChunk;
                            const size = std.fmt.parseInt(u64, number, 16) catch return error.InvalidChunk;
                            self.remaining = size;
                            self.state = if (size == 0) .trailers else .data;
                            break;
                        } else {
                            if (line.len == 0) {
                                self.state = .done;
                                return .{ .consumed = i, .event = .trailers_done };
                            }
                            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidChunk;
                            const name = line[0..colon];
                            if (!common.isToken(name)) return error.InvalidChunk;
                            const value = common.trimOws(line[colon + 1 ..]);
                            for (value) |c| if (c == 0 or c == '\r' or c == '\n') return error.InvalidChunk;
                            return .{ .consumed = i, .event = .{ .trailer = .{ .name = name, .value = value } } };
                        }
                    }
                }
                if (i == input.len) return .{ .consumed = i };
            },
        };
    }
};

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
