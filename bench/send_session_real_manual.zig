const std = @import("std");
const http = @import("http");
const shared = @import("send_session_real.zig");

const Context = struct {
    encoder: http.http2.hpack.Encoder,
    peer: http.http2.peer.State,
    manager: http.http2.streams.Manager,
    store: shared.Store = .{},
    next_stream_id: u31 = 1,

    fn init(allocator: std.mem.Allocator) Context {
        return .{
            .encoder = http.http2.hpack.Encoder.init(allocator, 4096),
            .peer = http.http2.peer.State.init(.server),
            .manager = http.http2.streams.Manager.init(.server, .{}),
        };
    }
    fn deinit(self: *Context) void {
        self.encoder.deinit();
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var fixture = try shared.Fixture.init(allocator);
    defer fixture.deinit();
    var contexts: [shared.max_scenarios]Context = undefined;
    for (&contexts) |*ctx| ctx.* = Context.init(allocator);
    defer for (&contexts) |*ctx| ctx.deinit();

    var discard_buffer: [8192]u8 = undefined;
    var discard = std.Io.Writer.Discarding.init(&discard_buffer);
    var staging: [4097]u8 = undefined;
    var tx: u64 = 0;
    var fields_total: u64 = 0;
    var checksum: u64 = 0;
    const start = std.Io.Clock.awake.now(init.io).nanoseconds;
    for (0..shared.rounds) |round| {
        const entry = fixture.entry(round);
        var ctx = &contexts[entry.scenario];
        const id = shared.nextStreamId(&ctx.next_stream_id);
        if (ctx.manager.receiveHeaders(&ctx.store, id, true) != .accepted) return error.Protocol;
        try shared.validateResponse(entry.fields);
        try ctx.manager.localHeaders(&ctx.store, &ctx.peer, id, entry.body == 0);
        var framer = try http.http2.send.HeaderFramer.init(&discard.writer, &staging, ctx.peer.settings.max_frame_size, id, entry.body == 0);
        for (entry.fields) |item| try ctx.encoder.field(&framer.writer, item.field, item.indexing);
        const stats = try framer.finish();
        ctx.store.get(id).?.local_headers = .regular;
        checksum +%= stats.encoded_bytes + stats.frame_count;

        var left = entry.body;
        while (left != 0) {
            const n: u32 = @intCast(@min(@as(usize, left), shared.data_chunk));
            left -= n;
            const header: http.http2.frame.FrameHeader = .{ .length = n, .type = .data, .flags = @intFromBool(left == 0), .stream_id = id };
            try http.http2.frame.writeFrame(&discard.writer, header, shared.body_bytes[0..n]);
            try ctx.peer.consumeSend(n);
            try ctx.manager.localData(&ctx.store, &ctx.peer, id, n, left == 0);
            try ctx.peer.send_window.update(@intCast(n));
            try ctx.store.get(id).?.windows.send.update(ctx.peer.settings.initial_window_size, @intCast(n));
            checksum +%= n;
        }
        tx += 1;
        fields_total += entry.fields.len;
    }
    const elapsed: u64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds - start);
    const wire_bytes = discard.fullCount();
    checksum +%= wire_bytes;
    std.mem.doNotOptimizeAway(checksum);
    shared.print("send session manual", elapsed, tx, fields_total, wire_bytes);
}
