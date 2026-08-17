const http = @import("http");

/// Minimal synchronous field sink demonstrating Session's structural contract.
/// Header slices are intentionally not retained because they borrow HPACK/session
/// scratch storage and are valid only during the callback.
pub const CountingFieldSink = struct {
    requests: usize = 0,
    responses: usize = 0,
    trailers: usize = 0,
    pending_requests: usize = 0,
    pending_responses: usize = 0,
    pending_trailers: usize = 0,

    pub fn begin(self: *CountingFieldSink, _: u31, _: http.http2.fields.Kind) void {
        self.pending_requests = 0;
        self.pending_responses = 0;
        self.pending_trailers = 0;
    }

    pub fn field(self: *CountingFieldSink, _: u31, kind: http.http2.fields.Kind, _: http.common.Header) void {
        switch (kind) {
            .request => self.pending_requests += 1,
            .response => self.pending_responses += 1,
            .trailers => self.pending_trailers += 1,
        }
    }

    pub fn commit(self: *CountingFieldSink, _: u31, _: http.http2.fields.Kind) void {
        self.requests += self.pending_requests;
        self.responses += self.pending_responses;
        self.trailers += self.pending_trailers;
        self.pending_requests = 0;
        self.pending_responses = 0;
        self.pending_trailers = 0;
    }

    pub fn abort(self: *CountingFieldSink, _: u31, _: http.http2.fields.Kind) void {
        self.pending_requests = 0;
        self.pending_responses = 0;
        self.pending_trailers = 0;
    }
};
