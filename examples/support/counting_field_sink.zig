const http = @import("http");

/// Minimal synchronous field sink demonstrating Session's structural contract.
/// Header slices are intentionally not retained because they borrow HPACK/session
/// scratch storage and are valid only during the callback.
pub const CountingFieldSink = struct {
    requests: usize = 0,
    responses: usize = 0,
    trailers: usize = 0,

    pub fn field(self: *CountingFieldSink, _: u31, kind: http.http2.fields.Kind, _: http.common.Header) void {
        switch (kind) {
            .request => self.requests += 1,
            .response => self.responses += 1,
            .trailers => self.trailers += 1,
        }
    }
};
