const std = @import("std");
const hilog = @import("hilog");
const input_method = @import("input_method");

const Sink = *const fn (bytes: []const u8) void;

var sink: ?Sink = null;
var editor: ?input_method.TextEditor = null;
var options: ?input_method.AttachOptions = null;
var proxy: ?input_method.InputMethod = null;
var keyboard_visible = false;

pub fn setSink(next: Sink) void {
    sink = next;
}

pub fn showKeyboard() void {
    // A service-side hide invalidates the visible session on some API 12
    // implementations. Reattach before asking it to show again.
    if (!keyboard_visible) detach();
    ensureEditor();
    attach();
    if (proxy) |*item| {
        item.showKeyboard() catch |err| {
            hilog.errorf("input method show keyboard failed: {s}", .{@errorName(err)});
        };
    }
}

pub fn detach() void {
    if (proxy) |*item| {
        item.detach() catch |err| {
            hilog.errorf("input method detach failed: {s}", .{@errorName(err)});
        };
    }
    proxy = null;
    keyboard_visible = false;
}

pub fn shutdown() void {
    detach();
    if (options) |*item| item.deinit();
    options = null;
    if (editor) |*item| item.deinit();
    editor = null;
    sink = null;
}

fn ensureEditor() void {
    if (editor != null) return;
    editor = input_method.TextEditor.init(.{
        .get_text_config = @ptrCast(&getTextConfig),
        .insert_text = @ptrCast(&insertText),
        .delete_forward = @ptrCast(&deleteForward),
        .delete_backward = @ptrCast(&deleteBackward),
        .send_keyboard_status = @ptrCast(&sendKeyboardStatus),
        .send_enter_key = @ptrCast(&sendEnterKey),
        .move_cursor = @ptrCast(&moveCursor),
        .handle_set_selection = @ptrCast(&handleSetSelection),
        .handle_extend_action = @ptrCast(&handleExtendAction),
        .get_left_text_of_cursor = @ptrCast(&getLeftText),
        .get_right_text_of_cursor = @ptrCast(&getRightText),
        .get_text_index_at_cursor = @ptrCast(&getTextIndex),
        .receive_private_command = @ptrCast(&receivePrivateCommand),
        .set_preview_text = @ptrCast(&setPreviewText),
        .finish_text_preview = @ptrCast(&finishTextPreview),
    }) catch |err| {
        hilog.errorf("input method editor creation failed: {s}", .{@errorName(err)});
        return;
    };
    options = input_method.AttachOptions.init(true) catch |err| {
        if (editor) |*item| item.deinit();
        editor = null;
        hilog.errorf("input method attach options creation failed: {s}", .{@errorName(err)});
        return;
    };
}

fn attach() void {
    if (proxy != null) return;
    const created_editor = if (editor) |*item| item else return;
    const created_options = if (options) |*item| item else return;
    proxy = input_method.InputMethod.attach(created_editor, created_options) catch |err| {
        hilog.errorf("input method attach failed: {s}", .{@errorName(err)});
        return;
    };
}

fn emit(bytes: []const u8) void {
    if (bytes.len == 0) return;
    if (sink) |callback| callback(bytes);
}

fn getTextConfig(
    _: ?*input_method.TextEditorProxy,
    config: ?*input_method.TextConfig,
) callconv(.c) void {
    input_method.configureText(
        config,
        input_method.text_input_type.text,
        input_method.enter_key.newline,
    ) catch |err| {
        hilog.errorf("input method text configuration failed: {s}", .{@errorName(err)});
    };
}

fn insertText(
    _: ?*input_method.TextEditorProxy,
    text: [*]const u16,
    length: usize,
) callconv(.c) void {
    var iterator = std.unicode.Utf16LeIterator.init(text[0..length]);
    while (iterator.nextCodepoint() catch null) |codepoint| {
        var utf8: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(codepoint, &utf8) catch continue;
        emit(utf8[0..count]);
    }
}

fn deleteBackward(_: ?*input_method.TextEditorProxy, length: i32) callconv(.c) void {
    const count = @max(length, 1);
    var index: i32 = 0;
    while (index < count) : (index += 1) emit("\x7f");
}

fn deleteForward(_: ?*input_method.TextEditorProxy, _: i32) callconv(.c) void {}

fn sendKeyboardStatus(
    _: ?*input_method.TextEditorProxy,
    status: input_method.KeyboardStatus,
) callconv(.c) void {
    keyboard_visible = status == input_method.keyboard_status.shown;
}

fn sendEnterKey(
    _: ?*input_method.TextEditorProxy,
    _: input_method.EnterKeyType,
) callconv(.c) void {
    emit("\r");
}

fn moveCursor(
    _: ?*input_method.TextEditorProxy,
    value: input_method.Direction,
) callconv(.c) void {
    emit(if (value == input_method.direction.up)
        "\x1b[A"
    else if (value == input_method.direction.down)
        "\x1b[B"
    else if (value == input_method.direction.left)
        "\x1b[D"
    else if (value == input_method.direction.right)
        "\x1b[C"
    else
        &.{});
}

fn handleSetSelection(_: ?*input_method.TextEditorProxy, _: i32, _: i32) callconv(.c) void {}
fn handleExtendAction(
    _: ?*input_method.TextEditorProxy,
    _: input_method.ExtendAction,
) callconv(.c) void {}
fn getLeftText(
    _: ?*input_method.TextEditorProxy,
    _: i32,
    _: [*]u16,
    length: *usize,
) callconv(.c) void {
    length.* = 0;
}
fn getRightText(
    _: ?*input_method.TextEditorProxy,
    _: i32,
    _: [*]u16,
    length: *usize,
) callconv(.c) void {
    length.* = 0;
}
fn getTextIndex(_: ?*input_method.TextEditorProxy) callconv(.c) i32 {
    return 0;
}
fn receivePrivateCommand(
    _: ?*input_method.TextEditorProxy,
    _: [*]*input_method.PrivateCommand,
    _: usize,
) callconv(.c) i32 {
    return 0;
}
fn setPreviewText(
    _: ?*input_method.TextEditorProxy,
    _: [*]const u16,
    _: usize,
    _: i32,
    _: i32,
) callconv(.c) i32 {
    return 0;
}
fn finishTextPreview(_: ?*input_method.TextEditorProxy) callconv(.c) void {}
