/// Synchronous batch-drain callback decision shared by HTTP/1 and HTTP/2
/// convenience connections.
pub const DrainAction = enum { continue_, stop };

pub const DrainResult = struct {
    consumed: usize,
    events: usize,
    stopped: bool = false,
};
