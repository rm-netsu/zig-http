const std = @import("std");
const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

pub const Parser = struct {
    matched: u5 = 0,
    done: bool = false,

    pub fn feed(self: *Parser, input: []const u8) error{InvalidPreface}!usize {
        if (self.done) return 0;
        var i: usize = 0;
        while (i < input.len and self.matched < preface.len) : (i += 1) {
            if (input[i] != preface[self.matched]) return error.InvalidPreface;
            self.matched += 1;
        }
        if (self.matched == preface.len) self.done = true;
        return i;
    }
};

test "fragmented client preface" {
    var p: Parser = .{};
    try std.testing.expectEqual(@as(usize, 5), try p.feed(preface[0..5]));
    try std.testing.expectEqual(preface.len - 5, try p.feed(preface[5..]));
    try std.testing.expect(p.done);
}
