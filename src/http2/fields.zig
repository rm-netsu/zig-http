const std = @import("std");
const common = @import("../common.zig");

pub const Kind = enum { request, response, trailers };

pub const Validator = struct {
    kind: Kind,
    regular_seen: bool = false,
    method_seen: bool = false,
    scheme_seen: bool = false,
    path_seen: bool = false,
    authority_seen: bool = false,
    status_seen: bool = false,
    method_connect: bool = false,

    pub fn init(kind: Kind) Validator {
        return .{ .kind = kind };
    }

    pub fn field(self: *Validator, h: common.Header) error{InvalidHeader}!void {
        if (h.name.len == 0) return error.InvalidHeader;
        if (!validFieldValue(h.value)) return error.InvalidHeader;

        if (h.name[0] == ':') {
            if (self.regular_seen or self.kind == .trailers) return error.InvalidHeader;
            switch (h.name.len) {
                5 => {
                    if (!std.mem.eql(u8, h.name, ":path") or self.kind != .request or self.path_seen)
                        return error.InvalidHeader;
                    self.path_seen = true;
                },
                10 => {
                    if (!std.mem.eql(u8, h.name, ":authority") or self.kind != .request or self.authority_seen)
                        return error.InvalidHeader;
                    self.authority_seen = true;
                },
                7 => switch (h.name[1]) {
                    'm' => {
                        if (!std.mem.eql(u8, h.name, ":method") or self.kind != .request or self.method_seen)
                            return error.InvalidHeader;
                        self.method_seen = true;
                        self.method_connect = std.mem.eql(u8, h.value, "CONNECT");
                    },
                    's' => switch (h.name[2]) {
                        'c' => {
                            if (!std.mem.eql(u8, h.name, ":scheme") or self.kind != .request or self.scheme_seen)
                                return error.InvalidHeader;
                            self.scheme_seen = true;
                        },
                        't' => {
                            if (!std.mem.eql(u8, h.name, ":status") or self.kind != .response or self.status_seen or h.value.len != 3)
                                return error.InvalidHeader;
                            const a = h.value[0];
                            const b = h.value[1];
                            const c = h.value[2];
                            if (!std.ascii.isDigit(a) or !std.ascii.isDigit(b) or !std.ascii.isDigit(c)) return error.InvalidHeader;
                            const status = @as(u16, a - '0') * 100 + @as(u16, b - '0') * 10 + @as(u16, c - '0');
                            if (status < 100 or status > 599) return error.InvalidHeader;
                            self.status_seen = true;
                        },
                        else => return error.InvalidHeader,
                    },
                    else => return error.InvalidHeader,
                },
                else => return error.InvalidHeader,
            }
            return;
        }

        // HTTP/2 requires lowercase field names. Validate lowercase token syntax
        // in the same traversal instead of scanning again through `isToken`.
        for (h.name) |c| {
            if ((c >= 'A' and c <= 'Z') or !common.isTchar(c)) return error.InvalidHeader;
        }
        self.regular_seen = true;

        switch (h.name.len) {
            2 => if (std.mem.eql(u8, h.name, "te")) {
                if (!std.ascii.eqlIgnoreCase(common.trimOws(h.value), "trailers")) return error.InvalidHeader;
            },
            7 => if (std.mem.eql(u8, h.name, "upgrade")) return error.InvalidHeader,
            10 => {
                if (std.mem.eql(u8, h.name, "connection") or std.mem.eql(u8, h.name, "keep-alive"))
                    return error.InvalidHeader;
            },
            16 => if (std.mem.eql(u8, h.name, "proxy-connection")) return error.InvalidHeader,
            17 => if (std.mem.eql(u8, h.name, "transfer-encoding")) return error.InvalidHeader,
            else => {},
        }
    }

    pub fn finish(self: Validator) error{InvalidHeader}!void {
        switch (self.kind) {
            .request => {
                if (!self.method_seen) return error.InvalidHeader;
                if (self.method_connect) {
                    if (!self.authority_seen or self.scheme_seen or self.path_seen) return error.InvalidHeader;
                } else if (!self.scheme_seen or !self.path_seen) return error.InvalidHeader;
            },
            .response => if (!self.status_seen) return error.InvalidHeader,
            .trailers => {},
        }
    }
};

fn validFieldValue(value: []const u8) bool {
    if (value.len != 0) {
        const first = value[0];
        const last = value[value.len - 1];
        if (first == ' ' or first == '\t' or last == ' ' or last == '\t') return false;
    }
    const block_len = 8;
    const Block = @Vector(block_len, u8);
    var i: usize = 0;
    while (i + block_len <= value.len) : (i += block_len) {
        const block: Block = value[i..][0..block_len].*;
        const invalid = (block == @as(Block, @splat(0))) |
            (block == @as(Block, @splat('\r'))) |
            (block == @as(Block, @splat('\n')));
        if (@reduce(.Or, invalid)) return false;
    }
    for (value[i..]) |c| if (c == 0 or c == '\r' or c == '\n') return false;
    return true;
}

test "HTTP/2 header validation" {
    var v = Validator.init(.request);
    try v.field(.{ .name = ":method", .value = "GET" });
    try v.field(.{ .name = ":scheme", .value = "https" });
    try v.field(.{ .name = ":path", .value = "/" });
    try v.field(.{ .name = "accept", .value = "*/*" });
    try v.finish();
    try std.testing.expectError(error.InvalidHeader, v.field(.{ .name = ":authority", .value = "late.example" }));
}

test "CONNECT pseudo-header rules" {
    var v = Validator.init(.request);
    try v.field(.{ .name = ":method", .value = "CONNECT" });
    try v.field(.{ .name = ":authority", .value = "example.com:443" });
    try v.finish();
}

test "HTTP/2 validator rejects uppercase and connection-specific fields" {
    var v = Validator.init(.trailers);
    try std.testing.expectError(error.InvalidHeader, v.field(.{ .name = "X-Test", .value = "ok" }));
    try std.testing.expectError(error.InvalidHeader, v.field(.{ .name = "connection", .value = "close" }));
}

test "HTTP/2 value validation covers SIMD blocks" {
    var v = Validator.init(.trailers);
    try v.field(.{ .name = "x-long", .value = "0123456789abcdef01234567" });
    try std.testing.expectError(error.InvalidHeader, v.field(.{ .name = "x-bad", .value = "0123456789abcdef\x00tail" }));
    try std.testing.expectError(error.InvalidHeader, v.field(.{ .name = "x-leading", .value = " bad" }));
    try std.testing.expectError(error.InvalidHeader, v.field(.{ .name = "x-trailing", .value = "bad\t" }));
}

test "HTTP/2 response status pseudo-header" {
    var v = Validator.init(.response);
    try v.field(.{ .name = ":status", .value = "204" });
    try v.finish();
}
