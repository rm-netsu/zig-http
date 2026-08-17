const http = @import("http");

const h2 = http.http2;

/// Small fixed-capacity Session store for examples, tests, and embedded users.
/// Production applications can replace this with a slab, hash table, or shard
/// without changing Session itself.
pub fn FixedStreamStore(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            id: u31 = 0,
            used: bool = false,
            tracked: h2.stream.Tracked = undefined,
        };

        entries: [capacity]Entry = [_]Entry{.{}} ** capacity,

        pub fn get(self: *Self, id: u31) ?*h2.stream.Tracked {
            for (&self.entries) |*entry| {
                if (entry.used and entry.id == id) return &entry.tracked;
            }
            return null;
        }

        pub fn insert(self: *Self, id: u31, tracked: h2.stream.Tracked) ?*h2.stream.Tracked {
            if (self.get(id) != null) return null;
            for (&self.entries) |*entry| {
                if (!entry.used) {
                    entry.* = .{ .id = id, .used = true, .tracked = tracked };
                    return &entry.tracked;
                }
            }
            return null;
        }

        pub fn maxActiveSendAdjustment(self: *Self) i32 {
            var result: i32 = 0;
            for (&self.entries) |*entry| {
                if (!entry.used) continue;
                switch (entry.tracked.stream.state) {
                    .open, .half_closed_remote => result = @max(result, entry.tracked.windows.send.adjustment),
                    else => {},
                }
            }
            return result;
        }
    };
}
