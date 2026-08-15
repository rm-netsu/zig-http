const std = @import("std");
const frame = @import("frame.zig");

pub const HeadersPayload = struct {
    fragment: []const u8,
    dependency: ?u31 = null,
    exclusive: bool = false,
    weight: ?u8 = null,
};

pub fn data(header: frame.FrameHeader, payload: []const u8) error{ FrameSize, Protocol }![]const u8 {
    if (header.type != .data or payload.len != header.length) return error.FrameSize;
    if ((header.flags & 0x08) == 0) return payload;
    if (payload.len == 0) return error.Protocol;
    const pad = payload[0];
    if (@as(usize, pad) >= payload.len) return error.Protocol;
    return payload[1 .. payload.len - pad];
}

pub fn headers(header: frame.FrameHeader, payload: []const u8) error{ FrameSize, Protocol }!HeadersPayload {
    if (header.type != .headers or payload.len != header.length) return error.FrameSize;
    var start: usize = 0;
    var pad: usize = 0;
    if ((header.flags & 0x08) != 0) {
        if (payload.len == 0) return error.Protocol;
        pad = payload[0];
        start = 1;
    }

    var result: HeadersPayload = undefined;
    result.dependency = null;
    result.exclusive = false;
    result.weight = null;
    if ((header.flags & 0x20) != 0) {
        if (payload.len - start < 5) return error.FrameSize;
        const raw = std.mem.readInt(u32, payload[start..][0..4], .big);
        result.exclusive = (raw & 0x8000_0000) != 0;
        result.dependency = @intCast(raw & 0x7fff_ffff);
        result.weight = payload[start + 4];
        start += 5;
        if (result.dependency.? == header.stream_id) return error.Protocol;
    }
    if (pad > payload.len - start) return error.Protocol;
    result.fragment = payload[start .. payload.len - pad];
    return result;
}

pub const PushPromisePayload = struct {
    promised_stream_id: u31,
    fragment: []const u8,
};

pub fn pushPromise(header: frame.FrameHeader, payload: []const u8) error{ FrameSize, Protocol }!PushPromisePayload {
    if (header.type != .push_promise or payload.len != header.length) return error.FrameSize;
    var start: usize = 0;
    var pad: usize = 0;
    if ((header.flags & 0x08) != 0) {
        if (payload.len == 0) return error.Protocol;
        pad = payload[0];
        start = 1;
    }
    if (payload.len - start < 4) return error.FrameSize;
    const promised: u31 = @intCast(std.mem.readInt(u32, payload[start..][0..4], .big) & 0x7fff_ffff);
    start += 4;
    if (promised == 0 or pad > payload.len - start) return error.Protocol;
    return .{ .promised_stream_id = promised, .fragment = payload[start .. payload.len - pad] };
}

pub fn windowIncrement(payload: []const u8) error{ FrameSize, Protocol }!u31 {
    if (payload.len != 4) return error.FrameSize;
    const value: u31 = @intCast(std.mem.readInt(u32, payload[0..4], .big) & 0x7fff_ffff);
    if (value == 0) return error.Protocol;
    return value;
}

pub fn rstErrorCode(payload: []const u8) error{FrameSize}!u32 {
    if (payload.len != 4) return error.FrameSize;
    return std.mem.readInt(u32, payload[0..4], .big);
}

pub const GoAway = struct { last_stream_id: u31, error_code: u32, debug_data: []const u8 };

pub fn goAway(payload: []const u8) error{FrameSize}!GoAway {
    if (payload.len < 8) return error.FrameSize;
    return .{
        .last_stream_id = @intCast(std.mem.readInt(u32, payload[0..4], .big) & 0x7fff_ffff),
        .error_code = std.mem.readInt(u32, payload[4..8], .big),
        .debug_data = payload[8..],
    };
}

test "strip padded data" {
    const h: frame.FrameHeader = .{ .length = 6, .type = .data, .flags = 0x08, .stream_id = 1 };
    const payload = [_]u8{ 2, 'a', 'b', 'c', 0, 0 };
    try std.testing.expectEqualStrings("abc", try data(h, &payload));
}

test "window update rejects zero increment" {
    const bytes = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.Protocol, windowIncrement(&bytes));
}
