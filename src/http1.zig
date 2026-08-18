pub const head = @import("http1/head.zig");
pub const body = @import("http1/body.zig");
pub const write = @import("http1/write.zig");
pub const semantics = @import("http1/semantics.zig");
pub const connection = @import("http1/connection.zig");
pub const message = @import("http1/message.zig");

/// Recommended composed receive-side HTTP/1 engine. Syntax, framing and body
/// primitives remain available independently through the namespaces above.
pub const ConnectionDecoder = connection.Decoder;
/// Recommended composed send-side HTTP/1 message coordinator.
pub const MessageWriter = write.MessageWriter;
pub const Event = connection.Event;
