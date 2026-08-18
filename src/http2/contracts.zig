const std = @import("std");
const common = @import("../common.zig");
const fields = @import("fields.zig");
const stream = @import("stream.zig");

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

fn methodType(comptime T: type, comptime name: []const u8) ?type {
    const Impl = implementationType(T);
    if (!isContainer(Impl) or !@hasDecl(Impl, name)) return null;
    return @TypeOf(@field(Impl, name));
}

fn exactMethod(
    comptime T: type,
    comptime name: []const u8,
    comptime params: []const type,
    comptime Return: type,
) bool {
    const Method = methodType(T, name) orelse return false;
    const info = switch (@typeInfo(Method)) {
        .@"fn" => |value| value,
        else => return false,
    };
    if (info.params.len != params.len or info.return_type == null or info.return_type.? != Return) return false;
    inline for (info.params, 0..) |param, index| {
        if (param.type == null or param.type.? != params[index]) return false;
    }
    return true;
}

fn receiverType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => T,
        else => *T,
    };
}

fn sinkReceiverMatches(comptime T: type, comptime Actual: type) bool {
    const Expected = receiverType(T);
    if (Actual == Expected) return true;
    return switch (@typeInfo(Actual)) {
        .pointer => |actual| switch (@typeInfo(Expected)) {
            .pointer => |expected| actual.child == expected.child,
            else => false,
        },
        else => false,
    };
}

fn sinkMethod(
    comptime T: type,
    comptime name: []const u8,
    comptime tail_params: []const type,
) bool {
    const Method = methodType(T, name) orelse return false;
    const info = switch (@typeInfo(Method)) {
        .@"fn" => |value| value,
        else => return false,
    };
    if (info.params.len != tail_params.len + 1 or info.return_type == null or info.return_type.? != void) return false;
    if (info.params[0].type == null or !sinkReceiverMatches(T, info.params[0].type.?)) return false;
    inline for (tail_params, 0..) |Expected, index| {
        const param = info.params[index + 1];
        if (param.type == null or param.type.? != Expected) return false;
    }
    return true;
}

fn streamGet(comptime T: type) bool {
    const Self = receiverType(T);
    return exactMethod(T, "get", &.{ Self, u31 }, ?*stream.Tracked);
}

fn streamInsert(comptime T: type) bool {
    const Self = receiverType(T);
    return exactMethod(T, "insert", &.{ Self, u31, stream.Tracked }, ?*stream.Tracked);
}

/// Returns whether `T` satisfies the caller-owned stream-table contract used by
/// `streams.Manager`. Unlike ordinary method lookup, this checks the complete
/// public signature so an invalid adapter fails at the API boundary instead of
/// during a deeper generic instantiation.
pub fn hasStreamStore(comptime T: type) bool {
    return streamGet(T) and streamInsert(T);
}

/// Emits short API-oriented diagnostics for malformed stream-store adapters.
pub fn assertStreamStore(comptime T: type) void {
    if (!hasDecl(T, "get"))
        @compileError("zig-http HTTP/2 stream store must provide get(self, stream_id: u31) ?*http2.stream.Tracked");
    if (!streamGet(T))
        @compileError("zig-http HTTP/2 stream store get signature must be get(self, stream_id: u31) ?*http2.stream.Tracked");
    if (!hasDecl(T, "insert"))
        @compileError("zig-http HTTP/2 stream store must provide insert(self, stream_id: u31, tracked: http2.stream.Tracked) ?*http2.stream.Tracked");
    if (!streamInsert(T))
        @compileError("zig-http HTTP/2 stream store insert signature must be insert(self, stream_id: u31, tracked: http2.stream.Tracked) ?*http2.stream.Tracked");
}

fn sessionMaxAdjustment(comptime T: type) bool {
    const Self = receiverType(T);
    return exactMethod(T, "maxActiveSendAdjustment", &.{Self}, i32);
}

fn sessionBodyState(comptime T: type) bool {
    const Self = receiverType(T);
    return exactMethod(T, "bodyState", &.{ Self, u31 }, ?*fields.BodyState);
}

/// `Session` extends the stream-table contract with caller-owned body semantics
/// and the rare SETTINGS_INITIAL_WINDOW_SIZE exact high-water query.
pub fn hasSessionStore(comptime T: type) bool {
    return hasStreamStore(T) and sessionMaxAdjustment(T) and sessionBodyState(T);
}

pub fn assertSessionStore(comptime T: type) void {
    assertStreamStore(T);
    if (!hasDecl(T, "maxActiveSendAdjustment"))
        @compileError("zig-http HTTP/2 Session store must provide maxActiveSendAdjustment(self) i32");
    if (!sessionMaxAdjustment(T))
        @compileError("zig-http HTTP/2 Session store maxActiveSendAdjustment signature must be maxActiveSendAdjustment(self) i32");
    if (!hasDecl(T, "bodyState"))
        @compileError("zig-http HTTP/2 Session store must provide bodyState(self, stream_id: u31) ?*http2.fields.BodyState");
    if (!sessionBodyState(T))
        @compileError("zig-http HTTP/2 Session store bodyState signature must be bodyState(self, stream_id: u31) ?*http2.fields.BodyState");
}

fn sinkBegin(comptime T: type) bool {
    return sinkMethod(T, "begin", &.{ u31, fields.Kind });
}

fn sinkField(comptime T: type) bool {
    return sinkMethod(T, "field", &.{ u31, fields.Kind, common.Header });
}

fn sinkCommit(comptime T: type) bool {
    return sinkMethod(T, "commit", &.{ u31, fields.Kind });
}

fn sinkAbort(comptime T: type) bool {
    return sinkMethod(T, "abort", &.{ u31, fields.Kind });
}

/// Header sinks are structural, synchronous, and transactional. HPACK field
/// slices are callback-lifetime borrows, so Session cannot stage them itself;
/// instead the sink stages application side effects between begin/commit and
/// rolls them back on abort if a later field invalidates the section.
pub fn hasFieldSink(comptime T: type) bool {
    return sinkBegin(T) and sinkField(T) and sinkCommit(T) and sinkAbort(T);
}

pub fn assertFieldSink(comptime T: type) void {
    if (!hasDecl(T, "begin"))
        @compileError("zig-http HTTP/2 field sink must provide begin(self, stream_id: u31, kind: http2.fields.Kind) void");
    if (!sinkBegin(T))
        @compileError("zig-http HTTP/2 field sink begin signature must be begin(self, stream_id: u31, kind: http2.fields.Kind) void");
    if (!hasDecl(T, "field"))
        @compileError("zig-http HTTP/2 field sink must provide field(self, stream_id: u31, kind: http2.fields.Kind, header: http.common.Header) void");
    if (!sinkField(T))
        @compileError("zig-http HTTP/2 field sink field signature must be field(self, stream_id: u31, kind: http2.fields.Kind, header: http.common.Header) void");
    if (!hasDecl(T, "commit"))
        @compileError("zig-http HTTP/2 field sink must provide commit(self, stream_id: u31, kind: http2.fields.Kind) void");
    if (!sinkCommit(T))
        @compileError("zig-http HTTP/2 field sink commit signature must be commit(self, stream_id: u31, kind: http2.fields.Kind) void");
    if (!hasDecl(T, "abort"))
        @compileError("zig-http HTTP/2 field sink must provide abort(self, stream_id: u31, kind: http2.fields.Kind) void");
    if (!sinkAbort(T))
        @compileError("zig-http HTTP/2 field sink abort signature must be abort(self, stream_id: u31, kind: http2.fields.Kind) void");
}

fn trailerAllows(comptime T: type) bool {
    const Method = methodType(T, "allows") orelse return false;
    const info = switch (@typeInfo(Method)) {
        .@"fn" => |value| value,
        else => return false,
    };
    if (info.params.len != 2 or info.return_type == null or info.return_type.? != bool) return false;
    if (info.params[0].type == null or info.params[1].type == null) return false;
    const Receiver = info.params[0].type.?;
    const Impl = implementationType(T);
    if (Receiver != T and Receiver != Impl and Receiver != *Impl and Receiver != *const Impl) return false;
    return info.params[1].type.? == []const u8;
}

/// Trailer policies are caller-owned because core cannot know the semantics of
/// every registered or application-defined HTTP field.
pub fn hasTrailerPolicy(comptime T: type) bool {
    return trailerAllows(T);
}

pub fn assertTrailerPolicy(comptime T: type) void {
    if (!hasDecl(T, "allows"))
        @compileError("zig-http HTTP/2 trailer policy must provide allows(self, name: []const u8) bool");
    if (!trailerAllows(T))
        @compileError("zig-http HTTP/2 trailer policy allows signature must be allows(self, name: []const u8) bool");
}

test "contract predicates validate complete structural signatures" {
    const Store = struct {
        tracked: stream.Tracked = undefined,
        body: fields.BodyState = .{},
        pub fn get(self: *@This(), _: u31) ?*stream.Tracked {
            return &self.tracked;
        }
        pub fn insert(self: *@This(), _: u31, value: stream.Tracked) ?*stream.Tracked {
            self.tracked = value;
            return &self.tracked;
        }
        pub fn maxActiveSendAdjustment(_: *@This()) i32 {
            return 0;
        }
        pub fn bodyState(self: *@This(), _: u31) ?*fields.BodyState {
            return &self.body;
        }
    };
    const BadStore = struct {
        pub fn get(_: *@This(), _: u31) ?*u8 {
            return null;
        }
        pub fn insert(_: *@This(), _: u31, _: u8) ?*u8 {
            return null;
        }
        pub fn maxActiveSendAdjustment(_: *@This()) u32 {
            return 0;
        }
        pub fn bodyState(_: *@This(), _: u31) ?*u8 {
            return null;
        }
    };
    const Sink = struct {
        pub fn begin(_: *@This(), _: u31, _: fields.Kind) void {}
        pub fn field(_: *@This(), _: u31, _: fields.Kind, _: common.Header) void {}
        pub fn commit(_: *@This(), _: u31, _: fields.Kind) void {}
        pub fn abort(_: *@This(), _: u31, _: fields.Kind) void {}
    };
    const BadSink = struct {
        pub fn begin(_: *@This(), _: u31, _: u8) void {}
        pub fn field(_: *@This(), _: u31, _: u8, _: u8) void {}
        pub fn commit(_: *@This(), _: u31, _: u8) void {}
        pub fn abort(_: *@This(), _: u31, _: u8) void {}
    };
    const TrailerPolicy = struct {
        pub fn allows(_: @This(), _: []const u8) bool {
            return true;
        }
    };
    const BadTrailerPolicy = struct {
        pub fn allows(_: @This(), _: []const u8) u8 {
            return 1;
        }
    };
    const Incomplete = struct {};

    comptime {
        assertStreamStore(*Store);
        assertSessionStore(*Store);
        assertFieldSink(*Sink);
        assertTrailerPolicy(TrailerPolicy);
    }

    try std.testing.expect(hasStreamStore(*Store));
    try std.testing.expect(hasSessionStore(*Store));
    try std.testing.expect(!hasStreamStore(*const Store));
    try std.testing.expect(!hasSessionStore(*const Store));
    try std.testing.expect(!hasStreamStore(*BadStore));
    try std.testing.expect(!hasSessionStore(*BadStore));
    try std.testing.expect(hasFieldSink(*Sink));
    try std.testing.expect(!hasFieldSink(*BadSink));
    try std.testing.expect(hasTrailerPolicy(TrailerPolicy));
    try std.testing.expect(!hasTrailerPolicy(BadTrailerPolicy));
    try std.testing.expect(!hasStreamStore(*Incomplete));
    try std.testing.expect(!hasSessionStore(*Incomplete));
    try std.testing.expect(!hasFieldSink(*Incomplete));
    try std.testing.expect(!hasTrailerPolicy(*Incomplete));
}
