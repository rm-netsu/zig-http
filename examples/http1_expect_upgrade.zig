const std = @import("std");
const http = @import("http");

pub fn main() !void {
    const h1 = http.http1;

    const parsed = (try h1.head.parseRequest(
        "POST /chat HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "Content-Length: 4\r\n" ++
            "Expect: 100-continue\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Upgrade: websocket, IRC/6.9\r\n\r\n",
    )).?;

    const expectation = try h1.semantics.requestExpectation(parsed.head);
    std.debug.assert(expectation == .continue_100);
    var gate = h1.semantics.ContinueGate.init(expectation);
    std.debug.assert(!gate.maySendBody());
    gate.observeStatus(100);
    std.debug.assert(gate.maySendBody());

    const offer = try h1.semantics.UpgradeOffer.init(parsed.head);
    std.debug.assert(try offer.offers("WebSocket"));

    const selected = (try h1.head.parseResponse(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Upgrade: websocket\r\n\r\n",
        "POST",
    )).?;
    try offer.validateSelection(selected.head);

    const expect = h1.message.expectContinue();
    const upgrade = h1.message.upgrade("websocket");
    std.debug.assert(std.mem.eql(u8, expect.value, "100-continue"));
    std.debug.assert(std.mem.eql(u8, upgrade[1].value, "websocket"));
}
