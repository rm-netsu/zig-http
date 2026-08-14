pub const frame = @import("http2/frame.zig");
pub const preface = @import("http2/preface.zig");

pub const FrameHeader = frame.FrameHeader;
pub const FrameDecoder = frame.FrameDecoder;

pub const client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
