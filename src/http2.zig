pub const frame = @import("http2/frame.zig");
pub const settings = @import("http2/settings.zig");
pub const payload = @import("http2/payload.zig");
pub const preface = @import("http2/preface.zig");

pub const FrameHeader = frame.FrameHeader;
pub const FrameDecoder = frame.FrameDecoder;
pub const Settings = settings.Settings;

pub const client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
