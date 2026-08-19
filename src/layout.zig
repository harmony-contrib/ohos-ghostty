const std = @import("std");
const config = @import("config.zig");
const font = @import("font.zig");

pub const GridLayout = struct {
    cols: u16,
    rows: u16,
    cell: config.CellMetrics,
    padding_px: u32,

    pub fn fromSurface(
        width: u32,
        height: u32,
        font_size: i32,
        density: f64,
    ) GridLayout {
        const safe_density = if (std.math.isFinite(density) and density > 0) density else 1;
        const cell = font.metricsForFontSize(font_size, safe_density);
        const padding_px: u32 = @intFromFloat(@max(4 * safe_density, 0));
        const horizontal_padding = @min(width, padding_px *| 2);
        const vertical_padding = @min(height, padding_px *| 2);
        const inner_width = width - horizontal_padding;
        const inner_height = height - vertical_padding;
        const cols = dimension(inner_width, cell.width);
        const rows = dimension(inner_height, cell.height);
        return .{
            .cols = cols,
            .rows = rows,
            .cell = cell,
            .padding_px = padding_px,
        };
    }
};

fn dimension(pixels: u32, cell_pixels: f64) u16 {
    if (pixels == 0 or !std.math.isFinite(cell_pixels) or cell_pixels <= 0) return 1;
    const count: u32 = @intFromFloat(@floor(@as(f64, @floatFromInt(pixels)) / cell_pixels));
    return @intCast(@min(@max(count, 1), std.math.maxInt(u16)));
}

test "grid layout derives terminal dimensions from physical surface" {
    const grid = GridLayout.fromSurface(1080, 1920, 16, 3);
    try std.testing.expectEqual(@as(u16, 36), grid.cols);
    try std.testing.expectEqual(@as(u16, 31), grid.rows);
    try std.testing.expectEqual(@as(u32, 12), grid.padding_px);
}

test "grid layout clamps invalid and tiny surfaces" {
    const grid = GridLayout.fromSurface(0, 0, 1, std.math.nan(f64));
    try std.testing.expectEqual(@as(u16, 1), grid.cols);
    try std.testing.expectEqual(@as(u16, 1), grid.rows);
    try std.testing.expect(grid.cell.width > 0);
    try std.testing.expect(grid.cell.height > 0);
}
