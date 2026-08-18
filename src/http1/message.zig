const std = @import("std");
const common = @import("../common.zig");
const uri = @import("../uri.zig");
const head = @import("head.zig");
const semantics = @import("semantics.zig");

/// Request-method semantics that HTTP/1 response framing needs to retain across
/// pipelined requests. Arbitrary extension methods collapse to `.other`; only
/// HEAD and CONNECT have special response-body semantics.
pub const RequestKind = enum(u2) {
    other,
    head,
    connect,

    pub fn from(method: []const u8) RequestKind {
        if (std.ascii.eqlIgnoreCase(method, "HEAD")) return .head;
        if (std.ascii.eqlIgnoreCase(method, "CONNECT")) return .connect;
        return .other;
    }

    pub fn canonicalMethod(self: RequestKind) []const u8 {
        return switch (self) {
            .other => "GET",
            .head => "HEAD",
            .connect => "CONNECT",
        };
    }
};

pub const BuildError = semantics.RequestError || error{
    TooManyFields,
    DuplicateHost,
    InvalidRequestTarget,
};

/// Typed HTTP/1 request-head builder. It keeps Host/request-target composition
/// explicit while removing the most common source of invalid HTTP/1.1 heads:
/// forgetting Host or manually duplicating it in a regular-field list.
///
/// `build` is allocation-free and writes Header descriptors into caller-owned
/// storage; all byte slices continue to borrow the request and regular fields.
pub const RequestFields = struct {
    version: head.Version = .http_1_1,
    method: []const u8,
    target: []const u8,
    host: ?[]const u8,

    pub fn origin(method: []const u8, target: []const u8, host: []const u8) RequestFields {
        return .{ .method = method, .target = target, .host = host };
    }

    pub fn asterisk(host: []const u8) RequestFields {
        return .{ .method = "OPTIONS", .target = "*", .host = host };
    }

    pub fn connect(authority: []const u8) RequestFields {
        return .{ .method = "CONNECT", .target = authority, .host = authority };
    }

    /// Build absolute-form and derive Host from the URI authority. Generic
    /// absolute URIs without authority use the empty Host value required by the
    /// current strict send-side semantic validator.
    pub fn absolute(method: []const u8, target: []const u8) BuildError!RequestFields {
        const parsed = uri.validateAbsolute(target) orelse return error.InvalidRequestTarget;
        const host = if (parsed.authority) |authority| authority.host_port else "";
        return .{ .method = method, .target = target, .host = host };
    }

    /// Escape hatch for HTTP/1.0 or intentionally custom request composition.
    /// The resulting field section still goes through the normal semantic
    /// validator in `build`.
    pub fn raw(version: head.Version, method: []const u8, target: []const u8, host: ?[]const u8) RequestFields {
        return .{ .version = version, .method = method, .target = target, .host = host };
    }

    pub inline fn kind(self: RequestFields) RequestKind {
        return RequestKind.from(self.method);
    }

    pub fn build(self: RequestFields, out: []common.Header, regular_fields: []const common.Header) BuildError![]const common.Header {
        const extra: usize = if (self.host != null) 1 else 0;
        if (regular_fields.len + extra > out.len) return error.TooManyFields;

        if (self.host != null) {
            for (regular_fields) |field| {
                if (common.eqlHeaderName(field.name, "host")) return error.DuplicateHost;
            }
        }

        var index: usize = 0;
        if (self.host) |host| {
            out[index] = .{ .name = "host", .value = host };
            index += 1;
        }
        @memcpy(out[index..][0..regular_fields.len], regular_fields);
        index += regular_fields.len;

        _ = try semantics.validateRequestFields(self.version, self.method, self.target, out[0..index]);
        return out[0..index];
    }
};

/// Typed HTTP/1 response start-line parameters for the high-level wrapper.
/// Reason phrases remain caller-selected because they are presentation text,
/// not status-code semantics, and empty reason phrases are valid HTTP/1 wire.
pub const ResponseFields = struct {
    version: head.Version = .http_1_1,
    status: u16,
    reason: []const u8,

    pub fn init(status: u16, reason: []const u8) ResponseFields {
        return .{ .status = status, .reason = reason };
    }
};

pub inline fn header(name: []const u8, value: []const u8) common.Header {
    return .{ .name = name, .value = value };
}

/// Canonical request field for the only expectation defined by RFC 9110. The
/// caller still chooses framing/content and whether it waits before sending.
pub inline fn expectContinue() common.Header {
    return .{ .name = "expect", .value = "100-continue" };
}

/// Canonical pair required to advertise or select an HTTP/1.1 Upgrade.
/// `protocols` is the comma-separated protocol list/value retained by caller.
pub inline fn upgrade(protocols: []const u8) [2]common.Header {
    return .{
        .{ .name = "connection", .value = "Upgrade" },
        .{ .name = "upgrade", .value = protocols },
    };
}

test "typed request builder supplies Host and classifies response semantics" {
    var storage: [4]common.Header = undefined;
    const request = RequestFields.origin("HEAD", "/resource", "example.com");
    const fields = try request.build(&storage, &.{header("accept", "*/*")});
    try std.testing.expectEqual(RequestKind.head, request.kind());
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("host", fields[0].name);
    try std.testing.expectEqualStrings("example.com", fields[0].value);
}

test "typed absolute and CONNECT builders derive Host" {
    var storage: [2]common.Header = undefined;
    const absolute = try RequestFields.absolute("GET", "http://example.com:8080/a");
    const absolute_fields = try absolute.build(&storage, &.{});
    try std.testing.expectEqualStrings("example.com:8080", absolute_fields[0].value);

    const connect_request = RequestFields.connect("example.com:443");
    const connect_fields = try connect_request.build(&storage, &.{});
    try std.testing.expectEqualStrings("example.com:443", connect_fields[0].value);
    try std.testing.expectEqual(RequestKind.connect, connect_request.kind());
}

test "typed request builder rejects duplicate Host before serialization" {
    var storage: [4]common.Header = undefined;
    const request = RequestFields.origin("GET", "/", "example.com");
    try std.testing.expectError(error.DuplicateHost, request.build(&storage, &.{header("Host", "other.example")}));
}

test "Expect and Upgrade helpers generate canonical fields" {
    const expect = expectContinue();
    try std.testing.expectEqualStrings("expect", expect.name);
    try std.testing.expectEqualStrings("100-continue", expect.value);

    const fields = upgrade("websocket");
    try std.testing.expectEqualStrings("connection", fields[0].name);
    try std.testing.expectEqualStrings("Upgrade", fields[0].value);
    try std.testing.expectEqualStrings("upgrade", fields[1].name);
    try std.testing.expectEqualStrings("websocket", fields[1].value);
}
