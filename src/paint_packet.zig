const std = @import("std");
const config = @import("config.zig");
const font = @import("font.zig");

pub const PaintPacket = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    full_update: bool,
    dirty_rows: []u16,
    cell_width: u32,
    cell_height: u32,
    padding: u32,
    cells: []font.Cell,
    cursor: ?font.CursorCell,
    cursor_color: config.Rgb,
    background: config.Rgb,

    pub fn deinit(self: *PaintPacket) void {
        if (self.cells.len != 0) self.allocator.free(self.cells);
        if (self.dirty_rows.len != 0) self.allocator.free(self.dirty_rows);
        self.* = undefined;
    }

    /// Merge an update captured after this packet. This preserves latest-wins
    /// publication without dropping dirty rows that the renderer has not
    /// consumed yet.
    pub fn mergeFrom(self: *PaintPacket, next: *PaintPacket) bool {
        if (next.full_update or
            self.cols != next.cols or
            self.rows != next.rows or
            self.allocator.ptr != next.allocator.ptr)
        {
            return false;
        }
        if (next.cells.len != @as(usize, next.dirty_rows.len) * @as(usize, next.cols)) {
            return false;
        }

        if (self.full_update) {
            if (self.cells.len != @as(usize, self.cols) * @as(usize, self.rows)) return false;
            for (next.dirty_rows, 0..) |row, index| {
                if (row >= self.rows) return false;
                const destination = @as(usize, row) * @as(usize, self.cols);
                const source = index * @as(usize, self.cols);
                @memcpy(
                    self.cells[destination .. destination + self.cols],
                    next.cells[source .. source + self.cols],
                );
            }
            self.copyMetadata(next);
            next.deinit();
            return true;
        }

        if (next.dirty_rows.len == 0) {
            self.copyMetadata(next);
            next.deinit();
            return true;
        }
        if (self.dirty_rows.len == 0) return false;
        if (self.cells.len != @as(usize, self.dirty_rows.len) * @as(usize, self.cols)) {
            return false;
        }

        const merged_count = countMergedRows(self.dirty_rows, next.dirty_rows);
        const merged_rows = self.allocator.alloc(u16, merged_count) catch return false;
        const merged_cells = self.allocator.alloc(
            font.Cell,
            merged_count * @as(usize, self.cols),
        ) catch {
            self.allocator.free(merged_rows);
            return false;
        };

        var left: usize = 0;
        var right: usize = 0;
        var output: usize = 0;
        while (left < self.dirty_rows.len or right < next.dirty_rows.len) : (output += 1) {
            const take_right = left >= self.dirty_rows.len or
                (right < next.dirty_rows.len and next.dirty_rows[right] <= self.dirty_rows[left]);
            const same = left < self.dirty_rows.len and right < next.dirty_rows.len and
                self.dirty_rows[left] == next.dirty_rows[right];
            const source_cells = if (take_right) next.cells else self.cells;
            const source_index = if (take_right) right else left;
            const row = if (take_right) next.dirty_rows[right] else self.dirty_rows[left];
            merged_rows[output] = row;
            const source = source_index * @as(usize, self.cols);
            const destination = output * @as(usize, self.cols);
            @memcpy(
                merged_cells[destination .. destination + self.cols],
                source_cells[source .. source + self.cols],
            );
            if (take_right) right += 1 else left += 1;
            if (same) left += 1;
        }

        self.allocator.free(self.cells);
        self.allocator.free(self.dirty_rows);
        self.cells = merged_cells;
        self.dirty_rows = merged_rows;
        self.copyMetadata(next);
        next.deinit();
        return true;
    }

    fn copyMetadata(self: *PaintPacket, next: *const PaintPacket) void {
        self.cell_width = next.cell_width;
        self.cell_height = next.cell_height;
        self.padding = next.padding;
        self.cursor = next.cursor;
        self.cursor_color = next.cursor_color;
        self.background = next.background;
    }
};

fn countMergedRows(left: []const u16, right: []const u16) usize {
    var left_index: usize = 0;
    var right_index: usize = 0;
    var count: usize = 0;
    while (left_index < left.len or right_index < right.len) : (count += 1) {
        if (left_index >= left.len) {
            right_index += 1;
        } else if (right_index >= right.len) {
            left_index += 1;
        } else if (left[left_index] < right[right_index]) {
            left_index += 1;
        } else if (right[right_index] < left[left_index]) {
            right_index += 1;
        } else {
            left_index += 1;
            right_index += 1;
        }
    }
    return count;
}

fn testPacket(
    allocator: std.mem.Allocator,
    rows: []const u16,
    values: []const u32,
) !PaintPacket {
    const owned_rows = try allocator.dupe(u16, rows);
    errdefer allocator.free(owned_rows);
    const cells = try allocator.alloc(font.Cell, values.len);
    for (values, cells) |value, *cell| cell.* = .{ .codepoint = value };
    return .{
        .allocator = allocator,
        .cols = 2,
        .rows = 4,
        .full_update = false,
        .dirty_rows = owned_rows,
        .cell_width = 8,
        .cell_height = 16,
        .padding = 0,
        .cells = cells,
        .cursor = null,
        .cursor_color = .{},
        .background = .{},
    };
}

test "damage merge retains disjoint rows and newest overlap" {
    const allocator = std.testing.allocator;
    var current = try testPacket(allocator, &.{ 0, 2 }, &.{ 1, 2, 5, 6 });
    defer current.deinit();
    var next = try testPacket(allocator, &.{ 1, 2 }, &.{ 3, 4, 7, 8 });

    try std.testing.expect(current.mergeFrom(&next));
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, current.dirty_rows);
    try std.testing.expectEqual(@as(u32, 1), current.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 3), current.cells[2].codepoint);
    try std.testing.expectEqual(@as(u32, 7), current.cells[4].codepoint);
}

test "cursor-only update preserves pending cell damage" {
    const allocator = std.testing.allocator;
    var current = try testPacket(allocator, &.{1}, &.{ 3, 4 });
    defer current.deinit();
    var cursor = try testPacket(allocator, &.{}, &.{});
    cursor.cursor = .{ .x = 4, .y = 2 };

    try std.testing.expect(current.mergeFrom(&cursor));
    try std.testing.expectEqualSlices(u16, &.{1}, current.dirty_rows);
    try std.testing.expectEqual(@as(u16, 4), current.cursor.?.x);
}
