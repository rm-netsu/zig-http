const std = @import("std");
const common = @import("../common.zig");
const head = @import("head.zig");

pub const RequestError = error{
    InvalidRequestTarget,
    MissingHost,
    MultipleHost,
    InvalidHost,
};

pub const ConnectionError = error{InvalidConnectionHeader};

pub const RequestTargetForm = enum {
    origin,
    absolute,
    authority,
    asterisk,
};

pub const RequestInfo = struct {
    target_form: RequestTargetForm,
    host: ?[]const u8,
};

pub const Persistence = enum {
    persistent,
    close,
};

/// Validate HTTP/1 request semantics that intentionally sit above the raw
/// syntax/framing parser. This keeps `head.parseRequest` useful for proxies,
/// diagnostics, and callers that want to apply their own policy while giving
/// normal servers the HTTP-required request-target and Host checks.
pub fn validateRequest(h: head.Head) (head.Error || RequestError)!RequestInfo {
    const request = switch (h.start) {
        .request => |request| request,
        else => return error.InvalidRequestTarget,
    };

    const form = try classifyRequestTarget(request.method, request.target);

    var it = h.headerIterator();
    var host: ?[]const u8 = null;
    var host_count: u8 = 0;
    while (try it.next()) |field| {
        if (!common.eqlHeaderName(field.name, "host")) continue;
        if (host_count == std.math.maxInt(u8)) return error.MultipleHost;
        host_count += 1;
        if (host_count != 1) return error.MultipleHost;
        if (!validHost(field.value)) return error.InvalidHost;
        host = field.value;
    }

    if (h.version == .http_1_1 and host_count == 0) return error.MissingHost;
    return .{ .target_form = form, .host = host };
}

pub fn classifyRequestTarget(method: []const u8, target: []const u8) RequestError!RequestTargetForm {
    if (target.len == 0) return error.InvalidRequestTarget;

    if (std.mem.eql(u8, target, "*")) {
        if (!std.ascii.eqlIgnoreCase(method, "OPTIONS")) return error.InvalidRequestTarget;
        return .asterisk;
    }

    if (std.ascii.eqlIgnoreCase(method, "CONNECT")) {
        if (!validAuthorityForm(target)) return error.InvalidRequestTarget;
        return .authority;
    }

    if (target[0] == '/') {
        if (std.mem.indexOfScalar(u8, target, '#') != null) return error.InvalidRequestTarget;
        return .origin;
    }

    if (absoluteUriSchemeEnd(target)) |scheme_end| {
        if (scheme_end + 1 == target.len or std.mem.indexOfScalar(u8, target, '#') != null)
            return error.InvalidRequestTarget;
        return .absolute;
    }

    return error.InvalidRequestTarget;
}

/// Determine HTTP/1 connection persistence from the protocol version and
/// Connection field values. This is advisory protocol state only: the caller
/// still owns transport closure and reuse policy.
pub fn persistence(h: head.Head) (head.Error || ConnectionError)!Persistence {
    var close = false;
    var keep_alive = false;
    var it = h.headerIterator();
    while (try it.next()) |field| {
        if (!common.eqlHeaderName(field.name, "connection")) continue;
        var rest = field.value;
        while (true) {
            const comma = std.mem.indexOfScalar(u8, rest, ',');
            const option = common.trimOws(if (comma) |index| rest[0..index] else rest);
            if (!common.isToken(option)) return error.InvalidConnectionHeader;
            if (std.ascii.eqlIgnoreCase(option, "close")) close = true;
            if (std.ascii.eqlIgnoreCase(option, "keep-alive")) keep_alive = true;
            if (comma) |index| rest = rest[index + 1 ..] else break;
        }
    }

    return switch (h.version) {
        .http_1_1 => if (close) .close else .persistent,
        .http_1_0 => if (keep_alive and !close) .persistent else .close,
    };
}

fn absoluteUriSchemeEnd(target: []const u8) ?usize {
    if (target.len < 2 or !std.ascii.isAlphabetic(target[0])) return null;
    var pos: usize = 1;
    while (pos < target.len) : (pos += 1) switch (target[pos]) {
        'A'...'Z', 'a'...'z', '0'...'9', '+', '-', '.' => {},
        ':' => return pos,
        else => return null,
    };
    return null;
}

fn validAuthorityForm(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse return false;
        if (close <= 1 or close + 2 > value.len or value[close + 1] != ':') return false;
        if (!validIpLiteral(value[1..close])) return false;
        return validRequiredPort(value[close + 2 ..]);
    }

    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return false;
    if (colon == 0 or std.mem.indexOfScalar(u8, value[0..colon], ':') != null) return false;
    if (!validRegName(value[0..colon])) return false;
    return validRequiredPort(value[colon + 1 ..]);
}

fn validHost(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse return false;
        if (close <= 1 or !validIpLiteral(value[1..close])) return false;
        if (close + 1 == value.len) return true;
        if (value[close + 1] != ':') return false;
        return validPort(value[close + 2 ..]);
    }

    const colon = std.mem.lastIndexOfScalar(u8, value, ':');
    const host_part = if (colon) |index| value[0..index] else value;
    if (std.mem.indexOfScalar(u8, host_part, ':') != null) return false;
    if (!validRegName(host_part)) return false;
    return if (colon) |index| validPort(value[index + 1 ..]) else true;
}

fn validRegName(value: []const u8) bool {
    var pos: usize = 0;
    while (pos < value.len) : (pos += 1) switch (value[pos]) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => {},
        '%' => {
            if (pos + 2 >= value.len or !std.ascii.isHex(value[pos + 1]) or !std.ascii.isHex(value[pos + 2])) return false;
            pos += 2;
        },
        else => return false,
    };
    return true;
}

fn validIpLiteral(value: []const u8) bool {
    if (validIpvFuture(value)) return true;
    _ = std.Io.net.Ip6Address.parse(value, 0) catch return false;
    return true;
}

fn validIpvFuture(value: []const u8) bool {
    if (value.len < 4 or (value[0] != 'v' and value[0] != 'V')) return false;
    var pos: usize = 1;
    const hex_start = pos;
    while (pos < value.len and std.ascii.isHex(value[pos])) pos += 1;
    if (pos == hex_start or pos == value.len or value[pos] != '.') return false;
    pos += 1;
    const data_start = pos;
    while (pos < value.len) : (pos += 1) switch (value[pos]) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':' => {},
        else => return false,
    };
    return pos != data_start;
}

fn validRequiredPort(value: []const u8) bool {
    return value.len != 0 and validPort(value);
}

fn validPort(value: []const u8) bool {
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "request semantics validate Host and request target forms" {
    const origin = (try head.parseRequest("GET /x?q=1 HTTP/1.1\r\nHost: example.com\r\n\r\n")).?;
    try std.testing.expectEqual(RequestTargetForm.origin, (try validateRequest(origin.head)).target_form);

    const absolute = (try head.parseRequest("GET http://example.com/x HTTP/1.1\r\nHost: ignored.example\r\n\r\n")).?;
    try std.testing.expectEqual(RequestTargetForm.absolute, (try validateRequest(absolute.head)).target_form);

    const connect = (try head.parseRequest("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\n\r\n")).?;
    try std.testing.expectEqual(RequestTargetForm.authority, (try validateRequest(connect.head)).target_form);

    const options = (try head.parseRequest("OPTIONS * HTTP/1.1\r\nHost: example.com\r\n\r\n")).?;
    try std.testing.expectEqual(RequestTargetForm.asterisk, (try validateRequest(options.head)).target_form);
}

test "request semantics reject missing duplicate and invalid Host" {
    const missing = (try head.parseRequest("GET / HTTP/1.1\r\nX: y\r\n\r\n")).?;
    try std.testing.expectError(error.MissingHost, validateRequest(missing.head));

    const duplicate = (try head.parseRequest("GET / HTTP/1.1\r\nHost: a\r\nHost: a\r\n\r\n")).?;
    try std.testing.expectError(error.MultipleHost, validateRequest(duplicate.head));

    const invalid = (try head.parseRequest("GET / HTTP/1.1\r\nHost: bad host\r\n\r\n")).?;
    try std.testing.expectError(error.InvalidHost, validateRequest(invalid.head));
}

test "request semantics validate bracketed IPv6 and IPvFuture hosts" {
    const ipv6 = (try head.parseRequest("GET / HTTP/1.1\r\nHost: [2001:db8::1]:443\r\n\r\n")).?;
    _ = try validateRequest(ipv6.head);

    const future = (try head.parseRequest("GET / HTTP/1.1\r\nHost: [v1.fe80::a]:443\r\n\r\n")).?;
    _ = try validateRequest(future.head);

    const invalid = (try head.parseRequest("GET / HTTP/1.1\r\nHost: [:::]:443\r\n\r\n")).?;
    try std.testing.expectError(error.InvalidHost, validateRequest(invalid.head));
}

test "request semantics reject method-target mismatches" {
    const connect = (try head.parseRequest("CONNECT /wrong HTTP/1.1\r\nHost: example.com\r\n\r\n")).?;
    try std.testing.expectError(error.InvalidRequestTarget, validateRequest(connect.head));

    const star = (try head.parseRequest("GET * HTTP/1.1\r\nHost: example.com\r\n\r\n")).?;
    try std.testing.expectError(error.InvalidRequestTarget, validateRequest(star.head));

    const authority = (try head.parseRequest("GET example.com HTTP/1.1\r\nHost: example.com\r\n\r\n")).?;
    try std.testing.expectError(error.InvalidRequestTarget, validateRequest(authority.head));
}

test "HTTP persistence follows version and Connection options" {
    const h11 = (try head.parse(.request, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")).?.head;
    try std.testing.expectEqual(Persistence.persistent, try persistence(h11));

    const close = (try head.parse(.request, "GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive, close\r\n\r\n")).?.head;
    try std.testing.expectEqual(Persistence.close, try persistence(close));

    const h10 = (try head.parse(.request, "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")).?.head;
    try std.testing.expectEqual(Persistence.persistent, try persistence(h10));
}
