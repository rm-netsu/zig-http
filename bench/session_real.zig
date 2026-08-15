const std = @import("std");
const http = @import("http");
const corpus = @import("real_corpus.zig");

pub const rounds: usize = 120_000;
pub const batch_streams: usize = 32;
pub const data_chunk: u32 = 16_384;

pub const Block = struct {
    bytes: []u8,
    body: u32,
};

pub const Fixture = struct {
    allocator: std.mem.Allocator,
    blocks: [32]Block = undefined,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Fixture {
        var fixture: Fixture = .{ .allocator = allocator };
        var encoder = http.http2.hpack.Encoder.init(allocator, 4096);
        defer encoder.deinit();
        encoder.huffman_mode = .auto;

        for (corpus.scenarios) |scenario| {
            for (scenario.exchanges) |exchange| {
                if (fixture.count == fixture.blocks.len) break;
                var storage: [8192]u8 = undefined;
                var writer = std.Io.Writer.fixed(&storage);
                for (exchange.response) |field| {
                    try encoder.field(&writer, .{ .name = field.name, .value = field.value }, .without);
                }
                fixture.blocks[fixture.count] = .{
                    .bytes = try allocator.dupe(u8, writer.buffered()),
                    .body = responseLength(exchange.response),
                };
                fixture.count += 1;
            }
        }
        std.debug.assert(fixture.count != 0);
        return fixture;
    }

    pub fn deinit(self: *Fixture) void {
        for (self.blocks[0..self.count]) |entry| self.allocator.free(entry.bytes);
    }

    pub inline fn block(self: *const Fixture, i: usize) Block {
        return self.blocks[i % self.count];
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
    slots: [batch_streams]Slot = [_]Slot{.{}} ** batch_streams,

    inline fn index(id: u31) usize {
        return (@as(usize, id) >> 1) % batch_streams;
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

    pub inline fn applyPeerInitialWindow(self: *Store, change: http.http2.PeerState.InitialWindowChange) bool {
        for (&self.slots) |*slot| {
            if (!slot.used) continue;
            slot.value.windows.applyPeerInitialDelta(change.old, change.new) catch return false;
        }
        return true;
    }

    pub inline fn reset(self: *Store) void {
        for (&self.slots) |*slot| slot.used = false;
    }
};

pub const CountingSink = struct {
    fields: u64 = 0,
    pub inline fn field(self: *CountingSink, _: u31, _: http.http2.fields.Kind, _: http.common.Header) void {
        self.fields +%= 1;
    }
};

pub fn print(label: []const u8, elapsed_ns: u64, transactions: u64, field_count: u64) void {
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const rate = @as(f64, @floatFromInt(transactions)) / seconds;
    const fields_rate = @as(f64, @floatFromInt(field_count)) / seconds;
    std.debug.print("{s}: {d:.3} M tx/s, {d:.3} M fields/s ({d:.3} s)\n", .{
        label, rate / 1_000_000.0, fields_rate / 1_000_000.0, seconds,
    });
}

pub const body_bytes = [_]u8{0x61} ** data_chunk;
