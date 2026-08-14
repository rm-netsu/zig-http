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
        for (h.name) |c| {
            if (c >= 'A' and c <= 'Z') return error.InvalidHeader;
            if (c == ':' and h.name[0] != ':') return error.InvalidHeader;
        }
        for (h.value) |c| if (c == 0 or c == '\r' or c == '\n') return error.InvalidHeader;

        const pseudo = h.name[0] == ':';
        if (pseudo) {
            if (self.regular_seen or self.kind == .trailers) return error.InvalidHeader;
            if (std.mem.eql(u8, h.name, ":method")) {
                if (self.kind != .request or self.method_seen) return error.InvalidHeader;
                self.method_seen = true;
                self.method_connect = std.mem.eql(u8, h.value, "CONNECT");
            } else if (std.mem.eql(u8, h.name, ":scheme")) {
                if (self.kind != .request or self.scheme_seen) return error.InvalidHeader;
                self.scheme_seen = true;
            } else if (std.mem.eql(u8, h.name, ":path")) {
                if (self.kind != .request or self.path_seen) return error.InvalidHeader;
                self.path_seen = true;
            } else if (std.mem.eql(u8, h.name, ":authority")) {
                if (self.kind != .request or self.authority_seen) return error.InvalidHeader;
                self.authority_seen = true;
            } else if (std.mem.eql(u8, h.name, ":status")) {
                if (self.kind != .response or self.status_seen) return error.InvalidHeader;
                if (h.value.len != 3) return error.InvalidHeader;
                for (h.value) |c| if (!std.ascii.isDigit(c)) return error.InvalidHeader;
                const status = std.fmt.parseInt(u16, h.value, 10) catch return error.InvalidHeader;
                if (status < 100 or status > 599) return error.InvalidHeader;
                self.status_seen = true;
            } else return error.InvalidHeader;
            return;
        }

        self.regular_seen = true;
        if (!common.isToken(h.name)) return error.InvalidHeader;
        if (common.eqlHeaderName(h.name, "connection") or
            common.eqlHeaderName(h.name, "proxy-connection") or
            common.eqlHeaderName(h.name, "keep-alive") or
            common.eqlHeaderName(h.name, "transfer-encoding") or
            common.eqlHeaderName(h.name, "upgrade")) return error.InvalidHeader;
        if (common.eqlHeaderName(h.name, "te") and !std.ascii.eqlIgnoreCase(common.trimOws(h.value), "trailers"))
            return error.InvalidHeader;
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
