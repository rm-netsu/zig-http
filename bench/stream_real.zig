const std = @import("std");
const http = @import("http");
const corpus = @import("real_corpus.zig");

pub const rounds: usize = 400_000;
pub const streams_per_connection: usize = 64;
pub const data_chunk: u32 = 16_384;

pub const Fixture = struct {
    bodies: [32]u32 = undefined,
    count: usize = 0,

    pub fn init() Fixture {
        var out: Fixture = .{};
        for (corpus.scenarios) |scenario| {
            for (scenario.exchanges) |exchange| {
                if (out.count == out.bodies.len) break;
                out.bodies[out.count] = responseLength(exchange.response);
                out.count += 1;
            }
        }
        std.debug.assert(out.count != 0);
        return out;
    }

    pub inline fn body(self: *const Fixture, index: usize) u32 {
        return self.bodies[index % self.count];
    }
};

fn responseLength(fields: []const corpus.Field) u32 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, "content-length")) return std.fmt.parseInt(u32, field.value, 10) catch 0;
    }
    return 0;
}

pub const Store = struct {
    const capacity = streams_per_connection;
    const Slot = struct {
        id: u31 = 0,
        used: bool = false,
        value: http.http2.stream.Tracked = undefined,
    };

    slots: [capacity]Slot = [_]Slot{.{}} ** capacity,

    inline fn index(id: u31) usize {
        return (@as(usize, id) >> 1) % capacity;
    }

    pub inline fn get(self: *Store, id: u31) ?*http.http2.stream.Tracked {
        const slot = &self.slots[index(id)];
        if (!slot.used or slot.id != id) return null;
        return &slot.value;
    }

    pub inline fn insert(self: *Store, id: u31, value: http.http2.stream.Tracked) ?*http.http2.stream.Tracked {
        const slot = &self.slots[index(id)];
        if (slot.used) return null;
        slot.* = .{ .id = id, .used = true, .value = value };
        return &slot.value;
    }

    pub inline fn remove(self: *Store, id: u31) void {
        const slot = &self.slots[index(id)];
        std.debug.assert(slot.used and slot.id == id);
        slot.used = false;
    }
};

pub inline fn consumeBodyRaw(store: *Store, id: u31, body: u32) !void {
    if (body == 0) {
        try store.get(id).?.stream.remoteHeaders(true);
        return;
    }
    try store.get(id).?.stream.remoteHeaders(false);
    var left = body;
    while (left != 0) {
        const n = @min(left, data_chunk);
        left -= n;
        const tracked = store.get(id).?;
        try tracked.windows.receiveData(n);
        try tracked.stream.remoteData(left == 0);
        try tracked.windows.creditReceive(@intCast(n));
    }
}

pub fn print(label: []const u8, elapsed_ns: u64, transactions: u64) void {
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const rate = @as(f64, @floatFromInt(transactions)) / seconds;
    std.debug.print("{s}: {d:.3} M tx/s ({d} tx, {d:.3} s)\n", .{ label, rate / 1_000_000.0, transactions, seconds });
}
