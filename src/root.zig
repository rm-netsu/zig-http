//! Allocation-conscious HTTP/1.1 and HTTP/2 protocol primitives for Zig 0.16.
//! Networking and TLS are deliberately kept outside the core so applications can
//! pair these parsers/writers with their own event loop and transport strategy.

pub const common = @import("common.zig");
pub const uri = @import("uri.zig");
pub const http1 = @import("http1.zig");
pub const http2 = @import("http2.zig");
pub const high_level = @import("high_level.zig");

test {
    _ = common.Header;
    _ = common.isFieldValue;
    _ = uri.validateAbsolute;

    _ = http1.head.HeadParser;
    _ = http1.head.FramedHeadParser;
    _ = http1.body.ChunkDecoder;
    _ = http1.semantics.validateRequest;
    _ = http1.connection.Decoder;
    _ = http1.write.requestHead;
    _ = http1.MessageWriter;
    _ = http1.message.RequestFields;

    _ = http2.frame.FrameDecoder;
    _ = http2.settings.Settings;
    _ = http2.settings.StreamDecoder;
    _ = http2.flow.FlowWindow;
    _ = http2.flow.StreamSendWindow;
    _ = http2.flow.ReceiveCredit;
    _ = http2.fields.Validator;
    _ = http2.fields.DiagnosticValidator;
    _ = http2.fields.RequestTarget;
    _ = http2.payload.HeadersPayload;
    _ = http2.continuation.Guard;
    _ = http2.preface.Parser;
    _ = http2.bootstrap.Bootstrap;
    _ = http2.protocol.ErrorCode;
    _ = http2.priority.Update;
    _ = http2.stream.Stream;
    _ = http2.stream.Windows;
    _ = http2.stream.Tracked;
    _ = http2.streams.Manager;
    _ = http2.streams.Existing;
    _ = http2.streams.ReceiveResult;
    _ = http2.header_block.Collector;
    _ = http2.connection.State;
    _ = http2.connection.Violation;
    _ = http2.peer.State;
    _ = http2.connection.Decoder;
    _ = http2.connection.CompleteIterator;
    _ = http2.session.Session;
    _ = http2.session.Event;
    _ = http2.session.GracefulGoAway;
    _ = http2.dispatch.Prepared;
    _ = http2.dispatch.StreamWork;
    _ = http2.contracts.hasSessionStore;
    _ = http2.storage.FixedStreamStore;
    _ = http2.storage.FixedFieldCollector;
    _ = http2.message.RequestFields;
    _ = http2.message.ResponseFields;
    _ = http2.send.HeaderFramer;
    _ = high_level.DrainAction;
    _ = high_level.http1.Connection;
    _ = high_level.http2.Connection;
}

test "1.0 candidate composed API surface remains present" {
    const H1 = high_level.http1.Connection(.{
        .head_bytes = 256,
        .chunk_line_bytes = 64,
        .max_in_flight = 2,
        .outbound_fields = 8,
    });
    const H2 = high_level.http2.Connection(.{
        .max_streams = 2,
        .header_block_bytes = 256,
        .scratch_bytes = 256,
        .frame_staging_bytes = 256,
        .collected_fields = 8,
        .collected_field_bytes = 256,
        .outbound_fields = 8,
    });

    comptime {
        const h1_required = .{
            "initClientInPlace",
            "initServerInPlace",
            "sendRequest",
            "sendResponse",
            "writeData",
            "finish",
            "receive",
            "finishReceive",
            "drain",
            "pendingResponses",
            "protocolSwitched",
            "mustClose",
        };
        for (h1_required) |name| if (!@hasDecl(H1, name))
            @compileError("missing 1.0-candidate high-level HTTP/1 API: " ++ name);

        const h2_required = .{
            "initClientInPlace",
            "initServerInPlace",
            "start",
            "sendLocalSettings",
            "sendRequest",
            "sendResponse",
            "sendData",
            "sendTrailers",
            "sendControl",
            "sendPing",
            "releaseData",
            "flushReceiveCredit",
            "resetStream",
            "sendGoAway",
            "announceGracefulGoAway",
            "finishGracefulGoAway",
            "reclaimClosed",
            "receive",
            "drain",
            "acknowledgedLocalSettings",
            "effectiveLocalSettings",
            "pendingLocalSettings",
        };
        for (h2_required) |name| if (!@hasDecl(H2, name))
            @compileError("missing 1.0-candidate high-level HTTP/2 API: " ++ name);

        const session_required = .{
            "receiveBytes",
            "receiveComplete",
            "sendHeaders",
            "sendData",
            "sendTrailers",
            "sendSettings",
            "sendReset",
            "sendGoAway",
        };
        for (session_required) |name| if (!@hasDecl(http2.Session, name))
            @compileError("missing 1.0-candidate HTTP/2 Session API: " ++ name);

        if (!@hasDecl(http1.ConnectionDecoder, "feed"))
            @compileError("missing 1.0-candidate HTTP/1 ConnectionDecoder.feed");
        if (!@hasDecl(http1.MessageWriter, "beginRequest") or
            !@hasDecl(http1.MessageWriter, "beginResponse"))
            @compileError("missing 1.0-candidate HTTP/1 MessageWriter begin APIs");
    }
}
