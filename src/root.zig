//! Allocation-conscious HTTP/1.1 and HTTP/2 protocol primitives for Zig 0.16.
//! Networking and TLS are deliberately kept outside the core so applications can
//! pair these parsers/writers with their own event loop and transport strategy.

pub const common = @import("common.zig");
pub const http1 = @import("http1.zig");
pub const http2 = @import("http2.zig");

test {
    _ = common.Header;
    _ = common.isFieldValue;

    _ = http1.head.HeadParser;
    _ = http1.head.FramedHeadParser;
    _ = http1.body.ChunkDecoder;
    _ = http1.write.requestHead;

    _ = http2.frame.FrameDecoder;
    _ = http2.settings.Settings;
    _ = http2.settings.StreamDecoder;
    _ = http2.flow.FlowWindow;
    _ = http2.fields.Validator;
    _ = http2.payload.HeadersPayload;
    _ = http2.continuation.Guard;
    _ = http2.preface.Parser;
    _ = http2.protocol.ErrorCode;
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
    _ = http2.send.HeaderFramer;
}
