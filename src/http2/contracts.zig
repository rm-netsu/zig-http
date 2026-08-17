const std = @import("std");

fn implementationType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        else => T,
    };
}

fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    const Impl = implementationType(T);
    return isContainer(Impl) and @hasDecl(Impl, name);
}

/// Returns whether `T` declares the minimal caller-owned stream-table operations
/// consumed by `streams.Manager`: `get` and `insert`. This is an early
/// diagnostic preflight only; normal Zig method resolution still validates the
/// exact callable signatures when an operation is instantiated. The actual
/// stream-table representation, allocation strategy, synchronization, and
/// lookup complexity remain entirely caller-defined.
pub fn hasStreamStore(comptime T: type) bool {
    return hasDecl(T, "get") and hasDecl(T, "insert");
}

/// Emits a short, API-oriented diagnostic before generic method resolution can
/// fail deep inside the stream state machine.
pub fn assertStreamStore(comptime T: type) void {
    if (!hasDecl(T, "get"))
        @compileError("zig-http HTTP/2 stream store must provide get(stream_id) returning ?*http2.stream.Tracked");
    if (!hasDecl(T, "insert"))
        @compileError("zig-http HTTP/2 stream store must provide insert(stream_id, tracked) returning ?*http2.stream.Tracked");
}

/// `Session` needs one additional rare-path query when a positive
/// SETTINGS_INITIAL_WINDOW_SIZE delta could overflow an active stream window.
pub fn hasSessionStore(comptime T: type) bool {
    return hasStreamStore(T) and hasDecl(T, "maxActiveSendAdjustment");
}

pub fn assertSessionStore(comptime T: type) void {
    assertStreamStore(T);
    if (!hasDecl(T, "maxActiveSendAdjustment"))
        @compileError("zig-http HTTP/2 Session store must provide maxActiveSendAdjustment() i32");
}

/// Header sinks are deliberately structural and synchronous so callers can
/// project fields directly into their own request/response representation.
pub fn hasFieldSink(comptime T: type) bool {
    return hasDecl(T, "field");
}

pub fn assertFieldSink(comptime T: type) void {
    if (!hasDecl(T, "field"))
        @compileError("zig-http HTTP/2 field sink must provide field(stream_id, kind, header)");
}

/// Trailer policies are caller-owned because core cannot know the semantics of
/// every registered or application-defined HTTP field. The composed HTTP/2
/// send path uses this structural contract only for non-empty trailer blocks.
pub fn hasTrailerPolicy(comptime T: type) bool {
    return hasDecl(T, "allows");
}

pub fn assertTrailerPolicy(comptime T: type) void {
    if (!hasDecl(T, "allows"))
        @compileError("zig-http HTTP/2 trailer policy must provide allows(name) bool");
}

test "contract predicates detect required structural declarations" {
    const Store = struct {
        pub fn get(_: *@This(), _: u31) ?*u8 {
            return null;
        }
        pub fn insert(_: *@This(), _: u31, _: u8) ?*u8 {
            return null;
        }
        pub fn maxActiveSendAdjustment(_: *@This()) i32 {
            return 0;
        }
    };
    const Sink = struct {
        pub fn field(_: *@This(), _: u31, _: u8, _: u8) void {}
    };
    const Incomplete = struct {};

    try std.testing.expect(hasStreamStore(*Store));
    try std.testing.expect(hasSessionStore(*Store));
    const TrailerPolicy = struct {
        pub fn allows(_: @This(), _: []const u8) bool {
            return true;
        }
    };

    try std.testing.expect(hasFieldSink(*Sink));
    try std.testing.expect(hasTrailerPolicy(TrailerPolicy));
    try std.testing.expect(!hasStreamStore(*Incomplete));
    try std.testing.expect(!hasSessionStore(*Incomplete));
    try std.testing.expect(!hasFieldSink(*Incomplete));
    try std.testing.expect(!hasTrailerPolicy(*Incomplete));
}
