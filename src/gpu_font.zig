const std = @import("std");
const drawing = @import("native_drawing");
const font_model = @import("font.zig");

pub const RasterizerError = drawing.NativeDrawingError || error{
    TypefaceUnavailable,
    OutOfMemory,
};

pub const RasterizedGlyph = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    row_bytes: u32,
    /// Pixel bearings relative to the logical cell origin.
    offset_x: i32,
    offset_y: i32,
    is_color: bool,
};

/// Rasterizes each distinct grapheme once for upload into the GPU glyph atlas.
pub const Rasterizer = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    bitmap: drawing.Bitmap,
    canvas: drawing.Canvas,
    font: drawing.Font,
    manager: drawing.FontManager,
    primary_typeface: drawing.Typeface,
    brush: drawing.Brush,
    cell_width: u32,
    cell_height: u32,
    scratch_width: u32,
    scratch_height: u32,
    scratch_origin_x: u32,
    scratch_origin_y: u32,
    row_bytes: u32,
    baseline_offset: f32,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_width: u32,
        cell_height: u32,
    ) RasterizerError!Rasterizer {
        const resolved_width = @max(cell_width, 1);
        const resolved_height = @max(cell_height, 1);
        // One cell of overscan around a two-cell grapheme preserves signed
        // bearings and prevents italic/combining glyphs from being clipped.
        const scratch_width = resolved_width *| 4;
        const scratch_height = resolved_height *| 3;
        const scratch_origin_x = resolved_width;
        const scratch_origin_y = resolved_height;
        const row_bytes: u32 = @intCast(std.mem.alignForward(
            usize,
            @as(usize, scratch_width) * 4,
            256,
        ));
        const pixels = allocator.alloc(
            u8,
            @as(usize, row_bytes) * @as(usize, scratch_height),
        ) catch return error.OutOfMemory;
        errdefer allocator.free(pixels);
        @memset(pixels, 0);

        var bitmap = try drawing.Bitmap.wrapPixels(
            pixels,
            scratch_width,
            scratch_height,
            row_bytes,
            .rgba8888,
            .premultiplied,
        );
        errdefer bitmap.deinit();
        var canvas = try drawing.Canvas.init(&bitmap);
        errdefer canvas.deinit();
        var manager = try drawing.FontManager.init();
        errdefer manager.deinit();
        var primary = manager.matchFamilyStyle("monospace", .{}) orelse
            return error.TypefaceUnavailable;
        errdefer primary.deinit();
        var native_font = try drawing.Font.init();
        errdefer native_font.deinit();
        native_font.setTypeface(&primary);
        native_font.setSubpixel(true);
        native_font.setHinting(.normal);
        native_font.setEdging(.anti_alias);
        native_font.setTextSize(@as(f32, @floatFromInt(resolved_height)) * 0.78);
        native_font.setScaleX(1);
        const metrics = native_font.metrics();
        const glyph_height = metrics.descent - metrics.ascent;
        const baseline = (@as(f32, @floatFromInt(resolved_height)) - glyph_height) * 0.5 - metrics.ascent;

        var brush = try drawing.Brush.init();
        errdefer brush.deinit();
        brush.setColor(0xFFFFFFFF);
        return .{
            .allocator = allocator,
            .pixels = pixels,
            .bitmap = bitmap,
            .canvas = canvas,
            .font = native_font,
            .manager = manager,
            .primary_typeface = primary,
            .brush = brush,
            .cell_width = resolved_width,
            .cell_height = resolved_height,
            .scratch_width = scratch_width,
            .scratch_height = scratch_height,
            .scratch_origin_x = scratch_origin_x,
            .scratch_origin_y = scratch_origin_y,
            .row_bytes = row_bytes,
            .baseline_offset = baseline,
        };
    }

    pub fn deinit(self: *Rasterizer) void {
        self.brush.deinit();
        self.font.deinit();
        self.primary_typeface.deinit();
        self.manager.deinit();
        self.canvas.deinit();
        self.bitmap.deinit();
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn rasterize(self: *Rasterizer, cell: *const font_model.Cell) ?RasterizedGlyph {
        if (cell.codepoint == 0 or cell.codepoint == ' ') return null;
        @memset(self.pixels, 0);

        const codepoint = std.math.cast(u21, cell.codepoint) orelse return null;
        var matched_typeface: ?drawing.Typeface = null;
        if (codepoint > 0x7F) {
            matched_typeface = self.manager.matchFamilyStyleCharacter(
                "monospace",
                .{},
                codepoint,
            );
            if (matched_typeface == null) {
                matched_typeface = self.manager.matchFamilyStyle("monospace", .{});
            }
        }
        if (matched_typeface) |*typeface| self.font.setTypeface(typeface);
        self.font.setScaleX(1);
        // HarmonyOS may resolve "monospace" bold/italic to a different,
        // proportional family. Keep one face and synthesize style so grid
        // advance and baseline remain identical across SGR attributes.
        self.font.setFakeBold(cell.bold);
        self.font.setTextSkewX(if (cell.italic) -0.2 else 0);
        defer if (matched_typeface) |*typeface| {
            self.font.setTypeface(&self.primary_typeface);
            typeface.deinit();
        };
        defer self.font.setScaleX(1);
        defer self.font.setFakeBold(false);
        defer self.font.setTextSkewX(0);

        var encoded: [4]u8 = undefined;
        const stored = cell.text();
        const text = if (stored.len != 0) stored else encodeCodepoint(codepoint, &encoded);
        if (text.len == 0) return null;
        const span: u32 = @max(cell.span, 1);
        const target_advance: f32 = @floatFromInt(self.cell_width *| span);

        // The regular ASCII face defines the grid. Normalize every ASCII
        // style to the same authored advance, but preserve fallback aspect
        // ratios and only shrink a fallback that exceeds its cell allocation.
        const reference = if (codepoint <= 0x7F) "M" else text;
        if (self.font.measureText(reference, .utf8)) |reference_advance| {
            if (reference_advance > 0) {
                const scale = if (codepoint <= 0x7F)
                    @as(f32, @floatFromInt(self.cell_width)) / reference_advance
                else
                    @min(@as(f32, 1), target_advance / reference_advance);
                self.font.setScaleX(scale);
            }
        }
        const advance = self.font.measureText(text, .utf8) orelse target_advance;
        const draw_x = @as(f32, @floatFromInt(self.scratch_origin_x)) +
            (target_advance - advance) * 0.5;
        const draw_y = @as(f32, @floatFromInt(self.scratch_origin_y)) + self.baseline_offset;
        var blob = drawing.TextBlob.fromText(text, &self.font, .utf8) orelse return null;
        defer blob.deinit();
        self.canvas.attachBrush(&self.brush);
        self.canvas.drawTextBlob(&blob, draw_x, draw_y);
        self.canvas.detachBrush();
        const ink = findInk(
            self.pixels,
            self.scratch_width,
            self.scratch_height,
            self.row_bytes,
        ) orelse return null;
        const start = @as(usize, ink.y) * self.row_bytes + @as(usize, ink.x) * 4;
        const pixels = self.pixels[start..];
        return .{
            .pixels = pixels,
            .width = ink.width,
            .height = ink.height,
            .row_bytes = self.row_bytes,
            .offset_x = @as(i32, @intCast(ink.x)) - @as(i32, @intCast(self.scratch_origin_x)),
            .offset_y = @as(i32, @intCast(ink.y)) - @as(i32, @intCast(self.scratch_origin_y)),
            .is_color = containsColor(pixels, ink.width, ink.height, self.row_bytes),
        };
    }
};

const InkBounds = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

fn findInk(pixels: []const u8, width: u32, height: u32, row_bytes: u32) ?InkBounds {
    var min_x = width;
    var min_y = height;
    var max_x: u32 = 0;
    var max_y: u32 = 0;
    var found = false;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const alpha_offset = @as(usize, y) * row_bytes + @as(usize, x) * 4 + 3;
            if (pixels[alpha_offset] == 0) continue;
            found = true;
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x);
            max_y = @max(max_y, y);
        }
    }
    if (!found) return null;
    return .{
        .x = min_x,
        .y = min_y,
        .width = max_x - min_x + 1,
        .height = max_y - min_y + 1,
    };
}

fn containsColor(pixels: []const u8, width: u32, height: u32, row_bytes: u32) bool {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const offset = @as(usize, y) * row_bytes + @as(usize, x) * 4;
            const r = pixels[offset];
            const g = pixels[offset + 1];
            const b = pixels[offset + 2];
            const a = pixels[offset + 3];
            if (a != 0 and (r != g or g != b)) return true;
        }
    }
    return false;
}

fn encodeCodepoint(codepoint: u21, output: *[4]u8) []const u8 {
    const count = std.unicode.utf8CodepointSequenceLength(codepoint) catch return &.{};
    _ = std.unicode.utf8Encode(codepoint, output[0..count]) catch return &.{};
    return output[0..count];
}
