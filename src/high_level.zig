//! Optional convenience layer built entirely on top of the protocol core.
//! It may own bounded protocol storage, request/response coordination queues, and
//! HPACK contexts, but still owns no socket, TLS session, event loop, timer, or
//! application routing policy.

pub const common = @import("high_level/common.zig");
pub const Role = @import("common.zig").Role;
pub const DrainAction = common.DrainAction;
pub const DrainResult = common.DrainResult;

pub const http1 = @import("high_level/http1.zig");
pub const http2 = @import("high_level/http2.zig");
