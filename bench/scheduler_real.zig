const std = @import("std");
const http = @import("http");
const corpus = @import("real_corpus.zig");

pub const streams_per_connection: usize = 64;
pub const rounds: usize = 8_000_000;

pub const Candidate = http.http2.scheduler.Candidate;

pub fn runtimeSeed(init: std.process.Init) !usize {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next(); // executable name
    if (args.next()) |value| return try std.fmt.parseInt(usize, value, 10);
    return @truncate(@as(u96, @bitCast(std.Io.Clock.awake.now(init.io).nanoseconds)));
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
};

pub const Context = struct {
    decoder: http.http2.hpack.Decoder,
    encoder: http.http2.hpack.Encoder,
    session: http.http2.Session,
    store: Store = .{},
    header_storage: [64]u8 = undefined,
    candidates: [streams_per_connection]Candidate = undefined,

    pub fn init(self: *Context, allocator: std.mem.Allocator, runtime_seed: usize) !void {
        self.decoder = http.http2.hpack.Decoder.init(allocator, 4096);
        self.encoder = http.http2.hpack.Encoder.init(allocator, 4096);
        self.store = .{};
        self.session = http.http2.Session.init(.{ .role = .client, .decoder = &self.decoder, .encoder = &self.encoder, .header_storage = &self.header_storage });
        self.session.peer.send_window.value = 0x7fff_ffff;

        var i: usize = 0;
        while (i < streams_per_connection) : (i += 1) {
            const id: u31 = @intCast(i * 2 + 1);
            try self.session.streams.openLocal(&self.store, &self.session.peer, id, false);
            const body = bodyAt(i + runtime_seed);
            self.candidates[i] = .{ .stream_id = id, .remaining = body };
            const tracked = self.store.get(id).?;
            const effective: i32 = if (((i + runtime_seed) & 3) == 0)
                0
            else
                @intCast(1024 + ((body + @as(u32, @truncate(runtime_seed))) % 65_000));
            tracked.windows.send.adjustment = effective - @as(i32, @intCast(self.session.peer.settings.initial_window_size));
        }
    }

    pub fn deinit(self: *Context) void {
        self.decoder.deinit();
        self.encoder.deinit();
    }
};

fn bodyAt(index: usize) usize {
    var current: usize = 0;
    for (corpus.scenarios) |scenario| {
        for (scenario.exchanges) |exchange| {
            if (current == index % exchangeCount()) return responseLength(exchange.response);
            current += 1;
        }
    }
    unreachable;
}

fn exchangeCount() usize {
    var total: usize = 0;
    for (corpus.scenarios) |scenario| total += scenario.exchanges.len;
    return total;
}

fn responseLength(fields: []const corpus.Field) usize {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, "content-length"))
            return std.fmt.parseInt(usize, field.value, 10) catch 0;
    }
    // Captures without a Content-Length still represent runnable response DATA
    // in real deployments; use a small body instead of turning them all idle.
    return 4096;
}

pub inline fn setConnectionPhase(ctx: *Context, round: usize) void {
    ctx.session.peer.send_window.value = if ((round & 15) == 0) 0 else 0x7fff_ffff;
}

pub fn print(label: []const u8, elapsed_ns: u64, decisions: u64, checksum: u64) void {
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const rate = @as(f64, @floatFromInt(decisions)) / seconds;
    std.debug.print("{s}: {d:.3} M decisions/s ({d} decisions, {d:.3} s, checksum={d})\n", .{
        label,
        rate / 1_000_000.0,
        decisions,
        seconds,
        checksum,
    });
}
