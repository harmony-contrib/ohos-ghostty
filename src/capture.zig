const std = @import("std");
const config = @import("config.zig");
const font = @import("font.zig");
const ghostty = @import("ghostty.zig");

pub const Snapshot = struct {
    cols: u16,
    rows: u16,
    cells: []font.Cell,
    cursor: ?font.CursorCell,
    cursor_color: config.Rgb,
    background: config.Rgb,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    cells: []font.Cell = &.{},
    cols: u16 = 0,
    rows: u16 = 0,
    viewport_offset: u64 = 0,
    initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        if (self.cells.len != 0) self.allocator.free(self.cells);
        self.* = undefined;
    }

    fn ensureSize(self: *Cache, cols: u16, rows: u16) bool {
        const count = std.math.mul(usize, cols, rows) catch return false;
        if (self.cells.len != count) {
            if (self.cells.len != 0) self.allocator.free(self.cells);
            self.cells = self.allocator.alloc(font.Cell, count) catch {
                self.cells = &.{};
                self.initialized = false;
                return false;
            };
            self.initialized = false;
        }
        return true;
    }
};

pub fn capture(
    allocator: std.mem.Allocator,
    terminal: *ghostty.Terminal,
    render_state: *ghostty.RenderState,
    cursor_phase: bool,
) ?Snapshot {
    return captureInternal(
        allocator,
        terminal,
        render_state,
        cursor_phase,
        null,
        .full,
    );
}

pub fn captureCached(
    cache: *Cache,
    allocator: std.mem.Allocator,
    terminal: *ghostty.Terminal,
    render_state: *ghostty.RenderState,
    cursor_phase: bool,
    update_hint: config.UpdateHint,
) ?Snapshot {
    return captureInternal(
        allocator,
        terminal,
        render_state,
        cursor_phase,
        cache,
        update_hint,
    );
}

fn captureInternal(
    allocator: std.mem.Allocator,
    terminal: *ghostty.Terminal,
    render_state: *ghostty.RenderState,
    cursor_phase: bool,
    maybe_cache: ?*Cache,
    update_hint: config.UpdateHint,
) ?Snapshot {
    ghostty.check(ghostty.ghostty_render_state_update(render_state, terminal)) catch return null;

    var dirty = ghostty.RenderStateDirty.full;
    _ = ghostty.ghostty_render_state_get(render_state, .dirty, &dirty);

    var foreground: ghostty.ColorRgb = .{};
    var background: ghostty.ColorRgb = .{};
    var cursor_rgb: ghostty.ColorRgb = .{};
    var palette: [256]ghostty.ColorRgb = undefined;
    var cursor_has_value = false;
    if (ghostty.ghostty_render_state_get(render_state, .color_foreground, &foreground) != .success or
        ghostty.ghostty_render_state_get(render_state, .color_background, &background) != .success)
    {
        return null;
    }
    _ = ghostty.ghostty_render_state_get(render_state, .color_cursor, &cursor_rgb);
    _ = ghostty.ghostty_render_state_get(render_state, .color_cursor_has_value, &cursor_has_value);
    if (ghostty.ghostty_render_state_get(render_state, .color_palette, &palette) != .success) {
        return null;
    }
    const default_fg = ghostty.toRgb(foreground);
    const default_bg = ghostty.toRgb(background);

    var cols: u16 = 0;
    var rows: u16 = 0;
    _ = ghostty.ghostty_render_state_get(render_state, .cols, &cols);
    _ = ghostty.ghostty_render_state_get(render_state, .rows, &rows);
    if (cols == 0 or rows == 0) return null;

    const cursor = readCursor(render_state, cursor_phase);
    const viewport_offset = if (ghostty.getScrollbar(terminal)) |scrollbar|
        scrollbar.offset
    else |_|
        0;
    const cursor_color = if (cursor_has_value) ghostty.toRgb(cursor_rgb) else default_fg;

    var owned_cells: ?[]font.Cell = null;
    var target: []font.Cell = undefined;
    var read_start: u16 = 0;
    var read_end: u16 = rows;
    var read_dirty_rows = false;

    if (maybe_cache) |cache| {
        if (!cache.ensureSize(cols, rows)) return null;
        target = cache.cells;
        const reusable = cache.initialized and
            cache.cols == cols and
            cache.rows == rows;
        if (reusable) switch (update_hint) {
            .full => switch (dirty) {
                .clean => {
                    read_start = 0;
                    read_end = 0;
                },
                .partial => {
                    read_start = 0;
                    read_end = 0;
                    read_dirty_rows = true;
                },
                else => {},
            },
            .cursor => if (cache.viewport_offset == viewport_offset) {
                read_start = 0;
                read_end = 0;
            },
            .viewport => {
                const delta = viewportDelta(cache.viewport_offset, viewport_offset);
                const amount: u64 = @abs(delta);
                if (amount == 0) {
                    read_start = 0;
                    read_end = 0;
                } else if (amount < rows) {
                    shiftCachedRows(target, cols, rows, delta);
                    const moved: u16 = @intCast(amount);
                    if (delta > 0) {
                        read_start = rows - moved;
                        read_end = rows;
                    } else {
                        read_start = 0;
                        read_end = moved;
                    }
                }
            },
        };
    } else {
        target = allocator.alloc(font.Cell, @as(usize, cols) * @as(usize, rows)) catch return null;
        owned_cells = target;
    }

    if (read_dirty_rows and !readDirtyRows(
        allocator,
        render_state,
        target,
        cols,
        rows,
        default_fg,
        default_bg,
        &palette,
    )) {
        if (owned_cells) |cells| allocator.free(cells);
        return null;
    }

    if (read_start < read_end) {
        const first = @as(usize, read_start) * @as(usize, cols);
        const last = @as(usize, read_end) * @as(usize, cols);
        @memset(target[first..last], .{ .fg = default_fg, .bg = default_bg });
        if (!readRows(
            allocator,
            render_state,
            target,
            cols,
            rows,
            read_start,
            read_end,
            default_fg,
            default_bg,
            &palette,
        )) {
            if (owned_cells) |cells| allocator.free(cells);
            return null;
        }
    }

    const result_cells = if (maybe_cache) |cache| blk: {
        cache.cols = cols;
        cache.rows = rows;
        cache.viewport_offset = viewport_offset;
        cache.initialized = true;
        break :blk allocator.dupe(font.Cell, target) catch return null;
    } else owned_cells.?;

    if (ghostty.ghostty_render_state_clean(render_state) != .success) {
        allocator.free(result_cells);
        return null;
    }

    return .{
        .cols = cols,
        .rows = rows,
        .cells = result_cells,
        .cursor = cursor,
        .cursor_color = cursor_color,
        .background = default_bg,
    };
}

fn readDirtyRows(
    allocator: std.mem.Allocator,
    render_state: *ghostty.RenderState,
    target: []font.Cell,
    cols: u16,
    rows: u16,
    default_fg: config.Rgb,
    default_bg: config.Rgb,
    palette: *const [256]ghostty.ColorRgb,
) bool {
    var iterator: ?*ghostty.RowIterator = null;
    if (ghostty.ghostty_render_state_row_iterator_new(null, &iterator) != .success) return false;
    defer ghostty.ghostty_render_state_row_iterator_free(iterator);
    if (ghostty.ghostty_render_state_get(render_state, .row_iterator, @ptrCast(&iterator)) != .success) {
        return false;
    }

    var cells_handle: ?*ghostty.RowCells = null;
    if (ghostty.ghostty_render_state_row_cells_new(null, &cells_handle) != .success) return false;
    defer ghostty.ghostty_render_state_row_cells_free(cells_handle);

    var row: u16 = 0;
    while (ghostty.ghostty_render_state_row_iterator_next_dirty(iterator, &row)) {
        if (row >= rows) return false;
        const first = @as(usize, row) * @as(usize, cols);
        @memset(target[first .. first + cols], .{ .fg = default_fg, .bg = default_bg });
        if (ghostty.ghostty_render_state_row_get(iterator, .cells, @ptrCast(&cells_handle)) != .success) {
            return false;
        }
        var col: u16 = 0;
        while (ghostty.ghostty_render_state_row_cells_next(cells_handle) and col < cols) : (col += 1) {
            target[first + col] = readCell(
                allocator,
                cells_handle,
                default_fg,
                default_bg,
                palette,
            );
        }
    }
    return true;
}

fn readRows(
    allocator: std.mem.Allocator,
    render_state: *ghostty.RenderState,
    target: []font.Cell,
    cols: u16,
    rows: u16,
    read_start: u16,
    read_end: u16,
    default_fg: config.Rgb,
    default_bg: config.Rgb,
    palette: *const [256]ghostty.ColorRgb,
) bool {
    var iterator: ?*ghostty.RowIterator = null;
    if (ghostty.ghostty_render_state_row_iterator_new(null, &iterator) != .success) return false;
    defer ghostty.ghostty_render_state_row_iterator_free(iterator);
    if (ghostty.ghostty_render_state_get(render_state, .row_iterator, @ptrCast(&iterator)) != .success) {
        return false;
    }

    var cells_handle: ?*ghostty.RowCells = null;
    if (ghostty.ghostty_render_state_row_cells_new(null, &cells_handle) != .success) return false;
    defer ghostty.ghostty_render_state_row_cells_free(cells_handle);

    var row: u16 = 0;
    while (ghostty.ghostty_render_state_row_iterator_next(iterator) and row < rows) : (row += 1) {
        if (row < read_start or row >= read_end) continue;
        if (ghostty.ghostty_render_state_row_get(iterator, .cells, @ptrCast(&cells_handle)) != .success) {
            return false;
        }
        var col: u16 = 0;
        while (ghostty.ghostty_render_state_row_cells_next(cells_handle) and col < cols) : (col += 1) {
            target[@as(usize, row) * @as(usize, cols) + @as(usize, col)] = readCell(
                allocator,
                cells_handle,
                default_fg,
                default_bg,
                palette,
            );
        }
    }
    return true;
}

fn shiftCachedRows(cells: []font.Cell, cols: u16, rows: u16, delta: i64) void {
    const amount: usize = @intCast(@abs(delta));
    const width: usize = cols;
    const retained = (@as(usize, rows) - amount) * width;
    const shift = amount * width;
    if (delta > 0) {
        std.mem.copyForwards(font.Cell, cells[0..retained], cells[shift .. shift + retained]);
    } else {
        std.mem.copyBackwards(font.Cell, cells[shift .. shift + retained], cells[0..retained]);
    }
}

fn readCursor(render_state: *ghostty.RenderState, cursor_phase: bool) ?font.CursorCell {
    var visible = false;
    var in_viewport = false;
    var blinking = false;
    var style = ghostty.CursorVisualStyle.block;
    var col: u16 = 0;
    var row: u16 = 0;
    _ = ghostty.ghostty_render_state_get(render_state, .cursor_visible, &visible);
    _ = ghostty.ghostty_render_state_get(render_state, .cursor_viewport_has_value, &in_viewport);
    _ = ghostty.ghostty_render_state_get(render_state, .cursor_blinking, &blinking);
    _ = ghostty.ghostty_render_state_get(render_state, .cursor_visual_style, &style);
    if (!visible or !in_viewport or (blinking and !cursor_phase)) return null;
    _ = ghostty.ghostty_render_state_get(render_state, .cursor_viewport_x, &col);
    _ = ghostty.ghostty_render_state_get(render_state, .cursor_viewport_y, &row);
    return .{
        .x = col,
        .y = row,
        .style = switch (style) {
            .bar => 1,
            .underline => 2,
            .block_hollow => 3,
            else => 0,
        },
    };
}

fn readCell(
    allocator: std.mem.Allocator,
    cells: ?*ghostty.RowCells,
    default_fg: config.Rgb,
    default_bg: config.Rgb,
    palette: *const [256]ghostty.ColorRgb,
) font.Cell {
    var fg = ghostty.ColorRgb{ .r = default_fg.r, .g = default_fg.g, .b = default_fg.b };
    var bg = ghostty.ColorRgb{ .r = default_bg.r, .g = default_bg.g, .b = default_bg.b };
    var storage: [64]u8 = undefined;
    var buffer = ghostty.Buffer{ .ptr = &storage, .cap = storage.len, .len = 0 };
    const fg_result = ghostty.ghostty_render_state_row_cells_get(cells, .fg_color, &fg);
    const bg_result = ghostty.ghostty_render_state_row_cells_get(cells, .bg_color, &bg);
    const text_result = ghostty.ghostty_render_state_row_cells_get(cells, .graphemes_utf8, &buffer);
    var raw_cell: ghostty.Cell = 0;
    var style = ghostty.defaultStyle();
    var selected = false;
    _ = ghostty.ghostty_render_state_row_cells_get(cells, .raw, &raw_cell);
    _ = ghostty.ghostty_render_state_row_cells_get(cells, .style, &style);
    _ = ghostty.ghostty_render_state_row_cells_get(cells, .selected, &selected);
    const span: u8 = switch (ghostty.cellWide(raw_cell)) {
        .wide => 2,
        .spacer_tail, .spacer_head => 0,
        else => 1,
    };

    var result = font.Cell{
        .span = span,
        .fg = if (fg_result == .success) ghostty.toRgb(fg) else default_fg,
        .bg = if (bg_result == .success) ghostty.toRgb(bg) else default_bg,
        .underline_color = ghostty.resolveStyleColor(style.underline_color, palette) orelse
            if (fg_result == .success) ghostty.toRgb(fg) else default_fg,
        .bold = style.bold,
        .italic = style.italic,
        .faint = style.faint,
        .inverse = style.inverse,
        .invisible = style.invisible,
        .strikethrough = style.strikethrough,
        .overline = style.overline,
        .selected = selected,
        .underline = @intCast(@min(style.underline, @intFromEnum(ghostty.Underline.dashed))),
    };
    if (text_result == .success and buffer.len > 0) {
        setCellText(&result, storage[0..buffer.len]);
    } else if (text_result == .out_of_space and buffer.len > storage.len) {
        const dynamic = allocator.alloc(u8, buffer.len) catch return result;
        defer allocator.free(dynamic);
        var dynamic_buffer = ghostty.Buffer{ .ptr = dynamic.ptr, .cap = dynamic.len, .len = 0 };
        if (ghostty.ghostty_render_state_row_cells_get(cells, .graphemes_utf8, &dynamic_buffer) == .success and
            dynamic_buffer.len != 0)
        {
            setCellText(&result, dynamic[0..dynamic_buffer.len]);
        }
    }
    return result;
}

fn setCellText(cell: *font.Cell, text: []const u8) void {
    cell.codepoint = firstCodepoint(text);
    cell.setText(text);
}

fn firstCodepoint(bytes: []const u8) u32 {
    if (bytes.len == 0) return 0;
    const count = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return bytes[0];
    if (count > bytes.len) return 0;
    return std.unicode.utf8Decode(bytes[0..count]) catch 0;
}

fn viewportDelta(previous: u64, next: u64) i64 {
    if (next >= previous) {
        return @intCast(@min(next - previous, std.math.maxInt(i64)));
    }
    return -@as(i64, @intCast(@min(previous - next, std.math.maxInt(i64))));
}
