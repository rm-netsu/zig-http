const std = @import("std");
const http = @import("http");

const Recovery = union(enum) {
    close_connection: http.http2.protocol.ErrorCode,
    reset_stream: struct {
        stream_id: u31,
        code: http.http2.protocol.ErrorCode,
    },
};

/// Peer HTTP/2 faults preserve protocol scope. The transport integration can
/// then choose Session state-aware writers or the lower-level frame writers
/// described in docs/operations.md.
fn recoveryForFault(fault: http.http2.session.Fault) Recovery {
    return switch (fault) {
        .connection => |code| .{ .close_connection = code },
        .stream => |stream_fault| .{ .reset_stream = .{
            .stream_id = stream_fault.stream_id,
            .code = stream_fault.code,
        } },
    };
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    const stream_recovery = recoveryForFault(.{ .stream = .{
        .stream_id = 7,
        .code = .protocol_error,
    } });
    switch (stream_recovery) {
        .reset_stream => |reset| {
            std.debug.assert(reset.stream_id == 7);
            std.debug.assert(reset.code == .protocol_error);
        },
        .close_connection => unreachable,
    }

    const connection_recovery = recoveryForFault(.{ .connection = .flow_control_error });
    switch (connection_recovery) {
        .close_connection => |code| std.debug.assert(code == .flow_control_error),
        .reset_stream => unreachable,
    }

    // HTTP/1 send preflight errors are recoverable because MessageWriter has
    // not emitted a new message head yet. Partial I/O errors are different:
    // MessageWriter.failed() then tells the transport owner to close instead of
    // trying another HTTP message on the same connection.
    var message = http.http1.MessageWriter.init();
    std.debug.assert(message.ready());
    std.debug.assert(!message.failed());
    std.debug.assert(!message.mustClose());
    std.debug.assert(!message.protocolSwitched());
}
