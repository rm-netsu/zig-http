const std = @import("std");
const common = @import("../common.zig");

pub const Error = std.Io.Writer.Error || error{InvalidHeader};

pub fn requestHead(w: *std.Io.Writer, method: []const u8, target: []const u8, headers: []const common.Header) Error!void {
    if (!common.isToken(method) or !validTarget(target)) return error.InvalidHeader;
    try w.writeAll(method);
    try w.writeByte(' ');
    try w.writeAll(target);
    try w.writeAll(" HTTP/1.1\r\n");
    try writeHeaders(w, headers);
}

pub fn responseHead(w: *std.Io.Writer, status: u16, reason: []const u8, headers: []const common.Header) Error!void {
    if (status < 100 or status > 999 or !validReason(reason)) return error.InvalidHeader;
    try w.print("HTTP/1.1 {d} {s}\r\n", .{ status, reason });
    try writeHeaders(w, headers);
}

pub fn writeHeaders(w: *std.Io.Writer, headers: []const common.Header) Error!void {
    for (headers) |h| {
        if (!common.isToken(h.name)) return error.InvalidHeader;
        if (!common.isFieldValue(h.value)) return error.InvalidHeader;
        try w.writeAll(h.name);
        try w.writeAll(": ");
        try w.writeAll(h.value);
        try w.writeAll("\r\n");
    }
    try w.writeAll("\r\n");
}

pub fn chunk(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    if (bytes.len == 0) return;
    try w.print("{x}\r\n", .{bytes.len});
    try w.writeAll(bytes);
    try w.writeAll("\r\n");
}

pub fn endChunks(w: *std.Io.Writer, trailers: []const common.Header) Error!void {
    try w.writeAll("0\r\n");
    try writeHeaders(w, trailers);
}

fn validTarget(target: []const u8) bool {
    if (target.len == 0) return false;
    for (target) |c| if (c <= 0x20 or c == 0x7f) return false;
    return true;
}

fn validReason(reason: []const u8) bool {
    return common.isFieldValue(reason);
}
