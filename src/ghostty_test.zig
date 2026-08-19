const std = @import("std");
const capture = @import("capture.zig");
const ghostty = @import("ghostty.zig");

fn createTerminal(cols: u16, rows: u16, scrollback: usize) !*ghostty.Terminal {
    const terminal = try ghostty.createTerminal(.{
        .cols = cols,
        .rows = rows,
        .max_scrollback = scrollback,
    });
    errdefer ghostty.ghostty_terminal_free(terminal);
    try ghostty.setColor(terminal, .color_foreground, .{ .r = 0xE2, .g = 0xE8, .b = 0xF0 });
    try ghostty.setColor(terminal, .color_background, .{ .r = 0x0B, .g = 0x12, .b = 0x20 });
    try ghostty.setColor(terminal, .color_cursor, .{ .r = 0xE2, .g = 0xE8, .b = 0xF0 });
    return terminal;
}

fn snapshot(allocator: std.mem.Allocator, terminal: *ghostty.Terminal) !capture.Snapshot {
    const state = try ghostty.createRenderState();
    defer ghostty.ghostty_render_state_free(state);
    return capture.capture(allocator, terminal, state, true) orelse
        error.CaptureFailed;
}

test "official Ghostty performs soft wrapping at the configured width" {
    const terminal = try createTerminal(8, 3, 32);
    defer ghostty.ghostty_terminal_free(terminal);

    ghostty.write(terminal, "abcdefghijk");
    const frame = try snapshot(std.testing.allocator, terminal);
    defer std.testing.allocator.free(frame.cells);

    for ("abcdefgh", 0..) |expected, col| {
        try std.testing.expectEqual(@as(u32, expected), frame.cells[col].codepoint);
    }
    for ("ijk", 0..) |expected, col| {
        try std.testing.expectEqual(@as(u32, expected), frame.cells[8 + col].codepoint);
    }
    try std.testing.expectEqual(@as(u16, 3), try ghostty.getU16(terminal, .cursor_x));
    try std.testing.expectEqual(@as(u16, 1), try ghostty.getU16(terminal, .cursor_y));
}

test "official Ghostty retains and navigates a long scrollback" {
    const terminal = try createTerminal(24, 6, 2048);
    defer ghostty.ghostty_terminal_free(terminal);

    var line_buffer: [96]u8 = undefined;
    for (0..1000) |index| {
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "line-{d:0>4} 0123456789 abcdefghijklmnopqrstuvwxyz\r\n",
            .{index},
        );
        ghostty.write(terminal, line);
    }

    var scrollback_rows: usize = 0;
    try ghostty.check(ghostty.ghostty_terminal_get(
        terminal,
        .scrollback_rows,
        &scrollback_rows,
    ));
    try std.testing.expect(scrollback_rows > 900);

    const bottom = try ghostty.getScrollbar(terminal);
    ghostty.scrollDelta(terminal, -40);
    const history = try ghostty.getScrollbar(terminal);
    try std.testing.expect(history.offset < bottom.offset);

    const frame = try snapshot(std.testing.allocator, terminal);
    defer std.testing.allocator.free(frame.cells);
    try std.testing.expect(frame.cells[0].codepoint != 0);

    ghostty.scrollBottom(terminal);
    const restored = try ghostty.getScrollbar(terminal);
    try std.testing.expectEqual(bottom.offset, restored.offset);
}

test "official Ghostty handles explicit newlines and wide UTF-8 input" {
    const terminal = try createTerminal(12, 4, 32);
    defer ghostty.ghostty_terminal_free(terminal);

    ghostty.write(terminal, "first\r\nsecond\r\n中文🙂\r\n");
    const frame = try snapshot(std.testing.allocator, terminal);
    defer std.testing.allocator.free(frame.cells);

    try std.testing.expectEqual(@as(u32, 'f'), frame.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 's'), frame.cells[12].codepoint);
    try std.testing.expect(frame.cells[24].codepoint > 0x7F);
}

test "official Ghostty render state exposes complete cell styling" {
    const terminal = try createTerminal(8, 2, 8);
    defer ghostty.ghostty_terminal_free(terminal);

    ghostty.write(
        terminal,
        "\x1b[1;3;2;4;9;53;7;58;2;10;20;30mX\x1b[8mY\x1b[0m",
    );
    const frame = try snapshot(std.testing.allocator, terminal);
    defer std.testing.allocator.free(frame.cells);

    const styled = frame.cells[0];
    try std.testing.expect(styled.bold);
    try std.testing.expect(styled.italic);
    try std.testing.expect(styled.faint);
    try std.testing.expect(styled.inverse);
    try std.testing.expect(styled.strikethrough);
    try std.testing.expect(styled.overline);
    try std.testing.expectEqual(@as(u8, 1), styled.underline);
    try std.testing.expectEqual(@as(u8, 10), styled.underline_color.r);
    try std.testing.expectEqual(@as(u8, 20), styled.underline_color.g);
    try std.testing.expectEqual(@as(u8, 30), styled.underline_color.b);
    try std.testing.expect(frame.cells[1].invisible);
}

test "official Ghostty key encoder follows active terminal modes" {
    const terminal = try createTerminal(8, 2, 8);
    defer ghostty.ghostty_terminal_free(terminal);
    const encoder = try ghostty.createKeyEncoder();
    defer ghostty.freeKeyEncoder(encoder);
    const event = try ghostty.createKeyEvent();
    defer ghostty.freeKeyEvent(event);
    var storage: [128]u8 = undefined;

    const normal = try ghostty.encodeKey(
        encoder,
        event,
        terminal,
        .press,
        .arrow_up,
        0,
        &.{},
        0,
        &storage,
    );
    try std.testing.expectEqualStrings("\x1b[A", normal);

    ghostty.write(terminal, "\x1b[?1h");
    const application = try ghostty.encodeKey(
        encoder,
        event,
        terminal,
        .press,
        .arrow_up,
        0,
        &.{},
        0,
        &storage,
    );
    try std.testing.expectEqualStrings("\x1bOA", application);

    const interrupt = try ghostty.encodeKey(
        encoder,
        event,
        terminal,
        .press,
        .c,
        ghostty.mod_ctrl,
        "c",
        'c',
        &storage,
    );
    try std.testing.expectEqualStrings("\x03", interrupt);
}
