const std = @import("std");
const hpack = @import("hpack");
const frame = @import("frame.zig");
const peer = @import("peer.zig");
const preface = @import("preface.zig");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const settings = @import("settings.zig");

/// Transport-neutral HTTP/2 connection-preface coordinator.
///
/// `Bootstrap` owns only connection establishment ordering. The caller still
/// owns the transport, HPACK objects, stream storage, buffers, and event loop.
/// Once the peer preface has been accepted, subsequent frames are forwarded to
/// the existing composed `Session` without another protocol layer.
pub const Bootstrap = struct {
    role: peer.Role,
    parser: preface.Parser = .{},
    local_state: LocalState = .unsent,
    peer_settings_seen: bool = false,
    failed: bool = false,

    const LocalState = enum(u2) { unsent, sent, poisoned };

    pub const StartError = session_mod.SendSettingsError || error{ AlreadyStarted, RoleMismatch };
    pub const ReceiveError = hpack.codec.Error || error{
        HeaderBlockTooLarge,
        FrameSize,
        Protocol,
        InvalidPreface,
        RoleMismatch,
    };

    /// A result can consume only client-preface bytes and therefore carry no
    /// Session event. This makes fragmented preface handling explicit without
    /// requiring callers to retain bytes that have already been validated.
    pub const ReceiveResult = struct {
        consumed: usize,
        event: ?session_mod.Event = null,
    };

    pub fn init(role: peer.Role) Bootstrap {
        var result: Bootstrap = .{ .role = role };
        // Clients do not receive the 24-byte magic; the server preface starts
        // directly with its SETTINGS frame.
        if (role == .client) result.parser.done = true;
        return result;
    }

    /// Writes this endpoint's complete connection preface exactly once. For a
    /// client this is the 24-byte magic followed by initial SETTINGS; for a
    /// server it is just initial SETTINGS. Local SETTINGS are preflighted before
    /// any preface byte is written.
    ///
    /// Any writer/codec failure after output begins poisons Bootstrap. The
    /// entire connection must then be discarded, matching Session send-failure
    /// semantics.
    pub fn start(
        self: *Bootstrap,
        session: *session_mod.Session,
        sync: *session_mod.SettingsSync,
        out: *std.Io.Writer,
        items: []const settings.Setting,
    ) StartError!session_mod.SettingsTicket {
        if (session.role() != self.role) return error.RoleMismatch;
        if (self.local_state == .sent) return error.AlreadyStarted;
        if (self.local_state == .poisoned or session.sendPoisoned()) return error.SendPoisoned;

        // Avoid emitting the client magic and only then discovering invalid
        // local SETTINGS.
        try session.preflightSettings(items);

        if (self.role == .client) {
            out.writeAll(preface.bytes) catch |err| {
                self.local_state = .poisoned;
                return err;
            };
        }

        const ticket = session.sendSettings(sync, out, items) catch |err| {
            self.local_state = .poisoned;
            return err;
        };
        self.local_state = .sent;
        return ticket;
    }

    /// Receives at most one composed Session event while also consuming the
    /// server-side client magic and enforcing that the peer's first frame is a
    /// non-ACK SETTINGS frame. Additional frames may immediately follow the
    /// initial SETTINGS and are accepted on subsequent calls without waiting
    /// for its ACK, as required by RFC 9113 connection establishment.
    pub fn receiveBytes(
        self: *Bootstrap,
        session: *session_mod.Session,
        store: anytype,
        input: []const u8,
        receiver_max_frame_size: u32,
        scratch: []u8,
        sink: anytype,
    ) ReceiveError!?ReceiveResult {
        if (session.role() != self.role) return error.RoleMismatch;
        if (self.failed) return error.InvalidPreface;

        var consumed_prefix: usize = 0;
        if (!self.parser.done) {
            const used = self.parser.feed(input) catch {
                self.failed = true;
                return error.InvalidPreface;
            };
            consumed_prefix += used;
            if (!self.parser.done) return .{ .consumed = consumed_prefix };
        }

        const remaining = input[consumed_prefix..];
        if (!self.peer_settings_seen) {
            const parsed = (try frame.parseComplete(remaining, receiver_max_frame_size)) orelse {
                if (consumed_prefix == 0) return null;
                return .{ .consumed = consumed_prefix };
            };

            // A SETTINGS ACK cannot be the peer connection preface: it carries
            // no initial settings and can only acknowledge a previously
            // received SETTINGS frame.
            if (parsed.frame.header.type != .settings or (parsed.frame.header.flags & 0x01) != 0) {
                self.failed = true;
                return .{
                    .consumed = consumed_prefix + parsed.consumed,
                    .event = .{ .fault = .{ .connection = .protocol_error } },
                };
            }

            const event = try session.receiveComplete(store, parsed.frame, scratch, sink);
            switch (event) {
                .settings => |applied| {
                    if (applied.ack) unreachable;
                    self.peer_settings_seen = true;
                },
                .fault => self.failed = true,
                else => unreachable,
            }
            return .{ .consumed = consumed_prefix + parsed.consumed, .event = event };
        }

        const result = (try session.receiveBytes(
            store,
            remaining,
            receiver_max_frame_size,
            scratch,
            sink,
        )) orelse {
            if (consumed_prefix == 0) return null;
            return .{ .consumed = consumed_prefix };
        };
        return .{ .consumed = consumed_prefix + result.consumed, .event = result.event };
    }

    pub inline fn localPrefaceSent(self: Bootstrap) bool {
        return self.local_state == .sent;
    }

    pub inline fn peerPrefaceReceived(self: Bootstrap) bool {
        return self.parser.done and self.peer_settings_seen;
    }

    pub inline fn active(self: Bootstrap) bool {
        return self.localPrefaceSent() and self.peerPrefaceReceived();
    }

    pub inline fn sendPoisoned(self: Bootstrap) bool {
        return self.local_state == .poisoned;
    }
};

// Full integration behavior is exercised by the conformance fixture. Keep unit
// coverage here focused on the ordering state machine so this module does not
// duplicate Session's stream-store fixtures.
test "bootstrap client skips inbound magic while server parses it incrementally" {
    var client = Bootstrap.init(.client);
    try std.testing.expect(client.parser.done);
    try std.testing.expect(!client.peerPrefaceReceived());

    var server = Bootstrap.init(.server);
    try std.testing.expect(!server.parser.done);
    const first = try server.parser.feed(preface.bytes[0..7]);
    try std.testing.expectEqual(@as(usize, 7), first);
    try std.testing.expect(!server.parser.done);
    const rest = try server.parser.feed(preface.bytes[7..]);
    try std.testing.expectEqual(preface.bytes.len - 7, rest);
    try std.testing.expect(server.parser.done);
}

test "bootstrap exposes active only after both connection prefaces" {
    var state = Bootstrap.init(.client);
    state.local_state = .sent;
    try std.testing.expect(!state.active());
    state.peer_settings_seen = true;
    try std.testing.expect(state.active());
}

const fields = @import("fields.zig");
const stream = @import("stream.zig");

const TestStore = struct {
    tracked: stream.Tracked = stream.Tracked.init(65_535),
    body: fields.BodyState = .{},
    present: bool = false,

    pub fn get(self: *TestStore, _: u31) ?*stream.Tracked {
        return if (self.present) &self.tracked else null;
    }

    pub fn insert(self: *TestStore, _: u31, value: stream.Tracked) ?*stream.Tracked {
        if (self.present) return null;
        self.tracked = value;
        self.present = true;
        return &self.tracked;
    }

    pub fn maxActiveSendAdjustment(_: *TestStore) i32 {
        return 0;
    }

    pub fn bodyState(self: *TestStore, _: u31) ?*fields.BodyState {
        return if (self.present) &self.body else null;
    }
};

test "bootstrap start emits complete client connection preface" {
    const allocator = std.testing.allocator;
    var decoder = hpack.Decoder.init(allocator, 4096);
    defer decoder.deinit();
    var encoder = hpack.Encoder.init(allocator, 4096);
    defer encoder.deinit();
    var header_storage: [64]u8 = undefined;
    var session = session_mod.Session.init(.{ .role = .client, .decoder = &decoder, .encoder = &encoder, .header_storage = &header_storage });
    var sync: session_mod.SettingsSync = .{};
    var bootstrap = Bootstrap.init(.client);
    var wire_storage: [128]u8 = undefined;
    var wire = std.Io.Writer.fixed(&wire_storage);

    const ticket = try bootstrap.start(&session, &sync, &wire, &.{});
    try std.testing.expectEqual(@as(session_mod.SettingsTicket, 1), ticket);
    const bytes_out = wire.buffered();
    try std.testing.expect(std.mem.startsWith(u8, bytes_out, preface.bytes));
    try std.testing.expectEqual(preface.bytes.len + 9, bytes_out.len);
    const header: *const [9]u8 = bytes_out[preface.bytes.len..][0..9];
    const parsed = frame.FrameHeader.parse(header);
    try std.testing.expectEqual(frame.Type.settings, parsed.type);
    try std.testing.expectEqual(@as(u24, 0), parsed.length);
    try std.testing.expect(bootstrap.localPrefaceSent());
    try std.testing.expect(!bootstrap.active());
}

test "bootstrap receives fragmented client magic and initial SETTINGS" {
    const allocator = std.testing.allocator;
    var decoder = hpack.Decoder.init(allocator, 4096);
    defer decoder.deinit();
    var encoder = hpack.Encoder.init(allocator, 4096);
    defer encoder.deinit();
    var header_storage: [64]u8 = undefined;
    var session = session_mod.Session.init(.{ .role = .server, .decoder = &decoder, .encoder = &encoder, .header_storage = &header_storage });
    var bootstrap = Bootstrap.init(.server);
    var store: TestStore = .{};
    var sink: session_mod.NullSink = .{};
    var scratch: [64]u8 = undefined;

    var settings_header: [9]u8 = undefined;
    try (frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0, .stream_id = 0 }).encode(&settings_header);
    const input = preface.bytes.* ++ settings_header;

    const first = (try bootstrap.receiveBytes(&session, &store, input[0..10], frame.default_max_frame_size, &scratch, &sink)).?;
    try std.testing.expectEqual(@as(usize, 10), first.consumed);
    try std.testing.expect(first.event == null);

    const second = (try bootstrap.receiveBytes(&session, &store, input[10..], frame.default_max_frame_size, &scratch, &sink)).?;
    try std.testing.expectEqual(input.len - 10, second.consumed);
    switch (second.event.?) {
        .settings => |applied| try std.testing.expect(!applied.ack),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(bootstrap.peerPrefaceReceived());
}

test "bootstrap rejects ACK as peer initial SETTINGS" {
    const allocator = std.testing.allocator;
    var decoder = hpack.Decoder.init(allocator, 4096);
    defer decoder.deinit();
    var encoder = hpack.Encoder.init(allocator, 4096);
    defer encoder.deinit();
    var header_storage: [64]u8 = undefined;
    var session = session_mod.Session.init(.{ .role = .client, .decoder = &decoder, .encoder = &encoder, .header_storage = &header_storage });
    var bootstrap = Bootstrap.init(.client);
    var store: TestStore = .{};
    var sink: session_mod.NullSink = .{};
    var scratch: [64]u8 = undefined;
    var settings_header: [9]u8 = undefined;
    try (frame.FrameHeader{ .length = 0, .type = .settings, .flags = 0x01, .stream_id = 0 }).encode(&settings_header);

    const result = (try bootstrap.receiveBytes(&session, &store, &settings_header, frame.default_max_frame_size, &scratch, &sink)).?;
    switch (result.event.?) {
        .fault => |fault| switch (fault) {
            .connection => |code| try std.testing.expectEqual(protocol.ErrorCode.protocol_error, code),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}
