const std = @import("std");
const http = @import("http");
const corpus = @import("real_corpus.zig");

pub const rounds: usize = 600_000;
pub const max_scenarios: usize = 8;
pub const store_slots: usize = 64;
pub const data_chunk: usize = 16_384;

pub const Entry = struct {
    fields: []http.http2.hpack.EncodedField,
    body: u32,
    scenario: usize,
};

pub const Fixture = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,

    pub fn init(allocator: std.mem.Allocator) !Fixture {
        var count: usize = 0;
        for (corpus.scenarios) |scenario| count += scenario.exchanges.len;
        const entries = try allocator.alloc(Entry, count);
        errdefer allocator.free(entries);
        var at: usize = 0;
        for (corpus.scenarios, 0..) |scenario, scenario_index| {
            for (scenario.exchanges) |exchange| {
                const encoded = try allocator.alloc(http.http2.hpack.EncodedField, exchange.response.len);
                for (exchange.response, encoded) |field, *item| {
                    item.* = .{
                        .field = .{ .name = field.name, .value = field.value },
                        .indexing = indexingFor(field.name),
                    };
                }
                entries[at] = .{
                    .fields = encoded,
                    .body = responseLength(exchange.response),
                    .scenario = scenario_index,
                };
                at += 1;
            }
        }
        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *Fixture) void {
        for (self.entries) |item| self.allocator.free(item.fields);
        self.allocator.free(self.entries);
    }

    pub inline fn entry(self: Fixture, i: usize) Entry {
        return self.entries[i % self.entries.len];
    }
};

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn indexingFor(name: []const u8) http.http2.hpack.Indexing {
    if (same(name, "authorization") or same(name, "proxy-authorization") or same(name, "cookie") or same(name, "set-cookie"))
        return .never;
    if (same(name, ":path") or same(name, "date") or same(name, "etag") or same(name, "content-length") or
        same(name, "content-range") or same(name, "range") or same(name, "x-request-id") or
        same(name, "x-connection-hash") or same(name, "x-amz-request-id"))
        return .without;
    return .incremental;
}

fn responseLength(fields: []const corpus.Field) u32 {
    for (fields) |field| {
        if (same(field.name, "content-length")) return std.fmt.parseInt(u32, field.value, 10) catch 0;
    }
    return 0;
}

pub const Store = struct {
    const Slot = struct {
        id: u31 = 0,
        used: bool = false,
        value: http.http2.stream.Tracked = undefined,
        body: http.http2.fields.BodyState = .{},
    };
    slots: [store_slots]Slot = [_]Slot{.{}} ** store_slots,

    inline fn index(id: u31) usize {
        return (@as(usize, id) >> 1) % store_slots;
    }

    pub inline fn get(self: *Store, id: u31) ?*http.http2.stream.Tracked {
        const slot = &self.slots[index(id)];
        if (!slot.used or slot.id != id) return null;
        return &slot.value;
    }

    pub inline fn insert(self: *Store, id: u31, value: http.http2.stream.Tracked) ?*http.http2.stream.Tracked {
        const slot = &self.slots[index(id)];
        if (slot.used and slot.value.stream.state != .closed) return null;
        slot.* = .{ .id = id, .used = true, .value = value };
        return &slot.value;
    }

    pub inline fn maxActiveSendAdjustment(self: *Store) i32 {
        var result: i32 = 0;
        for (&self.slots) |*slot| {
            if (!slot.used) continue;
            switch (slot.value.stream.state) {
                .open, .half_closed_remote => result = @max(result, slot.value.windows.send.adjustment),
                else => {},
            }
        }
        return result;
    }

    pub inline fn bodyState(self: *Store, id: u31) ?*http.http2.fields.BodyState {
        const slot = &self.slots[index(id)];
        if (!slot.used or slot.id != id) return null;
        return &slot.body;
    }
};

pub const body_bytes = [_]u8{'x'} ** data_chunk;

pub inline fn nextStreamId(next: *u31) u31 {
    const id = next.*;
    next.* += 2;
    return id;
}

pub fn validateResponse(items: []const http.http2.hpack.EncodedField) !void {
    var validator = http.http2.fields.Validator.init(.response);
    for (items) |item| try validator.field(.{ .name = item.field.name, .value = item.field.value });
    try validator.finish();
}

pub fn print(label: []const u8, elapsed_ns: u64, transactions: u64, fields: u64, wire_bytes: u64) void {
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    std.debug.print("{s}: {d:.3} M tx/s, {d:.3} M fields/s, {d:.1} MiB/s wire, {d:.1} B/tx ({d:.3} s)\n", .{
        label,
        @as(f64, @floatFromInt(transactions)) / seconds / 1_000_000.0,
        @as(f64, @floatFromInt(fields)) / seconds / 1_000_000.0,
        @as(f64, @floatFromInt(wire_bytes)) / seconds / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(wire_bytes)) / @as(f64, @floatFromInt(transactions)),
        seconds,
    });
}
