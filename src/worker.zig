const std = @import("std");

const hilog = @import("hilog");
const native_vsync = @import("native_vsync");
const native_window = @import("native_window");
const renderer_mod = @import("renderer.zig");
const window_mod = @import("window.zig");

const vsync_min_fps: i32 = 30;
const vsync_max_fps: i32 = 120;
const vsync_expected_fps: i32 = 120;

pub const FrameSink = *const fn (context: ?*anyopaque, timestamp: u64) bool;
pub const PaintPacket = @import("paint_packet.zig").PaintPacket;

const SurfaceMsg = struct {
    window: native_window.NativeWindow,
    surface_id: ?u64,
    width: u32,
    height: u32,
};

const ResizeMsg = struct {
    width: u32,
    height: u32,
};

const VsyncMsg = struct {
    generation: u64,
    timestamp: u64,
};

const WindowVsync = struct {
    handle: native_vsync.NativeVSync,
    generation: u64,
    requested: bool,
};

const Message = union(enum) {
    surface: SurfaceMsg,
    resize: ResizeMsg,
    vsync: VsyncMsg,
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
    fallback_timestamp: std.atomic.Value(u64) = .init(0),
    vsync_live: std.atomic.Value(bool) = .init(false),
    vsync_generation: std.atomic.Value(u64) = .init(0),
    ready: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(true),
    frame_sink: ?FrameSink = null,
    frame_context: ?*anyopaque = null,
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

    pub fn isVsyncLive(self: *WorkerHandle) bool {
        return self.vsync_live.load(.acquire);
    }

    pub fn setFrameSink(
        self: *WorkerHandle,
        callback: FrameSink,
        context: ?*anyopaque,
    ) void {
        self.lock();
        defer self.unlock();
        self.frame_sink = callback;
        self.frame_context = context;
    }

    pub fn copyError(self: *WorkerHandle, allocator: std.mem.Allocator) []u8 {
        self.lock();
        defer self.unlock();
        return allocator.dupe(u8, self.last_error.items) catch allocator.alloc(u8, 0) catch &.{};
    }

    pub fn sendSurface(
        self: *WorkerHandle,
        window: native_window.NativeWindow,
        surface_id: ?u64,
        width: u32,
        height: u32,
    ) void {
        var message = Message{ .surface = .{
            .window = window,
            .surface_id = surface_id,
            .width = width,
            .height = height,
        } };
        if (!self.push(message)) deinitMessage(&message);
    }

    pub fn resizeSurface(self: *WorkerHandle, width: u32, height: u32) void {
        _ = self.push(.{ .resize = .{ .width = width, .height = height } });
    }

    pub fn sendLost(self: *WorkerHandle) void {
        _ = self.push(.lost);
    }

    pub fn publish(self: *WorkerHandle, packet: PaintPacket) void {
        var next = packet;
        self.lock();
        if (self.latest) |*previous| {
            if (!previous.mergeFrom(&next)) {
                previous.deinit();
                previous.* = next;
            }
        } else {
            self.latest = next;
        }
        self.unlock();
        if (!self.isVsyncLive()) self.requestFrame(0);
    }

    pub fn requestFrame(self: *WorkerHandle, timestamp: u64) void {
        if (timestamp != 0) self.fallback_timestamp.store(timestamp, .release);
        if (self.isVsyncLive()) return;
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

    fn invokeFrameSink(self: *WorkerHandle, timestamp: u64) bool {
        self.lock();
        const callback = self.frame_sink;
        const context = self.frame_context;
        self.unlock();
        return if (callback) |sink| sink(context, timestamp) else false;
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
    var vsync: ?WindowVsync = null;
    var next_vsync_generation: u64 = 1;
    var current: ?PaintPacket = null;
    var current_dirty = false;
    defer {
        stopVsync(self, &vsync);
        if (renderer) |*item| item.deinit();
        if (held_window) |*window| window.deinit();
        if (current) |*packet| packet.deinit();
    }

    while (self.running.load(.seq_cst)) {
        const message = self.take() orelse break;
        switch (message) {
            .lost => {
                stopVsync(self, &vsync);
                if (renderer) |*item| {
                    item.deinit();
                    renderer = null;
                }
                if (held_window) |*window| {
                    window.deinit();
                    held_window = null;
                }
                if (current) |*packet| packet.deinit();
                current = null;
                current_dirty = false;
                self.ready.store(false, .seq_cst);
            },
            .surface => |surface| {
                if (self.takeLatest()) |packet| {
                    mergeCurrent(&current, &current_dirty, packet);
                }
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
                    if (vsync == null) {
                        bindVsync(self, &vsync, &next_vsync_generation, surface.surface_id);
                    }
                    if (present(self, &renderer, current)) current_dirty = false;
                    continue;
                }
                stopVsync(self, &vsync);
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
                bindVsync(self, &vsync, &next_vsync_generation, surface.surface_id);
                self.ready.store(false, .release);
                self.clearError();
                if (present(self, &renderer, current)) current_dirty = false;
            },
            .resize => |size| {
                if (self.takeLatest()) |packet| {
                    mergeCurrent(&current, &current_dirty, packet);
                }
                const gpu = if (renderer) |*item| item else continue;
                gpu.resize(size.width, size.height) catch |err| {
                    self.setError(@errorName(err));
                    self.ready.store(false, .release);
                    hilog.errorf("terminal worker failed to resize renderer: {s}", .{@errorName(err)});
                    continue;
                };
                if (present(self, &renderer, current)) current_dirty = false;
            },
            .vsync => |frame| {
                if (!acceptVsync(&vsync, frame.generation)) continue;
                _ = self.invokeFrameSink(frame.timestamp);
                if (self.takeLatest()) |packet| {
                    mergeCurrent(&current, &current_dirty, packet);
                }
                if (current_dirty and present(self, &renderer, current)) {
                    current_dirty = false;
                }
                requestNextVsync(self, &vsync);
            },
            .render => {
                const more_work = self.invokeFrameSink(
                    self.fallback_timestamp.swap(0, .acq_rel),
                );
                if (self.takeLatest()) |packet| {
                    mergeCurrent(&current, &current_dirty, packet);
                }
                if (!self.isVsyncLive() and current_dirty and present(self, &renderer, current)) {
                    current_dirty = false;
                }
                self.render_pending.store(false, .release);
                if (!self.isVsyncLive() and (more_work or self.hasLatest())) {
                    self.requestFrame(0);
                }
            },
        }
    }
}

fn mergeCurrent(current: *?PaintPacket, dirty: *bool, packet: PaintPacket) void {
    var next = packet;
    if (current.*) |*previous| {
        if (dirty.* and previous.mergeFrom(&next)) return;
        previous.deinit();
    }
    current.* = next;
    dirty.* = true;
}

fn bindVsync(
    self: *WorkerHandle,
    connection: *?WindowVsync,
    next_generation: *u64,
    surface_id: ?u64,
) void {
    stopVsync(self, connection);
    const id = surface_id orelse return;
    var handle = native_vsync.NativeVSync.createForAssociatedWindow(
        std.heap.c_allocator,
        id,
        "ohos-terminal",
    ) catch |err| {
        hilog.errorf("terminal worker failed to create surface VSync: {s}", .{@errorName(err)});
        return;
    };
    handle.setExpectedFrameRateRange(.{
        .min = vsync_min_fps,
        .max = vsync_max_fps,
        .expected = vsync_expected_fps,
    }) catch |err| {
        hilog.errorf("terminal worker failed to set VSync frame rate: {s}", .{@errorName(err)});
    };
    const generation = next_generation.*;
    next_generation.* +%= 1;
    if (next_generation.* == 0) next_generation.* = 1;
    self.vsync_generation.store(generation, .release);
    connection.* = .{
        .handle = handle,
        .generation = generation,
        .requested = false,
    };
    requestNextVsync(self, connection);
}

fn stopVsync(self: *WorkerHandle, connection: *?WindowVsync) void {
    if (connection.*) |*item| item.handle.deinit();
    connection.* = null;
    self.vsync_live.store(false, .release);
}

fn acceptVsync(connection: *?WindowVsync, generation: u64) bool {
    const item = if (connection.*) |*value| value else return false;
    if (item.generation != generation) return false;
    item.requested = false;
    return true;
}

fn requestNextVsync(self: *WorkerHandle, connection: *?WindowVsync) void {
    const item = if (connection.*) |*value| value else return;
    if (item.requested) return;
    item.handle.requestFrame(onNativeFrame, self) catch |err| {
        hilog.errorf("terminal worker failed to request VSync frame: {s}", .{@errorName(err)});
        stopVsync(self, connection);
        self.requestFrame(0);
        return;
    };
    item.requested = true;
    self.vsync_live.store(true, .release);
}

fn onNativeFrame(timestamp: i64, context: ?*anyopaque) void {
    const self: *WorkerHandle = @ptrCast(@alignCast(context orelse return));
    if (!self.running.load(.acquire)) return;
    const resolved_timestamp: u64 = if (timestamp > 0) @intCast(timestamp) else 0;
    const generation = self.vsync_generation.load(.acquire);
    if (!self.push(.{ .vsync = .{
        .generation = generation,
        .timestamp = resolved_timestamp,
    } })) {
        self.vsync_live.store(false, .release);
        self.requestFrame(0);
    }
}

fn present(self: *WorkerHandle, renderer: *?renderer_mod.Renderer, packet: ?PaintPacket) bool {
    const gpu = if (renderer.*) |*item| item else return false;
    const frame = packet orelse return false;
    gpu.present(
        frame.cols,
        frame.rows,
        frame.full_update,
        frame.dirty_rows,
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
        return false;
    };
    self.clearError();
    self.ready.store(true, .release);
    return true;
}

fn deinitMessage(message: *Message) void {
    switch (message.*) {
        .surface => |*surface| surface.window.deinit(),
        else => {},
    }
}
