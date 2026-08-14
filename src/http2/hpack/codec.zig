const std = @import("std");
const common = @import("../../common.zig");
const huffman = @import("huffman.zig");
const table_mod = @import("table.zig");

pub const Error = error{
    Truncated,
    IntegerOverflow,
    InvalidIndex,
    InvalidHuffman,
    ScratchTooSmall,
    InvalidTableSizeUpdate,
    TableSizeTooLarge,
    HeaderListTooLarge,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

pub const Integer = struct { value: usize, consumed: usize };

pub fn decodeInteger(input: []const u8, prefix_bits: u4) error{ Truncated, IntegerOverflow }!Integer {
    if (input.len == 0 or prefix_bits == 0 or prefix_bits > 8) return error.Truncated;
    const prefix_max: usize = (@as(usize, 1) << @intCast(prefix_bits)) - 1;
    var value: usize = input[0] & @as(u8, @intCast(prefix_max));
    if (value < prefix_max) return .{ .value = value, .consumed = 1 };

    var shift: usize = 0;
    var i: usize = 1;
    while (true) {
        if (i == input.len) return error.Truncated;
        const byte = input[i];
        const low: usize = byte & 0x7f;
        if (shift >= @bitSizeOf(usize) or (low << @intCast(shift)) >> @intCast(shift) != low)
            return error.IntegerOverflow;
        const add = low << @intCast(shift);
        if (value > std.math.maxInt(usize) - add) return error.IntegerOverflow;
        value += add;
        i += 1;
        if ((byte & 0x80) == 0) return .{ .value = value, .consumed = i };
        shift += 7;
        if (shift > @bitSizeOf(usize) + 7) return error.IntegerOverflow;
    }
}

pub fn encodeInteger(w: *std.Io.Writer, value: usize, prefix_bits: u4, high_bits: u8) std.Io.Writer.Error!void {
    const prefix_max: usize = (@as(usize, 1) << @intCast(prefix_bits)) - 1;
    if (value < prefix_max) {
        try w.writeByte(high_bits | @as(u8, @intCast(value)));
        return;
    }
    try w.writeByte(high_bits | @as(u8, @intCast(prefix_max)));
    var rest = value - prefix_max;
    while (rest >= 128) {
        try w.writeByte(@as(u8, @intCast(rest & 0x7f)) | 0x80);
        rest >>= 7;
    }
    try w.writeByte(@intCast(rest));
}

pub const HuffmanMode = enum { never, always, auto };

fn stringEncodedLen(bytes: []const u8, mode: HuffmanMode) struct { huffman: bool, len: usize } {
    const hlen = huffman.encodedLen(bytes);
    return switch (mode) {
        .never => .{ .huffman = false, .len = bytes.len },
        .always => .{ .huffman = true, .len = hlen },
        .auto => if (hlen < bytes.len) .{ .huffman = true, .len = hlen } else .{ .huffman = false, .len = bytes.len },
    };
}

pub fn encodeString(w: *std.Io.Writer, bytes: []const u8, mode: HuffmanMode) std.Io.Writer.Error!void {
    const choice = stringEncodedLen(bytes, mode);
    try encodeInteger(w, choice.len, 7, if (choice.huffman) 0x80 else 0x00);
    if (choice.huffman) try huffman.encode(w, bytes) else try w.writeAll(bytes);
}

const DecodedString = struct { bytes: []const u8, consumed: usize, scratch_used: usize };

fn decodeString(input: []const u8, scratch: []u8) Error!DecodedString {
    if (input.len == 0) return error.Truncated;
    const compressed = (input[0] & 0x80) != 0;
    const n = try decodeInteger(input, 7);
    if (n.value > input.len - n.consumed) return error.Truncated;
    const payload = input[n.consumed .. n.consumed + n.value];
    if (!compressed) return .{ .bytes = payload, .consumed = n.consumed + n.value, .scratch_used = 0 };
    const decoded = huffman.decode(payload, scratch) catch |err| switch (err) {
        error.InvalidHuffman => return error.InvalidHuffman,
        error.OutputTooSmall => return error.ScratchTooSmall,
    };
    return .{ .bytes = decoded, .consumed = n.consumed + n.value, .scratch_used = decoded.len };
}

pub const Decoder = struct {
    dynamic: table_mod.DynamicTable,
    allowed_max_size: usize,
    max_header_list_size: usize = std.math.maxInt(usize),

    pub fn init(allocator: std.mem.Allocator, max_table_size: usize) Decoder {
        return .{
            .dynamic = table_mod.DynamicTable.init(allocator, max_table_size),
            .allowed_max_size = max_table_size,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.dynamic.deinit();
    }

    pub fn setAllowedMaxSize(self: *Decoder, max_size: usize) void {
        self.allowed_max_size = max_size;
        if (self.dynamic.max_size > max_size) self.dynamic.setMaxSize(max_size);
    }

    pub fn setMaxHeaderListSize(self: *Decoder, max_size: usize) void {
        self.max_header_list_size = max_size;
    }

    pub fn iterator(self: *Decoder, block: []const u8, scratch: []u8) Iterator {
        return .{ .decoder = self, .block = block, .scratch = scratch };
    }
};

/// Each returned header remains valid until the next call to `next` when one of
/// its strings was Huffman-coded; raw literals and table entries live longer.
pub const Iterator = struct {
    decoder: *Decoder,
    block: []const u8,
    scratch: []u8,
    offset: usize = 0,
    saw_field: bool = false,
    header_list_size: usize = 0,

    pub fn next(self: *Iterator) Error!?common.Header {
        while (self.offset < self.block.len and (self.block[self.offset] & 0xe0) == 0x20) {
            if (self.saw_field) return error.InvalidTableSizeUpdate;
            const size = try decodeInteger(self.block[self.offset..], 5);
            if (size.value > self.decoder.allowed_max_size) return error.TableSizeTooLarge;
            self.decoder.dynamic.setMaxSize(size.value);
            self.offset += size.consumed;
        }
        if (self.offset == self.block.len) return null;
        const input = self.block[self.offset..];
        const first = input[0];

        if ((first & 0x80) != 0) {
            const idx = try decodeInteger(input, 7);
            if (idx.value == 0) return error.InvalidIndex;
            self.offset += idx.consumed;
            self.saw_field = true;
            const h = self.decoder.dynamic.get(idx.value) orelse return error.InvalidIndex;
            try self.account(h);
            return h;
        }

        const incremental = (first & 0x40) != 0;
        const prefix: u4 = if (incremental) 6 else 4;
        const name_idx = try decodeInteger(input, prefix);
        var cursor = name_idx.consumed;
        var scratch_used: usize = 0;
        const name: []const u8 = if (name_idx.value == 0) blk: {
            const decoded = try decodeString(input[cursor..], self.scratch[scratch_used..]);
            cursor += decoded.consumed;
            scratch_used += decoded.scratch_used;
            break :blk decoded.bytes;
        } else blk: {
            break :blk (self.decoder.dynamic.get(name_idx.value) orelse return error.InvalidIndex).name;
        };

        const value_decoded = try decodeString(input[cursor..], self.scratch[scratch_used..]);
        cursor += value_decoded.consumed;
        const h: common.Header = .{ .name = name, .value = value_decoded.bytes };
        if (incremental) try self.decoder.dynamic.add(h);
        self.offset += cursor;
        self.saw_field = true;
        try self.account(h);
        return h;
    }

    fn account(self: *Iterator, h: common.Header) Error!void {
        const field_size = h.name.len + h.value.len + 32;
        if (field_size > self.decoder.max_header_list_size -| self.header_list_size)
            return error.HeaderListTooLarge;
        self.header_list_size += field_size;
    }
};

pub const Indexing = enum { incremental, without, never };

pub const Encoder = struct {
    dynamic: table_mod.DynamicTable,
    huffman_mode: HuffmanMode = .auto,

    pub fn init(allocator: std.mem.Allocator, max_table_size: usize) Encoder {
        return .{ .dynamic = table_mod.DynamicTable.init(allocator, max_table_size) };
    }

    pub fn deinit(self: *Encoder) void {
        self.dynamic.deinit();
    }

    pub fn setTableSize(self: *Encoder, w: *std.Io.Writer, size: usize) Error!void {
        self.dynamic.setMaxSize(size);
        try encodeInteger(w, size, 5, 0x20);
    }

    pub fn field(self: *Encoder, w: *std.Io.Writer, h: common.Header, indexing: Indexing) Error!void {
        if (indexing != .never) if (self.dynamic.findExact(h)) |idx| {
            try encodeInteger(w, idx, 7, 0x80);
            return;
        };
        const name_idx = self.dynamic.findName(h.name) orelse 0;
        switch (indexing) {
            .incremental => try encodeInteger(w, name_idx, 6, 0x40),
            .without => try encodeInteger(w, name_idx, 4, 0x00),
            .never => try encodeInteger(w, name_idx, 4, 0x10),
        }
        if (name_idx == 0) try encodeString(w, h.name, self.huffman_mode);
        try encodeString(w, h.value, self.huffman_mode);
        if (indexing == .incremental) try self.dynamic.add(h);
    }
};

test "HPACK integer examples" {
    const a = [_]u8{0x0a};
    try std.testing.expectEqual(@as(usize, 10), (try decodeInteger(&a, 5)).value);
    const b = [_]u8{ 0x1f, 0x9a, 0x0a };
    try std.testing.expectEqual(@as(usize, 1337), (try decodeInteger(&b, 5)).value);
}

test "decode RFC request block without Huffman" {
    // C.3.1: :method GET, :scheme http, :path /, :authority www.example.com
    const block = [_]u8{ 0x82, 0x86, 0x84, 0x41, 0x0f, 'w', 'w', 'w', '.', 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm' };
    var decoder = Decoder.init(std.testing.allocator, 4096);
    defer decoder.deinit();
    var scratch: [256]u8 = undefined;
    var it = decoder.iterator(&block, &scratch);
    try std.testing.expectEqualStrings(":method", (try it.next()).?.name);
    try std.testing.expectEqualStrings(":scheme", (try it.next()).?.name);
    try std.testing.expectEqualStrings(":path", (try it.next()).?.name);
    const authority = (try it.next()).?;
    try std.testing.expectEqualStrings(":authority", authority.name);
    try std.testing.expectEqualStrings("www.example.com", authority.value);
    try std.testing.expect((try it.next()) == null);
}

test "encoder and decoder roundtrip with dynamic table" {
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var encoder = Encoder.init(std.testing.allocator, 4096);
    defer encoder.deinit();
    try encoder.field(&writer, .{ .name = ":method", .value = "GET" }, .without);
    try encoder.field(&writer, .{ .name = "x-test", .value = "abcdef" }, .incremental);
    try encoder.field(&writer, .{ .name = "x-test", .value = "ghijkl" }, .without);
    const encoded = writer.buffered();

    var decoder = Decoder.init(std.testing.allocator, 4096);
    defer decoder.deinit();
    var scratch: [256]u8 = undefined;
    var it = decoder.iterator(encoded, &scratch);
    try std.testing.expectEqualStrings(":method", (try it.next()).?.name);
    const a = (try it.next()).?;
    try std.testing.expectEqualStrings("x-test", a.name);
    try std.testing.expectEqualStrings("abcdef", a.value);
    const b = (try it.next()).?;
    try std.testing.expectEqualStrings("x-test", b.name);
    try std.testing.expectEqualStrings("ghijkl", b.value);
    try std.testing.expect((try it.next()) == null);
}

test "decode RFC Huffman request block" {
    const block = [_]u8{ 0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff };
    var decoder = Decoder.init(std.testing.allocator, 4096);
    defer decoder.deinit();
    var scratch: [256]u8 = undefined;
    var it = decoder.iterator(&block, &scratch);
    _ = try it.next();
    _ = try it.next();
    _ = try it.next();
    const authority = (try it.next()).?;
    try std.testing.expectEqualStrings("www.example.com", authority.value);
}

test "header list size is bounded" {
    const block = [_]u8{0x82};
    var decoder = Decoder.init(std.testing.allocator, 4096);
    defer decoder.deinit();
    decoder.setMaxHeaderListSize(10);
    var scratch: [16]u8 = undefined;
    var it = decoder.iterator(&block, &scratch);
    try std.testing.expectError(error.HeaderListTooLarge, it.next());
}
