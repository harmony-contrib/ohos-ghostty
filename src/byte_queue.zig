const std = @import("std");

pub const ByteQueue = struct {
    allocator: std.mem.Allocator,
    lock_state: std.atomic.Value(bool) = .init(false),
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) ByteQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ByteQueue) void {
        self.lock();
        self.bytes.deinit(self.allocator);
        self.unlock();
    }

    pub fn append(self: *ByteQueue, value: []const u8) void {
        if (value.len == 0) return;
        self.lock();
        defer self.unlock();
        self.bytes.appendSlice(self.allocator, value) catch {};
    }

    pub fn drain(self: *ByteQueue, allocator: std.mem.Allocator) []u8 {
        self.lock();
        defer self.unlock();
        const copy = allocator.dupe(u8, self.bytes.items) catch
            return allocator.alloc(u8, 0) catch &.{};
        self.bytes.clearRetainingCapacity();
        return copy;
    }

    fn lock(self: *ByteQueue) void {
        while (self.lock_state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *ByteQueue) void {
        self.lock_state.store(false, .release);
    }
};

test "byte queue drains atomically" {
    var queue = ByteQueue.init(std.testing.allocator);
    defer queue.deinit();
    queue.append("abc");
    queue.append("def");
    const first = queue.drain(std.testing.allocator);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("abcdef", first);
    const second = queue.drain(std.testing.allocator);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}
