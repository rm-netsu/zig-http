//! Allocation-conscious HTTP/1.1 and HTTP/2 protocol primitives for Zig 0.16.
//! Networking and TLS are deliberately kept outside the core so applications can
//! pair these parsers/writers with their own event loop and transport strategy.

pub const common = @import("common.zig");
pub const http1 = @import("http1.zig");
pub const http2 = @import("http2.zig");

test {
    _ = common;
    _ = http1;
    _ = http2;
}
