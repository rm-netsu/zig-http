//! Allocation-conscious HTTP/1.1 and HTTP/2 protocol primitives for Zig 0.16.
//! Networking and TLS are deliberately kept outside the core so applications can
//! pair these parsers/writers with their own event loop and transport strategy.

pub const common = @import("common.zig");

test {
    _ = common;
}
