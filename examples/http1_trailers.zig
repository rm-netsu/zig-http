const std = @import("std");
const http = @import("http");

const ApplicationTrailers = struct {
    /// This application owns the definition of `x-checksum` and explicitly
    /// permits that field to be generated in a trailer section.
    pub fn allows(_: @This(), name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(name, "x-checksum");
    }
};

pub fn main() !void {
    var storage: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    var message = http.http1.MessageWriter.init();

    _ = try message.beginResponse(
        &out,
        .http_1_1,
        200,
        "OK",
        "GET",
        &.{
            .{ .name = "transfer-encoding", .value = "chunked" },
            .{ .name = "trailer", .value = "x-checksum" },
        },
    );
    _ = try message.writeData(&out, "payload");

    // The composed writer is safe by default: non-empty trailers require an
    // explicit semantic policy because core cannot know every field definition.
    const before = out.buffered().len;
    if (message.finish(&out, &.{.{ .name = "x-checksum", .value = "demo" }})) |_| {
        return error.ExpectedTrailerPolicyRequirement;
    } else |err| switch (err) {
        error.TrailerPolicyRequired => {},
        else => return err,
    }
    std.debug.assert(out.buffered().len == before);

    try message.finishWithTrailerPolicy(
        &out,
        &.{.{ .name = "x-checksum", .value = "demo" }},
        ApplicationTrailers{},
    );
    std.debug.assert(message.ready());
    std.debug.assert(std.mem.endsWith(u8, out.buffered(), "0\r\nx-checksum: demo\r\n\r\n"));
}
