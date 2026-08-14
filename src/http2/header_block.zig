const std = @import("std");

/// Bounded collector for compressed HPACK field blocks that span HEADERS /
/// PUSH_PROMISE / CONTINUATION frames. A block completed in its first frame is
/// returned directly from caller input; storage is touched only for fragmented
/// blocks that require concatenation.
pub const Collector = struct {
    storage: []u8,
    used: u32 = 0,
    stream_id: u31 = 0,

    pub fn init(storage: []u8) Collector {
        return .{ .storage = storage };
    }

    pub fn reset(self: *Collector) void {
        self.used = 0;
        self.stream_id = 0;
    }

    pub fn begin(self: *Collector, stream_id: u31, fragment: []const u8, end_headers: bool) error{ Protocol, HeaderBlockTooLarge }!?[]const u8 {
        if (stream_id == 0 or self.stream_id != 0) return error.Protocol;
        self.used = 0;
        if (fragment.len > self.storage.len) return error.HeaderBlockTooLarge;
        if (end_headers) return fragment;
        self.stream_id = stream_id;
        try self.append(fragment);
        return null;
    }

    pub fn continuation(self: *Collector, stream_id: u31, fragment: []const u8, end_headers: bool) error{ Protocol, HeaderBlockTooLarge }!?[]const u8 {
        if (self.stream_id == 0 or self.stream_id != stream_id) return error.Protocol;
        try self.append(fragment);
        if (end_headers) return self.finish();
        return null;
    }

    fn append(self: *Collector, fragment: []const u8) error{HeaderBlockTooLarge}!void {
        const used = @as(usize, self.used);
        if (used > self.storage.len or fragment.len > self.storage.len - used) return error.HeaderBlockTooLarge;
        if (fragment.len > std.math.maxInt(u32) - self.used) return error.HeaderBlockTooLarge;
        @memcpy(self.storage[used .. used + fragment.len], fragment);
        self.used += @intCast(fragment.len);
    }

    fn finish(self: *Collector) []const u8 {
        const block = self.storage[0..self.used];
        self.stream_id = 0;
        return block;
    }
};

test "collect continuation fragments" {
    var storage: [32]u8 = undefined;
    var c = Collector.init(&storage);
    try std.testing.expect((try c.begin(1, "abc", false)) == null);
    const block = (try c.continuation(1, "def", true)).?;
    try std.testing.expectEqualStrings("abcdef", block);
}

test "single-frame header block bypasses collector storage" {
    var storage: [32]u8 = undefined;
    @memset(&storage, 0xaa);
    var c = Collector.init(&storage);
    const fragment = "larger than storage";
    const block = (try c.begin(1, fragment, true)).?;
    try std.testing.expectEqualStrings(fragment, block);
    try std.testing.expectEqual(@as(u32, 0), c.used);
    try std.testing.expectEqual(@as(u8, 0xaa), storage[0]);
    try std.testing.expectError(error.HeaderBlockTooLarge, c.begin(1, "012345678901234567890123456789012", true));
}
