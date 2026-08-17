const std = @import("std");

/// HTTP-facing URI syntax helpers shared by HTTP/1 request-target and HTTP/2
/// pseudo-field validation. These functions validate wire syntax only; they do
/// not perform DNS resolution, normalization, or origin-authority policy.
pub const Scheme = enum(u2) { http, https, other };

pub const AuthorityInfo = struct {
    /// Authority with any userinfo prefix removed. The slice still contains
    /// brackets around an IP literal and an optional `:port` suffix.
    host_port: []const u8,
    empty_host: bool,
    has_userinfo: bool,
    has_port: bool,
};

pub const PathInfo = struct {
    path_empty: bool,
    asterisk: bool,
    starts_slash: bool,
};

pub const AbsoluteInfo = struct {
    scheme: Scheme,
    authority: ?AuthorityInfo,
    path: PathInfo,
};

pub fn validScheme(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..]) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '+', '-', '.' => {},
        else => return false,
    };
    return true;
}

pub fn classifyScheme(value: []const u8) ?Scheme {
    if (!validScheme(value)) return null;
    if (std.ascii.eqlIgnoreCase(value, "http")) return .http;
    if (std.ascii.eqlIgnoreCase(value, "https")) return .https;
    return .other;
}

/// Validate an RFC 3986 authority and expose the host/port portion without
/// allocating. Empty host and empty port are syntactically valid in generic
/// URI authority; HTTP-specific callers decide when they are forbidden.
pub fn validateAuthority(value: []const u8) ?AuthorityInfo {
    if (std.mem.indexOfAny(u8, value, "/?#") != null) return null;
    const at = std.mem.lastIndexOfScalar(u8, value, '@');
    const host_port = if (at) |i| blk: {
        if (!validUserinfo(value[0..i])) return null;
        break :blk value[i + 1 ..];
    } else value;
    const has_userinfo = at != null;

    if (host_port.len != 0 and host_port[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return null;
        if (close <= 1 or !validIpLiteral(host_port[1..close])) return null;
        if (close + 1 != host_port.len) {
            if (host_port[close + 1] != ':' or !validPort(host_port[close + 2 ..])) return null;
        }
        return .{
            .host_port = host_port,
            .empty_host = false,
            .has_userinfo = has_userinfo,
            .has_port = close + 2 < host_port.len,
        };
    }

    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host = if (colon) |i| host_port[0..i] else host_port;
    if (std.mem.indexOfScalar(u8, host, ':') != null or !validRegName(host)) return null;
    if (colon) |i| if (!validPort(host_port[i + 1 ..])) return null;
    return .{
        .host_port = host_port,
        .empty_host = host.len == 0,
        .has_userinfo = has_userinfo,
        .has_port = if (colon) |i| host_port[i + 1 ..].len != 0 else false,
    };
}

/// Validate a path plus optional query component. Fragment identifiers are not
/// legal in HTTP request targets and are rejected here.
pub fn validatePathQuery(value: []const u8) ?PathInfo {
    if (std.mem.eql(u8, value, "*")) return .{
        .path_empty = false,
        .asterisk = true,
        .starts_slash = false,
    };
    if (std.mem.indexOfScalar(u8, value, '#') != null) return null;
    const query_at = std.mem.indexOfScalar(u8, value, '?');
    const path = if (query_at) |i| value[0..i] else value;
    const query = if (query_at) |i| value[i + 1 ..] else "";
    if (!validPath(path) or !validQuery(query)) return null;
    return .{
        .path_empty = path.len == 0,
        .asterisk = false,
        .starts_slash = path.len != 0 and path[0] == '/',
    };
}

/// Validate an RFC 3986 absolute URI used in HTTP/1 absolute-form. For the
/// built-in `http` and `https` schemes, RFC 9110's stricter authority rules are
/// applied: authority and a non-empty host are required and userinfo is rejected.
pub fn validateAbsolute(value: []const u8) ?AbsoluteInfo {
    const scheme_end = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    const scheme = classifyScheme(value[0..scheme_end]) orelse return null;
    const rest = value[scheme_end + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '#') != null) return null;

    var authority: ?AuthorityInfo = null;
    var path_query = rest;
    if (std.mem.startsWith(u8, rest, "//")) {
        const authority_end_rel = std.mem.indexOfAny(u8, rest[2..], "/?") orelse rest.len - 2;
        const authority_end = 2 + authority_end_rel;
        authority = validateAuthority(rest[2..authority_end]) orelse return null;
        path_query = rest[authority_end..];
    }

    const path = validatePathQuery(path_query) orelse return null;
    if (authority != null and !path.path_empty and !path.starts_slash) return null;

    if (scheme == .http or scheme == .https) {
        const a = authority orelse return null;
        if (a.empty_host or a.has_userinfo) return null;
    }

    return .{ .scheme = scheme, .authority = authority, .path = path };
}

fn validPath(value: []const u8) bool {
    var pos: usize = 0;
    while (pos < value.len) : (pos += 1) {
        if (value[pos] == '/') continue;
        if (!consumeUriChar(value, &pos)) return false;
    }
    return true;
}

fn validQuery(value: []const u8) bool {
    var pos: usize = 0;
    while (pos < value.len) : (pos += 1) {
        if (value[pos] == '/' or value[pos] == '?') continue;
        if (!consumeUriChar(value, &pos)) return false;
    }
    return true;
}

fn consumeUriChar(value: []const u8, pos: *usize) bool {
    const c = value[pos.*];
    switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@' => return true,
        '%' => {
            if (pos.* + 2 >= value.len or !std.ascii.isHex(value[pos.* + 1]) or !std.ascii.isHex(value[pos.* + 2])) return false;
            pos.* += 2;
            return true;
        },
        else => return false,
    }
}

fn validUserinfo(value: []const u8) bool {
    var pos: usize = 0;
    while (pos < value.len) : (pos += 1) switch (value[pos]) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':' => {},
        '%' => {
            if (pos + 2 >= value.len or !std.ascii.isHex(value[pos + 1]) or !std.ascii.isHex(value[pos + 2])) return false;
            pos += 2;
        },
        else => return false,
    };
    return true;
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

fn validPort(value: []const u8) bool {
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "absolute URI validation exposes effective authority without userinfo" {
    const http = validateAbsolute("https://example.com:8443/a?q=1").?;
    try std.testing.expectEqual(Scheme.https, http.scheme);
    try std.testing.expectEqualStrings("example.com:8443", http.authority.?.host_port);

    const generic = validateAbsolute("foo://user@example.com/path").?;
    try std.testing.expectEqualStrings("example.com", generic.authority.?.host_port);
    try std.testing.expect(generic.authority.?.has_userinfo);
}

test "HTTP absolute URI rejects invalid HTTP authority and malformed escapes" {
    try std.testing.expect(validateAbsolute("http:///x") == null);
    try std.testing.expect(validateAbsolute("https://user@example.com/x") == null);
    try std.testing.expect(validateAbsolute("http://example.com/%zz") == null);
    try std.testing.expect(validateAbsolute("urn:example:animal:ferret:nose") != null);
}
