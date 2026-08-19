const std = @import("std");
const config = @import("config.zig");

pub const Cell = struct {
    pub const max_grapheme_bytes = 64;

    codepoint: u32 = 0,
    span: u8 = 1,
    grapheme_len: u8 = 0,
    grapheme: [max_grapheme_bytes]u8 = [_]u8{0} ** max_grapheme_bytes,
    fg: config.Rgb = .{},
    bg: config.Rgb = .{},
    underline_color: config.Rgb = .{},
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    selected: bool = false,
    underline: u8 = 0,

    pub fn setText(self: *Cell, value: []const u8) void {
        self.grapheme_len = 0;
        if (value.len == 0) return;
        const copy_len = if (value.len <= self.grapheme.len)
            value.len
        else
            std.unicode.utf8ByteSequenceLength(value[0]) catch 1;
        const safe_len = @min(copy_len, self.grapheme.len);
        @memcpy(self.grapheme[0..safe_len], value[0..safe_len]);
        self.grapheme_len = @intCast(safe_len);
    }

    pub fn text(self: *const Cell) []const u8 {
        return self.grapheme[0..self.grapheme_len];
    }
};

pub const CursorCell = struct {
    x: u16,
    y: u16,
    /// 0 = block, 1 = bar, 2 = underline, 3 = hollow block.
    style: i32 = 0,
};

pub fn metricsForFontSize(font_size: i32, density: f64) config.CellMetrics {
    const size: i32 = @max(font_size, 8);
    const scale = if (std.math.isFinite(density) and density > 0) density else 1;
    const size_px = @as(f64, @floatFromInt(size)) * scale;
    return .{
        .width = @max(6 * scale, size_px * 0.6),
        .height = @max(10 * scale, size_px * 1.25),
    };
}

test "cell preserves a complete ordinary grapheme cluster" {
    var cell: Cell = .{};
    cell.setText("e\xcc\x81");
    try std.testing.expectEqualStrings("e\xcc\x81", cell.text());
}
