const std = @import("std");
const common = @import("../common.zig");
const fields = @import("fields.zig");
const flow = @import("flow.zig");
const stream = @import("stream.zig");

/// Small fixed-capacity Session store for embedded applications, examples, and
/// integrations that prefer bounded memory over a custom map/slab. Operations
/// are O(capacity); high-concurrency runtimes can keep using their own store.
pub fn FixedStreamStore(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            id: u31 = 0,
            used: bool = false,
            tracked: stream.Tracked = undefined,
            body: fields.BodyState = .{},
            receive_credit: ?flow.ReceiveCredit = null,
        };

        entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
        used_count: usize = 0,

        pub fn get(self: *Self, id: u31) ?*stream.Tracked {
            for (&self.entries) |*entry| {
                if (entry.used and entry.id == id) return &entry.tracked;
            }
            return null;
        }

        pub fn insert(self: *Self, id: u31, tracked: stream.Tracked) ?*stream.Tracked {
            if (self.get(id) != null) return null;
            for (&self.entries) |*entry| {
                if (!entry.used) {
                    entry.* = .{ .id = id, .used = true, .tracked = tracked, .body = .{}, .receive_credit = null };
                    self.used_count += 1;
                    return &entry.tracked;
                }
            }
            return null;
        }

        pub fn maxActiveSendAdjustment(self: *Self) i32 {
            var result: i32 = 0;
            for (&self.entries) |*entry| {
                if (!entry.used) continue;
                switch (entry.tracked.stream.state) {
                    .open, .half_closed_remote => result = @max(result, entry.tracked.windows.send.adjustment),
                    else => {},
                }
            }
            return result;
        }

        pub fn bodyState(self: *Self, id: u31) ?*fields.BodyState {
            for (&self.entries) |*entry| {
                if (entry.used and entry.id == id) return &entry.body;
            }
            return null;
        }

        pub fn receiveCredit(self: *Self, id: u31) ?*flow.ReceiveCredit {
            for (&self.entries) |*entry| {
                if (entry.used and entry.id == id) {
                    if (entry.receive_credit) |*credit| return credit;
                    return null;
                }
            }
            return null;
        }

        pub fn setReceiveCredit(self: *Self, id: u31, credit: flow.ReceiveCredit) bool {
            for (&self.entries) |*entry| {
                if (entry.used and entry.id == id) {
                    entry.receive_credit = credit;
                    return true;
                }
            }
            return false;
        }

        /// Preflight a local SETTINGS_INITIAL_WINDOW_SIZE transition without
        /// mutating retained stream state. High-level SETTINGS composition uses
        /// this before committing the frame so a known local representational
        /// failure can never be discovered only after the peer-visible write.
        pub fn validateLocalInitialWindow(self: *Self, old: u31, new: u31) error{FlowControl}!void {
            const delta = @as(i64, new) - @as(i64, old);
            for (&self.entries) |*entry| {
                if (!entry.used) continue;
                const next = @as(i64, entry.tracked.windows.receive.value) + delta;
                if (next > 0x7fff_ffff or next < -0x7fff_ffff) return error.FlowControl;
            }
        }

        /// Activates a local SETTINGS_INITIAL_WINDOW_SIZE policy for every
        /// retained stream. Validation is completed before mutation so an
        /// impossible delta never leaves only part of the bounded store updated.
        pub fn applyLocalInitialWindow(self: *Self, old: u31, new: u31) error{FlowControl}!void {
            try self.validateLocalInitialWindow(old, new);
            for (&self.entries) |*entry| {
                if (!entry.used) continue;
                entry.tracked.windows.receive.applyInitialDelta(old, new) catch unreachable;
            }
        }

        /// Changes the receive-credit target for active streams while retaining
        /// bytes already released by the application.
        pub fn setReceiveCreditPolicy(self: *Self, target: u31, low_watermark: u31) void {
            for (&self.entries) |*entry| {
                if (!entry.used) continue;
                if (entry.receive_credit) |*credit| credit.setPolicy(target, low_watermark) catch unreachable;
            }
        }

        /// Removes one record only after it reached the HTTP/2 closed state.
        /// This explicit operation keeps the final record inspectable until the
        /// application has consumed the event that closed it.
        pub fn removeClosed(self: *Self, id: u31) bool {
            for (&self.entries) |*entry| {
                if (!entry.used or entry.id != id) continue;
                if (entry.tracked.stream.state != .closed) return false;
                entry.* = .{};
                self.used_count -= 1;
                return true;
            }
            return false;
        }

        /// Reclaims every closed record and returns the number of freed slots.
        /// StreamManager keeps the required high-water identifiers, so removing
        /// old closed records does not make their stream IDs reusable.
        pub fn reclaimClosed(self: *Self) usize {
            var removed: usize = 0;
            for (&self.entries) |*entry| {
                if (!entry.used or entry.tracked.stream.state != .closed) continue;
                entry.* = .{};
                removed += 1;
            }
            self.used_count -= removed;
            return removed;
        }

        pub inline fn count(self: *const Self) usize {
            return self.used_count;
        }

        pub inline fn remainingCapacity(self: *const Self) usize {
            return capacity - self.used_count;
        }

        pub fn clear(self: *Self) void {
            self.* = .{};
        }
    };
}

/// Transactional fixed-capacity field sink. Header bytes are copied out of the
/// HPACK callback lifetime and remain valid until the next successful commit.
/// If one field section exceeds either bound, the committed view is empty and
/// `overflowed()` reports the local capacity failure; protocol decoding itself
/// remains synchronized and can continue.
pub fn FixedFieldCollector(comptime max_fields: usize, comptime byte_capacity: usize) type {
    return struct {
        const Self = @This();
        const Descriptor = struct {
            name_start: usize,
            name_len: usize,
            value_start: usize,
            value_len: usize,
        };

        staging_bytes: [byte_capacity]u8 = undefined,
        committed_bytes: [byte_capacity]u8 = undefined,
        staging_desc: [max_fields]Descriptor = undefined,
        committed_headers: [max_fields]common.Header = undefined,
        staging_count: usize = 0,
        staging_used: usize = 0,
        staging_overflow: bool = false,
        committed_count: usize = 0,
        last_overflow: bool = false,
        committed_stream_id: u31 = 0,
        committed_kind: fields.Kind = .request,
        has_commit: bool = false,

        pub fn begin(self: *Self, _: u31, _: fields.Kind) void {
            self.staging_count = 0;
            self.staging_used = 0;
            self.staging_overflow = false;
        }

        pub fn field(self: *Self, _: u31, _: fields.Kind, header: common.Header) void {
            if (self.staging_overflow) return;
            if (self.staging_count == max_fields) {
                self.staging_overflow = true;
                return;
            }
            const needed = header.name.len + header.value.len;
            if (needed > byte_capacity - self.staging_used) {
                self.staging_overflow = true;
                return;
            }

            const name_start = self.staging_used;
            @memcpy(self.staging_bytes[name_start..][0..header.name.len], header.name);
            self.staging_used += header.name.len;
            const value_start = self.staging_used;
            @memcpy(self.staging_bytes[value_start..][0..header.value.len], header.value);
            self.staging_used += header.value.len;
            self.staging_desc[self.staging_count] = .{
                .name_start = name_start,
                .name_len = header.name.len,
                .value_start = value_start,
                .value_len = header.value.len,
            };
            self.staging_count += 1;
        }

        pub fn commit(self: *Self, stream_id: u31, section_kind: fields.Kind) void {
            self.committed_stream_id = stream_id;
            self.committed_kind = section_kind;
            self.has_commit = true;
            self.last_overflow = self.staging_overflow;
            self.committed_count = 0;
            if (self.staging_overflow) return;

            @memcpy(self.committed_bytes[0..self.staging_used], self.staging_bytes[0..self.staging_used]);
            for (self.staging_desc[0..self.staging_count], 0..) |desc, index| {
                self.committed_headers[index] = .{
                    .name = self.committed_bytes[desc.name_start..][0..desc.name_len],
                    .value = self.committed_bytes[desc.value_start..][0..desc.value_len],
                };
            }
            self.committed_count = self.staging_count;
        }

        pub fn abort(self: *Self, _: u31, _: fields.Kind) void {
            self.staging_count = 0;
            self.staging_used = 0;
            self.staging_overflow = false;
        }

        pub inline fn headers(self: *const Self) []const common.Header {
            return self.committed_headers[0..self.committed_count];
        }

        pub inline fn overflowed(self: *const Self) bool {
            return self.has_commit and self.last_overflow;
        }

        pub inline fn streamId(self: *const Self) ?u31 {
            return if (self.has_commit) self.committed_stream_id else null;
        }

        pub inline fn kind(self: *const Self) ?fields.Kind {
            return if (self.has_commit) self.committed_kind else null;
        }

        pub fn clear(self: *Self) void {
            self.staging_count = 0;
            self.staging_used = 0;
            self.staging_overflow = false;
            self.committed_count = 0;
            self.last_overflow = false;
            self.has_commit = false;
        }
    };
}

test "fixed stream store explicitly reclaims closed records" {
    const Store = FixedStreamStore(2);
    var store: Store = .{};
    var tracked = stream.Tracked.init(65_535);
    tracked.stream.state = .closed;
    _ = store.insert(1, tracked).?;
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expect(store.removeClosed(1));
    try std.testing.expectEqual(@as(usize, 0), store.count());

    tracked.stream.state = .open;
    _ = store.insert(3, tracked).?;
    try std.testing.expect(!store.removeClosed(3));
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "fixed field collector commits copies and reports overflow without partial publish" {
    const Collector = FixedFieldCollector(2, 16);
    var collector: Collector = .{};
    collector.begin(1, .request);
    collector.field(1, .request, .{ .name = "x-a", .value = "one" });
    collector.field(1, .request, .{ .name = "x-b", .value = "two" });
    collector.commit(1, .request);
    try std.testing.expect(!collector.overflowed());
    try std.testing.expectEqual(@as(usize, 2), collector.headers().len);
    try std.testing.expectEqualStrings("one", collector.headers()[0].value);

    collector.begin(3, .request);
    collector.field(3, .request, .{ .name = "x-a", .value = "0123456789012345" });
    collector.commit(3, .request);
    try std.testing.expect(collector.overflowed());
    try std.testing.expectEqual(@as(usize, 0), collector.headers().len);
    try std.testing.expectEqual(@as(?u31, 3), collector.streamId());
}
