const config = @import("config.zig");
const c = @import("ghostty_c");

pub const Result = enum(c_int) {
    success = 0,
    out_of_memory = -1,
    invalid_value = -2,
    out_of_space = -3,
    no_value = -4,
    io_error = -5,
    limit_exceeded = -6,
    _,
};

// Opaque handles and value layouts come from Ghostty's public C headers. This
// module only adds Zig-friendly names and error handling; it does not maintain
// an independent ABI description.
pub const Terminal = c.struct_GhosttyTerminalImpl;
pub const RenderState = c.struct_GhosttyRenderStateImpl;
pub const RowIterator = c.struct_GhosttyRenderStateRowIteratorImpl;
pub const RowCells = c.struct_GhosttyRenderStateRowCellsImpl;
pub const KeyEncoder = c.struct_GhosttyKeyEncoderImpl;
pub const KeyEvent = c.struct_GhosttyKeyEventImpl;
pub const Buffer = c.GhosttyBuffer;
pub const Cell = c.GhosttyCell;
pub const Style = c.GhosttyStyle;
pub const StyleColor = c.GhosttyStyleColor;
pub const ColorRgb = c.GhosttyColorRgb;
pub const Scrollbar = c.GhosttyTerminalScrollbar;

pub const TerminalOptions = struct {
    cols: u16,
    rows: u16,
    max_scrollback: usize,
};

pub const TerminalOption = enum(c_int) {
    userdata = 0,
    write_pty = 1,
    bell = 2,
    enquiry = 3,
    xtversion = 4,
    title_changed = 5,
    size = 6,
    color_scheme = 7,
    device_attributes = 8,
    title = 9,
    pwd = 10,
    color_foreground = 11,
    color_background = 12,
    color_cursor = 13,
    color_palette = 14,
    kitty_image_storage_limit = 15,
    kitty_image_medium_file = 16,
    kitty_image_medium_temp_file = 17,
    kitty_image_medium_shared_mem = 18,
    apc_max_bytes = 19,
    apc_max_bytes_kitty = 20,
    selection = 21,
    default_cursor_style = 22,
    default_cursor_blink = 23,
    glyph_protocol = 24,
    pwd_changed = 25,
    clipboard_write = 26,
    scrollback_max_bytes = 27,
    scrollback_max_lines = 28,
    _,
};

pub const TerminalData = enum(c_int) {
    invalid = 0,
    cols = 1,
    rows = 2,
    cursor_x = 3,
    cursor_y = 4,
    cursor_pending_wrap = 5,
    active_screen = 6,
    cursor_visible = 7,
    kitty_keyboard_flags = 8,
    scrollbar = 9,
    cursor_style = 10,
    mouse_tracking = 11,
    title = 12,
    pwd = 13,
    total_rows = 14,
    scrollback_rows = 15,
    width_px = 16,
    height_px = 17,
    color_foreground = 18,
    color_background = 19,
    color_cursor = 20,
    color_palette = 21,
    color_foreground_default = 22,
    color_background_default = 23,
    color_cursor_default = 24,
    color_palette_default = 25,
    viewport_active = 32,
    _,
};

pub const RenderStateData = enum(c_int) {
    invalid = 0,
    cols = 1,
    rows = 2,
    dirty = 3,
    row_iterator = 4,
    color_background = 5,
    color_foreground = 6,
    color_cursor = 7,
    color_cursor_has_value = 8,
    color_palette = 9,
    cursor_visual_style = 10,
    cursor_visible = 11,
    cursor_blinking = 12,
    cursor_password_input = 13,
    cursor_viewport_has_value = 14,
    cursor_viewport_x = 15,
    cursor_viewport_y = 16,
    cursor_viewport_wide_tail = 17,
    _,
};

pub const RenderStateDirty = enum(c_uint) {
    clean = c.GHOSTTY_RENDER_STATE_DIRTY_FALSE,
    partial = c.GHOSTTY_RENDER_STATE_DIRTY_PARTIAL,
    full = c.GHOSTTY_RENDER_STATE_DIRTY_FULL,
    _,
};

pub const RenderStateRowData = enum(c_int) {
    invalid = 0,
    dirty = 1,
    raw = 2,
    cells = 3,
    selection = 4,
    _,
};

pub const RenderStateRowCellsData = enum(c_int) {
    invalid = 0,
    raw = 1,
    style = 2,
    graphemes_len = 3,
    graphemes_buf = 4,
    bg_color = 5,
    fg_color = 6,
    selected = 7,
    has_styling = 8,
    graphemes_utf8 = 9,
    _,
};

pub const CursorVisualStyle = enum(c_int) {
    bar = 0,
    block = 1,
    underline = 2,
    block_hollow = 3,
    _,
};

pub const CellWide = enum(c_int) {
    narrow = 0,
    wide = 1,
    spacer_tail = 2,
    spacer_head = 3,
    _,
};

pub const TerminalCursorStyle = enum(c_int) {
    bar = c.GHOSTTY_TERMINAL_CURSOR_STYLE_BAR,
    block = c.GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK,
    underline = c.GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE,
    block_hollow = c.GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW,
    _,
};

pub const KeyAction = enum(c_int) {
    release = c.GHOSTTY_KEY_ACTION_RELEASE,
    press = c.GHOSTTY_KEY_ACTION_PRESS,
    repeat = c.GHOSTTY_KEY_ACTION_REPEAT,
    _,
};

pub const Key = enum(c_int) {
    unidentified = c.GHOSTTY_KEY_UNIDENTIFIED,
    backquote = c.GHOSTTY_KEY_BACKQUOTE,
    backslash = c.GHOSTTY_KEY_BACKSLASH,
    bracket_left = c.GHOSTTY_KEY_BRACKET_LEFT,
    bracket_right = c.GHOSTTY_KEY_BRACKET_RIGHT,
    comma = c.GHOSTTY_KEY_COMMA,
    digit_0 = c.GHOSTTY_KEY_DIGIT_0,
    digit_1 = c.GHOSTTY_KEY_DIGIT_1,
    digit_2 = c.GHOSTTY_KEY_DIGIT_2,
    digit_3 = c.GHOSTTY_KEY_DIGIT_3,
    digit_4 = c.GHOSTTY_KEY_DIGIT_4,
    digit_5 = c.GHOSTTY_KEY_DIGIT_5,
    digit_6 = c.GHOSTTY_KEY_DIGIT_6,
    digit_7 = c.GHOSTTY_KEY_DIGIT_7,
    digit_8 = c.GHOSTTY_KEY_DIGIT_8,
    digit_9 = c.GHOSTTY_KEY_DIGIT_9,
    equal = c.GHOSTTY_KEY_EQUAL,
    a = c.GHOSTTY_KEY_A,
    b = c.GHOSTTY_KEY_B,
    c = c.GHOSTTY_KEY_C,
    d = c.GHOSTTY_KEY_D,
    e = c.GHOSTTY_KEY_E,
    f = c.GHOSTTY_KEY_F,
    g = c.GHOSTTY_KEY_G,
    h = c.GHOSTTY_KEY_H,
    i = c.GHOSTTY_KEY_I,
    j = c.GHOSTTY_KEY_J,
    k = c.GHOSTTY_KEY_K,
    l = c.GHOSTTY_KEY_L,
    m = c.GHOSTTY_KEY_M,
    n = c.GHOSTTY_KEY_N,
    o = c.GHOSTTY_KEY_O,
    p = c.GHOSTTY_KEY_P,
    q = c.GHOSTTY_KEY_Q,
    r = c.GHOSTTY_KEY_R,
    s = c.GHOSTTY_KEY_S,
    t = c.GHOSTTY_KEY_T,
    u = c.GHOSTTY_KEY_U,
    v = c.GHOSTTY_KEY_V,
    w = c.GHOSTTY_KEY_W,
    x = c.GHOSTTY_KEY_X,
    y = c.GHOSTTY_KEY_Y,
    z = c.GHOSTTY_KEY_Z,
    minus = c.GHOSTTY_KEY_MINUS,
    period = c.GHOSTTY_KEY_PERIOD,
    quote = c.GHOSTTY_KEY_QUOTE,
    semicolon = c.GHOSTTY_KEY_SEMICOLON,
    slash = c.GHOSTTY_KEY_SLASH,
    alt_left = c.GHOSTTY_KEY_ALT_LEFT,
    alt_right = c.GHOSTTY_KEY_ALT_RIGHT,
    backspace = c.GHOSTTY_KEY_BACKSPACE,
    caps_lock = c.GHOSTTY_KEY_CAPS_LOCK,
    control_left = c.GHOSTTY_KEY_CONTROL_LEFT,
    control_right = c.GHOSTTY_KEY_CONTROL_RIGHT,
    enter = c.GHOSTTY_KEY_ENTER,
    meta_left = c.GHOSTTY_KEY_META_LEFT,
    meta_right = c.GHOSTTY_KEY_META_RIGHT,
    shift_left = c.GHOSTTY_KEY_SHIFT_LEFT,
    shift_right = c.GHOSTTY_KEY_SHIFT_RIGHT,
    space = c.GHOSTTY_KEY_SPACE,
    tab = c.GHOSTTY_KEY_TAB,
    delete = c.GHOSTTY_KEY_DELETE,
    end = c.GHOSTTY_KEY_END,
    home = c.GHOSTTY_KEY_HOME,
    insert = c.GHOSTTY_KEY_INSERT,
    page_down = c.GHOSTTY_KEY_PAGE_DOWN,
    page_up = c.GHOSTTY_KEY_PAGE_UP,
    arrow_down = c.GHOSTTY_KEY_ARROW_DOWN,
    arrow_left = c.GHOSTTY_KEY_ARROW_LEFT,
    arrow_right = c.GHOSTTY_KEY_ARROW_RIGHT,
    arrow_up = c.GHOSTTY_KEY_ARROW_UP,
    escape = c.GHOSTTY_KEY_ESCAPE,
    f1 = c.GHOSTTY_KEY_F1,
    f2 = c.GHOSTTY_KEY_F2,
    f3 = c.GHOSTTY_KEY_F3,
    f4 = c.GHOSTTY_KEY_F4,
    f5 = c.GHOSTTY_KEY_F5,
    f6 = c.GHOSTTY_KEY_F6,
    f7 = c.GHOSTTY_KEY_F7,
    f8 = c.GHOSTTY_KEY_F8,
    f9 = c.GHOSTTY_KEY_F9,
    f10 = c.GHOSTTY_KEY_F10,
    f11 = c.GHOSTTY_KEY_F11,
    f12 = c.GHOSTTY_KEY_F12,
    _,
};

pub const Mods = u16;
pub const mod_shift: Mods = c.GHOSTTY_MODS_SHIFT;
pub const mod_ctrl: Mods = c.GHOSTTY_MODS_CTRL;
pub const mod_alt: Mods = c.GHOSTTY_MODS_ALT;
pub const mod_super: Mods = c.GHOSTTY_MODS_SUPER;
pub const mod_caps_lock: Mods = c.GHOSTTY_MODS_CAPS_LOCK;
pub const mod_shift_side: Mods = c.GHOSTTY_MODS_SHIFT_SIDE;
pub const mod_ctrl_side: Mods = c.GHOSTTY_MODS_CTRL_SIDE;
pub const mod_alt_side: Mods = c.GHOSTTY_MODS_ALT_SIDE;
pub const mod_super_side: Mods = c.GHOSTTY_MODS_SUPER_SIDE;

pub const Underline = enum(c_uint) {
    none = c.GHOSTTY_SGR_UNDERLINE_NONE,
    single = c.GHOSTTY_SGR_UNDERLINE_SINGLE,
    double = c.GHOSTTY_SGR_UNDERLINE_DOUBLE,
    curly = c.GHOSTTY_SGR_UNDERLINE_CURLY,
    dotted = c.GHOSTTY_SGR_UNDERLINE_DOTTED,
    dashed = c.GHOSTTY_SGR_UNDERLINE_DASHED,
    _,
};

pub const WritePtyFn = *const fn (
    terminal: ?*Terminal,
    userdata: ?*anyopaque,
    data: [*]const u8,
    len: usize,
) callconv(.c) void;

pub const Error = error{
    OutOfMemory,
    InvalidValue,
    OutOfSpace,
    NoValue,
    IoError,
    LimitExceeded,
};

pub fn toRgb(color: ColorRgb) config.Rgb {
    return .{ .r = color.r, .g = color.g, .b = color.b };
}

pub fn check(result: Result) Error!void {
    return switch (result) {
        .success => {},
        .out_of_memory => error.OutOfMemory,
        .invalid_value => error.InvalidValue,
        .out_of_space => error.OutOfSpace,
        .no_value => error.NoValue,
        .io_error => error.IoError,
        .limit_exceeded => error.LimitExceeded,
        else => error.InvalidValue,
    };
}

pub fn ghostty_terminal_new(
    _: ?*const anyopaque,
    terminal: *?*Terminal,
    cols: u16,
    rows: u16,
) Result {
    return fromRaw(c.ghostty_terminal_new(null, @ptrCast(terminal), cols, rows));
}

pub fn ghostty_terminal_free(terminal: ?*Terminal) void {
    c.ghostty_terminal_free(terminal);
}

pub fn ghostty_terminal_resize(
    terminal: ?*Terminal,
    cols: u16,
    rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
) Result {
    return fromRaw(c.ghostty_terminal_resize(
        terminal,
        cols,
        rows,
        cell_width_px,
        cell_height_px,
    ));
}

pub fn ghostty_terminal_set(
    terminal: ?*Terminal,
    option: TerminalOption,
    value: ?*const anyopaque,
) Result {
    return fromRaw(c.ghostty_terminal_set(
        terminal,
        @intCast(@intFromEnum(option)),
        value,
    ));
}

pub fn ghostty_terminal_vt_write(terminal: ?*Terminal, data: [*]const u8, len: usize) void {
    c.ghostty_terminal_vt_write(terminal, data, len);
}

pub fn ghostty_terminal_get(
    terminal: ?*Terminal,
    data: TerminalData,
    out: ?*anyopaque,
) Result {
    return fromRaw(c.ghostty_terminal_get(
        terminal,
        @intCast(@intFromEnum(data)),
        out,
    ));
}

pub fn ghostty_render_state_new(_: ?*const anyopaque, state: *?*RenderState) Result {
    return fromRaw(c.ghostty_render_state_new(null, @ptrCast(state)));
}

pub fn ghostty_render_state_free(state: ?*RenderState) void {
    c.ghostty_render_state_free(state);
}

pub fn ghostty_render_state_update(state: ?*RenderState, terminal: ?*Terminal) Result {
    return fromRaw(c.ghostty_render_state_update(state, terminal));
}

pub fn ghostty_render_state_get(
    state: ?*RenderState,
    data: RenderStateData,
    out: ?*anyopaque,
) Result {
    return fromRaw(c.ghostty_render_state_get(
        state,
        @intCast(@intFromEnum(data)),
        out,
    ));
}

pub fn ghostty_render_state_clean(state: ?*RenderState) Result {
    return fromRaw(c.ghostty_render_state_clean(state));
}

pub fn defaultStyle() Style {
    var style: Style = undefined;
    c.ghostty_style_default(&style);
    return style;
}

pub fn resolveStyleColor(
    color: StyleColor,
    palette: *const [256]ColorRgb,
) ?config.Rgb {
    return switch (color.tag) {
        c.GHOSTTY_STYLE_COLOR_RGB => toRgb(color.value.rgb),
        c.GHOSTTY_STYLE_COLOR_PALETTE => toRgb(palette[color.value.palette]),
        else => null,
    };
}

pub fn ghostty_render_state_row_iterator_new(
    _: ?*const anyopaque,
    iterator: *?*RowIterator,
) Result {
    return fromRaw(c.ghostty_render_state_row_iterator_new(null, @ptrCast(iterator)));
}

pub fn ghostty_render_state_row_iterator_free(iterator: ?*RowIterator) void {
    c.ghostty_render_state_row_iterator_free(iterator);
}

pub fn ghostty_render_state_row_iterator_next(iterator: ?*RowIterator) bool {
    return c.ghostty_render_state_row_iterator_next(iterator);
}

pub fn ghostty_render_state_row_iterator_next_dirty(
    iterator: ?*RowIterator,
    row: *u16,
) bool {
    return c.ghostty_render_state_row_iterator_next_dirty(iterator, row);
}

pub fn ghostty_render_state_row_get(
    iterator: ?*RowIterator,
    data: RenderStateRowData,
    out: ?*anyopaque,
) Result {
    return fromRaw(c.ghostty_render_state_row_get(
        iterator,
        @intCast(@intFromEnum(data)),
        out,
    ));
}

pub fn ghostty_render_state_row_cells_new(
    _: ?*const anyopaque,
    cells: *?*RowCells,
) Result {
    return fromRaw(c.ghostty_render_state_row_cells_new(null, @ptrCast(cells)));
}

pub fn ghostty_render_state_row_cells_free(cells: ?*RowCells) void {
    c.ghostty_render_state_row_cells_free(cells);
}

pub fn ghostty_render_state_row_cells_next(cells: ?*RowCells) bool {
    return c.ghostty_render_state_row_cells_next(cells);
}

pub fn ghostty_render_state_row_cells_select(cells: ?*RowCells, x: u16) Result {
    return fromRaw(c.ghostty_render_state_row_cells_select(cells, x));
}

pub fn ghostty_render_state_row_cells_get(
    cells: ?*RowCells,
    data: RenderStateRowCellsData,
    out: ?*anyopaque,
) Result {
    return fromRaw(c.ghostty_render_state_row_cells_get(
        cells,
        @intCast(@intFromEnum(data)),
        out,
    ));
}

pub fn cellWide(cell: Cell) CellWide {
    var value: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
    if (c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_WIDE, &value) != c.GHOSTTY_SUCCESS) {
        return .narrow;
    }
    return @enumFromInt(value);
}

pub fn createTerminal(options: TerminalOptions) Error!*Terminal {
    var terminal: ?*Terminal = null;
    try check(ghostty_terminal_new(null, &terminal, options.cols, options.rows));
    const created = terminal orelse return error.InvalidValue;
    errdefer ghostty_terminal_free(created);
    try setMaxScrollback(created, options.max_scrollback);
    return created;
}

pub fn createRenderState() Error!*RenderState {
    var state: ?*RenderState = null;
    try check(ghostty_render_state_new(null, &state));
    return state orelse error.InvalidValue;
}

pub fn createRowIterator() Error!*RowIterator {
    var iterator: ?*RowIterator = null;
    try check(ghostty_render_state_row_iterator_new(null, &iterator));
    return iterator orelse error.InvalidValue;
}

pub fn createRowCells() Error!*RowCells {
    var cells: ?*RowCells = null;
    try check(ghostty_render_state_row_cells_new(null, &cells));
    return cells orelse error.InvalidValue;
}

pub fn createKeyEncoder() Error!*KeyEncoder {
    var encoder: c.GhosttyKeyEncoder = null;
    try check(fromRaw(c.ghostty_key_encoder_new(null, &encoder)));
    return encoder orelse error.InvalidValue;
}

pub fn createKeyEvent() Error!*KeyEvent {
    var event: c.GhosttyKeyEvent = null;
    try check(fromRaw(c.ghostty_key_event_new(null, &event)));
    return event orelse error.InvalidValue;
}

pub fn freeKeyEncoder(encoder: ?*KeyEncoder) void {
    c.ghostty_key_encoder_free(encoder);
}

pub fn freeKeyEvent(event: ?*KeyEvent) void {
    c.ghostty_key_event_free(event);
}

pub fn encodeKey(
    encoder: *KeyEncoder,
    event: *KeyEvent,
    terminal: *Terminal,
    action: KeyAction,
    key: Key,
    mods: Mods,
    utf8: []const u8,
    unshifted_codepoint: u32,
    output: []u8,
) Error![]const u8 {
    c.ghostty_key_encoder_setopt_from_terminal(encoder, terminal);
    c.ghostty_key_event_set_action(event, @intCast(@intFromEnum(action)));
    c.ghostty_key_event_set_key(event, @intCast(@intFromEnum(key)));
    c.ghostty_key_event_set_mods(event, mods);
    c.ghostty_key_event_set_consumed_mods(event, 0);
    c.ghostty_key_event_set_composing(event, false);
    c.ghostty_key_event_set_utf8(
        event,
        if (utf8.len == 0) null else utf8.ptr,
        utf8.len,
    );
    c.ghostty_key_event_set_unshifted_codepoint(event, unshifted_codepoint);
    var written: usize = 0;
    try check(fromRaw(c.ghostty_key_encoder_encode(
        encoder,
        event,
        output.ptr,
        output.len,
        &written,
    )));
    return output[0..written];
}

pub fn getU16(terminal: *Terminal, data: TerminalData) Error!u16 {
    var value: u16 = 0;
    try check(ghostty_terminal_get(terminal, data, &value));
    return value;
}

pub fn getScrollbar(terminal: *Terminal) Error!Scrollbar {
    var value: Scrollbar = .{};
    try check(ghostty_terminal_get(terminal, .scrollbar, &value));
    return value;
}

pub fn setColor(terminal: *Terminal, option: TerminalOption, color: ColorRgb) Error!void {
    try check(ghostty_terminal_set(terminal, option, &color));
}

pub fn setBool(terminal: *Terminal, option: TerminalOption, value: bool) Error!void {
    try check(ghostty_terminal_set(terminal, option, &value));
}

pub fn setCursorStyle(terminal: *Terminal, value: TerminalCursorStyle) Error!void {
    try check(ghostty_terminal_set(terminal, .default_cursor_style, &value));
}

pub fn setWritePty(terminal: *Terminal, callback: WritePtyFn) Error!void {
    try check(ghostty_terminal_set(terminal, .write_pty, @ptrCast(callback)));
}

pub fn setUserdata(terminal: *Terminal, userdata: *anyopaque) Error!void {
    try check(ghostty_terminal_set(terminal, .userdata, userdata));
}

pub fn setMaxScrollback(terminal: *Terminal, lines: usize) Error!void {
    try check(ghostty_terminal_set(terminal, .scrollback_max_lines, &lines));
}

pub fn write(terminal: *Terminal, bytes: []const u8) void {
    if (bytes.len != 0) ghostty_terminal_vt_write(terminal, bytes.ptr, bytes.len);
}

pub fn scrollDelta(terminal: *Terminal, delta: isize) void {
    c.ghostty_terminal_scroll_viewport(terminal, .{
        .tag = c.GHOSTTY_SCROLL_VIEWPORT_DELTA,
        .value = .{ .delta = delta },
    });
}

pub fn scrollBottom(terminal: *Terminal) void {
    c.ghostty_terminal_scroll_viewport(terminal, .{
        .tag = c.GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
        .value = .{ .delta = 0 },
    });
}

fn fromRaw(value: c.GhosttyResult) Result {
    return @enumFromInt(value);
}
