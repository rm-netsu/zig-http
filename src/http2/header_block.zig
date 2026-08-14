const std = @import("std");

/// Bounded collector for compressed HPACK field blocks that span HEADERS /
/// PUSH_PROMISE / CONTINUATION frames. Storage is supplied by the caller.
pub const Collector = struct {
    storage: []u8,
    used: usize = 0,
    stream_id: ?u31 = null,

    pub fn init(storage: []u8) Collector {
        return .{ .storage = storage };
    }

    pub fn reset(self: *Collector) void {
        self.used = 0;
        self.stream_id = null;
    }

    pub fn begin(self: *Collector, stream_id: u31, fragment: []const u8, end_headers: bool) error{ Protocol, HeaderBlockTooLarge }!?[]const u8 {
        if (stream_id == 0 or self.stream_id != null) return error.Protocol;
        self.used = 0;
        self.stream_id = stream_id;
        try self.append(fragment);
        if (end_headers) return self.finish();
        return null;
    }

    pub fn continuation(self: *Collector, stream_id: u31, fragment: []const u8, end_headers: bool) error{ Protocol, HeaderBlockTooLarge }!?[]const u8 {
        if (self.stream_id == null or self.stream_id.? != stream_id) return error.Protocol;
        try self.append(fragment);
        if (end_headers) return self.finish();
        return null;
    }

    fn append(self: *Collector, fragment: []const u8) error{HeaderBlockTooLarge}!void {
        if (fragment.len > self.storage.len - self.used) return error.HeaderBlockTooLarge;
        @memcpy(self.storage[self.used .. self.used + fragment.len], fragment);
        self.used += fragment.len;
    }

    fn finish(self: *Collector) []const u8 {
        const block = self.storage[0..self.used];
        self.stream_id = null;
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
