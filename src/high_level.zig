//! Optional convenience layer built entirely on top of the protocol core.
//! It owns bounded default storage and HPACK contexts, but still owns no socket,
//! TLS session, event loop, timer, or application routing policy.

pub const http2 = @import("high_level/http2.zig");
