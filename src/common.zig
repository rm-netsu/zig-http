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
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 4) {
        if (tchar_table[bytes[i]] == 0 or
            tchar_table[bytes[i + 1]] == 0 or
            tchar_table[bytes[i + 2]] == 0 or
            tchar_table[bytes[i + 3]] == 0) return false;
    }
    for (bytes[i..]) |c| if (tchar_table[c] == 0) return false;
    return true;
}

const tchar_table = blk: {
    var table: [256]u8 = @splat(0);
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        table[i] = @intFromBool(switch (c) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            '0'...'9', 'A'...'Z', 'a'...'z' => true,
            else => false,
        });
    }
    break :blk table;
};

pub inline fn isTchar(c: u8) bool {
    return tchar_table[c] != 0;
}

pub fn trimOws(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and (value[start] == ' ' or value[start] == '\t')) : (start += 1) {}
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) : (end -= 1) {}
    return value[start..end];
}

/// HTTP field values may contain HTAB, visible ASCII, and obs-text, but not
/// other control bytes. This also rejects DEL.
const field_value_table = blk: {
    var table: [256]u8 = @splat(1);
    for (0..0x20) |i| table[i] = 0;
    table['\t'] = 1;
    table[0x7f] = 0;
    break :blk table;
};

pub fn isFieldValue(bytes: []const u8) bool {
    const block_len = 8;
    const Block = @Vector(block_len, u8);
    var i: usize = 0;
    while (i + block_len <= bytes.len) : (i += block_len) {
        const block: Block = bytes[i..][0..block_len].*;
        const invalid = ((block < @as(Block, @splat(0x20))) & (block != @as(Block, @splat('\t')))) |
            (block == @as(Block, @splat(0x7f)));
        if (@reduce(.Or, invalid)) return false;
    }
    for (bytes[i..]) |c| if (field_value_table[c] == 0) return false;
    return true;
}

test "token validation" {
    try std.testing.expect(isToken("content-type"));
    try std.testing.expect(isToken("X_Custom"));
    try std.testing.expect(!isToken("bad name"));
}

test "field value validation rejects controls" {
    try std.testing.expect(isFieldValue("text\tvalue"));
    try std.testing.expect(isFieldValue("\x80obs-text"));
    try std.testing.expect(!isFieldValue("bad\x01value"));
    try std.testing.expect(!isFieldValue("bad\x7fvalue"));
    try std.testing.expect(!isFieldValue("0123456789abcdef\x01tail"));
}
