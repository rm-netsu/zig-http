const std = @import("std");
const common = @import("../common.zig");
const uri = @import("../uri.zig");
const head = @import("head.zig");

pub const RequestError = error{
    InvalidRequestTarget,
    MissingHost,
    MultipleHost,
    InvalidHost,
    MismatchedHost,
};

pub const ResponseError = error{
    InvalidStatus,
    InvalidUpgradeResponse,
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
    /// Raw Host field value, if present. For absolute-form and CONNECT this is
    /// not the routing authority; use `effective_authority` instead.
    host: ?[]const u8,
    /// Authority HTTP semantics require the recipient to use for routing.
    /// Absolute-form and CONNECT derive it from request-target so a conflicting
    /// Host field cannot accidentally become authoritative.
    effective_authority: ?[]const u8 = null,
};

pub const ResponseInfo = struct {
    status: u16,
    protocol_switched: bool = false,
};

pub const Persistence = enum {
    persistent,
    close,
};

/// Classification of the request's Expect field. Unknown but syntactically
/// representable expectations are reported separately so servers can choose a
/// 417 response without reimplementing field scanning.
pub const Expectation = enum {
    none,
    continue_100,
    unsupported,

    pub inline fn serverAction(self: Expectation) ExpectationAction {
        return switch (self) {
            .none => .proceed,
            .continue_100 => .send_continue_or_final,
            .unsupported => .reject_417_or_handle_extension,
        };
    }
};

pub const ExpectationAction = enum {
    proceed,
    send_continue_or_final,
    reject_417_or_handle_extension,
};

pub const ExpectationError = error{InvalidExpectation};

/// Tiny client-side coordinator for Expect: 100-continue. It owns no timer;
/// callers decide when to stop waiting and call `proceedWithoutContinue()`.
pub const ContinueGate = struct {
    phase: Phase,

    pub const Phase = enum { bypass, waiting, body_allowed, final_received };

    pub inline fn init(expectation_value: Expectation) ContinueGate {
        return .{ .phase = if (expectation_value == .continue_100) .waiting else .bypass };
    }

    pub inline fn maySendBody(self: ContinueGate) bool {
        return self.phase == .bypass or self.phase == .body_allowed;
    }

    pub inline fn waiting(self: ContinueGate) bool {
        return self.phase == .waiting;
    }

    /// HTTP clients are allowed to stop waiting for 100 Continue after an
    /// application-selected delay and send the content anyway.
    pub fn proceedWithoutContinue(self: *ContinueGate) void {
        if (self.phase == .waiting) self.phase = .body_allowed;
    }

    /// Observe one response status. Other informational responses do not open
    /// the gate; 100 does, while any final response suppresses request content.
    pub fn observeStatus(self: *ContinueGate, status: u16) void {
        if (self.phase != .waiting) return;
        if (status == 100) {
            self.phase = .body_allowed;
        } else if (status >= 200) {
            self.phase = .final_received;
        }
    }
};

pub const UpgradeOfferError = head.Error || ConnectionError || error{InvalidUpgradeRequest};

/// Borrowed HTTP/1.1 Upgrade offer. It validates Connection: Upgrade and the
/// Upgrade list once, then lets applications test candidate protocols or a 101
/// selection without allocating or copying field values.
pub const UpgradeOffer = struct {
    request: head.Head,

    pub fn init(request: head.Head) UpgradeOfferError!UpgradeOffer {
        if (request.version != .http_1_1 or request.start != .request)
            return error.InvalidUpgradeRequest;

        var options: ConnectionOptions = .{};
        var saw_upgrade = false;
        var it = request.headerIterator();
        while (try it.next()) |field| {
            if (common.eqlHeaderName(field.name, "connection")) {
                try addConnectionOptions(&options, field.value, .receive);
            } else if (common.eqlHeaderName(field.name, "upgrade")) {
                const saw = scanUpgradeList(field.value, .receive) orelse return error.InvalidUpgradeRequest;
                saw_upgrade = saw_upgrade or saw;
            }
        }
        if (!options.upgrade or !saw_upgrade) return error.InvalidUpgradeRequest;
        return .{ .request = request };
    }

    /// Case-insensitive protocol-name comparison per RFC 9110; an optional
    /// protocol-version token is compared exactly.
    pub fn offers(self: UpgradeOffer, candidate: []const u8) head.Error!bool {
        if (!validProtocol(candidate)) return false;
        var it = self.request.headerIterator();
        while (try it.next()) |field| {
            if (!common.eqlHeaderName(field.name, "upgrade")) continue;
            var list = ProtocolList.init(field.value, .receive);
            while (list.next() orelse return false) |protocol| {
                if (protocolMatches(protocol, candidate)) return true;
            }
        }
        return false;
    }

    /// Validate a 101 response structurally and ensure every selected protocol
    /// appeared in the original client offer.
    pub fn validateSelection(self: UpgradeOffer, response: head.Head) (head.Error || ConnectionError || ResponseError)!void {
        try validateUpgradeResponse(response);
        var it = response.headerIterator();
        while (try it.next()) |field| {
            if (!common.eqlHeaderName(field.name, "upgrade")) continue;
            var list = ProtocolList.init(field.value, .receive);
            while (true) {
                const next = list.next() orelse break;
                const protocol = next orelse return error.InvalidUpgradeResponse;
                if (!(try self.offers(protocol))) return error.InvalidUpgradeResponse;
            }
        }
    }
};

const TargetInfo = struct {
    form: RequestTargetForm,
    authority: ?[]const u8 = null,
};

const ConnectionOptions = struct {
    close: bool = false,
    keep_alive: bool = false,
    upgrade: bool = false,
};

/// Classify Expect fields on a parsed request. HTTP/1.0 expectations are
/// ignored, matching RFC semantics. Recipient parsing tolerates a bounded
/// number of empty #rule members but rejects broken quoted-string boundaries.
pub fn requestExpectation(h: head.Head) (head.Error || ExpectationError)!Expectation {
    if (h.start != .request) return error.InvalidExpectation;
    if (h.version == .http_1_0) return .none;
    var result: Expectation = .none;
    var it = h.headerIterator();
    while (try it.next()) |field| {
        if (!common.eqlHeaderName(field.name, "expect")) continue;
        result = mergeExpectation(result, try classifyExpectationValue(field.value, .receive));
    }
    return result;
}

/// Send-side form over caller-owned fields. Empty list members are rejected so
/// the library never helps generate non-canonical Expect values.
pub fn requestExpectationFields(version: head.Version, fields: []const common.Header) ExpectationError!Expectation {
    if (version == .http_1_0) return .none;
    var result: Expectation = .none;
    for (fields) |field| {
        if (!common.eqlHeaderName(field.name, "expect")) continue;
        result = mergeExpectation(result, try classifyExpectationValue(field.value, .send));
    }
    return result;
}

fn mergeExpectation(a: Expectation, b: Expectation) Expectation {
    if (a == .unsupported or b == .unsupported) return .unsupported;
    if (a == .continue_100 or b == .continue_100) return .continue_100;
    return .none;
}

fn classifyExpectationValue(value: []const u8, mode: ListMode) ExpectationError!Expectation {
    var list = ExpectationList.init(value, mode);
    var result: Expectation = .none;
    var saw = false;
    while (try list.next()) |member| {
        saw = true;
        const name_len = tokenPrefix(member);
        if (name_len == 0) return error.InvalidExpectation;
        const name = member[0..name_len];
        const remainder = common.trimOws(member[name_len..]);
        const current: Expectation = if (std.ascii.eqlIgnoreCase(name, "100-continue") and remainder.len == 0)
            .continue_100
        else
            .unsupported;
        result = mergeExpectation(result, current);
    }
    return if (saw) result else .none;
}

fn tokenPrefix(value: []const u8) usize {
    var n: usize = 0;
    while (n < value.len and common.isTchar(value[n])) : (n += 1) {}
    return n;
}

const ExpectationList = struct {
    value: []const u8,
    mode: ListMode,
    pos: usize = 0,
    empty_count: u8 = 0,

    fn init(value: []const u8, mode: ListMode) ExpectationList {
        return .{ .value = value, .mode = mode };
    }

    fn next(self: *ExpectationList) ExpectationError!?[]const u8 {
        while (self.pos <= self.value.len) {
            const start = self.pos;
            var quote = false;
            var escaped = false;
            var end = self.value.len;
            var i = start;
            while (i < self.value.len) : (i += 1) {
                const ch = self.value[i];
                if (quote) {
                    if (escaped) {
                        escaped = false;
                    } else if (ch == '\\') {
                        escaped = true;
                    } else if (ch == '"') {
                        quote = false;
                    }
                } else if (ch == '"') {
                    quote = true;
                } else if (ch == ',') {
                    end = i;
                    break;
                }
            }
            if (quote or escaped) return error.InvalidExpectation;
            self.pos = if (end == self.value.len) self.value.len + 1 else end + 1;
            const member = common.trimOws(self.value[start..end]);
            if (member.len == 0) {
                if (self.mode == .send) return error.InvalidExpectation;
                if (self.empty_count == max_ignored_empty_list_elements) return error.InvalidExpectation;
                self.empty_count += 1;
                continue;
            }
            return member;
        }
        return null;
    }
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

    const target = try requestTargetInfo(request.method, request.target);
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
    return .{
        .target_form = target.form,
        .host = host,
        .effective_authority = switch (target.form) {
            .absolute, .authority => target.authority,
            .origin, .asterisk => host,
        },
    };
}

/// Validate request-target and Host semantics directly from caller-owned
/// fields before serializing a request. Header syntax is validated by the
/// writer/framing layer; this helper focuses on HTTP request semantics.
pub const RequestFieldsInfo = struct {
    request: RequestInfo,
    expectation: Expectation,
};

pub fn validateRequestFields(version: head.Version, method: []const u8, target_value: []const u8, headers: []const common.Header) RequestError!RequestInfo {
    return validateRequestFieldsInternal(version, method, target_value, headers, null) catch |err| switch (err) {
        error.InvalidExpectation => unreachable,
        else => |request_err| return request_err,
    };
}

/// Send-oriented semantic pass that fuses Host/request-target checks with
/// Expect classification in the same header traversal.
pub fn validateRequestFieldsWithExpectation(
    version: head.Version,
    method: []const u8,
    target_value: []const u8,
    headers: []const common.Header,
) (RequestError || ExpectationError)!RequestFieldsInfo {
    var expectation_value: Expectation = .none;
    const request = try validateRequestFieldsInternal(version, method, target_value, headers, &expectation_value);
    return .{ .request = request, .expectation = expectation_value };
}

fn validateRequestFieldsInternal(
    version: head.Version,
    method: []const u8,
    target_value: []const u8,
    headers: []const common.Header,
    expectation_out: ?*Expectation,
) (RequestError || ExpectationError)!RequestInfo {
    const target = try requestTargetInfo(method, target_value);
    var host: ?[]const u8 = null;
    var host_count: u8 = 0;
    for (headers) |field| {
        if (common.eqlHeaderName(field.name, "host")) {
            if (host_count == std.math.maxInt(u8)) return error.MultipleHost;
            host_count += 1;
            if (host_count != 1) return error.MultipleHost;
            if (!validHost(field.value)) return error.InvalidHost;
            host = field.value;
            continue;
        }
        if (expectation_out) |out| {
            if (version == .http_1_1 and common.eqlHeaderName(field.name, "expect"))
                out.* = mergeExpectation(out.*, try classifyExpectationValue(field.value, .send));
        }
    }
    if (version == .http_1_1 and host_count == 0) return error.MissingHost;
    if (version == .http_1_1 and target.form == .absolute) {
        const required_host = target.authority orelse "";
        if (!std.mem.eql(u8, host.?, required_host)) return error.MismatchedHost;
    }
    return .{
        .target_form = target.form,
        .host = host,
        .effective_authority = switch (target.form) {
            .absolute, .authority => target.authority,
            .origin, .asterisk => host,
        },
    };
}

pub fn classifyRequestTarget(method: []const u8, target: []const u8) RequestError!RequestTargetForm {
    return (try requestTargetInfo(method, target)).form;
}

fn requestTargetInfo(method: []const u8, target: []const u8) RequestError!TargetInfo {
    if (target.len == 0) return error.InvalidRequestTarget;

    if (std.mem.eql(u8, target, "*")) {
        if (!std.ascii.eqlIgnoreCase(method, "OPTIONS")) return error.InvalidRequestTarget;
        return .{ .form = .asterisk };
    }

    if (std.ascii.eqlIgnoreCase(method, "CONNECT")) {
        const authority = uri.validateAuthority(target) orelse return error.InvalidRequestTarget;
        if (authority.empty_host or authority.has_userinfo or !authority.has_port)
            return error.InvalidRequestTarget;
        return .{ .form = .authority, .authority = authority.host_port };
    }

    if (target[0] == '/') {
        const path = uri.validatePathQuery(target) orelse return error.InvalidRequestTarget;
        if (!path.starts_slash or path.asterisk) return error.InvalidRequestTarget;
        return .{ .form = .origin };
    }

    const absolute = uri.validateAbsolute(target) orelse return error.InvalidRequestTarget;
    return .{
        .form = .absolute,
        .authority = if (absolute.authority) |authority| authority.host_port else null,
    };
}

/// Validate response semantics applied by the composed HTTP/1 decoder. Raw
/// response syntax parsing remains able to inspect non-standard 3-digit codes.
pub fn validateResponse(h: head.Head) (head.Error || ConnectionError || ResponseError)!ResponseInfo {
    const response = switch (h.start) {
        .response => |response| response,
        else => return error.InvalidStatus,
    };
    if (response.status < 100 or response.status > 599) return error.InvalidStatus;
    if (response.status == 101) try validateUpgradeResponse(h);
    return .{ .status = response.status, .protocol_switched = response.status == 101 };
}

/// Send-side response semantic preflight over caller-owned fields.
pub fn validateResponseFields(version: head.Version, status: u16, headers: []const common.Header) (ConnectionError || ResponseError)!ResponseInfo {
    if (status < 100 or status > 599) return error.InvalidStatus;
    if (status == 101) try validateUpgradeResponseFields(version, headers);
    return .{ .status = status, .protocol_switched = status == 101 };
}

/// RFC 9110 Upgrade handshake validation for a 101 response. The selected
/// protocol still belongs to the application; core only verifies that the
/// response is structurally a valid connection switch.
pub fn validateUpgradeResponse(h: head.Head) (head.Error || ConnectionError || ResponseError)!void {
    const response = switch (h.start) {
        .response => |response| response,
        else => return error.InvalidUpgradeResponse,
    };
    if (response.status != 101 or h.version != .http_1_1) return error.InvalidUpgradeResponse;

    var options: ConnectionOptions = .{};
    var upgrade_seen = false;
    var it = h.headerIterator();
    while (try it.next()) |field| {
        if (common.eqlHeaderName(field.name, "connection")) {
            try addConnectionOptions(&options, field.value, .receive);
        } else if (common.eqlHeaderName(field.name, "upgrade")) {
            const saw = scanUpgradeList(field.value, .receive) orelse return error.InvalidUpgradeResponse;
            upgrade_seen = upgrade_seen or saw;
        }
    }
    if (!options.upgrade or !upgrade_seen) return error.InvalidUpgradeResponse;
}

pub fn validateUpgradeResponseFields(version: head.Version, headers: []const common.Header) (ConnectionError || ResponseError)!void {
    if (version != .http_1_1) return error.InvalidUpgradeResponse;
    var options: ConnectionOptions = .{};
    var upgrade_seen = false;
    for (headers) |field| {
        if (common.eqlHeaderName(field.name, "connection")) {
            try addConnectionOptions(&options, field.value, .send);
        } else if (common.eqlHeaderName(field.name, "upgrade")) {
            const saw = scanUpgradeList(field.value, .send) orelse return error.InvalidUpgradeResponse;
            upgrade_seen = upgrade_seen or saw;
        }
    }
    if (!options.upgrade or !upgrade_seen) return error.InvalidUpgradeResponse;
}

/// Determine HTTP/1 connection persistence from the protocol version and
/// Connection field values. This is advisory protocol state only: the caller
/// still owns transport closure and reuse policy.
pub fn persistence(h: head.Head) (head.Error || ConnectionError)!Persistence {
    var options: ConnectionOptions = .{};
    var it = h.headerIterator();
    while (try it.next()) |field| {
        if (common.eqlHeaderName(field.name, "connection"))
            try addConnectionOptions(&options, field.value, .receive);
    }
    return persistenceFromOptions(h.version, options);
}

/// Determine persistence directly from caller-owned fields. This is the
/// send-side form, so list values must satisfy sender grammar (no empty list
/// members introduced around commas).
pub fn persistenceFields(version: head.Version, headers: []const common.Header) ConnectionError!Persistence {
    var options: ConnectionOptions = .{};
    for (headers) |field| {
        if (common.eqlHeaderName(field.name, "connection"))
            try addConnectionOptions(&options, field.value, .send);
    }
    return persistenceFromOptions(version, options);
}

fn persistenceFromOptions(version: head.Version, options: ConnectionOptions) Persistence {
    return switch (version) {
        .http_1_1 => if (options.close) .close else .persistent,
        .http_1_0 => if (options.keep_alive and !options.close) .persistent else .close,
    };
}

const ListMode = enum { receive, send };
const max_ignored_empty_list_elements: u8 = 32;

fn addConnectionOptions(options: *ConnectionOptions, value: []const u8, mode: ListMode) ConnectionError!void {
    var rest = value;
    var empty_count: u8 = 0;
    const entirely_empty = common.trimOws(value).len == 0;
    while (true) {
        const comma = std.mem.indexOfScalar(u8, rest, ',');
        const option = common.trimOws(if (comma) |index| rest[0..index] else rest);
        if (option.len == 0) {
            // Connection uses #connection-option, so an entirely empty field
            // is valid. Empty members around commas are recipient tolerance
            // only; a sender is forbidden from generating them.
            if (comma != null or !entirely_empty) {
                if (mode == .send) return error.InvalidConnectionHeader;
                if (empty_count == max_ignored_empty_list_elements) return error.InvalidConnectionHeader;
                empty_count += 1;
            }
        } else {
            if (!common.isToken(option)) return error.InvalidConnectionHeader;
            if (std.ascii.eqlIgnoreCase(option, "close")) options.close = true;
            if (std.ascii.eqlIgnoreCase(option, "keep-alive")) options.keep_alive = true;
            if (std.ascii.eqlIgnoreCase(option, "upgrade")) options.upgrade = true;
        }
        if (comma) |index| rest = rest[index + 1 ..] else break;
    }
}

const ProtocolList = struct {
    rest: []const u8,
    mode: ListMode,
    empty_count: u8 = 0,
    done: bool = false,

    fn init(value: []const u8, mode: ListMode) ProtocolList {
        return .{ .rest = value, .mode = mode };
    }

    fn next(self: *ProtocolList) ??[]const u8 {
        if (self.done) return null;
        while (true) {
            const comma = std.mem.indexOfScalar(u8, self.rest, ',');
            const protocol = common.trimOws(if (comma) |index| self.rest[0..index] else self.rest);
            if (comma) |index| {
                self.rest = self.rest[index + 1 ..];
            } else {
                self.done = true;
            }
            if (protocol.len == 0) {
                if (self.mode == .send or self.empty_count == max_ignored_empty_list_elements) return @as(?[]const u8, null);
                self.empty_count += 1;
                if (self.done) return null;
                continue;
            }
            if (!validProtocol(protocol)) return @as(?[]const u8, null);
            return protocol;
        }
    }
};

fn protocolMatches(a: []const u8, b: []const u8) bool {
    const a_slash = std.mem.indexOfScalar(u8, a, '/');
    const b_slash = std.mem.indexOfScalar(u8, b, '/');
    if ((a_slash == null) != (b_slash == null)) return false;
    const a_name = if (a_slash) |index| a[0..index] else a;
    const b_name = if (b_slash) |index| b[0..index] else b;
    if (!std.ascii.eqlIgnoreCase(a_name, b_name)) return false;
    if (a_slash) |ai| {
        const bi = b_slash.?;
        return std.mem.eql(u8, a[ai + 1 ..], b[bi + 1 ..]);
    }
    return true;
}

fn scanUpgradeList(value: []const u8, mode: ListMode) ?bool {
    var list = ProtocolList.init(value, mode);
    var saw = false;
    while (true) {
        const maybe = list.next() orelse break;
        const protocol = maybe orelse return null;
        _ = protocol;
        saw = true;
    }
    return saw;
}

fn validProtocol(value: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, value, '/');
    if (slash) |index| {
        if (std.mem.indexOfScalar(u8, value[index + 1 ..], '/') != null) return false;
        return common.isToken(value[0..index]) and common.isToken(value[index + 1 ..]);
    }
    return common.isToken(value);
}

fn validHost(value: []const u8) bool {
    const authority = uri.validateAuthority(value) orelse return false;
    return !authority.has_userinfo;
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

test "absolute-form exposes request-target authority instead of conflicting Host" {
    const parsed = (try head.parseRequest("GET http://target.example:8080/x HTTP/1.1\r\nHost: wrong.example\r\n\r\n")).?;
    const info = try validateRequest(parsed.head);
    try std.testing.expectEqual(RequestTargetForm.absolute, info.target_form);
    try std.testing.expectEqualStrings("wrong.example", info.host.?);
    try std.testing.expectEqualStrings("target.example:8080", info.effective_authority.?);

    const connect = (try head.parseRequest("CONNECT tunnel.example:443 HTTP/1.1\r\nHost: other.example\r\n\r\n")).?;
    const connect_info = try validateRequest(connect.head);
    try std.testing.expectEqualStrings("tunnel.example:443", connect_info.effective_authority.?);
}

test "request target rejects malformed URI syntax and HTTP userinfo" {
    const bad_escape = (try head.parseRequest("GET /a%zz HTTP/1.1\r\nHost: example.com\r\n\r\n")).?;
    try std.testing.expectError(error.InvalidRequestTarget, validateRequest(bad_escape.head));

    const bad_http = (try head.parseRequest("GET https://user@example.com/x HTTP/1.1\r\nHost: example.com\r\n\r\n")).?;
    try std.testing.expectError(error.InvalidRequestTarget, validateRequest(bad_http.head));

    const generic = (try head.parseRequest("GET urn:example:animal:ferret:nose HTTP/1.1\r\nHost: \r\n\r\n")).?;
    const info = try validateRequest(generic.head);
    try std.testing.expectEqual(RequestTargetForm.absolute, info.target_form);
    try std.testing.expect(info.effective_authority == null);
}

test "response semantics validate status range and 101 Upgrade structure" {
    const valid = (try head.parseResponse("HTTP/1.1 101 Switching Protocols\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\n\r\n", "GET")).?;
    const info = try validateResponse(valid.head);
    try std.testing.expect(info.protocol_switched);

    const missing_upgrade = (try head.parseResponse("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\n\r\n", "GET")).?;
    try std.testing.expectError(error.InvalidUpgradeResponse, validateResponse(missing_upgrade.head));

    const malformed_upgrade = (try head.parseResponse("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: web socket\r\n\r\n", "GET")).?;
    try std.testing.expectError(error.InvalidUpgradeResponse, validateResponse(malformed_upgrade.head));

    const private = (try head.parseResponse("HTTP/1.1 677 Private\r\nContent-Length: 0\r\n\r\n", "GET")).?;
    try std.testing.expectError(error.InvalidStatus, validateResponse(private.head));
}

test "received HTTP lists tolerate bounded empty members but send fields do not" {
    const received = (try head.parseRequest("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: , keep-alive, , close,\r\n\r\n")).?;
    try std.testing.expectEqual(Persistence.close, try persistence(received.head));

    const upgraded = (try head.parseResponse("HTTP/1.1 101 Switching Protocols\r\nConnection: , Upgrade,\r\nUpgrade: , websocket,\r\n\r\n", "GET")).?;
    _ = try validateResponse(upgraded.head);

    try std.testing.expectError(error.InvalidConnectionHeader, persistenceFields(.http_1_1, &.{
        .{ .name = "connection", .value = "keep-alive," },
    }));
    try std.testing.expectError(error.InvalidUpgradeResponse, validateResponseFields(.http_1_1, 101, &.{
        .{ .name = "connection", .value = "Upgrade" },
        .{ .name = "upgrade", .value = "websocket," },
    }));

    // Connection uses #connection-option (zero or more), so an empty value is
    // legal even for a sender.
    try std.testing.expectEqual(Persistence.persistent, try persistenceFields(.http_1_1, &.{
        .{ .name = "connection", .value = "" },
    }));
}

test "send-side absolute-form requires Host derived from request-target" {
    const ok = try validateRequestFields(.http_1_1, "GET", "http://example.com:8080/x", &.{
        .{ .name = "host", .value = "example.com:8080" },
    });
    try std.testing.expectEqualStrings("example.com:8080", ok.effective_authority.?);

    try std.testing.expectError(error.MismatchedHost, validateRequestFields(.http_1_1, "GET", "http://example.com/x", &.{
        .{ .name = "host", .value = "wrong.example" },
    }));

    _ = try validateRequestFields(.http_1_1, "GET", "foo://user@example.com/path", &.{
        .{ .name = "host", .value = "example.com" },
    });
    _ = try validateRequestFields(.http_1_1, "GET", "urn:example:item", &.{
        .{ .name = "host", .value = "" },
    });
}

test "Expect helper classifies continue and unsupported expectations" {
    const request = (try head.parseRequest(
        "PUT /upload HTTP/1.1\r\nHost: example.com\r\nExpect: 100-Continue\r\nContent-Length: 4\r\n\r\n",
    )).?;
    try std.testing.expectEqual(Expectation.continue_100, try requestExpectation(request.head));
    try std.testing.expectEqual(ExpectationAction.send_continue_or_final, (try requestExpectation(request.head)).serverAction());

    const extension = (try head.parseRequest(
        "PUT /upload HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue, x-feature=\"a,b\"\r\nContent-Length: 4\r\n\r\n",
    )).?;
    try std.testing.expectEqual(Expectation.unsupported, try requestExpectation(extension.head));

    const old = (try head.parseRequest(
        "PUT /upload HTTP/1.0\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n",
    )).?;
    try std.testing.expectEqual(Expectation.none, try requestExpectation(old.head));
}

test "ContinueGate waits only for 100 or application timeout" {
    var gate = ContinueGate.init(.continue_100);
    try std.testing.expect(gate.waiting());
    try std.testing.expect(!gate.maySendBody());
    gate.observeStatus(103);
    try std.testing.expect(gate.waiting());
    gate.observeStatus(100);
    try std.testing.expect(gate.maySendBody());

    var rejected = ContinueGate.init(.continue_100);
    rejected.observeStatus(401);
    try std.testing.expectEqual(ContinueGate.Phase.final_received, rejected.phase);
    try std.testing.expect(!rejected.maySendBody());

    var timeout = ContinueGate.init(.continue_100);
    timeout.proceedWithoutContinue();
    try std.testing.expect(timeout.maySendBody());
}

test "UpgradeOffer matches request protocols and validates 101 selection" {
    const request = (try head.parseRequest(
        "GET /chat HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive, Upgrade\r\nUpgrade: WebSocket, IRC/6.9\r\n\r\n",
    )).?;
    const offer = try UpgradeOffer.init(request.head);
    try std.testing.expect(try offer.offers("websocket"));
    try std.testing.expect(try offer.offers("irc/6.9"));
    try std.testing.expect(!try offer.offers("IRC/7.0"));

    const selected = (try head.parseResponse(
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n",
        "GET",
    )).?;
    try offer.validateSelection(selected.head);

    const invalid = (try head.parseResponse(
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n",
        "GET",
    )).?;
    try std.testing.expectError(error.InvalidUpgradeResponse, offer.validateSelection(invalid.head));
}
