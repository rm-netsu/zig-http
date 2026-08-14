const std = @import("std");
const common = @import("../../common.zig");
const static = @import("static.zig");

const Entry = struct {
    storage: []u8,
    name_len: usize,

    fn header(self: Entry) common.Header {
        return .{
            .name = self.storage[0..self.name_len],
            .value = self.storage[self.name_len..],
        };
    }

    fn size(self: Entry) usize {
        return self.storage.len + 32;
    }
};

/// RFC 7541 dynamic table. Memory use is bounded by `max_size` plus list metadata.
pub const DynamicTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    size: usize = 0,
    max_size: usize = 4096,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) DynamicTable {
        return .{ .allocator = allocator, .max_size = max_size };
    }

    pub fn deinit(self: *DynamicTable) void {
        self.clear();
        self.entries.deinit(self.allocator);
    }

    pub fn clear(self: *DynamicTable) void {
        for (self.entries.items) |entry| self.allocator.free(entry.storage);
        self.entries.clearRetainingCapacity();
        self.size = 0;
    }

    pub fn setMaxSize(self: *DynamicTable, new_max: usize) void {
        self.max_size = new_max;
        self.evictToFit(0);
    }

    pub fn add(self: *DynamicTable, h: common.Header) std.mem.Allocator.Error!void {
        const entry_size = h.name.len + h.value.len + 32;
        if (entry_size > self.max_size) {
            self.clear();
            return;
        }
        self.evictToFit(entry_size);
        var storage = try self.allocator.alloc(u8, h.name.len + h.value.len);
        errdefer self.allocator.free(storage);
        @memcpy(storage[0..h.name.len], h.name);
        @memcpy(storage[h.name.len..], h.value);
        try self.entries.insert(self.allocator, 0, .{ .storage = storage, .name_len = h.name.len });
        self.size += entry_size;
    }

    fn evictToFit(self: *DynamicTable, incoming: usize) void {
        while (self.size + incoming > self.max_size) {
            const entry = self.entries.pop() orelse break;
            self.size -= entry.size();
            self.allocator.free(entry.storage);
        }
    }

    /// HPACK indexes start at 1: static entries first, then newest dynamic entry.
    pub fn get(self: *const DynamicTable, index: usize) ?common.Header {
        if (index == 0) return null;
        if (static.get(index)) |h| return h;
        const dynamic_index = index - static.table.len - 1;
        if (dynamic_index >= self.entries.items.len) return null;
        return self.entries.items[dynamic_index].header();
    }

    pub fn findExact(self: *const DynamicTable, h: common.Header) ?usize {
        if (static.findExact(h)) |i| return i;
        for (self.entries.items, 0..) |entry, i| {
            const e = entry.header();
            if (std.mem.eql(u8, e.name, h.name) and std.mem.eql(u8, e.value, h.value))
                return static.table.len + 1 + i;
        }
        return null;
    }

    pub fn findName(self: *const DynamicTable, name: []const u8) ?usize {
        if (static.findName(name)) |i| return i;
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.header().name, name)) return static.table.len + 1 + i;
        }
        return null;
    }
};

test "dynamic table indexing and eviction" {
    var table = DynamicTable.init(std.testing.allocator, 96);
    defer table.deinit();
    try table.add(.{ .name = "x-a", .value = "one" });
    try table.add(.{ .name = "x-b", .value = "two" });
    try std.testing.expectEqualStrings("x-b", table.get(62).?.name);
    try std.testing.expectEqualStrings("x-a", table.get(63).?.name);
    table.setMaxSize(40);
    try std.testing.expect(table.get(63) == null);
}
