const std = @import("std");

/// HTTP-facing URI syntax helpers shared by HTTP/1 request-target and HTTP/2
/// pseudo-field validation. Validation functions inspect wire syntax only; the
/// authority comparison helper additionally applies RFC URI normalization. No
/// helper performs DNS resolution or origin-authority policy.
pub const Scheme = enum(u2) { http, https, other };

pub const AuthorityInfo = struct {
    /// Authority with any userinfo prefix removed. The slice still contains
    /// brackets around an IP literal and an optional `:port` suffix.
    host_port: []const u8,
    empty_host: bool,
    has_userinfo: bool,
    has_port: bool,
};

/// Short-lived authority capture used by HTTP/2 to defer `Host` / `:authority`
/// comparison across HPACK iterator callbacks without retaining borrowed slices.
/// Common authorities are copied verbatim into a small inline buffer and incur
/// no hashing when Host is absent. Unusually long authorities fall back to a
/// collision-resistant normalized fingerprint.
pub const HostAuthorityReference = struct {
    const inline_capacity = 40;

    data: union(enum) {
        short: struct {
            len: u8,
            bytes: [inline_capacity]u8,
        },
        fingerprint: AuthorityFingerprint,
    },
    has_userinfo: bool,

    pub fn capture(value: []const u8) ?HostAuthorityReference {
        const info = validateAuthority(value) orelse return null;
        return captureValidated(value, info);
    }

    /// Capture an authority that was already parsed by `validateAuthority`.
    /// This avoids a duplicate parse in composed validators while retaining a
    /// validating public `capture` entry point for standalone callers.
    pub fn captureValidated(value: []const u8, info: AuthorityInfo) HostAuthorityReference {
        if (value.len <= inline_capacity) {
            var bytes: [inline_capacity]u8 = undefined;
            @memcpy(bytes[0..value.len], value);
            return .{
                .data = .{ .short = .{ .len = @intCast(value.len), .bytes = bytes } },
                .has_userinfo = info.has_userinfo,
            };
        }
        return .{
            .data = .{ .fingerprint = fingerprintAuthorityInfo(info) orelse unreachable },
            .has_userinfo = info.has_userinfo,
        };
    }

    /// Compare a captured `:authority` with a Host field after URI
    /// normalization. Host never permits userinfo, so a captured authority that
    /// contains it cannot match.
    pub fn eqlHost(self: HostAuthorityReference, host: []const u8, scheme: Scheme) bool {
        const host_info = validateAuthority(host) orelse return false;
        return self.eqlHostValidated(host_info, scheme);
    }

    /// Compare against a Host value already parsed by `validateAuthority`.
    pub fn eqlHostValidated(self: HostAuthorityReference, host_info: AuthorityInfo, scheme: Scheme) bool {
        if (self.has_userinfo or host_info.has_userinfo) return false;
        return switch (self.data) {
            .short => |stored| authorityInfoEqualNormalized(
                validateAuthority(stored.bytes[0..stored.len]) orelse return false,
                host_info,
                scheme,
            ),
            .fingerprint => |stored| blk: {
                const candidate = fingerprintAuthorityInfo(host_info) orelse return false;
                break :blk stored.eql(candidate, scheme);
            },
        };
    }
};

const AuthorityFingerprint = struct {
    host: [16]u8,
    port: [16]u8,
    port_kind: PortKind,

    const PortKind = enum(u2) { absent, empty, explicit };

    fn eql(a: AuthorityFingerprint, b: AuthorityFingerprint, scheme: Scheme) bool {
        if (!std.mem.eql(u8, &a.host, &b.host)) return false;
        if (samePort(a, b)) return true;
        return switch (scheme) {
            .http => (a.isDefaultPort("80") and b.port_kind != .explicit) or
                (b.isDefaultPort("80") and a.port_kind != .explicit),
            .https => (a.isDefaultPort("443") and b.port_kind != .explicit) or
                (b.isDefaultPort("443") and a.port_kind != .explicit),
            .other => false,
        };
    }

    fn samePort(a: AuthorityFingerprint, b: AuthorityFingerprint) bool {
        if (a.port_kind != .explicit and b.port_kind != .explicit) return true;
        if (a.port_kind != .explicit or b.port_kind != .explicit) return false;
        return std.mem.eql(u8, &a.port, &b.port);
    }

    fn isDefaultPort(self: AuthorityFingerprint, comptime decimal: []const u8) bool {
        if (self.port_kind != .explicit) return false;
        return std.mem.eql(u8, &self.port, &digestDecimal(decimal));
    }
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

const HostPortParts = struct {
    host: []const u8,
    port: ?[]const u8,
};

/// Split an already validated host/port slice without repeating URI validation.
fn hostPortParts(host_port: []const u8) HostPortParts {
    if (host_port.len != 0 and host_port[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse unreachable;
        return .{
            .host = host_port[0 .. close + 1],
            .port = if (close + 1 == host_port.len) null else host_port[close + 2 ..],
        };
    }
    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':');
    return .{
        .host = if (colon) |i| host_port[0..i] else host_port,
        .port = if (colon) |i| host_port[i + 1 ..] else null,
    };
}

fn authorityInfoEqualNormalized(a: AuthorityInfo, b: AuthorityInfo, scheme: Scheme) bool {
    const ap = hostPortParts(a.host_port);
    const bp = hostPortParts(b.host_port);
    if (!hostEqualNormalized(ap.host, bp.host)) return false;
    return portEqualNormalized(ap.port, bp.port, scheme);
}

fn hostEqualNormalized(a: []const u8, b: []const u8) bool {
    const a_literal = a.len >= 2 and a[0] == '[' and a[a.len - 1] == ']';
    const b_literal = b.len >= 2 and b[0] == '[' and b[b.len - 1] == ']';
    if (a_literal != b_literal) return false;
    if (!a_literal) return regNameEqualNormalized(a, b);

    const a_value = a[1 .. a.len - 1];
    const b_value = b[1 .. b.len - 1];
    const a_future = validIpvFuture(a_value);
    const b_future = validIpvFuture(b_value);
    if (a_future != b_future) return false;
    if (a_future) return std.ascii.eqlIgnoreCase(a_value, b_value);

    const a_ip = std.Io.net.Ip6Address.parse(a_value, 0) catch return false;
    const b_ip = std.Io.net.Ip6Address.parse(b_value, 0) catch return false;
    return std.mem.eql(u8, &a_ip.bytes, &b_ip.bytes);
}

fn regNameEqualNormalized(a: []const u8, b: []const u8) bool {
    var a_iter = NormalizedRegNameIterator{ .value = a };
    var b_iter = NormalizedRegNameIterator{ .value = b };
    while (true) {
        const ac = a_iter.next();
        const bc = b_iter.next();
        if (ac == null or bc == null) return ac == null and bc == null;
        if (ac.? != bc.?) return false;
    }
}

const NormalizedRegNameIterator = struct {
    value: []const u8,
    index: usize = 0,
    pending: [2]u8 = undefined,
    pending_len: u2 = 0,
    pending_pos: u2 = 0,

    fn next(self: *NormalizedRegNameIterator) ?u8 {
        if (self.pending_pos < self.pending_len) {
            const result = self.pending[self.pending_pos];
            self.pending_pos += 1;
            return result;
        }
        self.pending_len = 0;
        self.pending_pos = 0;
        if (self.index >= self.value.len) return null;

        const c = self.value[self.index];
        if (c != '%') {
            self.index += 1;
            return std.ascii.toLower(c);
        }

        const hi = self.value[self.index + 1];
        const lo = self.value[self.index + 2];
        const decoded = (hexValue(hi) << 4) | hexValue(lo);
        self.index += 3;
        if (isUnreserved(decoded)) return std.ascii.toLower(decoded);

        // Percent-encoded reserved octets remain escaped; only hexadecimal
        // digit case is normalized. This deliberately keeps `%21` distinct
        // from a raw `!`, while treating `%2f` and `%2F` as equivalent.
        self.pending = .{ std.ascii.toUpper(hi), std.ascii.toUpper(lo) };
        self.pending_len = 2;
        return '%';
    }
};

fn portEqualNormalized(a: ?[]const u8, b: ?[]const u8, scheme: Scheme) bool {
    const a_omitted = a == null or a.?.len == 0;
    const b_omitted = b == null or b.?.len == 0;
    if (a_omitted and b_omitted) return true;
    if (!a_omitted and !b_omitted) return decimalEqual(a.?, b.?);
    const explicit = if (a_omitted) b.? else a.?;
    return switch (scheme) {
        .http => decimalEqual(explicit, "80"),
        .https => decimalEqual(explicit, "443"),
        .other => false,
    };
}

fn decimalEqual(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (ai + 1 < a.len and a[ai] == '0') ai += 1;
    while (bi + 1 < b.len and b[bi] == '0') bi += 1;
    return std.mem.eql(u8, a[ai..], b[bi..]);
}

fn fingerprintAuthorityInfo(info: AuthorityInfo) ?AuthorityFingerprint {
    const parts = hostPortParts(info.host_port);
    var result: AuthorityFingerprint = .{
        .host = undefined,
        .port = undefined,
        .port_kind = if (parts.port) |port| if (port.len == 0) .empty else .explicit else .absent,
    };

    var host_hash = std.crypto.hash.Blake3.init(.{});
    if (parts.host.len >= 2 and parts.host[0] == '[' and parts.host[parts.host.len - 1] == ']') {
        const literal = parts.host[1 .. parts.host.len - 1];
        if (validIpvFuture(literal)) {
            host_hash.update(&.{0x02});
            hashNormalizedRegName(&host_hash, literal);
        } else {
            const parsed = std.Io.net.Ip6Address.parse(literal, 0) catch return null;
            host_hash.update(&.{0x01});
            host_hash.update(&parsed.bytes);
        }
    } else {
        host_hash.update(&.{0x00});
        hashNormalizedRegName(&host_hash, parts.host);
    }
    host_hash.final(&result.host);

    switch (result.port_kind) {
        .absent, .empty => result.port = @splat(0),
        .explicit => result.port = digestDecimal(parts.port.?),
    }
    return result;
}

fn hashNormalizedRegName(hash: *std.crypto.hash.Blake3, value: []const u8) void {
    var iter = NormalizedRegNameIterator{ .value = value };
    var chunk: [64]u8 = undefined;
    var used: usize = 0;
    while (iter.next()) |c| {
        chunk[used] = c;
        used += 1;
        if (used == chunk.len) {
            hash.update(&chunk);
            used = 0;
        }
    }
    if (used != 0) hash.update(chunk[0..used]);
}

fn digestDecimal(value: []const u8) [16]u8 {
    var i: usize = 0;
    while (i + 1 < value.len and value[i] == '0') i += 1;
    var result: [16]u8 = undefined;
    std.crypto.hash.Blake3.hash(value[i..], &result, .{});
    return result;
}

fn hexValue(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => unreachable,
    };
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
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

test "authority reference preserves URI normalization semantics" {
    const https = HostAuthorityReference.capture("EXAMPLE.com:443").?;
    try std.testing.expect(https.eqlHost("example.com", .https));

    const escaped = HostAuthorityReference.capture("%65xample.com").?;
    try std.testing.expect(escaped.eqlHost("example.com", .https));

    const empty_port = HostAuthorityReference.capture("example.com:").?;
    try std.testing.expect(empty_port.eqlHost("example.com", .other));
    try std.testing.expect(empty_port.eqlHost("example.com:443", .https));

    const reserved = HostAuthorityReference.capture("%21.example").?;
    try std.testing.expect(!reserved.eqlHost("!.example", .https));
    try std.testing.expect(reserved.eqlHost("%21.example", .https));

    const ipv6 = HostAuthorityReference.capture("[2001:0db8::1]:443").?;
    try std.testing.expect(ipv6.eqlHost("[2001:db8:0:0:0:0:0:1]", .https));
}

test "long authority reference uses normalized fallback" {
    const authority = "THIS-IS-A-LONG-AUTHORITY-NAME-THAT-EXCEEDS-FORTY.example:0443";
    const matching = "this-is-a-long-authority-name-that-exceeds-forty.example:443";
    const mismatch = "this-is-a-long-authority-name-that-exceeds-forty.example:444";
    const reference = HostAuthorityReference.capture(authority).?;
    try std.testing.expect(reference.eqlHost(matching, .https));
    try std.testing.expect(!reference.eqlHost(mismatch, .https));
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
