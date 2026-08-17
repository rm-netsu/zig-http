const std = @import("std");
const http = @import("http");

const stream_count: usize = 4096;
const rounds: usize = 50_000;

const Store = struct {
    const Slot = struct {
        used: bool = true,
        value: http.http2.stream.Tracked,
        body: http.http2.fields.BodyState = .{},
    };

    slots: [stream_count]Slot,
    scan_calls: u64 = 0,

    fn init() Store {
        var result: Store = undefined;
        result.scan_calls = 0;
        for (&result.slots) |*slot| {
            slot.* = .{ .value = http.http2.stream.Tracked.init(65_535) };
            slot.value.stream.state = .open;
        }
        return result;
    }

    pub inline fn get(_: *Store, _: u31) ?*http.http2.stream.Tracked {
        return null;
    }

    pub inline fn insert(_: *Store, _: u31, _: http.http2.stream.Tracked) ?*http.http2.stream.Tracked {
        return null;
    }

    pub fn maxActiveSendAdjustment(self: *Store) i32 {
        self.scan_calls += 1;
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

    pub fn bodyState(_: *Store, _: u31) ?*http.http2.fields.BodyState {
        return null;
    }
};

const Sink = struct {
    pub inline fn begin(_: *Sink, _: u31, _: http.http2.fields.Kind) void {}
    pub inline fn field(_: *Sink, _: u31, _: http.http2.fields.Kind, _: http.common.Header) void {}
    pub inline fn commit(_: *Sink, _: u31, _: http.http2.fields.Kind) void {}
    pub inline fn abort(_: *Sink, _: u31, _: http.http2.fields.Kind) void {}
};

fn settingBytes(value: u32) [6]u8 {
    var bytes: [6]u8 = undefined;
    http.http2.settings.encode(&bytes, .{ .id = .initial_window_size, .value = value });
    return bytes;
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var decoder = http.http2.hpack.Decoder.init(allocator, 4096);
    defer decoder.deinit();
    var encoder = http.http2.hpack.Encoder.init(allocator, 4096);
    defer encoder.deinit();
    var header_storage: [64]u8 = undefined;
    var session = http.http2.Session.init(.{ .role = .client, .decoder = &decoder, .encoder = &encoder, .header_storage = &header_storage });
    var store = Store.init();
    var sink: Sink = .{};
    var scratch: [1]u8 = undefined;

    const low = settingBytes(32_768);
    const high = settingBytes(65_535);
    const header: http.http2.frame.FrameHeader = .{ .length = 6, .type = .settings, .flags = 0, .stream_id = 0 };

    var checksum: u64 = 0;
    const runtime_seed: usize = @truncate(@as(u96, @bitCast(std.Io.Clock.awake.now(init.io).nanoseconds)));
    std.mem.doNotOptimizeAway(runtime_seed);
    const start = std.Io.Clock.awake.now(init.io).nanoseconds;
    for (0..rounds) |i| {
        const payload: []const u8 = if (((i +% runtime_seed) & 1) == 0) &low else &high;
        const event = try session.receiveComplete(&store, .{ .header = header, .payload = payload }, &scratch, &sink);
        if (event != .settings) return error.Protocol;
        checksum +%= session.peer.settings.initial_window_size;
    }
    const elapsed: u64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds - start);
    std.mem.doNotOptimizeAway(&store);
    std.mem.doNotOptimizeAway(&session);
    std.mem.doNotOptimizeAway(checksum);

    const seconds = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
    const rate = @as(f64, @floatFromInt(rounds)) / seconds;
    std.debug.print("SETTINGS initial-window lazy: {d:.3} M settings/s, scans={} ({d:.3} s)\n", .{
        rate / 1_000_000.0,
        store.scan_calls,
        seconds,
    });
}
