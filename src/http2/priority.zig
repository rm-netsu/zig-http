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
    /// Parsing scheduler parameters is intentionally independent of frame/state
    /// handling so applications can use their own Structured Fields layer.
    field_value: []const u8,
};

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

pub inline fn validNoRfc7540PrioritiesValue(value: u32) bool {
    return value <= 1;
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
