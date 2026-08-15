const std = @import("std");
const http = @import("http");
const corpus = @import("real_corpus.zig");

pub const rounds: usize = 250_000;
pub const streams_per_connection: usize = 64;
pub const data_chunk: u32 = 16_384;

pub const Fixture = struct {
    bodies: [32]u32 = undefined,
    count: usize = 0,
    payload: [data_chunk]u8 = undefined,

    pub fn init(seed: u64) Fixture {
        var out: Fixture = .{};
        for (corpus.scenarios) |scenario| {
            for (scenario.exchanges) |exchange| {
                if (out.count == out.bodies.len) break;
                out.bodies[out.count] = responseLength(exchange.response);
                out.count += 1;
            }
        }
        std.debug.assert(out.count != 0);
        var x = seed | 1;
        for (&out.payload) |*byte| {
            x = x *% 6364136223846793005 +% 1442695040888963407;
            byte.* = @truncate(x >> 24);
        }
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
    const Slot = struct {
        id: u31 = 0,
        used: bool = false,
        value: http.http2.stream.Tracked = undefined,
    };

    slots: [streams_per_connection]Slot = [_]Slot{.{}} ** streams_per_connection,

    inline fn index(id: u31) usize {
        return (@as(usize, id) >> 1) % streams_per_connection;
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

pub inline fn dataFrame(payload_bytes: []const u8, stream_id: u31, end_stream: bool) http.http2.frame.CompleteFrame {
    return .{
        .header = .{
            .length = @intCast(payload_bytes.len),
            .type = .data,
            .flags = @intFromBool(end_stream),
            .stream_id = stream_id,
        },
        .payload = payload_bytes,
    };
}

pub fn print(label: []const u8, elapsed_ns: u64, frames: u64) void {
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const rate = @as(f64, @floatFromInt(frames)) / seconds;
    std.debug.print("{s}: {d:.3} M frames/s ({d} frames, {d:.3} s)\n", .{ label, rate / 1_000_000.0, frames, seconds });
}
