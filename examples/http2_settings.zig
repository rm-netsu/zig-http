const std = @import("std");
const http = @import("http");

const h2 = http.http2;
const Connection = http.high_level.http2.Connection(.{
    .max_streams = 4,
    .header_block_bytes = 2048,
    .scratch_bytes = 2048,
    .frame_staging_bytes = 1024,
    .collected_fields = 16,
    .collected_field_bytes = 2048,
    .outbound_fields = 16,
});

fn relayOne(comptime Conn: type, receiver: *Conn, input: []const u8, control_out: *std.Io.Writer) !usize {
    const result = (try receiver.receive(input)) orelse return 0;
    try receiver.sendControl(control_out, result.control);
    return result.consumed;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var client_storage: Connection.Storage = undefined;
    var client = Connection.initClientInPlace(&client_storage, allocator);
    defer client.deinit();
    var server_storage: Connection.Storage = undefined;
    var server = Connection.initServerInPlace(&server_storage, allocator);
    defer server.deinit();

    var c2s_storage: [4096]u8 = undefined;
    var c2s = std.Io.Writer.fixed(&c2s_storage);
    var s2c_storage: [4096]u8 = undefined;
    var s2c = std.Io.Writer.fixed(&s2c_storage);

    _ = try client.start(&c2s);
    _ = try server.start(&s2c);

    var c2s_offset: usize = 0;
    var s2c_offset: usize = 0;
    while (!client.initialSettingsAcknowledged() or !server.initialSettingsAcknowledged()) {
        while (c2s_offset < c2s.end) c2s_offset += try relayOne(Connection, &server, c2s.buffered()[c2s_offset..], &s2c);
        while (s2c_offset < s2c.end) s2c_offset += try relayOne(Connection, &client, s2c.buffered()[s2c_offset..], &c2s);
    }

    const next: http.high_level.http2.LocalSettings = .{
        .initial_window_size = 128 * 1024,
        .max_frame_size = 32 * 1024,
        .max_concurrent_streams = 32,
        .max_header_list_size = 64 * 1024,
    };
    _ = (try client.sendLocalSettings(&c2s, next)) orelse unreachable;

    // Receive-capacity expansions are safe immediately, while restrictions and
    // HPACK synchronization become authoritative at the matching ACK.
    std.debug.assert(client.effectiveLocalSettings().initial_window_size == 128 * 1024);
    std.debug.assert(client.acknowledgedLocalSettings().initial_window_size == 65_535);

    while (c2s_offset < c2s.end) c2s_offset += try relayOne(Connection, &server, c2s.buffered()[c2s_offset..], &s2c);
    while (s2c_offset < s2c.end) s2c_offset += try relayOne(Connection, &client, s2c.buffered()[s2c_offset..], &c2s);

    std.debug.assert(client.pendingLocalSettings() == null);
    std.debug.assert(client.acknowledgedLocalSettings().initial_window_size == 128 * 1024);
}
