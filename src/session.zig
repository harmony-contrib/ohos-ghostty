const std = @import("std");
const byte_queue = @import("byte_queue.zig");
const capture_mod = @import("capture.zig");
const config = @import("config.zig");
const ghostty = @import("ghostty.zig");
const hilog = @import("hilog");
const ime = @import("ime.zig");
const input = @import("input.zig");
const layout = @import("layout.zig");
const native_window = @import("native_window");
const worker_mod = @import("worker.zig");
const xcomponent = @import("xcomponent");

const output_chunk_size = 32 * 1024;

pub const Session = struct {
    allocator: std.mem.Allocator,
    terminal: *ghostty.Terminal,
    render_state: *ghostty.RenderState,
    capture_cache: capture_mod.Cache,
    row_iterator: *ghostty.RowIterator,
    row_cells: *ghostty.RowCells,
    key_encoder: *ghostty.KeyEncoder,
    key_event: *ghostty.KeyEvent,
    worker: *worker_mod.WorkerHandle,
    engine_mutex: std.Io.Mutex = .init,
    output_mutex: std.Io.Mutex = .init,
    output_condition: std.Io.Condition = .init,
    pending_output: std.ArrayList(u8) = .empty,
    pending_keys: std.ArrayList(input.KeyInput) = .empty,
    key_mod_state: input.ModState = .{},
    output_running: std.atomic.Value(bool) = .init(true),
    output_thread: ?std.Thread = null,
    width: u32 = 0,
    height: u32 = 0,
    density: f64 = 1,
    cell_metrics: config.CellMetrics = .{ .width = 10, .height = 20 },
    padding_px: u32 = 0,
    terminal_config: config.TerminalConfig = .{},
    pending_input: byte_queue.ByteQueue,
    screen_cache: std.ArrayList(u8),
    touch_active: bool = false,
    touch_scroll: bool = false,
    touch_origin_x: f32 = 0,
    touch_origin_y: f32 = 0,
    touch_last_y: f32 = 0,
    touch_acc: f32 = 0,
    pending_scroll: std.atomic.Value(i32) = .init(0),
    pending_reset_scroll: std.atomic.Value(bool) = .init(false),
    cursor_phase: bool = true,
    last_blink_timestamp: ?u64 = null,

    pub fn create(allocator: std.mem.Allocator) !*Session {
        const session = try allocator.create(Session);
        errdefer allocator.destroy(session);
        session.* = .{
            .allocator = allocator,
            .terminal = try ghostty.createTerminal(.{
                .cols = 40,
                .rows = 24,
                .max_scrollback = 10000,
            }),
            .render_state = try ghostty.createRenderState(),
            .capture_cache = .init(std.heap.c_allocator),
            .row_iterator = try ghostty.createRowIterator(),
            .row_cells = try ghostty.createRowCells(),
            .key_encoder = try ghostty.createKeyEncoder(),
            .key_event = try ghostty.createKeyEvent(),
            .worker = try worker_mod.WorkerHandle.spawn(std.heap.c_allocator),
            .pending_input = .init(allocator),
            .screen_cache = .empty,
        };
        ghostty.setUserdata(session.terminal, session) catch {};
        ghostty.setWritePty(session.terminal, writePty) catch {};
        session.applyConfig();
        ghostty.write(session.terminal, "\x1b[?25h");
        session.output_thread = std.Thread.spawn(.{}, outputRun, .{session}) catch |err| {
            session.destroy();
            return err;
        };
        return session;
    }

    pub fn destroy(self: *Session) void {
        self.shutdownOutput();
        ime.shutdown();
        self.worker.shutdown();
        ghostty.ghostty_render_state_row_cells_free(self.row_cells);
        ghostty.ghostty_render_state_row_iterator_free(self.row_iterator);
        ghostty.freeKeyEvent(self.key_event);
        ghostty.freeKeyEncoder(self.key_encoder);
        ghostty.ghostty_render_state_free(self.render_state);
        self.capture_cache.deinit();
        ghostty.ghostty_terminal_free(self.terminal);
        self.pending_input.deinit();
        self.screen_cache.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn attachSurface(
        self: *Session,
        raw_window: *anyopaque,
        width: u32,
        height: u32,
    ) void {
        var window = native_window.NativeWindow.cloneFromPtr(raw_window) catch |err| {
            hilog.errorf("failed to retain terminal surface: {s}", .{@errorName(err)});
            return;
        };
        window.setBufferGeometry(@intCast(@max(width, 1)), @intCast(@max(height, 1))) catch |err| {
            window.deinit();
            hilog.errorf("failed to configure terminal surface: {s}", .{@errorName(err)});
            return;
        };
        self.worker.sendSurface(window, width, height);
        self.lockEngine();
        defer self.unlockEngine();
        self.width = width;
        self.height = height;
        self.reflowGrid();
        self.publishFullFrameLocked();
    }

    pub fn updateSurface(self: *Session, width: u32, height: u32) void {
        self.lockEngine();
        defer self.unlockEngine();
        self.width = width;
        self.height = height;
        self.worker.resizeSurface(width, height);
        self.reflowGrid();
        self.publishFullFrameLocked();
    }

    pub fn detachSurface(self: *Session) void {
        self.worker.sendLost();
    }

    pub fn setConfig(self: *Session, next: config.TerminalConfig) void {
        self.lockEngine();
        defer self.unlockEngine();
        self.terminal_config = next;
        ghostty.setMaxScrollback(self.terminal, @intCast(@max(next.scrollbackLines, 0))) catch {};
        self.applyConfig();
        self.reflowGrid();
        self.publishFullFrameLocked();
    }

    pub fn setDensity(self: *Session, density: f64) void {
        self.lockEngine();
        defer self.unlockEngine();
        self.density = if (std.math.isFinite(density) and density > 0) density else 1;
        self.reflowGrid();
        self.publishFullFrameLocked();
    }

    pub fn feedOutput(self: *Session, bytes: []const u8) void {
        if (bytes.len == 0 or !self.output_running.load(.acquire)) return;
        self.lockOutput();
        defer self.unlockOutput();
        self.pending_output.appendSlice(self.allocator, bytes) catch {
            hilog.errorf("terminal output queue allocation failed", .{});
            return;
        };
        self.output_condition.signal(std.Options.debug_io);
    }

    pub fn writeInput(self: *Session, bytes: []const u8) void {
        self.pending_input.append(bytes);
    }

    pub fn handleKey(self: *Session, event: xcomponent.KeyEventData) void {
        const pending = self.key_mod_state.translate(event) orelse return;
        self.lockOutput();
        defer self.unlockOutput();
        self.pending_keys.append(self.allocator, pending) catch {
            hilog.errorf("terminal key queue allocation failed", .{});
            return;
        };
        self.output_condition.signal(std.Options.debug_io);
    }

    pub fn handleTouch(self: *Session, event: xcomponent.TouchEventData) void {
        const point = if (event.num_points > 0) event.touch_points[0] else return;
        const slop = @as(f32, @floatCast(@max(self.cell_metrics.height * 0.4, 6)));
        switch (event.event_type) {
            .down => {
                self.touch_active = true;
                self.touch_scroll = false;
                self.touch_origin_x = point.x;
                self.touch_origin_y = point.y;
                self.touch_last_y = point.y;
                self.touch_acc = 0;
            },
            .move => {
                if (!self.touch_active) return;
                const dy = @abs(point.y - self.touch_origin_y);
                const dx = @abs(point.x - self.touch_origin_x);
                if (!self.touch_scroll and dy > slop and dy >= dx) {
                    self.touch_scroll = true;
                }
                if (!self.touch_scroll) return;
                const step = point.y - self.touch_last_y;
                self.touch_last_y = point.y;
                self.touch_acc += step;
                const row_px: f32 = @floatCast(@max(self.cell_metrics.height, 1));
                const scrolled: i32 = @intFromFloat(self.touch_acc / row_px);
                if (scrolled != 0) {
                    self.touch_acc -= @as(f32, @floatFromInt(scrolled)) * row_px;
                    _ = self.pending_scroll.fetchAdd(-scrolled, .acq_rel);
                }
            },
            .up => {
                const tap = self.touch_active and !self.touch_scroll and
                    @abs(point.x - self.touch_origin_x) <= slop and
                    @abs(point.y - self.touch_origin_y) <= slop;
                self.touch_active = false;
                self.touch_scroll = false;
                if (tap) ime.showKeyboard();
            },
            else => {
                self.touch_active = false;
                self.touch_scroll = false;
            },
        }
    }

    pub fn renderFrame(self: *Session, timestamp: u64) void {
        if (!self.tryLockEngine()) return;
        defer self.unlockEngine();
        if (self.pending_reset_scroll.swap(false, .acq_rel)) {
            _ = self.pending_scroll.swap(0, .acq_rel);
            ghostty.scrollBottom(self.terminal);
            self.publishViewportFrameLocked();
        } else {
            const scroll = self.pending_scroll.swap(0, .acq_rel);
            if (scroll != 0) {
                ghostty.scrollDelta(self.terminal, scroll);
                self.publishViewportFrameLocked();
            }
        }
        if (self.terminal_config.cursorBlink) {
            const blink_ns: u64 = 600 * std.time.ns_per_ms;
            if (self.last_blink_timestamp) |previous| {
                const elapsed = timestamp -| previous;
                if (elapsed >= blink_ns) {
                    const phases = elapsed / blink_ns;
                    if (phases % 2 == 1) self.cursor_phase = !self.cursor_phase;
                    self.last_blink_timestamp = previous + phases * blink_ns;
                    self.publishCursorFrameLocked();
                }
            } else {
                self.last_blink_timestamp = timestamp;
            }
        } else {
            self.last_blink_timestamp = null;
            if (!self.cursor_phase) {
                self.cursor_phase = true;
                self.publishCursorFrameLocked();
            }
        }
    }

    pub fn scrollView(self: *Session, delta: i32) void {
        if (delta != 0) _ = self.pending_scroll.fetchAdd(delta, .acq_rel);
    }

    pub fn resetScroll(self: *Session) void {
        self.pending_reset_scroll.store(true, .release);
    }

    pub fn scrollbackSize(self: *Session) u32 {
        self.lockEngine();
        defer self.unlockEngine();
        var value: u64 = 0;
        _ = ghostty.ghostty_terminal_get(self.terminal, .scrollback_rows, &value);
        return @truncate(value);
    }

    pub fn metrics(self: *Session) config.CellMetrics {
        self.lockEngine();
        defer self.unlockEngine();
        return self.cell_metrics;
    }

    fn publishFullFrameLocked(self: *Session) void {
        self.publishFrame(.full);
    }

    fn publishViewportFrameLocked(self: *Session) void {
        self.publishFrame(.viewport);
    }

    fn publishCursorFrameLocked(self: *Session) void {
        self.publishFrame(.cursor);
    }

    fn publishFrame(self: *Session, update_hint: config.UpdateHint) void {
        const snapshot = capture_mod.captureCached(
            &self.capture_cache,
            std.heap.c_allocator,
            self.terminal,
            self.render_state,
            self.cursor_phase,
            update_hint,
        ) orelse return;
        self.worker.publish(.{
            .allocator = std.heap.c_allocator,
            .cols = snapshot.cols,
            .rows = snapshot.rows,
            .cell_width = @intFromFloat(@max(self.cell_metrics.width, 1)),
            .cell_height = @intFromFloat(@max(self.cell_metrics.height, 1)),
            .padding = self.padding_px,
            .cells = snapshot.cells,
            .cursor = snapshot.cursor,
            .cursor_color = snapshot.cursor_color,
            .background = snapshot.background,
        });
    }

    pub fn screenContent(self: *Session) []const u8 {
        self.lockEngine();
        defer self.unlockEngine();
        self.screen_cache.clearRetainingCapacity();
        ghostty.check(ghostty.ghostty_render_state_update(self.render_state, self.terminal)) catch
            return self.screen_cache.items;
        var grid_cols: u16 = 0;
        var grid_rows: u16 = 0;
        _ = ghostty.ghostty_render_state_get(self.render_state, .cols, &grid_cols);
        _ = ghostty.ghostty_render_state_get(self.render_state, .rows, &grid_rows);
        var iterator: ?*ghostty.RowIterator = self.row_iterator;
        _ = ghostty.ghostty_render_state_get(self.render_state, .row_iterator, @ptrCast(&iterator));
        var row: u16 = 0;
        while (ghostty.ghostty_render_state_row_iterator_next(self.row_iterator) and row < grid_rows) : (row += 1) {
            if (row != 0) self.screen_cache.append(self.allocator, '\n') catch {};
            var cells_handle: ?*ghostty.RowCells = self.row_cells;
            _ = ghostty.ghostty_render_state_row_get(self.row_iterator, .cells, @ptrCast(&cells_handle));
            var col: u16 = 0;
            while (ghostty.ghostty_render_state_row_cells_next(self.row_cells) and col < grid_cols) : (col += 1) {
                self.appendCurrentCell(&self.screen_cache);
            }
        }
        return self.screen_cache.items;
    }

    pub fn cursorPosition(self: *Session) config.CursorPosition {
        self.lockEngine();
        defer self.unlockEngine();
        const x = ghostty.getU16(self.terminal, .cursor_x) catch 0;
        const y = ghostty.getU16(self.terminal, .cursor_y) catch 0;
        return .{ .row = y, .col = x };
    }

    pub fn size(self: *Session) config.TerminalSize {
        self.lockEngine();
        defer self.unlockEngine();
        return .{
            .cols = @intCast(self.cols()),
            .rows = @intCast(self.rows()),
        };
    }

    fn cols(self: *Session) u16 {
        return ghostty.getU16(self.terminal, .cols) catch 80;
    }

    fn rows(self: *Session) u16 {
        return ghostty.getU16(self.terminal, .rows) catch 24;
    }

    fn reflowGrid(self: *Session) void {
        const previous_cell_width: u32 = @intFromFloat(@max(self.cell_metrics.width, 1));
        const previous_cell_height: u32 = @intFromFloat(@max(self.cell_metrics.height, 1));
        const next = layout.GridLayout.fromSurface(
            self.width,
            self.height,
            self.terminal_config.fontSize,
            self.density,
        );
        self.cell_metrics = next.cell;
        self.padding_px = next.padding_px;
        if (self.width == 0 or self.height == 0) return;
        const next_cell_width: u32 = @intFromFloat(@max(self.cell_metrics.width, 1));
        const next_cell_height: u32 = @intFromFloat(@max(self.cell_metrics.height, 1));
        if (self.cols() == next.cols and self.rows() == next.rows and
            previous_cell_width == next_cell_width and previous_cell_height == next_cell_height)
        {
            return;
        }
        _ = ghostty.ghostty_terminal_resize(
            self.terminal,
            next.cols,
            next.rows,
            next_cell_width,
            next_cell_height,
        );
    }

    fn applyConfig(self: *Session) void {
        const fg = ghostty.ColorRgb{
            .r = @truncate(self.terminal_config.fgColor >> 16),
            .g = @truncate(self.terminal_config.fgColor >> 8),
            .b = @truncate(self.terminal_config.fgColor),
        };
        const bg = ghostty.ColorRgb{
            .r = @truncate(self.terminal_config.bgColor >> 16),
            .g = @truncate(self.terminal_config.bgColor >> 8),
            .b = @truncate(self.terminal_config.bgColor),
        };
        ghostty.setColor(self.terminal, .color_foreground, fg) catch {};
        ghostty.setColor(self.terminal, .color_background, bg) catch {};
        ghostty.setColor(self.terminal, .color_cursor, fg) catch {};
        ghostty.setBool(
            self.terminal,
            .default_cursor_blink,
            self.terminal_config.cursorBlink,
        ) catch {};
        ghostty.setCursorStyle(
            self.terminal,
            switch (std.math.clamp(self.terminal_config.cursorStyle, 0, 3)) {
                1 => .bar,
                2 => .underline,
                3 => .block_hollow,
                else => .block,
            },
        ) catch {};
    }

    fn appendCurrentCell(self: *Session, output: *std.ArrayList(u8)) void {
        var storage: [64]u8 = undefined;
        var buffer = ghostty.Buffer{ .ptr = &storage, .cap = storage.len, .len = 0 };
        const result = ghostty.ghostty_render_state_row_cells_get(self.row_cells, .graphemes_utf8, &buffer);
        if (result == .success) {
            if (buffer.len == 0) {
                output.append(self.allocator, ' ') catch {};
            } else {
                output.appendSlice(self.allocator, storage[0..buffer.len]) catch {};
            }
            return;
        }
        if (result != .out_of_space or buffer.len <= storage.len) {
            output.append(self.allocator, ' ') catch {};
            return;
        }
        const dynamic = self.allocator.alloc(u8, buffer.len) catch {
            output.append(self.allocator, ' ') catch {};
            return;
        };
        defer self.allocator.free(dynamic);
        var dynamic_buffer = ghostty.Buffer{
            .ptr = dynamic.ptr,
            .cap = dynamic.len,
            .len = 0,
        };
        if (ghostty.ghostty_render_state_row_cells_get(self.row_cells, .graphemes_utf8, &dynamic_buffer) == .success) {
            output.appendSlice(self.allocator, dynamic[0..dynamic_buffer.len]) catch {};
        } else {
            output.append(self.allocator, ' ') catch {};
        }
    }

    fn shutdownOutput(self: *Session) void {
        self.output_running.store(false, .release);
        self.lockOutput();
        self.output_condition.broadcast(std.Options.debug_io);
        self.unlockOutput();
        if (self.output_thread) |thread| {
            thread.join();
            self.output_thread = null;
        }
        self.lockOutput();
        self.pending_output.deinit(self.allocator);
        self.pending_keys.deinit(self.allocator);
        self.unlockOutput();
    }

    const Work = union(enum) {
        output: usize,
        key: input.KeyInput,
    };

    fn takeWork(self: *Session, destination: []u8) ?Work {
        self.lockOutput();
        defer self.unlockOutput();
        while (self.pending_output.items.len == 0 and
            self.pending_keys.items.len == 0 and
            self.output_running.load(.acquire))
        {
            self.output_condition.waitUncancelable(std.Options.debug_io, &self.output_mutex);
        }
        if (self.pending_keys.items.len != 0) {
            return .{ .key = self.pending_keys.orderedRemove(0) };
        }
        if (self.pending_output.items.len == 0) return null;
        const count = @min(destination.len, self.pending_output.items.len);
        @memcpy(destination[0..count], self.pending_output.items[0..count]);
        const remaining = self.pending_output.items.len - count;
        std.mem.copyForwards(
            u8,
            self.pending_output.items[0..remaining],
            self.pending_output.items[count..],
        );
        self.pending_output.shrinkRetainingCapacity(remaining);
        return .{ .output = count };
    }

    fn lockEngine(self: *Session) void {
        self.engine_mutex.lockUncancelable(std.Options.debug_io);
    }

    fn tryLockEngine(self: *Session) bool {
        return self.engine_mutex.tryLock();
    }

    fn unlockEngine(self: *Session) void {
        self.engine_mutex.unlock(std.Options.debug_io);
    }

    fn lockOutput(self: *Session) void {
        self.output_mutex.lockUncancelable(std.Options.debug_io);
    }

    fn unlockOutput(self: *Session) void {
        self.output_mutex.unlock(std.Options.debug_io);
    }
};

fn outputRun(session: *Session) void {
    var chunk: [output_chunk_size]u8 = undefined;
    while (session.takeWork(&chunk)) |work| {
        switch (work) {
            .output => |len| {
                session.lockEngine();
                ghostty.write(session.terminal, chunk[0..len]);
                session.cursor_phase = true;
                session.last_blink_timestamp = null;
                session.publishFullFrameLocked();
                session.unlockEngine();
            },
            .key => |key| {
                var encoded_storage: [256]u8 = undefined;
                session.lockEngine();
                const encoded = ghostty.encodeKey(
                    session.key_encoder,
                    session.key_event,
                    session.terminal,
                    key.action,
                    key.key,
                    key.mods,
                    key.utf8(),
                    key.unshifted_codepoint,
                    &encoded_storage,
                ) catch |err| {
                    session.unlockEngine();
                    hilog.errorf("terminal key encoding failed: {s}", .{@errorName(err)});
                    continue;
                };
                session.pending_input.append(encoded);
                session.unlockEngine();
            },
        }
        std.Thread.yield() catch {};
    }
}

fn writePty(
    _: ?*ghostty.Terminal,
    userdata: ?*anyopaque,
    data: [*]const u8,
    len: usize,
) callconv(.c) void {
    const session: *Session = @ptrCast(@alignCast(userdata orelse return));
    session.pending_input.append(data[0..len]);
}
