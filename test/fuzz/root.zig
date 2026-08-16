const std = @import("std");
const http = @import("http");

const FlowWindow = http.http2.FlowWindow;

const Model = struct {
    value: i64 = 65_535,

    fn consume(self: *Model, amount: u32) bool {
        const next = self.value - @as(i64, amount);
        if (next < 0) return false;
        self.value = next;
        return true;
    }

    fn update(self: *Model, increment: u31) bool {
        if (increment == 0) return false;
        const next = self.value + @as(i64, increment);
        if (next > 0x7fff_ffff) return false;
        self.value = next;
        return true;
    }

    fn initialDelta(self: *Model, old: u31, new: u31) bool {
        const next = self.value + @as(i64, new) - @as(i64, old);
        if (next > 0x7fff_ffff or next < -0x7fff_ffff) return false;
        self.value = next;
        return true;
    }
};

fn resultOk(result: error{FlowControl}!void) bool {
    result catch return false;
    return true;
}

fn expectState(sut: FlowWindow, model: Model) !void {
    try std.testing.expectEqual(@as(i32, @intCast(model.value)), sut.value);
    const expected: u31 = if (model.value <= 0) 0 else @intCast(model.value);
    try std.testing.expectEqual(expected, sut.available());
}

fn fuzzFlowWindow(_: void, smith: *std.testing.Smith) !void {
    var sut: FlowWindow = .{};
    var model: Model = .{};

    var n: u8 = 0;
    while (n < 64 and !smith.eosWeightedSimple(15, 1)) : (n += 1) {
        switch (smith.valueRangeAtMost(u2, 0, 2)) {
            0 => {
                const amount = smith.value(u32);
                const before = sut.value;
                const expected = model.consume(amount);
                const actual = resultOk(sut.consume(amount));
                try std.testing.expectEqual(expected, actual);
                if (!actual) try std.testing.expectEqual(before, sut.value);
            },
            1 => {
                const increment: u31 = @intCast(smith.valueRangeAtMost(u32, 0, 0x7fff_ffff));
                const before = sut.value;
                const expected = model.update(increment);
                const actual = resultOk(sut.update(increment));
                try std.testing.expectEqual(expected, actual);
                if (!actual) try std.testing.expectEqual(before, sut.value);
            },
            else => {
                const old: u31 = @intCast(smith.valueRangeAtMost(u32, 0, 0x7fff_ffff));
                const new: u31 = @intCast(smith.valueRangeAtMost(u32, 0, 0x7fff_ffff));
                const before = sut.value;
                const expected = model.initialDelta(old, new);
                const actual = resultOk(sut.applyInitialDelta(old, new));
                try std.testing.expectEqual(expected, actual);
                if (!actual) try std.testing.expectEqual(before, sut.value);
            },
        }
        try expectState(sut, model);
    }
}

test "fuzz flow window against signed reference model" {
    try std.testing.fuzz({}, fuzzFlowWindow, .{
        .corpus = &.{
            "",
            "\x00\x00\x00\x00\x00\x00\x00\x00",
            "\xff\xff\xff\xff\xff\xff\xff\xff",
        },
    });
}
