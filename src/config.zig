pub const CursorPosition = struct {
    row: i32 = 0,
    col: i32 = 0,
};

pub const CellMetrics = struct {
    width: f64 = 8,
    height: f64 = 16,
};

pub const TerminalSize = struct {
    cols: i32 = 0,
    rows: i32 = 0,
};

pub const TerminalConfig = struct {
    fontSize: i32 = 14,
    scrollbackLines: i32 = 10000,
    bgColor: u32 = 0xFF0B1220,
    fgColor: u32 = 0xFFE2E8F0,
    cursorStyle: i32 = 0,
    cursorBlink: bool = true,
};

pub const UpdateHint = enum {
    full,
    viewport,
    cursor,
};

pub const Rgb = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};
