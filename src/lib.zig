const napi = @import("napi");
const xcomponent = @import("xcomponent");
const hilog = @import("hilog");
const config = @import("config.zig");
const ime = @import("ime.zig");
const session_mod = @import("session.zig");

var host: ?*session_mod.Session = null;

const callbacks: xcomponent.Callbacks = .{
    .on_surface_created = onSurfaceCreated,
    .on_surface_changed = onSurfaceChanged,
    .on_surface_destroyed = onSurfaceDestroyed,
    .on_touch_event = onTouch,
    .on_key_event = onKey,
    .on_frame = onFrame,
    .on_error = onComponentError,
};

fn currentSession() ?*session_mod.Session {
    return host;
}

fn ensureSession() !*session_mod.Session {
    if (host) |session| return session;
    const session = try session_mod.Session.create(napi.globalAllocator());
    host = session;
    ime.setSink(imeSink);
    return session;
}

fn imeSink(bytes: []const u8) void {
    if (currentSession()) |session| session.writeInput(bytes);
}

fn enableFrameRate(component: xcomponent.XComponentRaw) void {
    const wrapper = xcomponent.NativeXComponent{ .component = component };
    wrapper.setFrameRate(30, 120, 60) catch |err| {
        hilog.errorf("failed to set XComponent frame rate: {s}", .{@errorName(err)});
    };
}

fn attachFromWindow(component: xcomponent.XComponentRaw, window: xcomponent.WindowRaw) void {
    const size = component.size(window) catch return;
    const session = ensureSession() catch return;
    session.attachSurface(window.rawHandle(), @intCast(size.width), @intCast(size.height));
    enableFrameRate(component);
    hilog.infof("terminal surface created {d}x{d}", .{ size.width, size.height });
}

fn onSurfaceCreated(
    _: ?*anyopaque,
    component: xcomponent.XComponentRaw,
    window: xcomponent.WindowRaw,
) void {
    attachFromWindow(component, window);
}

fn onSurfaceChanged(
    _: ?*anyopaque,
    component: xcomponent.XComponentRaw,
    window: xcomponent.WindowRaw,
) void {
    attachFromWindow(component, window);
}

fn onSurfaceDestroyed(
    _: ?*anyopaque,
    _: xcomponent.XComponentRaw,
    _: xcomponent.WindowRaw,
) void {
    if (currentSession()) |session| session.detachSurface();
}

fn onTouch(
    _: ?*anyopaque,
    _: xcomponent.XComponentRaw,
    _: xcomponent.WindowRaw,
    event: xcomponent.TouchEventData,
) void {
    if (currentSession()) |session| {
        session.handleTouch(event);
    }
}

fn onKey(
    _: ?*anyopaque,
    _: xcomponent.XComponentRaw,
    _: xcomponent.WindowRaw,
    event: xcomponent.KeyEventData,
) void {
    if (currentSession()) |session| session.handleKey(event);
}

fn onFrame(
    _: ?*anyopaque,
    _: xcomponent.XComponentRaw,
    timestamp: u64,
    _: u64,
) void {
    if (currentSession()) |session| session.renderFrame(timestamp);
}

fn onComponentError(
    _: ?*anyopaque,
    _: xcomponent.XComponentRaw,
    result: xcomponent.ResultCode,
) void {
    hilog.errorf("terminal XComponent callback failed: {any}", .{result});
}

fn init(env: napi.Env, exports: napi.Object) !?napi.Object {
    hilog.setGlobalOptions(.{ .domain = 0x0D00, .tag = "ohos-terminal" });
    hilog.infof("initializing terminal XComponent addon", .{});
    const component = xcomponent.XComponent.initRaw(
        @ptrCast(env.raw),
        @ptrCast(exports.raw),
    ) catch |err| {
        hilog.errorf("failed to unwrap XComponent: {s}", .{@errorName(err)});
        return exports;
    };
    component.registerCallbacks(callbacks) catch |err| {
        hilog.errorf("failed to register XComponent callbacks: {s}", .{@errorName(err)});
    };
    return exports;
}

pub fn showKeyboard() void {
    ime.showKeyboard();
}

pub fn writeInput(data: []u8) void {
    if (currentSession()) |session| session.writeInput(data);
}

pub fn feedOutput(data: []u8) void {
    if (currentSession()) |session| session.feedOutput(data);
}

pub fn drainPendingInput() []u8 {
    const allocator = napi.globalAllocator();
    const session = currentSession() orelse return allocator.alloc(u8, 0) catch &.{};
    return session.pending_input.drain(allocator);
}

pub fn getScreenContent() []u8 {
    const allocator = napi.globalAllocator();
    const session = currentSession() orelse return allocator.alloc(u8, 0) catch &.{};
    return allocator.dupe(u8, session.screenContent()) catch allocator.alloc(u8, 0) catch &.{};
}

pub fn getCursorPosition() config.CursorPosition {
    return if (currentSession()) |session| session.cursorPosition() else .{};
}

pub fn getTerminalSize() config.TerminalSize {
    return if (currentSession()) |session| session.size() else .{};
}

pub fn getCellMetrics() config.CellMetrics {
    return if (currentSession()) |session| session.metrics() else .{};
}

pub fn setSurfaceSize(width: f64, height: f64) void {
    if (currentSession()) |session| {
        session.updateSurface(@intFromFloat(@max(width, 1)), @intFromFloat(@max(height, 1)));
    }
}

pub fn scrollView(delta: i32) void {
    if (currentSession()) |session| session.scrollView(delta);
}

pub fn resetScroll() void {
    if (currentSession()) |session| session.resetScroll();
}

pub fn getScrollbackSize() u32 {
    return if (currentSession()) |session| session.scrollbackSize() else 0;
}

pub fn setConfig(next: config.TerminalConfig) void {
    const session = ensureSession() catch return;
    session.setConfig(next);
}

pub fn setDensity(density: f64) void {
    const session = ensureSession() catch return;
    session.setDensity(density);
}

pub fn isRendererReady() bool {
    return if (currentSession()) |session| session.worker.isReady() else false;
}

pub fn getRendererError() []u8 {
    const allocator = napi.globalAllocator();
    const session = currentSession() orelse return allocator.alloc(u8, 0) catch &.{};
    return session.worker.copyError(allocator);
}

comptime {
    napi.NODE_API_MODULE_WITH_INIT("terminal", @This(), init);
}
