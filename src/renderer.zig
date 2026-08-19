const std = @import("std");
const wgpu = @import("wgpu");
const config = @import("config.zig");
const font = @import("font.zig");
const gpu_font = @import("gpu_font.zig");
const hilog = @import("hilog");
const window_mod = @import("window.zig");

const initial_atlas_size: u32 = 2048;

const RendererError = error{
    NoInstance,
    NoSurface,
    NoAdapter,
    NoDevice,
    NoQueue,
    NoTexture,
    NoPipeline,
    NoFont,
    InvalidSurfaceCapabilities,
    AtlasFull,
    OutOfMemory,
};

const RectInstance = extern struct {
    rect: [4]f32,
    color: [4]f32,
};

const GlyphInstance = extern struct {
    rect: [4]f32,
    uv: [4]f32,
    color: [4]f32,
    params: [4]f32,
};

const GlyphEntry = struct {
    hash: u64,
    text_len: u8,
    text: [font.Cell.max_grapheme_bytes]u8,
    span: u8,
    font_style: u8,
    is_color: bool,
    atlas_x: u32,
    atlas_y: u32,
    offset_x: i32,
    offset_y: i32,
    width: u32,
    height: u32,
};

const PipelineBundle = struct {
    rect: *wgpu.RenderPipeline,
    glyph: *wgpu.RenderPipeline,
    atlas_layout: *wgpu.BindGroupLayout,
    sampler: *wgpu.Sampler,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    instance: *wgpu.Instance,
    surface: *wgpu.Surface,
    adapter: *wgpu.Adapter,
    device: *wgpu.Device,
    queue: *wgpu.Queue,
    rect_pipeline: *wgpu.RenderPipeline,
    glyph_pipeline: *wgpu.RenderPipeline,
    atlas_layout: *wgpu.BindGroupLayout,
    atlas_sampler: *wgpu.Sampler,
    atlas_texture: *wgpu.Texture,
    atlas_view: *wgpu.TextureView,
    atlas_bind_group: *wgpu.BindGroup,
    rect_buffer: ?*wgpu.Buffer = null,
    glyph_buffer: ?*wgpu.Buffer = null,
    rect_buffer_capacity: u64 = 0,
    glyph_buffer_capacity: u64 = 0,
    format: wgpu.TextureFormat,
    alpha_mode: wgpu.CompositeAlphaMode,
    width: u32,
    height: u32,
    rasterizer: ?gpu_font.Rasterizer = null,
    glyph_cell_width: u32 = 0,
    glyph_cell_height: u32 = 0,
    atlas_size: u32 = initial_atlas_size,
    max_atlas_size: u32 = initial_atlas_size,
    atlas_cursor_x: u32 = 0,
    atlas_cursor_y: u32 = 0,
    atlas_row_height: u32 = 0,
    glyph_entries: std.ArrayList(GlyphEntry) = .empty,
    rect_before: std.ArrayList(RectInstance) = .empty,
    rect_after: std.ArrayList(RectInstance) = .empty,
    rect_instances: std.ArrayList(RectInstance) = .empty,
    glyph_instances: std.ArrayList(GlyphInstance) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        surface_window: window_mod.OhosSurfaceWindow,
        width: u32,
        height: u32,
    ) RendererError!Renderer {
        var extras = wgpu.InstanceExtras{
            .backends = wgpu.InstanceBackends.gl | wgpu.InstanceBackends.vulkan,
            .flags = wgpu.InstanceFlags.default,
            .dx12_shader_compiler = .undefined,
            .gles3_minor_version = .automatic,
            .gl_fence_behavior = .gl_fence_behaviour_normal,
            .dxc_max_shader_model = .dxc_max_shader_model_v6_0,
        };
        var instance_descriptor = wgpu.InstanceDescriptor{};
        const descriptor = instance_descriptor.withExtras(&extras);
        const instance = wgpu.Instance.create(&descriptor) orelse
            return error.NoInstance;
        errdefer instance.release();

        const native_window = surface_window.nativeWindowPtr() catch return error.NoSurface;
        const source = wgpu.SurfaceSourceOhosNativeWindow{ .window = native_window };
        const surface_descriptor = wgpu.surfaceDescriptorFromOhosNativeWindow(&source, "terminal");
        const surface = instance.createSurface(&surface_descriptor) orelse return error.NoSurface;
        errdefer surface.release();

        const adapter = try requestAdapter(instance, surface);
        errdefer adapter.release();
        logAdapter(adapter);
        const device = try requestDevice(instance, adapter);
        errdefer device.release();
        const queue = device.getQueue() orelse return error.NoQueue;
        errdefer queue.release();
        var device_limits: wgpu.Limits = .{};
        const max_atlas_size = if (device.getLimits(&device_limits) == .success)
            @max(initial_atlas_size, @min(device_limits.max_texture_dimension_2d, 8192))
        else
            initial_atlas_size;

        var capabilities: wgpu.SurfaceCapabilities = .{};
        _ = surface.getCapabilities(adapter, &capabilities);
        defer capabilities.deinit();
        const format = if (capabilities.formatsSlice().len > 0)
            capabilities.formatsSlice()[0]
        else
            return error.InvalidSurfaceCapabilities;
        const alpha_mode = if (capabilities.alphaModesSlice().len > 0)
            capabilities.alphaModesSlice()[0]
        else
            return error.InvalidSurfaceCapabilities;

        const pipelines = try createPipelines(device, format);
        errdefer pipelines.rect.release();
        errdefer pipelines.glyph.release();
        errdefer pipelines.atlas_layout.release();
        errdefer pipelines.sampler.release();

        const atlas_texture = device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("terminal glyph atlas"),
            .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
            .size = .{
                .width = initial_atlas_size,
                .height = initial_atlas_size,
                .depth_or_array_layers = 1,
            },
            .format = .rgba8_unorm,
        }) orelse return error.NoTexture;
        errdefer atlas_texture.release();
        const atlas_view = atlas_texture.createView(&.{
            .label = wgpu.StringView.fromSlice("terminal glyph atlas view"),
            .format = .rgba8_unorm,
            .dimension = .@"2d",
            .mip_level_count = 1,
            .array_layer_count = 1,
        }) orelse return error.NoTexture;
        errdefer atlas_view.release();
        const atlas_bind_group = device.createBindGroup(&wgpu.BindGroupDescriptor.init(
            pipelines.atlas_layout,
            &.{
                .{ .binding = 0, .texture_view = atlas_view },
                .{ .binding = 1, .sampler = pipelines.sampler },
            },
        )) orelse return error.NoPipeline;
        errdefer atlas_bind_group.release();

        var renderer = Renderer{
            .allocator = allocator,
            .instance = instance,
            .surface = surface,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .rect_pipeline = pipelines.rect,
            .glyph_pipeline = pipelines.glyph,
            .atlas_layout = pipelines.atlas_layout,
            .atlas_sampler = pipelines.sampler,
            .atlas_texture = atlas_texture,
            .atlas_view = atlas_view,
            .atlas_bind_group = atlas_bind_group,
            .format = format,
            .alpha_mode = alpha_mode,
            .width = @max(width, 1),
            .height = @max(height, 1),
            .max_atlas_size = max_atlas_size,
        };
        renderer.configureSurface();
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.rasterizer) |*item| item.deinit();
        self.rasterizer = null;
        self.glyph_entries.deinit(self.allocator);
        self.rect_before.deinit(self.allocator);
        self.rect_after.deinit(self.allocator);
        self.rect_instances.deinit(self.allocator);
        self.glyph_instances.deinit(self.allocator);
        if (self.rect_buffer) |item| item.release();
        if (self.glyph_buffer) |item| item.release();
        self.atlas_bind_group.release();
        self.atlas_view.release();
        self.atlas_texture.release();
        self.atlas_sampler.release();
        self.atlas_layout.release();
        self.rect_pipeline.release();
        self.glyph_pipeline.release();
        self.queue.release();
        self.device.release();
        self.adapter.release();
        self.surface.release();
        self.instance.release();
    }

    pub fn resize(self: *Renderer, width: u32, height: u32) RendererError!void {
        self.width = @max(width, 1);
        self.height = @max(height, 1);
        self.configureSurface();
    }

    pub fn present(
        self: *Renderer,
        cols: u16,
        rows: u16,
        cell_width: u32,
        cell_height: u32,
        padding: u32,
        cells: []const font.Cell,
        cursor: ?font.CursorCell,
        cursor_color: config.Rgb,
        clear: config.Rgb,
    ) RendererError!void {
        const resolved_cell_width = @max(cell_width, 1);
        const resolved_cell_height = @max(cell_height, 1);
        try self.ensureRasterizer(resolved_cell_width, resolved_cell_height);
        self.buildScene(
            cols,
            rows,
            resolved_cell_width,
            resolved_cell_height,
            padding,
            cells,
            cursor,
            cursor_color,
            clear,
        ) catch |err| {
            if (err != error.AtlasFull) return err;
            try self.growAtlas();
            try self.buildScene(
                cols,
                rows,
                resolved_cell_width,
                resolved_cell_height,
                padding,
                cells,
                cursor,
                cursor_color,
                clear,
            );
        };
        try self.uploadInstances();

        var surface_texture: wgpu.SurfaceTexture = .{};
        self.surface.getCurrentTexture(&surface_texture);
        switch (surface_texture.status) {
            .success_optimal, .success_suboptimal => {},
            .outdated, .lost => {
                self.configureSurface();
                return error.NoSurface;
            },
            .timeout, .occluded => return,
            else => return error.NoSurface,
        }
        const frame = surface_texture.takeTexture() orelse return error.NoTexture;
        defer frame.release();
        const view = frame.createView(null) orelse return error.NoTexture;
        defer view.release();
        const encoder = self.device.createCommandEncoder(&.{
            .label = wgpu.StringView.fromSlice("terminal GPU frame"),
        }) orelse return error.NoPipeline;
        defer encoder.release();

        const color_attachments = [_]wgpu.ColorAttachment{.{
            .view = view,
            .clear_value = wgpuColor(clear, isSrgb(self.format)),
        }};
        const pass = encoder.beginRenderPass(&wgpu.RenderPassDescriptor.init(&color_attachments)) orelse
            return error.NoPipeline;
        const before_count: u32 = @intCast(self.rect_before.items.len);
        const after_count: u32 = @intCast(self.rect_after.items.len);
        const glyph_count: u32 = @intCast(self.glyph_instances.items.len);
        if (before_count != 0) {
            pass.setPipeline(self.rect_pipeline);
            pass.setVertexBuffer(0, self.rect_buffer, 0, before_count * @sizeOf(RectInstance));
            pass.draw(6, before_count, 0, 0);
        }
        if (glyph_count != 0) {
            pass.setPipeline(self.glyph_pipeline);
            pass.setBindGroup(0, self.atlas_bind_group, &.{});
            pass.setVertexBuffer(0, self.glyph_buffer, 0, glyph_count * @sizeOf(GlyphInstance));
            pass.draw(6, glyph_count, 0, 0);
        }
        if (after_count != 0) {
            pass.setPipeline(self.rect_pipeline);
            const offset = @as(u64, before_count) * @sizeOf(RectInstance);
            pass.setVertexBuffer(
                0,
                self.rect_buffer,
                offset,
                @as(u64, after_count) * @sizeOf(RectInstance),
            );
            pass.draw(6, after_count, 0, 0);
        }
        pass.end();
        pass.release();

        const command = encoder.finish(&.{
            .label = wgpu.StringView.fromSlice("terminal GPU commands"),
        }) orelse return error.NoPipeline;
        defer command.release();
        self.queue.submit(&[_]*const wgpu.CommandBuffer{command});
        _ = self.surface.present();
        self.instance.processEvents();
    }

    fn configureSurface(self: *Renderer) void {
        self.surface.configure(&.{
            .device = self.device,
            .format = self.format,
            .usage = wgpu.TextureUsages.render_attachment,
            .width = self.width,
            .height = self.height,
            .alpha_mode = self.alpha_mode,
            .present_mode = .fifo,
        });
    }

    fn ensureRasterizer(
        self: *Renderer,
        cell_width: u32,
        cell_height: u32,
    ) RendererError!void {
        if (self.rasterizer != null and
            self.glyph_cell_width == cell_width and
            self.glyph_cell_height == cell_height)
        {
            return;
        }
        if (self.rasterizer) |*item| item.deinit();
        self.rasterizer = gpu_font.Rasterizer.init(
            self.allocator,
            cell_width,
            cell_height,
        ) catch return error.NoFont;
        self.glyph_cell_width = cell_width;
        self.glyph_cell_height = cell_height;
        self.atlas_cursor_x = 0;
        self.atlas_cursor_y = 0;
        self.atlas_row_height = 0;
        self.glyph_entries.clearRetainingCapacity();
    }

    fn buildScene(
        self: *Renderer,
        cols: u16,
        rows: u16,
        cell_width: u32,
        cell_height: u32,
        padding: u32,
        cells: []const font.Cell,
        cursor: ?font.CursorCell,
        cursor_color: config.Rgb,
        clear: config.Rgb,
    ) RendererError!void {
        self.rect_before.clearRetainingCapacity();
        self.rect_after.clearRetainingCapacity();
        self.rect_instances.clearRetainingCapacity();
        self.glyph_instances.clearRetainingCapacity();
        const srgb_target = isSrgb(self.format);
        const limit = @min(cells.len, @as(usize, cols) * @as(usize, rows));
        for (cells[0..limit], 0..) |*cell, index| {
            const col: u16 = @intCast(index % @as(usize, cols));
            const row: u16 = @intCast(index / @as(usize, cols));
            const x = padding +| @as(u32, col) *| cell_width;
            const y = padding +| @as(u32, row) *| cell_height;
            var effective_fg = cell.fg;
            var effective_bg = cell.bg;
            if (cell.inverse != cell.selected) {
                std.mem.swap(config.Rgb, &effective_fg, &effective_bg);
            }
            const foreground_alpha: f32 = if (cell.faint) 0.5 else 1;
            if (!std.meta.eql(effective_bg, clear)) {
                try self.appendRect(
                    &self.rect_before,
                    x,
                    y,
                    cell_width,
                    cell_height,
                    effective_bg,
                    srgb_target,
                );
            }
            const cursor_here = if (cursor) |value| value.x == col and value.y == row else false;
            const block_cursor = cursor_here and cursor.?.style == 0;
            if (block_cursor) {
                try self.appendRect(
                    &self.rect_before,
                    x,
                    y,
                    cell_width,
                    cell_height,
                    cursor_color,
                    srgb_target,
                );
            }

            if (!cell.invisible and cell.underline != 0) {
                try self.appendUnderline(
                    x,
                    y,
                    cell_width,
                    cell_height,
                    cell.underline,
                    cell.underline_color,
                    foreground_alpha,
                    srgb_target,
                );
            }
            if (!cell.invisible and cell.codepoint != 0 and cell.codepoint != ' ' and cell.span != 0) {
                if (try self.findOrCreateGlyph(cell)) |glyph| {
                    const glyph_color = if (block_cursor) effective_bg else effective_fg;
                    try self.glyph_instances.append(self.allocator, .{
                        .rect = glyphPixelRect(
                            x,
                            y,
                            glyph.offset_x,
                            glyph.offset_y,
                            glyph.width,
                            glyph.height,
                            self.width,
                            self.height,
                        ),
                        .uv = atlasUv(glyph, self.atlas_size),
                        .color = colorVector(glyph_color, srgb_target),
                        .params = .{
                            if (glyph.is_color) 1 else 0,
                            foreground_alpha,
                            0,
                            0,
                        },
                    });
                }
            }
            if (!cell.invisible and cell.overline) {
                try self.appendRectAlpha(
                    &self.rect_after,
                    x,
                    y,
                    cell_width,
                    @max(1, cell_height / 16),
                    effective_fg,
                    foreground_alpha,
                    srgb_target,
                );
            }
            if (!cell.invisible and cell.strikethrough) {
                try self.appendRectAlpha(
                    &self.rect_after,
                    x,
                    y + cell_height / 2,
                    cell_width,
                    @max(1, cell_height / 16),
                    effective_fg,
                    foreground_alpha,
                    srgb_target,
                );
            }
        }

        if (cursor) |value| {
            const x = padding +| @as(u32, value.x) *| cell_width;
            const y = padding +| @as(u32, value.y) *| cell_height;
            switch (value.style) {
                1 => try self.appendRect(
                    &self.rect_after,
                    x,
                    y,
                    @max(2, cell_width / 6),
                    cell_height,
                    cursor_color,
                    srgb_target,
                ),
                2 => {
                    const thickness = @max(2, cell_height / 8);
                    try self.appendRect(
                        &self.rect_after,
                        x,
                        y + cell_height -| thickness,
                        cell_width,
                        thickness,
                        cursor_color,
                        srgb_target,
                    );
                },
                3 => {
                    const thickness: u32 = 2;
                    try self.appendRect(&self.rect_after, x, y, cell_width, thickness, cursor_color, srgb_target);
                    try self.appendRect(&self.rect_after, x, y + cell_height -| thickness, cell_width, thickness, cursor_color, srgb_target);
                    try self.appendRect(&self.rect_after, x, y, thickness, cell_height, cursor_color, srgb_target);
                    try self.appendRect(&self.rect_after, x + cell_width -| thickness, y, thickness, cell_height, cursor_color, srgb_target);
                },
                else => {},
            }
        }

        try self.rect_instances.appendSlice(self.allocator, self.rect_before.items);
        try self.rect_instances.appendSlice(self.allocator, self.rect_after.items);
    }

    fn appendRect(
        self: *Renderer,
        list: *std.ArrayList(RectInstance),
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        color: config.Rgb,
        srgb_target: bool,
    ) RendererError!void {
        return self.appendRectAlpha(list, x, y, width, height, color, 1, srgb_target);
    }

    fn appendRectAlpha(
        self: *Renderer,
        list: *std.ArrayList(RectInstance),
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        color: config.Rgb,
        alpha: f32,
        srgb_target: bool,
    ) RendererError!void {
        if (x >= self.width or y >= self.height or width == 0 or height == 0) return;
        var vector = colorVector(color, srgb_target);
        vector[3] = std.math.clamp(alpha, 0, 1);
        list.append(self.allocator, .{
            .rect = pixelRect(x, y, width, height, self.width, self.height),
            .color = vector,
        }) catch return error.OutOfMemory;
    }

    fn appendUnderline(
        self: *Renderer,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        style: u8,
        color: config.Rgb,
        alpha: f32,
        srgb_target: bool,
    ) RendererError!void {
        const thickness = @max(1, height / 16);
        const baseline = y + height -| @max(2, height / 10);
        switch (style) {
            2 => {
                try self.appendRectAlpha(&self.rect_before, x, baseline -| thickness * 2, width, thickness, color, alpha, srgb_target);
                try self.appendRectAlpha(&self.rect_before, x, baseline, width, thickness, color, alpha, srgb_target);
            },
            3 => {
                const segment = @max(2, thickness * 2);
                var offset: u32 = 0;
                var up = false;
                while (offset < width) : (offset += segment) {
                    try self.appendRectAlpha(
                        &self.rect_before,
                        x + offset,
                        baseline -| if (up) thickness else 0,
                        @min(segment, width - offset),
                        thickness,
                        color,
                        alpha,
                        srgb_target,
                    );
                    up = !up;
                }
            },
            4 => {
                const dot = @max(1, thickness);
                var offset: u32 = 0;
                while (offset < width) : (offset += dot * 2) {
                    try self.appendRectAlpha(&self.rect_before, x + offset, baseline, @min(dot, width - offset), thickness, color, alpha, srgb_target);
                }
            },
            5 => {
                const dash = @max(3, width / 3);
                var offset: u32 = 0;
                while (offset < width) : (offset += dash + thickness) {
                    try self.appendRectAlpha(&self.rect_before, x + offset, baseline, @min(dash, width - offset), thickness, color, alpha, srgb_target);
                }
            },
            else => try self.appendRectAlpha(&self.rect_before, x, baseline, width, thickness, color, alpha, srgb_target),
        }
    }

    fn findOrCreateGlyph(
        self: *Renderer,
        cell: *const font.Cell,
    ) RendererError!?GlyphEntry {
        var encoded: [4]u8 = undefined;
        const stored = cell.text();
        const text = if (stored.len != 0) stored else encodeCodepoint(cell.codepoint, &encoded);
        if (text.len == 0 or text.len > font.Cell.max_grapheme_bytes) return null;
        const span: u8 = @max(cell.span, 1);
        const font_style: u8 = @as(u8, @intFromBool(cell.bold)) |
            (@as(u8, @intFromBool(cell.italic)) << 1);
        const hash = std.hash.Wyhash.hash(
            @as(u64, span) | (@as(u64, font_style) << 8),
            text,
        );
        for (self.glyph_entries.items) |entry| {
            if (entry.hash == hash and entry.span == span and entry.font_style == font_style and
                entry.text_len == text.len and
                std.mem.eql(u8, entry.text[0..entry.text_len], text))
            {
                return entry;
            }
        }

        const rasterizer = if (self.rasterizer) |*item| item else return error.NoFont;
        const rasterized = rasterizer.rasterize(cell) orelse return null;
        const packed_width = rasterized.width +| 2;
        const packed_height = rasterized.height +| 2;
        if (self.atlas_cursor_x +| packed_width > self.atlas_size) {
            self.atlas_cursor_x = 0;
            self.atlas_cursor_y +|= self.atlas_row_height;
            self.atlas_row_height = 0;
        }
        if (packed_width > self.atlas_size or
            self.atlas_cursor_y +| packed_height > self.atlas_size)
        {
            return error.AtlasFull;
        }
        const atlas_x = self.atlas_cursor_x + 1;
        const atlas_y = self.atlas_cursor_y + 1;
        self.atlas_cursor_x +|= packed_width;
        self.atlas_row_height = @max(self.atlas_row_height, packed_height);
        self.queue.writeTexture(
            &.{
                .texture = self.atlas_texture,
                .origin = .{ .x = atlas_x, .y = atlas_y },
                .aspect = .all,
            },
            rasterized.pixels,
            &.{
                .bytes_per_row = rasterized.row_bytes,
                .rows_per_image = rasterized.height,
            },
            &.{
                .width = rasterized.width,
                .height = rasterized.height,
                .depth_or_array_layers = 1,
            },
        );
        var entry = GlyphEntry{
            .hash = hash,
            .text_len = @intCast(text.len),
            .text = [_]u8{0} ** font.Cell.max_grapheme_bytes,
            .span = span,
            .font_style = font_style,
            .is_color = rasterized.is_color,
            .atlas_x = atlas_x,
            .atlas_y = atlas_y,
            .offset_x = rasterized.offset_x,
            .offset_y = rasterized.offset_y,
            .width = rasterized.width,
            .height = rasterized.height,
        };
        @memcpy(entry.text[0..text.len], text);
        self.glyph_entries.append(self.allocator, entry) catch return error.OutOfMemory;
        return entry;
    }

    fn growAtlas(self: *Renderer) RendererError!void {
        const next_size = if (self.atlas_size < self.max_atlas_size)
            @min(self.atlas_size *| 2, self.max_atlas_size)
        else
            self.atlas_size;
        const replacement_texture = self.device.createTexture(&.{
            .label = wgpu.StringView.fromSlice("terminal glyph atlas"),
            .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
            .size = .{
                .width = next_size,
                .height = next_size,
                .depth_or_array_layers = 1,
            },
            .format = .rgba8_unorm,
        }) orelse return error.NoTexture;
        errdefer replacement_texture.release();
        const replacement_view = replacement_texture.createView(&.{
            .label = wgpu.StringView.fromSlice("terminal glyph atlas view"),
            .format = .rgba8_unorm,
            .dimension = .@"2d",
            .mip_level_count = 1,
            .array_layer_count = 1,
        }) orelse return error.NoTexture;
        errdefer replacement_view.release();
        const replacement_bind_group = self.device.createBindGroup(&wgpu.BindGroupDescriptor.init(
            self.atlas_layout,
            &.{
                .{ .binding = 0, .texture_view = replacement_view },
                .{ .binding = 1, .sampler = self.atlas_sampler },
            },
        )) orelse return error.NoPipeline;

        self.atlas_bind_group.release();
        self.atlas_view.release();
        self.atlas_texture.release();
        self.atlas_texture = replacement_texture;
        self.atlas_view = replacement_view;
        self.atlas_bind_group = replacement_bind_group;
        self.atlas_size = next_size;
        self.atlas_cursor_x = 0;
        self.atlas_cursor_y = 0;
        self.atlas_row_height = 0;
        self.glyph_entries.clearRetainingCapacity();
    }

    fn uploadInstances(self: *Renderer) RendererError!void {
        const rect_bytes = std.mem.sliceAsBytes(self.rect_instances.items);
        const glyph_bytes = std.mem.sliceAsBytes(self.glyph_instances.items);
        try self.ensureBuffer(
            &self.rect_buffer,
            &self.rect_buffer_capacity,
            rect_bytes.len,
            "terminal rectangle instances",
        );
        try self.ensureBuffer(
            &self.glyph_buffer,
            &self.glyph_buffer_capacity,
            glyph_bytes.len,
            "terminal glyph instances",
        );
        if (rect_bytes.len != 0) self.queue.writeBuffer(self.rect_buffer.?, 0, rect_bytes);
        if (glyph_bytes.len != 0) self.queue.writeBuffer(self.glyph_buffer.?, 0, glyph_bytes);
    }

    fn ensureBuffer(
        self: *Renderer,
        buffer: *?*wgpu.Buffer,
        capacity: *u64,
        required: usize,
        label: []const u8,
    ) RendererError!void {
        if (required == 0 or capacity.* >= required) return;
        var next: u64 = 4096;
        while (next < required) next *|= 2;
        const replacement = self.device.createBuffer(&.{
            .label = wgpu.StringView.fromSlice(label),
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .size = next,
        }) orelse return error.NoTexture;
        if (buffer.*) |previous| previous.release();
        buffer.* = replacement;
        capacity.* = next;
    }
};

fn createPipelines(device: *wgpu.Device, format: wgpu.TextureFormat) RendererError!PipelineBundle {
    const rect_shader = createShader(device, @embedFile("shaders/rect.wgsl"), "rect.wgsl") orelse
        return error.NoPipeline;
    defer rect_shader.release();
    const glyph_shader = createShader(device, @embedFile("shaders/glyph.wgsl"), "glyph.wgsl") orelse
        return error.NoPipeline;
    defer glyph_shader.release();

    const atlas_layout = device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor.init(&.{
        .{
            .binding = 0,
            .visibility = wgpu.ShaderStages.fragment,
            .texture = .{ .sample_type = .float, .view_dimension = .@"2d" },
        },
        .{
            .binding = 1,
            .visibility = wgpu.ShaderStages.fragment,
            .sampler = .{ .type = .filtering },
        },
    })) orelse return error.NoPipeline;
    errdefer atlas_layout.release();
    const sampler = device.createSampler(&.{
        .label = wgpu.StringView.fromSlice("terminal glyph sampler"),
        .mag_filter = .linear,
        .min_filter = .linear,
    }) orelse return error.NoPipeline;
    errdefer sampler.release();

    const rect_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x4, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x4, .offset = 16, .shader_location = 1 },
    };
    var rect_layout = wgpu.VertexBufferLayout.init(@sizeOf(RectInstance), &rect_attributes);
    rect_layout.step_mode = .instance;
    const empty_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor.init(&.{})) orelse
        return error.NoPipeline;
    defer empty_layout.release();
    const rect_pipeline = createPipeline(
        device,
        rect_shader,
        empty_layout,
        &.{rect_layout},
        format,
        true,
    ) orelse return error.NoPipeline;
    errdefer rect_pipeline.release();

    const glyph_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x4, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x4, .offset = 16, .shader_location = 1 },
        .{ .format = .float32x4, .offset = 32, .shader_location = 2 },
        .{ .format = .float32x4, .offset = 48, .shader_location = 3 },
    };
    var glyph_layout = wgpu.VertexBufferLayout.init(@sizeOf(GlyphInstance), &glyph_attributes);
    glyph_layout.step_mode = .instance;
    const glyph_pipeline_layout = device.createPipelineLayout(
        &wgpu.PipelineLayoutDescriptor.init(&.{atlas_layout}),
    ) orelse return error.NoPipeline;
    defer glyph_pipeline_layout.release();
    const glyph_pipeline = createPipeline(
        device,
        glyph_shader,
        glyph_pipeline_layout,
        &.{glyph_layout},
        format,
        true,
    ) orelse return error.NoPipeline;
    return .{
        .rect = rect_pipeline,
        .glyph = glyph_pipeline,
        .atlas_layout = atlas_layout,
        .sampler = sampler,
    };
}

fn createShader(
    device: *wgpu.Device,
    source: []const u8,
    label: []const u8,
) ?*wgpu.ShaderModule {
    const shader_source = wgpu.ShaderSourceWGSL{ .code = wgpu.StringView.fromSlice(source) };
    return device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(&shader_source, label));
}

fn createPipeline(
    device: *wgpu.Device,
    shader: *wgpu.ShaderModule,
    layout: *wgpu.PipelineLayout,
    buffers: []const wgpu.VertexBufferLayout,
    format: wgpu.TextureFormat,
    blending: bool,
) ?*wgpu.RenderPipeline {
    var vertex = wgpu.VertexState{
        .module = shader,
        .entry_point = wgpu.StringView.fromSlice("vs_main"),
    };
    vertex = vertex.withBuffers(buffers);
    const blend = wgpu.BlendState{
        .color = .{
            .operation = .add,
            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
        },
        .alpha = .{
            .operation = .add,
            .src_factor = .one,
            .dst_factor = .one_minus_src_alpha,
        },
    };
    const targets = [_]wgpu.ColorTargetState{.{
        .format = format,
        .blend = if (blending) &blend else null,
    }};
    var fragment = wgpu.FragmentState.init(shader, &targets);
    fragment.entry_point = wgpu.StringView.fromSlice("fs_main");
    return device.createRenderPipeline(&.{
        .label = wgpu.StringView.fromSlice("terminal instanced pipeline"),
        .layout = layout,
        .vertex = vertex,
        .primitive = .{},
        .fragment = &fragment,
        .multisample = .{},
    });
}

fn requestAdapter(instance: *wgpu.Instance, surface: *wgpu.Surface) RendererError!*wgpu.Adapter {
    if (waitForAdapter(instance, .{
        .feature_level = .core,
        .power_preference = .high_performance,
        .backend_type = .vulkan,
        .compatible_surface = surface,
    })) |adapter| return adapter;
    return waitForAdapter(instance, .{
        .feature_level = .compatibility,
        .power_preference = .high_performance,
        .backend_type = .opengl_es,
        .compatible_surface = surface,
    }) orelse error.NoAdapter;
}

fn logAdapter(adapter: *wgpu.Adapter) void {
    var info: wgpu.AdapterInfo = .{};
    if (adapter.getInfo(&info) != .success) return;
    defer info.deinit();
    hilog.infof(
        "terminal GPU adapter backend={s} type={s} device={s} description={s}",
        .{
            backendName(info.backend_type),
            adapterTypeName(info.adapter_type),
            info.device.toSlice() orelse "unknown",
            info.description.toSlice() orelse "unknown",
        },
    );
}

fn backendName(value: wgpu.BackendType) []const u8 {
    return switch (value) {
        .vulkan => "Vulkan",
        .opengl_es => "OpenGL ES",
        .opengl => "OpenGL",
        else => "unknown",
    };
}

fn adapterTypeName(value: wgpu.AdapterType) []const u8 {
    return switch (value) {
        .discrete_gpu => "discrete GPU",
        .integrated_gpu => "integrated GPU",
        .cpu => "CPU",
        else => "unknown",
    };
}

fn requestDevice(instance: *wgpu.Instance, adapter: *wgpu.Adapter) RendererError!*wgpu.Device {
    const Wait = struct { completed: bool = false, device: ?*wgpu.Device = null };
    var state = Wait{};
    var limits: wgpu.Limits = .{};
    if (adapter.getLimits(&limits) != .success) return error.NoDevice;
    _ = adapter.requestDevice(&.{
        .label = wgpu.StringView.fromSlice("terminal GPU device"),
        .required_limits = &limits,
        .uncaptured_error_callback_info = .{ .callback = uncapturedError },
    }, .{
        .mode = .allow_process_events,
        .callback = struct {
            fn call(
                status: wgpu.Adapter.RequestDeviceStatus,
                device: ?*wgpu.Device,
                _: wgpu.StringView,
                userdata: ?*anyopaque,
                _: ?*anyopaque,
            ) callconv(.c) void {
                const wait: *Wait = @ptrCast(@alignCast(userdata));
                wait.device = if (status == .success) device else null;
                wait.completed = true;
            }
        }.call,
        .userdata1 = &state,
    });
    var spins: usize = 0;
    while (!state.completed and spins < 2000) : (spins += 1) instance.processEvents();
    return state.device orelse error.NoDevice;
}

fn waitForAdapter(
    instance: *wgpu.Instance,
    options: wgpu.RequestAdapterOptions,
) ?*wgpu.Adapter {
    const Wait = struct { completed: bool = false, adapter: ?*wgpu.Adapter = null };
    var state = Wait{};
    _ = instance.requestAdapter(&options, .{
        .mode = .allow_process_events,
        .callback = struct {
            fn call(
                status: wgpu.Instance.RequestAdapterStatus,
                adapter: ?*wgpu.Adapter,
                _: wgpu.StringView,
                userdata: ?*anyopaque,
                _: ?*anyopaque,
            ) callconv(.c) void {
                const wait: *Wait = @ptrCast(@alignCast(userdata));
                wait.adapter = if (status == .success) adapter else null;
                wait.completed = true;
            }
        }.call,
        .userdata1 = &state,
    });
    var spins: usize = 0;
    while (!state.completed and spins < 2000) : (spins += 1) instance.processEvents();
    return state.adapter;
}

fn uncapturedError(
    _: ?*wgpu.Device,
    error_type: wgpu.Device.ErrorType,
    message: wgpu.StringView,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    hilog.errorf(
        "wgpu uncaptured {s}: {s}",
        .{ @tagName(error_type), message.toSlice() orelse "unknown error" },
    );
}

fn pixelRect(x: u32, y: u32, width: u32, height: u32, viewport_width: u32, viewport_height: u32) [4]f32 {
    const left = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(viewport_width)) * 2 - 1;
    const right_px = @min(viewport_width, x +| width);
    const right = @as(f32, @floatFromInt(right_px)) / @as(f32, @floatFromInt(viewport_width)) * 2 - 1;
    const top = 1 - @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(viewport_height)) * 2;
    const bottom_px = @min(viewport_height, y +| height);
    const bottom = 1 - @as(f32, @floatFromInt(bottom_px)) / @as(f32, @floatFromInt(viewport_height)) * 2;
    return .{ left, top, right, bottom };
}

/// Convert a glyph rectangle without clamping it to its logical cell. Signed
/// bearings are intentional; the GPU viewport clips actual screen edges.
fn glyphPixelRect(
    cell_x: u32,
    cell_y: u32,
    bearing_x: i32,
    bearing_y: i32,
    width: u32,
    height: u32,
    viewport_width: u32,
    viewport_height: u32,
) [4]f32 {
    const viewport_w: f32 = @floatFromInt(viewport_width);
    const viewport_h: f32 = @floatFromInt(viewport_height);
    const x = @as(f32, @floatFromInt(cell_x)) + @as(f32, @floatFromInt(bearing_x));
    const y = @as(f32, @floatFromInt(cell_y)) + @as(f32, @floatFromInt(bearing_y));
    const right_px = x + @as(f32, @floatFromInt(width));
    const bottom_px = y + @as(f32, @floatFromInt(height));
    return .{
        x / viewport_w * 2 - 1,
        1 - y / viewport_h * 2,
        right_px / viewport_w * 2 - 1,
        1 - bottom_px / viewport_h * 2,
    };
}

fn atlasUv(entry: GlyphEntry, atlas_size: u32) [4]f32 {
    const size: f32 = @floatFromInt(atlas_size);
    return .{
        @as(f32, @floatFromInt(entry.atlas_x)) / size,
        @as(f32, @floatFromInt(entry.atlas_y)) / size,
        @as(f32, @floatFromInt(entry.atlas_x +| entry.width)) / size,
        @as(f32, @floatFromInt(entry.atlas_y +| entry.height)) / size,
    };
}

fn colorVector(color: config.Rgb, srgb_target: bool) [4]f32 {
    return .{
        colorChannel(color.r, srgb_target),
        colorChannel(color.g, srgb_target),
        colorChannel(color.b, srgb_target),
        1,
    };
}

fn wgpuColor(color: config.Rgb, srgb_target: bool) wgpu.Color {
    const value = colorVector(color, srgb_target);
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = 1 };
}

fn colorChannel(value: u8, srgb_target: bool) f32 {
    const encoded = @as(f32, @floatFromInt(value)) / 255;
    if (!srgb_target) return encoded;
    return if (encoded <= 0.04045)
        encoded / 12.92
    else
        std.math.pow(f32, (encoded + 0.055) / 1.055, 2.4);
}

fn isSrgb(format: wgpu.TextureFormat) bool {
    return format == .rgba8_unorm_srgb or format == .bgra8_unorm_srgb;
}

fn encodeCodepoint(codepoint: u32, output: *[4]u8) []const u8 {
    const value = std.math.cast(u21, codepoint) orelse return &.{};
    const count = std.unicode.utf8CodepointSequenceLength(value) catch return &.{};
    _ = std.unicode.utf8Encode(value, output[0..count]) catch return &.{};
    return output[0..count];
}
