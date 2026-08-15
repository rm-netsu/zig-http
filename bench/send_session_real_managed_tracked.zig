const std = @import("std");
const http = @import("http");
const shared = @import("send_session_real.zig");

const Context = struct {
    decoder: http.http2.hpack.Decoder,
    encoder: http.http2.hpack.Encoder,
    session: http.http2.Session,
    store: shared.Store = .{},
    next_stream_id: u31 = 1,
    header_storage: [4096]u8 = undefined,

    fn init(self: *Context, allocator: std.mem.Allocator) void {
        self.decoder = http.http2.hpack.Decoder.init(allocator, 4096);
        self.encoder = http.http2.hpack.Encoder.init(allocator, 4096);
        self.store = .{};
        self.next_stream_id = 1;
        self.session = http.http2.Session.init(.server, .{}, &self.decoder, &self.encoder, &self.header_storage);
    }
    fn deinit(self: *Context) void {
        self.decoder.deinit();
        self.encoder.deinit();
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var fixture = try shared.Fixture.init(allocator);
    defer fixture.deinit();
    var contexts: [shared.max_scenarios]Context = undefined;
    for (&contexts) |*ctx| ctx.init(allocator);
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
        if (ctx.session.streams.receiveHeaders(&ctx.store, &ctx.session.peer, id, true) != .accepted) return error.Protocol;
        const existing = ctx.session.streams.existing(&ctx.store, id).?;
        const stats = try ctx.session.sendHeadersExisting(&discard.writer, existing, entry.body == 0, &staging, entry.fields);
        checksum +%= stats.encoded_bytes + stats.frame_count;

        var left = entry.body;
        while (left != 0) {
            const chunk = shared.body_bytes[0..@min(@as(usize, left), shared.data_chunk)];
            const result = try ctx.session.sendDataExisting(&discard.writer, existing, chunk, left <= chunk.len);
            if (result.blocked or result.consumed == 0) return error.FlowControl;
            left -= @intCast(result.consumed);
            try ctx.session.peer.send_window.update(@intCast(result.consumed));
            try ctx.store.get(id).?.windows.send.update(@intCast(result.consumed));
            checksum +%= result.consumed;
        }
        tx += 1;
        fields_total += entry.fields.len;
    }
    const elapsed: u64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds - start);
    const wire_bytes = discard.fullCount();
    checksum +%= wire_bytes;
    std.mem.doNotOptimizeAway(checksum);
    shared.print("send session managed tracked", elapsed, tx, fields_total, wire_bytes);
}
