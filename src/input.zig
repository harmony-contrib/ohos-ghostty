const ghostty = @import("ghostty.zig");
const xcomponent = @import("xcomponent");

pub const KeyInput = struct {
    action: ghostty.KeyAction,
    key: ghostty.Key,
    mods: ghostty.Mods,
    text: [4]u8 = [_]u8{0} ** 4,
    text_len: u8 = 0,
    unshifted_codepoint: u32 = 0,

    pub fn utf8(self: *const KeyInput) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const ModState = struct {
    mods: ghostty.Mods = 0,

    pub fn translate(self: *ModState, event: xcomponent.KeyEventData) ?KeyInput {
        const action: ghostty.KeyAction = switch (event.action) {
            .down => .press,
            .up => .release,
            else => return null,
        };
        self.updateModifier(event.code, event.action);
        const key = mapKey(event.code);
        if (key == .unidentified) return null;
        var result = KeyInput{ .action = action, .key = key, .mods = self.mods };
        if (action == .press) fillText(&result, event.code, self.mods);
        return result;
    }

    fn updateModifier(self: *ModState, code: xcomponent.KeyCode, action: xcomponent.Action) void {
        const down = action == .down;
        switch (code) {
            .shift_left => setMod(&self.mods, ghostty.mod_shift, down),
            .shift_right => {
                setMod(&self.mods, ghostty.mod_shift, down);
                setMod(&self.mods, ghostty.mod_shift_side, down);
            },
            .ctrl_left => setMod(&self.mods, ghostty.mod_ctrl, down),
            .ctrl_right => {
                setMod(&self.mods, ghostty.mod_ctrl, down);
                setMod(&self.mods, ghostty.mod_ctrl_side, down);
            },
            .alt_left => setMod(&self.mods, ghostty.mod_alt, down),
            .alt_right => {
                setMod(&self.mods, ghostty.mod_alt, down);
                setMod(&self.mods, ghostty.mod_alt_side, down);
            },
            .meta_left => setMod(&self.mods, ghostty.mod_super, down),
            .meta_right => {
                setMod(&self.mods, ghostty.mod_super, down);
                setMod(&self.mods, ghostty.mod_super_side, down);
            },
            .caps_lock => {
                if (down) self.mods ^= ghostty.mod_caps_lock;
            },
            else => {},
        }
    }
};

fn setMod(mods: *ghostty.Mods, mask: ghostty.Mods, enabled: bool) void {
    if (enabled) {
        mods.* |= mask;
    } else {
        mods.* &= ~mask;
    }
}

fn fillText(result: *KeyInput, code: xcomponent.KeyCode, mods: ghostty.Mods) void {
    const shift = mods & ghostty.mod_shift != 0;
    const caps = mods & ghostty.mod_caps_lock != 0;
    const pair: ?struct { u8, u8 } = switch (code) {
        .a => .{ 'a', if (shift != caps) 'A' else 'a' },
        .b => .{ 'b', if (shift != caps) 'B' else 'b' },
        .c => .{ 'c', if (shift != caps) 'C' else 'c' },
        .d => .{ 'd', if (shift != caps) 'D' else 'd' },
        .e => .{ 'e', if (shift != caps) 'E' else 'e' },
        .f => .{ 'f', if (shift != caps) 'F' else 'f' },
        .g => .{ 'g', if (shift != caps) 'G' else 'g' },
        .h => .{ 'h', if (shift != caps) 'H' else 'h' },
        .i => .{ 'i', if (shift != caps) 'I' else 'i' },
        .j => .{ 'j', if (shift != caps) 'J' else 'j' },
        .k => .{ 'k', if (shift != caps) 'K' else 'k' },
        .l => .{ 'l', if (shift != caps) 'L' else 'l' },
        .m => .{ 'm', if (shift != caps) 'M' else 'm' },
        .n => .{ 'n', if (shift != caps) 'N' else 'n' },
        .o => .{ 'o', if (shift != caps) 'O' else 'o' },
        .p => .{ 'p', if (shift != caps) 'P' else 'p' },
        .q => .{ 'q', if (shift != caps) 'Q' else 'q' },
        .r => .{ 'r', if (shift != caps) 'R' else 'r' },
        .s => .{ 's', if (shift != caps) 'S' else 's' },
        .t => .{ 't', if (shift != caps) 'T' else 't' },
        .u => .{ 'u', if (shift != caps) 'U' else 'u' },
        .v => .{ 'v', if (shift != caps) 'V' else 'v' },
        .w => .{ 'w', if (shift != caps) 'W' else 'w' },
        .x => .{ 'x', if (shift != caps) 'X' else 'x' },
        .y => .{ 'y', if (shift != caps) 'Y' else 'y' },
        .z => .{ 'z', if (shift != caps) 'Z' else 'z' },
        .key_0 => .{ '0', if (shift) ')' else '0' },
        .key_1 => .{ '1', if (shift) '!' else '1' },
        .key_2 => .{ '2', if (shift) '@' else '2' },
        .key_3 => .{ '3', if (shift) '#' else '3' },
        .key_4 => .{ '4', if (shift) '$' else '4' },
        .key_5 => .{ '5', if (shift) '%' else '5' },
        .key_6 => .{ '6', if (shift) '^' else '6' },
        .key_7 => .{ '7', if (shift) '&' else '7' },
        .key_8 => .{ '8', if (shift) '*' else '8' },
        .key_9 => .{ '9', if (shift) '(' else '9' },
        .grave => .{ '`', if (shift) '~' else '`' },
        .minus => .{ '-', if (shift) '_' else '-' },
        .equals => .{ '=', if (shift) '+' else '=' },
        .left_bracket => .{ '[', if (shift) '{' else '[' },
        .right_bracket => .{ ']', if (shift) '}' else ']' },
        .backslash => .{ '\\', if (shift) '|' else '\\' },
        .semicolon => .{ ';', if (shift) ':' else ';' },
        .apostrophe => .{ '\'', if (shift) '"' else '\'' },
        .comma => .{ ',', if (shift) '<' else ',' },
        .period => .{ '.', if (shift) '>' else '.' },
        .slash => .{ '/', if (shift) '?' else '/' },
        .space => .{ ' ', ' ' },
        else => null,
    };
    const text = pair orelse return;
    result.unshifted_codepoint = text[0];
    result.text[0] = text[1];
    result.text_len = 1;
}

fn mapKey(code: xcomponent.KeyCode) ghostty.Key {
    return switch (code) {
        .grave => .backquote,
        .backslash => .backslash,
        .left_bracket => .bracket_left,
        .right_bracket => .bracket_right,
        .comma => .comma,
        .key_0 => .digit_0,
        .key_1 => .digit_1,
        .key_2 => .digit_2,
        .key_3 => .digit_3,
        .key_4 => .digit_4,
        .key_5 => .digit_5,
        .key_6 => .digit_6,
        .key_7 => .digit_7,
        .key_8 => .digit_8,
        .key_9 => .digit_9,
        .equals => .equal,
        .a => .a,
        .b => .b,
        .c => .c,
        .d => .d,
        .e => .e,
        .f => .f,
        .g => .g,
        .h => .h,
        .i => .i,
        .j => .j,
        .k => .k,
        .l => .l,
        .m => .m,
        .n => .n,
        .o => .o,
        .p => .p,
        .q => .q,
        .r => .r,
        .s => .s,
        .t => .t,
        .u => .u,
        .v => .v,
        .w => .w,
        .x => .x,
        .y => .y,
        .z => .z,
        .minus => .minus,
        .period => .period,
        .apostrophe => .quote,
        .semicolon => .semicolon,
        .slash => .slash,
        .alt_left => .alt_left,
        .alt_right => .alt_right,
        .del, .back => .backspace,
        .caps_lock => .caps_lock,
        .ctrl_left => .control_left,
        .ctrl_right => .control_right,
        .enter, .dpad_center => .enter,
        .meta_left => .meta_left,
        .meta_right => .meta_right,
        .shift_left => .shift_left,
        .shift_right => .shift_right,
        .space => .space,
        .tab => .tab,
        .forward_del => .delete,
        .move_end => .end,
        .move_home => .home,
        .insert => .insert,
        .page_down => .page_down,
        .page_up => .page_up,
        .dpad_down => .arrow_down,
        .dpad_left => .arrow_left,
        .dpad_right => .arrow_right,
        .dpad_up => .arrow_up,
        .escape => .escape,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
        else => .unidentified,
    };
}
