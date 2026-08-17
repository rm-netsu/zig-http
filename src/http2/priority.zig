const std = @import("std");
const frame = @import("frame.zig");
const settings = @import("settings.zig");

/// RFC 9218 SETTINGS_NO_RFC7540_PRIORITIES. It stays an extension identifier
/// rather than becoming implicit Session policy; callers can inspect it through
/// `SessionEvent.settings.iterator()` and decide which scheduler/signals they
/// implement.
pub const no_rfc7540_priorities_id: settings.Id = @enumFromInt(0x9);

/// RFC 9218 HTTP/2 PRIORITY_UPDATE frame type.
pub const update_frame_type: frame.Type = @enumFromInt(0x10);

pub const Update = struct {
    prioritized_stream_id: u31,
    /// ASCII Structured Field value. This slice aliases caller-owned payload.
    field_value: []const u8,
};

pub const Effective = struct {
    urgency: u3 = 3,
    incremental: bool = false,
};

/// RFC 9218 priority parameters. Absence is preserved because omission has
/// context-dependent semantics (notably for response Priority fields), while
/// `effective()` applies the RFC request/PRIORITY_UPDATE defaults.
pub const Parameters = struct {
    urgency: ?u3 = null,
    incremental: ?bool = null,

    pub inline fn effective(self: Parameters) Effective {
        return .{
            .urgency = self.urgency orelse 3,
            .incremental = self.incremental orelse false,
        };
    }
};

pub const FieldError = error{InvalidStructuredField};

const BareKind = enum { integer, boolean, other };
const Bare = struct {
    kind: BareKind,
    integer: i64 = 0,
    boolean: bool = false,
};

const Parser = struct {
    input: []const u8,
    pos: usize = 0,

    fn done(self: Parser) bool { return self.pos == self.input.len; }
    fn peek(self: Parser) ?u8 { return if (self.done()) null else self.input[self.pos]; }
    fn take(self: *Parser) FieldError!u8 {
        const ch = self.peek() orelse return error.InvalidStructuredField;
        self.pos += 1;
        return ch;
    }
    fn skipSp(self: *Parser) void { while (self.peek() == ' ') self.pos += 1; }
    fn skipOws(self: *Parser) void {
        while (self.peek()) |ch| {
            if (ch != ' ' and ch != '\t') break;
            self.pos += 1;
        }
    }

    fn key(self: *Parser) FieldError![]const u8 {
        const start = self.pos;
        const first = try self.take();
        if (!((first >= 'a' and first <= 'z') or first == '*')) return error.InvalidStructuredField;
        while (self.peek()) |ch| {
            if ((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or
                ch == '_' or ch == '-' or ch == '.' or ch == '*')
            {
                self.pos += 1;
            } else break;
        }
        return self.input[start..self.pos];
    }

    fn params(self: *Parser) FieldError!void {
        while (self.peek() == ';') {
            self.pos += 1;
            _ = try self.key();
            if (self.peek() == '=') {
                self.pos += 1;
                _ = try self.bare();
            }
        }
    }

    fn item(self: *Parser) FieldError!Bare {
        const value = try self.bare();
        try self.params();
        return value;
    }

    fn member(self: *Parser) FieldError!Bare {
        if (self.peek() == '(') {
            self.pos += 1;
            while (true) {
                self.skipSp();
                if (self.peek() == ')') {
                    self.pos += 1;
                    try self.params();
                    return .{ .kind = .other };
                }
                _ = try self.item();
                const next = self.peek() orelse return error.InvalidStructuredField;
                if (next != ' ' and next != ')') return error.InvalidStructuredField;
            }
        }
        return self.item();
    }

    fn bare(self: *Parser) FieldError!Bare {
        const ch = self.peek() orelse return error.InvalidStructuredField;
        if (ch == '-' or (ch >= '0' and ch <= '9')) return self.number();
        if (ch == '"') return self.string();
        if (ch == ':') return self.binary();
        if (ch == '?') return self.boolean();
        if (ch == '@') {
            self.pos += 1;
            _ = try self.number();
            return .{ .kind = .other };
        }
        if (ch == '%') return self.displayString();
        if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or ch == '*') return self.token();
        return error.InvalidStructuredField;
    }

    fn number(self: *Parser) FieldError!Bare {
        const start = self.pos;
        if (self.peek() == '-') self.pos += 1;
        const digits_start = self.pos;
        while (self.peek()) |ch| {
            if (ch < '0' or ch > '9') break;
            self.pos += 1;
        }
        if (self.pos == digits_start) return error.InvalidStructuredField;
        const whole_digits = self.pos - digits_start;
        if (self.peek() == '.') {
            if (whole_digits > 12) return error.InvalidStructuredField;
            self.pos += 1;
            const frac_start = self.pos;
            while (self.peek()) |ch| {
                if (ch < '0' or ch > '9') break;
                self.pos += 1;
            }
            const frac = self.pos - frac_start;
            if (frac == 0 or frac > 3) return error.InvalidStructuredField;
            return .{ .kind = .other };
        }
        if (whole_digits > 15) return error.InvalidStructuredField;
        const n = std.fmt.parseInt(i64, self.input[start..self.pos], 10) catch return error.InvalidStructuredField;
        return .{ .kind = .integer, .integer = n };
    }

    fn string(self: *Parser) FieldError!Bare {
        _ = try self.take();
        while (true) {
            const ch = try self.take();
            if (ch == '"') break;
            if (ch == '\\') {
                const escaped = try self.take();
                if (escaped != '\\' and escaped != '"') return error.InvalidStructuredField;
            } else if (ch < 0x20 or ch > 0x7e) return error.InvalidStructuredField;
        }
        return .{ .kind = .other };
    }

    fn tokenChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or switch (ch) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~', ':', '/' => true,
            else => false,
        };
    }

    fn token(self: *Parser) FieldError!Bare {
        self.pos += 1;
        while (self.peek()) |ch| {
            if (!tokenChar(ch)) break;
            self.pos += 1;
        }
        return .{ .kind = .other };
    }

    fn binary(self: *Parser) FieldError!Bare {
        self.pos += 1;
        var encoded_len: usize = 0;
        var padding: u2 = 0;
        var saw_padding = false;
        while (true) {
            const ch = try self.take();
            if (ch == ':') break;
            encoded_len += 1;
            if (ch == '=') {
                saw_padding = true;
                if (padding == 2) return error.InvalidStructuredField;
                padding += 1;
            } else {
                if (saw_padding or !(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '/'))
                    return error.InvalidStructuredField;
            }
        }
        if (padding != 0) {
            if (encoded_len % 4 != 0) return error.InvalidStructuredField;
        } else if (encoded_len % 4 == 1) return error.InvalidStructuredField;
        return .{ .kind = .other };
    }

    fn boolean(self: *Parser) FieldError!Bare {
        self.pos += 1;
        const ch = try self.take();
        if (ch != '0' and ch != '1') return error.InvalidStructuredField;
        return .{ .kind = .boolean, .boolean = ch == '1' };
    }

    fn hexLower(ch: u8) bool { return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'); }
    fn displayString(self: *Parser) FieldError!Bare {
        self.pos += 1;
        if (try self.take() != '"') return error.InvalidStructuredField;
        while (true) {
            const ch = try self.take();
            if (ch == '"') break;
            if (ch == '%') {
                if (!hexLower(try self.take()) or !hexLower(try self.take())) return error.InvalidStructuredField;
            } else if (ch < 0x20 or ch > 0x7e) return error.InvalidStructuredField;
        }
        return .{ .kind = .other };
    }
};

/// Parses the RFC 9218 Priority Field Value as a Structured Fields Dictionary.
/// Unknown dictionary members are syntax-checked and ignored. Known members of
/// the wrong type or outside their allowed range are ignored as required by RFC
/// 9218. Duplicate dictionary keys use the final value.
pub fn parseFieldValue(value: []const u8) FieldError!Parameters {
    var p: Parser = .{ .input = value };
    var result: Parameters = .{};
    p.skipSp();
    if (p.done()) return result;

    while (true) {
        const member_key = try p.key();
        var member: Bare = .{ .kind = .boolean, .boolean = true };
        if (p.peek() == '=') {
            p.pos += 1;
            member = try p.member();
        } else {
            try p.params();
        }

        if (std.mem.eql(u8, member_key, "u")) {
            result.urgency = null;
            if (member.kind == .integer and member.integer >= 0 and member.integer <= 7)
                result.urgency = @intCast(member.integer);
        } else if (std.mem.eql(u8, member_key, "i")) {
            result.incremental = null;
            if (member.kind == .boolean) result.incremental = member.boolean;
        }

        p.skipOws();
        if (p.done()) return result;
        if (try p.take() != ',') return error.InvalidStructuredField;
        p.skipOws();
        if (p.done()) return error.InvalidStructuredField;
    }
}

/// Canonically serializes only the known RFC 9218 parameters. The caller owns
/// the writer and decides whether omitted/default values should be materialized.
pub fn writeFieldValue(out: *std.Io.Writer, parameters: Parameters) std.Io.Writer.Error!void {
    var wrote = false;
    if (parameters.urgency) |urgency| {
        try out.print("u={d}", .{urgency});
        wrote = true;
    }
    if (parameters.incremental) |incremental| {
        if (wrote) try out.writeAll(", ");
        if (incremental) try out.writeAll("i") else try out.writeAll("i=?0");
    }
}

/// Validates the wire-local invariants of an RFC 9218 HTTP/2 PRIORITY_UPDATE.
/// Connection role, referenced-stream lifecycle/concurrency accounting, and
/// scheduling policy remain explicit caller concerns at this low composition
/// level. Session exposes the frame through `.extension` rather than silently
/// consuming it.
pub fn parseUpdate(header: frame.FrameHeader, payload: []const u8) error{ FrameSize, Protocol }!Update {
    if (@intFromEnum(header.type) != @intFromEnum(update_frame_type)) return error.Protocol;
    if (payload.len != header.length or payload.len < 4) return error.FrameSize;
    if (header.stream_id != 0) return error.Protocol;
    const prioritized: u31 = @intCast(std.mem.readInt(u32, payload[0..4], .big) & 0x7fff_ffff);
    if (prioritized == 0) return error.Protocol;
    return .{ .prioritized_stream_id = prioritized, .field_value = payload[4..] };
}

pub fn parseUpdateParameters(update: Update) FieldError!Parameters {
    return parseFieldValue(update.field_value);
}

/// Writes an HTTP/2 PRIORITY_UPDATE containing the caller-provided Structured
/// Field value. The field is preflight-parsed before any bytes are emitted, so
/// malformed local priority syntax cannot partially corrupt the connection.
pub fn writeUpdate(
    out: *std.Io.Writer,
    prioritized_stream_id: u31,
    field_value: []const u8,
) (std.Io.Writer.Error || FieldError || error{ Protocol, FrameTooLarge })!void {
    if (prioritized_stream_id == 0) return error.Protocol;
    _ = try parseFieldValue(field_value);
    const payload_len = std.math.add(usize, field_value.len, 4) catch return error.FrameTooLarge;
    if (payload_len > frame.max_frame_size) return error.FrameTooLarge;

    var prefix: [13]u8 = undefined;
    try (frame.FrameHeader{
        .length = @intCast(payload_len),
        .type = update_frame_type,
        .flags = 0,
        .stream_id = 0,
    }).encode(prefix[0..9]);
    std.mem.writeInt(u32, prefix[9..13], prioritized_stream_id, .big);
    try out.writeAll(&prefix);
    try out.writeAll(field_value);
}

/// Canonically writes the known RFC 9218 parameters into a PRIORITY_UPDATE.
/// Unknown extension parameters remain available through the raw `writeUpdate`
/// path when an application needs to preserve or originate them.
pub fn writeUpdateParameters(
    out: *std.Io.Writer,
    prioritized_stream_id: u31,
    parameters: Parameters,
) (std.Io.Writer.Error || error{ Protocol, FrameTooLarge })!void {
    var field_storage: [16]u8 = undefined;
    var field_writer = std.Io.Writer.fixed(&field_storage);
    writeFieldValue(&field_writer, parameters) catch unreachable;
    writeUpdate(out, prioritized_stream_id, field_writer.buffered()) catch |err| switch (err) {
        error.InvalidStructuredField => unreachable,
        error.Protocol => return error.Protocol,
        error.FrameTooLarge => return error.FrameTooLarge,
        error.WriteFailed => return error.WriteFailed,
    };
}

pub inline fn validNoRfc7540PrioritiesValue(value: u32) bool {
    return value <= 1;
}

fn serializeForTest(parameters: Parameters, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writeFieldValue(&writer, parameters);
    return writer.buffered();
}

test "parse RFC 9218 priority parameters and defaults" {
    const parsed = try parseFieldValue("u=5, i");
    try std.testing.expectEqual(@as(?u3, 5), parsed.urgency);
    try std.testing.expectEqual(@as(?bool, true), parsed.incremental);
    try std.testing.expectEqual(Effective{ .urgency = 5, .incremental = true }, parsed.effective());
    try std.testing.expectEqual(Effective{}, (try parseFieldValue("")).effective());
}

test "priority parameters ignore unknown and invalid known members" {
    const parsed = try parseFieldValue("x=(1 2);foo=bar, u=99, i=7, vendor=:YWJj:");
    try std.testing.expectEqual(@as(?u3, null), parsed.urgency);
    try std.testing.expectEqual(@as(?bool, null), parsed.incremental);
    try std.testing.expectEqual(Effective{}, parsed.effective());
}

test "priority dictionary duplicate keys use final value" {
    const parsed = try parseFieldValue("u=1, i=?0, u=6, i=?1");
    try std.testing.expectEqual(@as(?u3, 6), parsed.urgency);
    try std.testing.expectEqual(@as(?bool, true), parsed.incremental);
}

test "priority field rejects malformed structured dictionary" {
    const malformed = [_][]const u8{
        "u =1", "U=1", "u=1,", "u=\"unterminated", "x=(1, 2)",
        "x;bad=()", "u=1234567890123456", "i=?2", "x=:a=:", "x=:YW=J:",
    };
    for (malformed) |value| try std.testing.expectError(error.InvalidStructuredField, parseFieldValue(value));
}

test "priority field serialization is canonical" {
    var storage: [64]u8 = undefined;
    try std.testing.expectEqualStrings("u=0, i", try serializeForTest(.{ .urgency = 0, .incremental = true }, &storage));
    try std.testing.expectEqualStrings("i=?0", try serializeForTest(.{ .incremental = false }, &storage));
    try std.testing.expectEqualStrings("", try serializeForTest(.{}, &storage));
}

test "parse RFC 9218 PRIORITY_UPDATE without imposing scheduling policy" {
    const payload = [_]u8{ 0, 0, 0, 7 } ++ "u=0, i".*;
    const update = try parseUpdate(.{
        .length = payload.len,
        .type = update_frame_type,
        .flags = 0,
        .stream_id = 0,
    }, &payload);
    try std.testing.expectEqual(@as(u31, 7), update.prioritized_stream_id);
    try std.testing.expectEqualStrings("u=0, i", update.field_value);
    try std.testing.expectEqual(Effective{ .urgency = 0, .incremental = true }, (try parseUpdateParameters(update)).effective());
}

test "write PRIORITY_UPDATE preflights and round trips parameters" {
    var storage: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeUpdateParameters(&writer, 11, .{ .urgency = 2, .incremental = true });
    const wire = writer.buffered();
    try std.testing.expectEqual(@as(usize, 9 + 4 + "u=2, i".len), wire.len);
    const header = frame.FrameHeader.parse(wire[0..9]);
    const update = try parseUpdate(header, wire[9..]);
    try std.testing.expectEqual(@as(u31, 11), update.prioritized_stream_id);
    try std.testing.expectEqual(Effective{ .urgency = 2, .incremental = true }, (try parseUpdateParameters(update)).effective());

    var invalid_storage: [64]u8 = undefined;
    var invalid_writer = std.Io.Writer.fixed(&invalid_storage);
    try std.testing.expectError(error.InvalidStructuredField, writeUpdate(&invalid_writer, 1, "u = 1"));
    try std.testing.expectEqual(@as(usize, 0), invalid_writer.buffered().len);
}

test "PRIORITY_UPDATE rejects connection stream and zero target violations" {
    const payload = [_]u8{ 0, 0, 0, 1 };
    try std.testing.expectError(error.Protocol, parseUpdate(.{
        .length = 4,
        .type = update_frame_type,
        .flags = 0,
        .stream_id = 1,
    }, &payload));

    const zero = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.Protocol, parseUpdate(.{
        .length = 4,
        .type = update_frame_type,
        .flags = 0,
        .stream_id = 0,
    }, &zero));
    try std.testing.expect(!validNoRfc7540PrioritiesValue(2));
}
