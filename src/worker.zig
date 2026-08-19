const std = @import("std");

const config = @import("config.zig");
const font = @import("font.zig");
const hilog = @import("hilog");
const native_window = @import("native_window");
const renderer_mod = @import("renderer.zig");
const window_mod = @import("window.zig");

pub const PaintPacket = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    cell_width: u32,
    cell_height: u32,
    padding: u32,
    cells: []font.Cell,
    cursor: ?font.CursorCell,
    cursor_color: config.Rgb,
    background: config.Rgb,

    fn deinit(self: *PaintPacket) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};

const SurfaceMsg = struct {
    window: native_window.NativeWindow,
    width: u32,
    height: u32,
};

const ResizeMsg = struct {
    width: u32,
    height: u32,
};

const Message = union(enum) {
    surface: SurfaceMsg,
    resize: ResizeMsg,
    lost,
    render,
};

pub const WorkerHandle = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: std.ArrayList(Message) = .empty,
    latest: ?PaintPacket = null,
    render_pending: std.atomic.Value(bool) = .init(false),
    ready: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(true),
    last_error: std.ArrayList(u8) = .empty,
    thread: ?std.Thread = null,

    pub fn spawn(allocator: std.mem.Allocator) !*WorkerHandle {
        const self = try allocator.create(WorkerHandle);
        self.* = .{ .allocator = allocator };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            allocator.destroy(self);
            return err;
        };
        return self;
    }

    pub fn shutdown(self: *WorkerHandle) void {
        self.running.store(false, .release);
        self.lock();
        self.condition.broadcast(std.Options.debug_io);
        self.unlock();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.lock();
        if (self.latest) |*packet| packet.deinit();
        self.latest = null;
        for (self.queue.items) |*message| deinitMessage(message);
        self.queue.deinit(self.allocator);
        self.last_error.deinit(self.allocator);
        self.unlock();
        self.allocator.destroy(self);
    }

    pub fn isReady(self: *WorkerHandle) bool {
        return self.ready.load(.seq_cst);
    }

    pub fn copyError(self: *WorkerHandle, allocator: std.mem.Allocator) []u8 {
        self.lock();
        defer self.unlock();
        return allocator.dupe(u8, self.last_error.items) catch allocator.alloc(u8, 0) catch &.{};
    }

    pub fn sendSurface(self: *WorkerHandle, window: native_window.NativeWindow, width: u32, height: u32) void {
        var message = Message{ .surface = .{ .window = window, .width = width, .height = height } };
        if (!self.push(message)) deinitMessage(&message);
    }

    pub fn resizeSurface(self: *WorkerHandle, width: u32, height: u32) void {
        _ = self.push(.{ .resize = .{ .width = width, .height = height } });
    }

    pub fn sendLost(self: *WorkerHandle) void {
        _ = self.push(.lost);
    }

    pub fn publish(self: *WorkerHandle, packet: PaintPacket) void {
        self.lock();
        if (self.latest) |*previous| previous.deinit();
        self.latest = packet;
        self.unlock();
        self.scheduleRender();
    }

    fn scheduleRender(self: *WorkerHandle) void {
        if (self.render_pending.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            if (!self.push(.render)) self.render_pending.store(false, .release);
        }
    }

    fn push(self: *WorkerHandle, message: Message) bool {
        self.lock();
        defer self.unlock();
        self.queue.append(self.allocator, message) catch return false;
        self.condition.signal(std.Options.debug_io);
        return true;
    }

    fn take(self: *WorkerHandle) ?Message {
        self.lock();
        defer self.unlock();
        while (self.queue.items.len == 0 and self.running.load(.acquire)) {
            self.condition.waitUncancelable(std.Options.debug_io, &self.mutex);
        }
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    fn takeLatest(self: *WorkerHandle) ?PaintPacket {
        self.lock();
        defer self.unlock();
        const packet = self.latest;
        self.latest = null;
        return packet;
    }

    fn hasLatest(self: *WorkerHandle) bool {
        self.lock();
        defer self.unlock();
        return self.latest != null;
    }

    fn setError(self: *WorkerHandle, name: []const u8) void {
        self.lock();
        defer self.unlock();
        self.last_error.clearRetainingCapacity();
        self.last_error.appendSlice(self.allocator, name) catch {};
    }

    fn clearError(self: *WorkerHandle) void {
        self.lock();
        defer self.unlock();
        self.last_error.clearRetainingCapacity();
    }

    fn lock(self: *WorkerHandle) void {
        self.mutex.lockUncancelable(std.Options.debug_io);
    }

    fn unlock(self: *WorkerHandle) void {
        self.mutex.unlock(std.Options.debug_io);
    }
};

fn run(self: *WorkerHandle) void {
    var renderer: ?renderer_mod.Renderer = null;
    var held_window: ?native_window.NativeWindow = null;
    var current: ?PaintPacket = null;
    defer {
        if (renderer) |*item| item.deinit();
        if (held_window) |*window| window.deinit();
        if (current) |*packet| packet.deinit();
    }

    while (self.running.load(.seq_cst)) {
        const message = self.take() orelse break;
        switch (message) {
            .lost => {
                if (renderer) |*item| {
                    item.deinit();
                    renderer = null;
                }
                if (held_window) |*window| {
                    window.deinit();
                    held_window = null;
                }
                self.ready.store(false, .seq_cst);
            },
            .surface => |surface| {
                if (renderer != null and held_window != null and
                    held_window.?.rawHandle() == surface.window.rawHandle())
                {
                    var redundant_window = surface.window;
                    redundant_window.deinit();
                    renderer.?.resize(surface.width, surface.height) catch |err| {
                        self.setError(@errorName(err));
                        self.ready.store(false, .release);
                        hilog.errorf("terminal worker failed to resize surface: {s}", .{@errorName(err)});
                        continue;
                    };
                    present(self, &renderer, current);
                    continue;
                }
                if (renderer) |*item| {
                    item.deinit();
                    renderer = null;
                }
                if (held_window) |*window| {
                    window.deinit();
                    held_window = null;
                }
                const handle = surface.window.rawHandle() orelse {
                    var owned = surface.window;
                    owned.deinit();
                    self.setError("InvalidWindow");
                    continue;
                };
                const surface_window = window_mod.OhosSurfaceWindow.fromRaw(@ptrCast(handle));
                renderer = renderer_mod.Renderer.init(
                    std.heap.c_allocator,
                    surface_window,
                    surface.width,
                    surface.height,
                ) catch |err| {
                    self.setError(@errorName(err));
                    hilog.errorf("terminal worker failed to bind surface: {s}", .{@errorName(err)});
                    var owned = surface.window;
                    owned.deinit();
                    self.ready.store(false, .seq_cst);
                    continue;
                };
                held_window = surface.window;
                self.ready.store(false, .release);
                self.clearError();
                present(self, &renderer, current);
            },
            .resize => |size| {
                const gpu = if (renderer) |*item| item else continue;
                gpu.resize(size.width, size.height) catch |err| {
                    self.setError(@errorName(err));
                    self.ready.store(false, .release);
                    hilog.errorf("terminal worker failed to resize renderer: {s}", .{@errorName(err)});
                    continue;
                };
                present(self, &renderer, current);
            },
            .render => {
                if (self.takeLatest()) |packet| {
                    if (current) |*previous| previous.deinit();
                    current = packet;
                }
                present(self, &renderer, current);
                self.render_pending.store(false, .release);
                if (self.hasLatest()) self.scheduleRender();
            },
        }
    }
}

fn present(self: *WorkerHandle, renderer: *?renderer_mod.Renderer, packet: ?PaintPacket) void {
    const gpu = if (renderer.*) |*item| item else return;
    const frame = packet orelse return;
    gpu.present(
        frame.cols,
        frame.rows,
        @max(frame.cell_width, 1),
        @max(frame.cell_height, 1),
        frame.padding,
        frame.cells,
        frame.cursor,
        frame.cursor_color,
        frame.background,
    ) catch |err| {
        self.setError(@errorName(err));
        self.ready.store(false, .release);
        hilog.errorf("terminal worker failed to present frame: {s}", .{@errorName(err)});
        return;
    };
    self.clearError();
    self.ready.store(true, .release);
}

fn deinitMessage(message: *Message) void {
    switch (message.*) {
        .surface => |*surface| surface.window.deinit(),
        else => {},
    }
}
