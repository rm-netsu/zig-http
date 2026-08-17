const std = @import("std");
const common = @import("../common.zig");
const uri = @import("../uri.zig");

pub const Kind = enum { request, response, trailers };

pub const RequestTarget = struct {
    const Scheme = enum(u2) { none, http, https, other };

    method_connect: bool = false,
    method_options: bool = false,
    scheme: Scheme = .none,
    path_seen: bool = false,
    path_empty: bool = false,
    path_asterisk: bool = false,
    path_starts_slash: bool = false,
    authority_seen: bool = false,
    authority_empty_host: bool = false,
    authority_userinfo: bool = false,
    authority_has_port: bool = false,

    pub fn method(self: *RequestTarget, value: []const u8) error{InvalidHeader}!void {
        self.method_connect = std.mem.eql(u8, value, "CONNECT");
        self.method_options = std.mem.eql(u8, value, "OPTIONS");
    }

    pub fn schemeField(self: *RequestTarget, value: []const u8) error{InvalidHeader}!void {
        if (!uri.validScheme(value)) return error.InvalidHeader;
        self.scheme = if (std.ascii.eqlIgnoreCase(value, "http"))
            .http
        else if (std.ascii.eqlIgnoreCase(value, "https"))
            .https
        else
            .other;
    }

    pub fn pathField(self: *RequestTarget, value: []const u8) error{InvalidHeader}!void {
        const info = uri.validatePathQuery(value) orelse return error.InvalidHeader;
        self.path_seen = true;
        self.path_empty = info.path_empty;
        self.path_asterisk = info.asterisk;
        self.path_starts_slash = info.starts_slash;
    }

    pub fn authorityField(self: *RequestTarget, value: []const u8) error{InvalidHeader}!void {
        const info = uri.validateAuthority(value) orelse return error.InvalidHeader;
        self.authority_seen = true;
        self.authority_empty_host = info.empty_host;
        self.authority_userinfo = info.has_userinfo;
        self.authority_has_port = info.has_port;
    }

    pub fn finish(self: RequestTarget, extended_connect: bool) error{InvalidHeader}!void {
        if (self.method_connect and !extended_connect) {
            // Traditional CONNECT carries authority-form only: host and a
            // required decimal port, with no URI scheme/path pseudo-fields.
            if (!self.authority_seen or self.scheme != .none or self.path_seen or
                self.authority_empty_host or self.authority_userinfo or !self.authority_has_port)
                return error.InvalidHeader;
            return;
        }

        if (self.scheme == .none or !self.path_seen) return error.InvalidHeader;

        if (self.path_asterisk and !self.method_options) return error.InvalidHeader;
        if (self.path_asterisk and self.authority_seen) return error.InvalidHeader;

        const http_scheme = self.scheme == .http or self.scheme == .https;
        if (http_scheme) {
            if (self.path_empty) return error.InvalidHeader;
            if (!self.path_asterisk and !self.path_starts_slash) return error.InvalidHeader;
            if (self.authority_seen and (self.authority_empty_host or self.authority_userinfo))
                return error.InvalidHeader;
        } else if (self.authority_seen) {
            // RFC 3986 hier-part with authority permits only path-abempty.
            if (!self.path_empty and !self.path_starts_slash) return error.InvalidHeader;
        }
    }
};

pub const Validator = struct {
    kind: Kind,
    regular_seen: bool = false,
    method_seen: bool = false,
    scheme_seen: bool = false,
    path_seen: bool = false,
    authority_seen: bool = false,
    status_seen: bool = false,
    method_connect: bool = false,
    protocol_seen: bool = false,
    request_target: RequestTarget = .{},
    /// Parsed Content-Length for the current initial field section. Keeping
    /// this on the ephemeral validator lets Session surface HTTP message
    /// semantics without adding per-stream storage to the protocol engine.
    content_length: ?u64 = null,

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
                    try self.request_target.pathField(h.value);
                    self.path_seen = true;
                },
                9 => {
                    if (!std.mem.eql(u8, h.name, ":protocol") or self.kind != .request or self.protocol_seen or !common.isToken(h.value))
                        return error.InvalidHeader;
                    self.protocol_seen = true;
                },
                10 => {
                    if (!std.mem.eql(u8, h.name, ":authority") or self.kind != .request or self.authority_seen)
                        return error.InvalidHeader;
                    try self.request_target.authorityField(h.value);
                    self.authority_seen = true;
                },
                7 => switch (h.name[1]) {
                    'm' => {
                        if (!std.mem.eql(u8, h.name, ":method") or self.kind != .request or self.method_seen or !common.isToken(h.value))
                            return error.InvalidHeader;
                        self.method_seen = true;
                        self.method_connect = std.mem.eql(u8, h.value, "CONNECT");
                        try self.request_target.method(h.value);
                    },
                    's' => switch (h.name[2]) {
                        'c' => {
                            if (!std.mem.eql(u8, h.name, ":scheme") or self.kind != .request or self.scheme_seen)
                                return error.InvalidHeader;
                            try self.request_target.schemeField(h.value);
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
            14 => if (std.mem.eql(u8, h.name, "content-length")) {
                if (self.kind == .trailers) return error.InvalidHeader;
                const length = parseContentLength(h.value) orelse return error.InvalidHeader;
                if (self.content_length) |previous| {
                    if (previous != length) return error.InvalidHeader;
                } else {
                    self.content_length = length;
                }
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
                    if (self.protocol_seen) {
                        // RFC 8441 Extended CONNECT retains normal URI pseudo-
                        // headers; :protocol itself is single-valued above.
                        if (!self.scheme_seen or !self.path_seen) return error.InvalidHeader;
                    } else if (!self.authority_seen or self.scheme_seen or self.path_seen) {
                        return error.InvalidHeader;
                    }
                } else {
                    if (self.protocol_seen or !self.scheme_seen or !self.path_seen) return error.InvalidHeader;
                }
                try self.request_target.finish(self.protocol_seen);
            },
            .response => if (!self.status_seen) return error.InvalidHeader,
            .trailers => {},
        }
    }

    pub inline fn extendedConnect(self: Validator) bool {
        return self.kind == .request and self.method_connect and self.protocol_seen;
    }
};

/// Caller-owned HTTP message-body length validation. HTTP/2 framing knows the
/// bytes carried by DATA, but retaining application message metadata for every
/// stream is policy/state ownership that Session deliberately leaves outside
/// the connection engine. Consumers that care about Content-Length semantics
/// can keep this tiny helper next to their own stream/application record.
pub const BodyLength = struct {
    expected: ?u64 = null,
    received: u64 = 0,

    pub inline fn init(expected: ?u64) BodyLength {
        return .{ .expected = expected };
    }

    pub fn receive(self: *BodyLength, byte_count: usize, end_stream: bool) error{Protocol}!void {
        const count: u64 = @intCast(byte_count);
        self.received = std.math.add(u64, self.received, count) catch return error.Protocol;
        if (self.expected) |expected| {
            if (self.received > expected) return error.Protocol;
            if (end_stream and self.received != expected) return error.Protocol;
        }
    }

    pub fn finish(self: BodyLength) error{Protocol}!void {
        if (self.expected) |expected| {
            if (self.received != expected) return error.Protocol;
        }
    }
};

fn parseContentLength(value: []const u8) ?u64 {
    if (value.len == 0) return null;
    var result: u64 = 0;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return null;
        result = std.math.mul(u64, result, 10) catch return null;
        result = std.math.add(u64, result, c - '0') catch return null;
    }
    return result;
}

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

test "HTTP/2 HTTP-scheme path cannot be empty" {
    var v = Validator.init(.request);
    try v.field(.{ .name = ":method", .value = "GET" });
    try v.field(.{ .name = ":scheme", .value = "https" });
    try v.field(.{ .name = ":path", .value = "" });
    try std.testing.expectError(error.InvalidHeader, v.finish());

    var custom = Validator.init(.request);
    try custom.field(.{ .name = ":method", .value = "GET" });
    try custom.field(.{ .name = ":scheme", .value = "urn" });
    try custom.field(.{ .name = ":path", .value = "" });
    try custom.finish();
}

test "HTTP/2 request target validates scheme path and authority semantics" {
    var bad_scheme = Validator.init(.request);
    try bad_scheme.field(.{ .name = ":method", .value = "GET" });
    try std.testing.expectError(error.InvalidHeader, bad_scheme.field(.{ .name = ":scheme", .value = "1http" }));

    var userinfo = Validator.init(.request);
    try userinfo.field(.{ .name = ":method", .value = "GET" });
    try userinfo.field(.{ .name = ":scheme", .value = "https" });
    try userinfo.field(.{ .name = ":path", .value = "/" });
    try userinfo.field(.{ .name = ":authority", .value = "user@example.com" });
    try std.testing.expectError(error.InvalidHeader, userinfo.finish());

    var empty_host = Validator.init(.request);
    try empty_host.field(.{ .name = ":method", .value = "GET" });
    try empty_host.field(.{ .name = ":scheme", .value = "http" });
    try empty_host.field(.{ .name = ":path", .value = "/" });
    try empty_host.field(.{ .name = ":authority", .value = ":80" });
    try std.testing.expectError(error.InvalidHeader, empty_host.finish());

    var relative = Validator.init(.request);
    try relative.field(.{ .name = ":method", .value = "GET" });
    try relative.field(.{ .name = ":scheme", .value = "https" });
    try relative.field(.{ .name = ":path", .value = "relative" });
    try std.testing.expectError(error.InvalidHeader, relative.finish());

    var fragment = Validator.init(.request);
    try fragment.field(.{ .name = ":method", .value = "GET" });
    try fragment.field(.{ .name = ":scheme", .value = "https" });
    try std.testing.expectError(error.InvalidHeader, fragment.field(.{ .name = ":path", .value = "/x#frag" }));

    var encoded = Validator.init(.request);
    try encoded.field(.{ .name = ":method", .value = "GET" });
    try encoded.field(.{ .name = ":scheme", .value = "https" });
    try encoded.field(.{ .name = ":path", .value = "/a%20b?q=x/y?z" });
    try encoded.field(.{ .name = ":authority", .value = "[2001:db8::1]:443" });
    try encoded.finish();

    var custom_rootless = Validator.init(.request);
    try custom_rootless.field(.{ .name = ":method", .value = "GET" });
    try custom_rootless.field(.{ .name = ":scheme", .value = "urn" });
    try custom_rootless.field(.{ .name = ":path", .value = "example:animal" });
    try custom_rootless.finish();

    var custom_authority = Validator.init(.request);
    try custom_authority.field(.{ .name = ":method", .value = "GET" });
    try custom_authority.field(.{ .name = ":scheme", .value = "custom" });
    try custom_authority.field(.{ .name = ":path", .value = "rootless" });
    try custom_authority.field(.{ .name = ":authority", .value = "example.test" });
    try std.testing.expectError(error.InvalidHeader, custom_authority.finish());
}

test "HTTP/2 asterisk path is restricted to server-wide OPTIONS" {
    var options = Validator.init(.request);
    try options.field(.{ .name = ":method", .value = "OPTIONS" });
    try options.field(.{ .name = ":scheme", .value = "https" });
    try options.field(.{ .name = ":path", .value = "*" });
    try options.finish();

    var get = Validator.init(.request);
    try get.field(.{ .name = ":method", .value = "GET" });
    try get.field(.{ .name = ":scheme", .value = "https" });
    try get.field(.{ .name = ":path", .value = "*" });
    try std.testing.expectError(error.InvalidHeader, get.finish());

    var with_authority = Validator.init(.request);
    try with_authority.field(.{ .name = ":method", .value = "OPTIONS" });
    try with_authority.field(.{ .name = ":scheme", .value = "https" });
    try with_authority.field(.{ .name = ":path", .value = "*" });
    try with_authority.field(.{ .name = ":authority", .value = "example.com" });
    try std.testing.expectError(error.InvalidHeader, with_authority.finish());
}

test "Extended CONNECT pseudo-header rules" {
    var v = Validator.init(.request);
    try v.field(.{ .name = ":method", .value = "CONNECT" });
    try v.field(.{ .name = ":protocol", .value = "websocket" });
    try v.field(.{ .name = ":scheme", .value = "https" });
    try v.field(.{ .name = ":path", .value = "/chat" });
    try v.field(.{ .name = ":authority", .value = "example.com" });
    try v.finish();
    try std.testing.expect(v.extendedConnect());

    var missing_uri = Validator.init(.request);
    try missing_uri.field(.{ .name = ":method", .value = "CONNECT" });
    try missing_uri.field(.{ .name = ":protocol", .value = "websocket" });
    try std.testing.expectError(error.InvalidHeader, missing_uri.finish());

    var non_connect = Validator.init(.request);
    try non_connect.field(.{ .name = ":method", .value = "GET" });
    try non_connect.field(.{ .name = ":protocol", .value = "websocket" });
    try non_connect.field(.{ .name = ":scheme", .value = "https" });
    try non_connect.field(.{ .name = ":path", .value = "/" });
    try std.testing.expectError(error.InvalidHeader, non_connect.finish());

    var bad_protocol = Validator.init(.request);
    try bad_protocol.field(.{ .name = ":method", .value = "CONNECT" });
    try std.testing.expectError(error.InvalidHeader, bad_protocol.field(.{ .name = ":protocol", .value = "bad protocol" }));
}

test "CONNECT pseudo-header rules" {
    var v = Validator.init(.request);
    try v.field(.{ .name = ":method", .value = "CONNECT" });
    try v.field(.{ .name = ":authority", .value = "example.com:443" });
    try v.finish();

    var missing_port = Validator.init(.request);
    try missing_port.field(.{ .name = ":method", .value = "CONNECT" });
    try missing_port.field(.{ .name = ":authority", .value = "example.com" });
    try std.testing.expectError(error.InvalidHeader, missing_port.finish());

    var empty_port = Validator.init(.request);
    try empty_port.field(.{ .name = ":method", .value = "CONNECT" });
    try empty_port.field(.{ .name = ":authority", .value = "[2001:db8::1]:" });
    try std.testing.expectError(error.InvalidHeader, empty_port.finish());

    var userinfo = Validator.init(.request);
    try userinfo.field(.{ .name = ":method", .value = "CONNECT" });
    try userinfo.field(.{ .name = ":authority", .value = "user@example.com:443" });
    try std.testing.expectError(error.InvalidHeader, userinfo.finish());
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

test "HTTP/2 content-length parsing and duplicate validation" {
    var v = Validator.init(.request);
    try v.field(.{ .name = ":method", .value = "POST" });
    try v.field(.{ .name = ":scheme", .value = "https" });
    try v.field(.{ .name = ":path", .value = "/" });
    try v.field(.{ .name = "content-length", .value = "42" });
    try v.field(.{ .name = "content-length", .value = "42" });
    try std.testing.expectEqual(@as(?u64, 42), v.content_length);
    try std.testing.expectError(error.InvalidHeader, v.field(.{ .name = "content-length", .value = "43" }));

    var malformed = Validator.init(.trailers);
    try std.testing.expectError(error.InvalidHeader, malformed.field(.{ .name = "content-length", .value = "1" }));

    var overflow = Validator.init(.request);
    try std.testing.expectError(error.InvalidHeader, overflow.field(.{ .name = "content-length", .value = "18446744073709551616" }));
}

test "HTTP/2 body length validates DATA bytes at end stream" {
    var exact = BodyLength.init(7);
    try exact.receive(3, false);
    try exact.receive(4, true);
    try exact.finish();

    var too_long = BodyLength.init(1);
    try std.testing.expectError(error.Protocol, too_long.receive(4, true));

    var too_short = BodyLength.init(5);
    try too_short.receive(4, false);
    try std.testing.expectError(error.Protocol, too_short.finish());

    var unrestricted = BodyLength.init(null);
    try unrestricted.receive(1024, true);
    try unrestricted.finish();
}
