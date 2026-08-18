const std = @import("std");
const common = @import("../common.zig");
const fields = @import("fields.zig");
const hpack = @import("hpack");

pub const BuildError = error{ BufferTooSmall, InvalidRequest, InvalidResponse };

/// RFC 9113 field-section size used by SETTINGS_MAX_HEADER_LIST_SIZE: the
/// uncompressed name length + value length + 32 bytes of per-field overhead.
/// The result saturates rather than overflowing so it remains safe for
/// attacker-controlled or synthetic slices on every target width.
pub fn fieldSectionSize(items: []const hpack.EncodedField) u64 {
    var total: u64 = 0;
    for (items) |item| {
        total = std.math.add(u64, total, @intCast(item.field.name.len)) catch return std.math.maxInt(u64);
        total = std.math.add(u64, total, @intCast(item.field.value.len)) catch return std.math.maxInt(u64);
        total = std.math.add(u64, total, 32) catch return std.math.maxInt(u64);
    }
    return total;
}

/// Concise regular-field constructor for typed HTTP/2 message builders.
pub inline fn header(name: []const u8, value: []const u8) hpack.EncodedField {
    return .{ .field = .{ .name = name, .value = value } };
}

/// Regular-field constructor with an explicit HPACK indexing policy.
pub inline fn indexedHeader(name: []const u8, value: []const u8, indexing: hpack.Indexing) hpack.EncodedField {
    return .{ .field = .{ .name = name, .value = value }, .indexing = indexing };
}

/// Typed request pseudo-field layout. The union makes traditional CONNECT and
/// RFC 8441 Extended CONNECT structurally distinct from ordinary requests, so
/// callers do not manually order or accidentally mix pseudo-fields.
pub const RequestFields = union(enum) {
    regular: Regular,
    connect: Connect,
    extended_connect: ExtendedConnect,

    pub const Regular = struct {
        method: []const u8,
        scheme: []const u8,
        authority: ?[]const u8,
        path: []const u8,
    };

    pub const Connect = struct {
        authority: []const u8,
    };

    pub const ExtendedConnect = struct {
        protocol: []const u8,
        scheme: []const u8,
        authority: []const u8,
        path: []const u8,
    };

    pub inline fn init(method: []const u8, scheme: []const u8, authority: ?[]const u8, path: []const u8) RequestFields {
        return .{ .regular = .{ .method = method, .scheme = scheme, .authority = authority, .path = path } };
    }

    pub inline fn connectTo(authority: []const u8) RequestFields {
        return .{ .connect = .{ .authority = authority } };
    }

    pub inline fn extendedConnect(protocol: []const u8, scheme: []const u8, authority: []const u8, path: []const u8) RequestFields {
        return .{ .extended_connect = .{ .protocol = protocol, .scheme = scheme, .authority = authority, .path = path } };
    }

    pub fn required(self: RequestFields, regular_count: usize) usize {
        const pseudo: usize = switch (self) {
            .regular => |value| if (value.authority == null) 3 else 4,
            .connect => 2,
            .extended_connect => 5,
        };
        return pseudo + regular_count;
    }

    /// Builds a Session-ready field slice in caller-owned storage. Regular
    /// fields retain their requested HPACK indexing policy. The resulting
    /// section is validated with the same production HTTP/2 field validator
    /// before it is returned.
    pub fn build(self: RequestFields, out: []hpack.EncodedField, regular_fields: []const hpack.EncodedField) BuildError![]const hpack.EncodedField {
        const needed = self.required(regular_fields.len);
        if (out.len < needed) return error.BufferTooSmall;

        var at: usize = 0;
        switch (self) {
            .regular => |value| {
                out[at] = header(":method", value.method);
                at += 1;
                out[at] = header(":scheme", value.scheme);
                at += 1;
                if (value.authority) |authority| {
                    out[at] = header(":authority", authority);
                    at += 1;
                }
                out[at] = header(":path", value.path);
                at += 1;
            },
            .connect => |value| {
                out[at] = header(":method", "CONNECT");
                at += 1;
                out[at] = header(":authority", value.authority);
                at += 1;
            },
            .extended_connect => |value| {
                out[at] = header(":method", "CONNECT");
                at += 1;
                out[at] = header(":protocol", value.protocol);
                at += 1;
                out[at] = header(":scheme", value.scheme);
                at += 1;
                out[at] = header(":authority", value.authority);
                at += 1;
                out[at] = header(":path", value.path);
                at += 1;
            },
        }
        @memcpy(out[at..][0..regular_fields.len], regular_fields);
        at += regular_fields.len;
        const result = out[0..at];
        validate(.request, result) catch return error.InvalidRequest;
        return result;
    }
};

/// Typed response pseudo-field builder. `init` accepts a numeric HTTP status and
/// stores its three wire digits inside the builder, so callers never hand-format
/// `:status` or place it after regular fields.
pub const ResponseFields = struct {
    status_bytes: [3]u8,

    pub fn init(status: u16) error{InvalidStatus}!ResponseFields {
        if (status < 100 or status > 599) return error.InvalidStatus;
        return .{ .status_bytes = .{
            @intCast('0' + (status / 100)),
            @intCast('0' + ((status / 10) % 10)),
            @intCast('0' + (status % 10)),
        } };
    }

    pub inline fn required(_: *const ResponseFields, regular_count: usize) usize {
        return 1 + regular_count;
    }

    pub fn build(self: *const ResponseFields, out: []hpack.EncodedField, regular_fields: []const hpack.EncodedField) BuildError![]const hpack.EncodedField {
        const needed = self.required(regular_fields.len);
        if (out.len < needed) return error.BufferTooSmall;
        out[0] = header(":status", self.status_bytes[0..]);
        @memcpy(out[1..][0..regular_fields.len], regular_fields);
        const result = out[0..needed];
        validate(.response, result) catch return error.InvalidResponse;
        return result;
    }
};

fn validate(kind: fields.Kind, items: []const hpack.EncodedField) error{InvalidHeader}!void {
    var validator = fields.Validator.init(kind);
    for (items) |item| {
        try validator.field(.{ .name = item.field.name, .value = item.field.value });
    }
    try validator.finish();
}

test "request builder orders pseudo fields and preserves regular indexing" {
    var out: [8]hpack.EncodedField = undefined;
    const request = RequestFields.init("GET", "https", "example.com", "/a");
    const built = try request.build(&out, &.{indexedHeader("authorization", "secret", .never)});
    try std.testing.expectEqual(@as(usize, 5), built.len);
    try std.testing.expectEqualStrings(":method", built[0].field.name);
    try std.testing.expectEqualStrings(":path", built[3].field.name);
    try std.testing.expectEqual(hpack.Indexing.never, built[4].indexing);
}

test "request builder keeps CONNECT shapes distinct" {
    var out: [8]hpack.EncodedField = undefined;
    const tunnel = try RequestFields.connectTo("example.com:443").build(&out, &.{});
    try std.testing.expectEqual(@as(usize, 2), tunnel.len);
    try std.testing.expectEqualStrings(":authority", tunnel[1].field.name);

    const extended = try RequestFields.extendedConnect("websocket", "https", "example.com", "/chat").build(&out, &.{});
    try std.testing.expectEqual(@as(usize, 5), extended.len);
    try std.testing.expectEqualStrings(":protocol", extended[1].field.name);
}

test "request builder rejects malformed target and host mismatch" {
    var out: [8]hpack.EncodedField = undefined;
    const bad = RequestFields.init("GET", "https", "example.com", "relative");
    try std.testing.expectError(error.InvalidRequest, bad.build(&out, &.{}));

    const good = RequestFields.init("GET", "https", "example.com", "/");
    try std.testing.expectError(error.InvalidRequest, good.build(&out, &.{header("host", "other.example")}));
}

test "response builder formats and validates numeric status" {
    var response = try ResponseFields.init(204);
    var out: [4]hpack.EncodedField = undefined;
    const built = try response.build(&out, &.{header("cache-control", "no-store")});
    try std.testing.expectEqualStrings("204", built[0].field.value);
    try std.testing.expectError(error.InvalidStatus, ResponseFields.init(99));
}

// Ensure the public helper accepts the same header octets as the common layer;
// semantic rejection remains in Validator rather than this constructor.
test "header helper is allocation free" {
    const item = header("x-test", "ok");
    const value: common.Header = .{ .name = item.field.name, .value = item.field.value };
    try std.testing.expectEqualStrings("x-test", value.name);
}

test "field section size follows RFC accounting" {
    const items = [_]hpack.EncodedField{
        header(":method", "GET"),
        header("x", "abc"),
    };
    try std.testing.expectEqual(@as(u64, 7 + 3 + 32 + 1 + 3 + 32), fieldSectionSize(&items));
}
