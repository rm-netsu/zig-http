const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub fn eqlHeaderName(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn isToken(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |c| if (!isTchar(c)) return false;
    return true;
}

pub fn isTchar(c: u8) bool {
    return switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

pub fn trimOws(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and (value[start] == ' ' or value[start] == '\t')) : (start += 1) {}
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) : (end -= 1) {}
    return value[start..end];
}

test "token validation" {
    try std.testing.expect(isToken("content-type"));
    try std.testing.expect(isToken("X_Custom"));
    try std.testing.expect(!isToken("bad name"));
}
