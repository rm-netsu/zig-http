//! Allocation-conscious HTTP/1.1 and HTTP/2 protocol primitives for Zig 0.16.
//! Networking and TLS are deliberately kept outside the core so applications can
//! pair these parsers/writers with their own event loop and transport strategy.

const std = @import("std");

pub const common = @import("common.zig");
pub const uri = @import("uri.zig");
pub const http1 = @import("http1.zig");
pub const http2 = @import("http2.zig");
pub const high_level = @import("high_level.zig");

/// Library semantic version for compile-time feature reporting.
pub const version = std.SemanticVersion{ .major = 1, .minor = 0, .patch = 0 };

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

test "1.0 stable composed API surface remains present" {
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
        if (high_level.Role != common.Role or high_level.http1.Role != common.Role or http2.Role != common.Role)
            @compileError("stable endpoint role types must share http.common.Role identity");

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
            "lifecycle",
            "peerCloseRequired",
            "continuePhase",
            "proceedWithoutContinue",
            "cancelRequestBody",
        };
        for (h1_required) |name| if (!@hasDecl(H1, name))
            @compileError("missing stable high-level HTTP/1 API: " ++ name);

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
            "controlForReceiveError",
            "sendPing",
            "releaseData",
            "flushReceiveCredit",
            "resetStream",
            "sendGoAway",
            "announceGracefulGoAway",
            "finishGracefulGoAway",
            "reclaimStream",
            "reclaimClosed",
            "cancelRequest",
            "activeLocalStreams",
            "activeRemoteStreams",
            "activeStreams",
            "retainedStreams",
            "streamsDrained",
            "lifecycle",
            "peerGoAwayLastStreamId",
            "localGoAwayLastStreamId",
            "unprocessedByPeer",
            "requestAvailability",
            "canOpenRequest",
            "peerReceiveClosed",
            "receive",
            "finishReceive",
            "drain",
            "acknowledgedLocalSettings",
            "effectiveLocalSettings",
            "pendingLocalSettings",
        };
        for (h2_required) |name| if (!@hasDecl(H2, name))
            @compileError("missing stable high-level HTTP/2 API: " ++ name);

        // High-level connections intentionally do not expose pointers to their
        // internal parser/session/store composition. Applications that require
        // those layers instantiate the public low-level APIs directly.
        const internal_h1 = .{ "decoder", "writer" };
        for (internal_h1) |name| if (@hasDecl(H1, name))
            @compileError("stable high-level HTTP/1 leaked internal accessor: " ++ name);
        const internal_h2 = .{ "core", "bootstrap", "store", "collector", "StreamStore", "FieldCollector" };
        for (internal_h2) |name| if (@hasDecl(H2, name))
            @compileError("stable high-level HTTP/2 leaked internal composition: " ++ name);

        if (@typeInfo(H1.Storage).@"struct".fields.len != 1 or @typeInfo(H2.Storage).@"struct".fields.len != 1)
            @compileError("stable in-place Storage must remain opaque-by-convention");
        if (@sizeOf(H1.Storage) != H1.state_bytes or @sizeOf(H2.Storage) != H2.state_bytes)
            @compileError("stable state_bytes must describe the public in-place Storage size");

        const h1_config: high_level.http1.Config = .{};
        if (@TypeOf(h1_config.head_bytes) != usize or
            @TypeOf(h1_config.chunk_line_bytes) != usize or
            @TypeOf(h1_config.max_in_flight) != usize or
            @TypeOf(h1_config.outbound_fields) != usize or
            @TypeOf(h1_config.upgrade_offer_bytes) != usize or
            @TypeOf(h1_config.decoder_options) != http1.connection.Options)
            @compileError("stable high-level HTTP/1 Config shape changed");

        const h2_config: high_level.http2.Config = .{};
        if (@TypeOf(h2_config.max_streams) != usize or
            @TypeOf(h2_config.header_block_bytes) != usize or
            @TypeOf(h2_config.scratch_bytes) != usize or
            @TypeOf(h2_config.frame_staging_bytes) != usize or
            @TypeOf(h2_config.collected_fields) != usize or
            @TypeOf(h2_config.collected_field_bytes) != usize or
            @TypeOf(h2_config.outbound_fields) != usize or
            @TypeOf(h2_config.local_settings) != high_level.http2.LocalSettings or
            @TypeOf(h2_config.enforce_peer_header_list_size) != bool)
            @compileError("stable high-level HTTP/2 Config shape changed");

        // Result and error types are module-level so different bounded
        // Connection(config) instantiations share one source-compatible API.
        if (@hasDecl(H1, "ReceiveError") or @hasDecl(H1, "SendRequestError"))
            @compileError("HTTP/1 stable errors must remain module-level");
        if (@hasDecl(H2, "ReceiveResult") or @hasDecl(H2, "ReceiveError"))
            @compileError("HTTP/2 stable result/error types must remain module-level");

        const h1_send_request = @typeInfo(@TypeOf(H1.sendRequest)).@"fn";
        if (h1_send_request.params.len != 4 or
            h1_send_request.params[0].type.? != *H1 or
            h1_send_request.params[1].type.? != *std.Io.Writer or
            h1_send_request.params[2].type.? != http1.message.RequestFields or
            h1_send_request.params[3].type.? != []const common.Header or
            h1_send_request.return_type.? != high_level.http1.SendRequestError!http1.MessageWriter.BeginResult)
            @compileError("stable HTTP/1 sendRequest signature changed");

        const h1_receive = @typeInfo(@TypeOf(H1.receive)).@"fn";
        if (h1_receive.params.len != 2 or
            h1_receive.params[0].type.? != *H1 or
            h1_receive.params[1].type.? != []const u8 or
            h1_receive.return_type.? != high_level.http1.ReceiveError!http1.connection.FeedResult)
            @compileError("stable HTTP/1 receive signature changed");

        const h2_send_request = @typeInfo(@TypeOf(H2.sendRequest)).@"fn";
        if (h2_send_request.params.len != 5 or
            h2_send_request.params[0].type.? != *H2 or
            h2_send_request.params[1].type.? != *std.Io.Writer or
            h2_send_request.params[2].type.? != http2.message.RequestFields or
            h2_send_request.params[3].type.? != []const http2.hpack.EncodedField or
            h2_send_request.params[4].type.? != bool or
            h2_send_request.return_type.? != high_level.http2.SendRequestError!high_level.http2.SendRequestResult)
            @compileError("stable HTTP/2 sendRequest signature changed");

        const h2_receive = @typeInfo(@TypeOf(H2.receive)).@"fn";
        if (h2_receive.params.len != 2 or
            h2_receive.params[0].type.? != *H2 or
            h2_receive.params[1].type.? != []const u8 or
            h2_receive.return_type.? != high_level.http2.ReceiveError!?high_level.http2.ReceiveResult)
            @compileError("stable HTTP/2 receive signature changed");

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
            @compileError("missing stable HTTP/2 Session API: " ++ name);

        if (!@hasDecl(http1.ConnectionDecoder, "feed"))
            @compileError("missing stable HTTP/1 ConnectionDecoder.feed");
        if (!@hasDecl(http1.MessageWriter, "beginRequest") or
            !@hasDecl(http1.MessageWriter, "beginResponse") or
            !@hasDecl(http1.MessageWriter, "abandonBody"))
            @compileError("missing stable HTTP/1 MessageWriter begin/abandon APIs");
    }
}
