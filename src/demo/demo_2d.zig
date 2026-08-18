const std = @import("std");

const vklib = @import("vulkan");
const sdl3 = @import("sdl3");

const vkzig = @import("../vulkan.zig");
const sdl_vk_mod = @import("../sdl_vk.zig");
const sdlzig = @import("../sdl.zig");
const widgets = @import("widgets.zig");
const fontmod = @import("font.zig");

const shader_module_src align(@alignOf(u32)) = @embedFile("shader_2d_module").*;
const text_shader_module_src align(@alignOf(u32)) = @embedFile("shader_2d_text_module").*;

// Each beveled widget draws two 4-strip edge rings plus a face fill (9
// flat rects = 54 vertices); 5 beveled elements (panel, button, checkbox,
// slider groove, slider handle) comfortably fit with headroom to spare.
const max_vertices: u32 = 512;
const max_text_vertices: u32 = 512;
const font_pixel_size: u32 = 18;
const atlas_size: u32 = 256;

const Vertex = widgets.Vertex;
const TextVertex = widgets.TextVertex;

const PushConstants = struct {
    screen_size: [2]f32,
};

/// Stable per-widget ids for this frame's UI - see widgets.zig's WidgetId
/// doc comment for why an immediate-mode widget needs one at all.
const Ids = enum(widgets.WidgetId) {
    reset_button,
    checkbox,
    slider,
};

// Layout - screen-space rects, computed once at comptime. Real widgets
// would come from a layout pass instead of literals.
const panel_rect: widgets.Rect = .{ .x = 40, .y = 40, .w = 320, .h = 200 };
const button_rect: widgets.Rect = .{ .x = panel_rect.x + 24, .y = panel_rect.y + 24, .w = 272, .h = 44 };
const checkbox_rect: widgets.Rect = .{ .x = panel_rect.x + 24, .y = panel_rect.y + 92, .w = 22, .h = 22 };
const slider_track_rect: widgets.Rect = .{ .x = panel_rect.x + 24, .y = panel_rect.y + 150, .w = 272, .h = 8 };
const slider_handle_w: f32 = 18;

pub fn demo2d(alloc: std.mem.Allocator, io: std.Io, window: *sdl_vk_mod.VkWindow) !void {
    const vk = &window.sdlvk.vk;
    const dev = vk.dev;

    // Font + glyph atlas - loaded once at startup. `font` stays alive for
    // the whole render loop since widget captions are (re-)shaped every
    // frame, immediate-mode style, same as the box widgets are re-drawn
    // every frame instead of cached.
    const font_data = try fontmod.loadFontFile(alloc, io, fontmod.default_font_path);
    defer alloc.free(font_data);
    var font = try fontmod.Font.init(font_data, font_pixel_size);
    defer font.deinit();
    var atlas = try fontmod.Atlas.build(alloc, &font, &fontmod.ascii_char_range, atlas_size, atlas_size);
    defer atlas.deinit(alloc);

    var vertex_buffer_data: VertexBufferData = .{ .vk = vk };
    try vertex_buffer_data.init(window.max_frames_in_flight);
    defer vertex_buffer_data.destroy();

    var text_vertex_buffer_data: TextVertexBufferData = .{ .vk = vk };
    try text_vertex_buffer_data.init(window.max_frames_in_flight);
    defer text_vertex_buffer_data.destroy();

    // Load shaders
    const shader_module = try dev.createShaderModule(&.{
        .code_size = shader_module_src.len,
        .p_code = @ptrCast(&shader_module_src),
    }, null);
    defer dev.destroyShaderModule(shader_module, null);

    const text_shader_module = try dev.createShaderModule(&.{
        .code_size = text_shader_module_src.len,
        .p_code = @ptrCast(&text_shader_module_src),
    }, null);
    defer dev.destroyShaderModule(text_shader_module, null);

    var pipeline_data: PipelineData = .{ .vk = vk };
    try pipeline_data.init(window.surface, shader_module);
    defer pipeline_data.destroy();

    var atlas_texture: AtlasTexture = .{ .vk = vk };
    try atlas_texture.init(&atlas, window.surface.cmd_pool);
    defer atlas_texture.destroy();

    var text_pipeline_data: TextPipelineData = .{ .vk = vk };
    try text_pipeline_data.init(window.surface, text_shader_module, atlas_texture.desc_set_layout);
    defer text_pipeline_data.destroy();

    var frame: Frame = .{
        .window = window,
        .vertex_buffers = vertex_buffer_data.buffers.ptr,
        .pipeline_data = pipeline_data,
        .text_vertex_buffers = text_vertex_buffer_data.buffers.ptr,
        .text_pipeline_data = text_pipeline_data,
        .atlas_desc_set = atlas_texture.desc_set,
        .font = &font,
        .atlas = &atlas,
    };
    try renderLoop(&frame);
}

/// All per-frame render state, plus the app's own persistent widget
/// *values* (checkbox_checked, slider_value) - owned here rather than by
/// any widget object, same as Dear ImGui's caller-owned `&value` pattern.
/// Transient interaction state (which widget is mid-press/mid-drag) lives
/// in `active_id`, threaded into and back out of a widgets.Ui each frame.
///
/// Bundled into a struct (rather than locals in renderLoop) so a full
/// frame can be rendered from `renderOneFrame` alone, callable both from
/// the normal poll-driven loop and re-entrant from the live-repaint
/// event watcher (see VkWindow.setLiveRepaint) while the window is being
/// moved or resized.
const Frame = struct {
    window: *sdl_vk_mod.VkWindow,
    vertex_buffers: [*]VertexGpuBuffer,
    pipeline_data: PipelineData,
    text_vertex_buffers: [*]TextGpuBuffer,
    text_pipeline_data: TextPipelineData,
    atlas_desc_set: vklib.DescriptorSet,
    font: *fontmod.Font,
    atlas: *const fontmod.Atlas,

    frame_index: u32 = 0,
    update_swapchain: bool = false,

    mouse_pos: [2]f32 = .{ -1, -1 },
    mouse_down: bool = false,
    mouse_pressed: bool = false,
    mouse_released: bool = false,
    active_id: ?widgets.WidgetId = null,

    checkbox_checked: bool = false,
    slider_value: f32 = 0.5,

    const BuildResult = struct { vertex_count: usize, text_vertex_count: usize };

    /// Describes the whole UI fresh each frame, immediate-mode style, into
    /// `vertices`/`text_vertices`.
    fn buildUi(self: *Frame, vertices: []Vertex, text_vertices: []TextVertex) BuildResult {
        // Widget captions are short-lived, shaped fresh every frame (same
        // as the rest of the UI) - a fixed-buffer allocator avoids heap
        // churn for that on every single frame.
        var caption_buf: [1024]u8 = undefined;
        var caption_fba = std.heap.FixedBufferAllocator.init(&caption_buf);
        const caption_alloc = caption_fba.allocator();

        var ui: widgets.Ui = .{
            .vertices = vertices,
            .text_vertices = text_vertices,
            .mouse_pos = self.mouse_pos,
            .mouse_down = self.mouse_down,
            .mouse_pressed = self.mouse_pressed,
            .mouse_released = self.mouse_released,
            .active_id = self.active_id,
        };

        widgets.panel(&ui, panel_rect, .{});

        if (widgets.button(&ui, @intFromEnum(Ids.reset_button), button_rect, .{})) {
            self.checkbox_checked = false;
            self.slider_value = 0.5;
        }
        self.labelCentered(&ui, caption_alloc, "Reset", button_rect, widgets.win95.text);

        widgets.checkbox(&ui, @intFromEnum(Ids.checkbox), checkbox_rect, &self.checkbox_checked, .{});
        if (self.checkbox_checked) {
            self.labelCentered(&ui, caption_alloc, "X", checkbox_rect, widgets.win95.text);
        }
        self.labelAfter(&ui, caption_alloc, "Enabled", checkbox_rect, widgets.win95.text);

        widgets.slider(&ui, @intFromEnum(Ids.slider), slider_track_rect, &self.slider_value, slider_handle_w, .{});

        // Interaction state persists across frames (active_id spans a
        // whole drag); the press/release edges only apply to this one
        // build, so they're consumed here rather than carried forward.
        self.active_id = ui.active_id;
        self.mouse_pressed = false;
        self.mouse_released = false;

        return .{ .vertex_count = ui.vertex_count, .text_vertex_count = ui.text_vertex_count };
    }

    /// Draws `text` horizontally and (approximately) vertically centered
    /// within `rect` - e.g. a button caption.
    fn labelCentered(self: *Frame, ui: *widgets.Ui, alloc: std.mem.Allocator, text: []const u8, rect: widgets.Rect, color: [4]f32) void {
        const glyphs = self.font.shape(alloc, text) catch return;
        var width: f32 = 0;
        for (glyphs) |g| width += g.x_advance;
        const x = rect.x + (rect.w - width) / 2;
        const y = rect.y + rect.h / 2 + @as(f32, @floatFromInt(self.font.pixel_size)) * 0.35;
        _ = ui.text(self.atlas, glyphs, .{ x, y }, color);
    }

    /// Draws `text` vertically centered against `rect`, starting just to
    /// its right - e.g. a checkbox's description.
    fn labelAfter(self: *Frame, ui: *widgets.Ui, alloc: std.mem.Allocator, text: []const u8, rect: widgets.Rect, color: [4]f32) void {
        const glyphs = self.font.shape(alloc, text) catch return;
        const y = rect.y + rect.h / 2 + @as(f32, @floatFromInt(self.font.pixel_size)) * 0.35;
        _ = ui.text(self.atlas, glyphs, .{ rect.x + rect.w + 10, y }, color);
    }

    fn renderOneFrame(self: *Frame) !void {
        const window = self.window;
        const vk = &window.sdlvk.vk;
        const dev = vk.dev;
        const surface = &window.surface;
        const queue_family = vk.graphics_queue_family;
        const pipeline = self.pipeline_data.pipeline;
        const pipeline_layout = self.pipeline_data.pipeline_layout;
        const text_pipeline = self.text_pipeline_data.pipeline;
        const text_pipeline_layout = self.text_pipeline_data.pipeline_layout;
        const queue = vk.queue;
        const frame_index = self.frame_index;

        // Sync
        if (try dev.waitForFences(@ptrCast(&surface.fences[frame_index]), .true, std.math.maxInt(u64)) != .success) {
            @panic("failed to wait for fence");
        }

        try dev.resetFences(@ptrCast(&surface.fences[frame_index]));

        const image_index = val: {
            const next_image = try dev.acquireNextImageKHR(
                surface.swapchain,
                std.math.maxInt(u64),
                surface.image_acquired_semaphores[frame_index],
                .null_handle,
            );
            switch (next_image.result) {
                .success => break :val next_image.image_index,
                .error_out_of_date_khr, .suboptimal_khr => {
                    self.update_swapchain = true;
                    break :val next_image.image_index;
                },
                else => |result| std.debug.panic("Failed to acquire next image: {t}", .{result}),
            }
        };

        const window_extent = surface.getExtent();
        const screen_size: [2]f32 = .{
            @floatFromInt(window_extent.width),
            @floatFromInt(window_extent.height),
        };

        var vertices: [max_vertices]Vertex = undefined;
        var text_vertices: [max_text_vertices]TextVertex = undefined;
        const built = self.buildUi(&vertices, &text_vertices);

        const frame_buffer = &self.vertex_buffers[frame_index];
        @memcpy(frame_buffer.mapped_memory[0..built.vertex_count], vertices[0..built.vertex_count]);

        const text_frame_buffer = &self.text_vertex_buffers[frame_index];
        @memcpy(text_frame_buffer.mapped_memory[0..built.text_vertex_count], text_vertices[0..built.text_vertex_count]);

        // Build command buffer
        const cmd_buf = surface.cmd_buf[frame_index];
        try dev.resetCommandBuffer(cmd_buf, .{});
        try dev.beginCommandBuffer(cmd_buf, &.{ .flags = .{ .one_time_submit_bit = true } });
        dev.cmdPipelineBarrier2(cmd_buf, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = &.{
                .{
                    .src_stage_mask = .{ .color_attachment_output_bit = true },
                    .src_access_mask = .{},
                    .dst_stage_mask = .{ .color_attachment_output_bit = true },
                    .dst_access_mask = .{
                        .color_attachment_read_bit = true,
                        .color_attachment_write_bit = true,
                    },
                    .old_layout = .undefined,
                    .new_layout = .attachment_optimal,
                    .image = surface.swap_img[image_index],
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .level_count = 1,
                        .layer_count = 1,
                        .base_array_layer = 0,
                        .base_mip_level = 0,
                    },
                    .src_queue_family_index = queue_family,
                    .dst_queue_family_index = queue_family,
                },
            },
        });
        dev.cmdBeginRendering(cmd_buf, &.{
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{
                    .width = window_extent.width,
                    .height = window_extent.height,
                },
            },
            .layer_count = 1,
            .color_attachment_count = 1,
            .p_color_attachments = &.{
                .{
                    .image_view = surface.swap_view[image_index],
                    .image_layout = .attachment_optimal,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_value = .{ .color = .{ .float_32 = widgets.win95.desktop } },
                    .resolve_mode = .{},
                    .resolve_image_layout = .undefined,
                },
            },
            .view_mask = 0,
        });
        dev.cmdSetViewport(cmd_buf, 0, &.{
            .{
                .width = @floatFromInt(window_extent.width),
                .height = @floatFromInt(window_extent.height),
                .x = 0,
                .y = 0,
                .min_depth = 0,
                .max_depth = 1,
            },
        });
        dev.cmdSetScissor(cmd_buf, 0, &.{vklib.Rect2D{ .extent = window_extent, .offset = .{ .x = 0, .y = 0 } }});

        // Box widgets (panel/button/checkbox/slider), via the SDF shader.
        dev.cmdBindPipeline(cmd_buf, .graphics, pipeline);
        dev.cmdBindVertexBuffers(cmd_buf, 0, @ptrCast(&frame_buffer.buffer), &.{0});
        dev.cmdPushConstants(
            cmd_buf,
            pipeline_layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(PushConstants),
            &PushConstants{ .screen_size = screen_size },
        );
        dev.cmdDraw(cmd_buf, @intCast(built.vertex_count), 1, 0, 0);

        // Text, on top - own pipeline since it samples the glyph atlas
        // instead of doing SDF math.
        if (built.text_vertex_count > 0) {
            dev.cmdBindPipeline(cmd_buf, .graphics, text_pipeline);
            dev.cmdBindDescriptorSets(cmd_buf, .graphics, text_pipeline_layout, 0, &.{self.atlas_desc_set}, null);
            dev.cmdBindVertexBuffers(cmd_buf, 0, @ptrCast(&text_frame_buffer.buffer), &.{0});
            dev.cmdPushConstants(
                cmd_buf,
                text_pipeline_layout,
                .{ .vertex_bit = true },
                0,
                @sizeOf(PushConstants),
                &PushConstants{ .screen_size = screen_size },
            );
            dev.cmdDraw(cmd_buf, @intCast(built.text_vertex_count), 1, 0, 0);
        }

        dev.cmdEndRendering(cmd_buf);
        dev.cmdPipelineBarrier2(cmd_buf, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = &.{
                .{
                    .src_stage_mask = .{ .color_attachment_output_bit = true },
                    .src_access_mask = .{ .color_attachment_write_bit = true },
                    .dst_stage_mask = .{ .color_attachment_output_bit = true },
                    .dst_access_mask = .{},
                    .old_layout = .attachment_optimal,
                    .new_layout = .present_src_khr,
                    .image = surface.swap_img[image_index],
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .level_count = 1,
                        .layer_count = 1,
                        .base_array_layer = 0,
                        .base_mip_level = 0,
                    },
                    .dst_queue_family_index = queue_family,
                    .src_queue_family_index = queue_family,
                },
            },
        });
        try dev.endCommandBuffer(cmd_buf);

        // Submit to graphics queue
        try dev.queueSubmit(
            queue,
            &.{
                vklib.SubmitInfo{
                    .wait_semaphore_count = 1,
                    .p_wait_semaphores = @ptrCast(&surface.image_acquired_semaphores[frame_index]),
                    .p_wait_dst_stage_mask = &.{
                        .{ .color_attachment_output_bit = true },
                    },
                    .command_buffer_count = 1,
                    .p_command_buffers = &.{cmd_buf},
                    .signal_semaphore_count = 1,
                    .p_signal_semaphores = @ptrCast(&surface.render_complete_semaphores[image_index]),
                },
            },
            surface.fences[frame_index],
        );
        const present_result = dev.queuePresentKHR(
            queue,
            &.{
                .wait_semaphore_count = 1,
                .p_wait_semaphores = &.{surface.render_complete_semaphores[image_index]},
                .swapchain_count = 1,
                .p_swapchains = &.{surface.swapchain},
                .p_image_indices = @ptrCast(&image_index),
            },
        ) catch |err| switch (err) {
            error.OutOfDateKHR => .suboptimal_khr,
            else => return err,
        };

        switch (present_result) {
            .success => {},
            .suboptimal_khr => {
                self.update_swapchain = true;
            },
            else => std.debug.panic("Queue present not successful: {t}", .{present_result}),
        }

        self.frame_index = (self.frame_index + 1) % window.max_frames_in_flight;

        if (self.update_swapchain) {
            self.update_swapchain = false;
            try surface.updateSwapchain(window.getWindowSize());
        }
    }
};

fn liveRepaint(ctx: *anyopaque) void {
    const frame: *Frame = @ptrCast(@alignCast(ctx));
    frame.renderOneFrame() catch |err| {
        std.debug.print("live-resize repaint failed: {t}\n", .{err});
    };
}

fn renderLoop(frame: *Frame) !void {
    const window = frame.window;

    // Keeps the window repainting (instead of showing a stale/torn frame)
    // while it's being dragged/resized, since Win32's modal move/resize
    // loop otherwise blocks SDL_PollEvent below for the whole drag.
    window.setLiveRepaint(frame, &liveRepaint);
    defer window.clearLiveRepaint();

    var event: sdl3.SDL_Event = undefined;
    while (event.type != sdl3.SDL_EVENT_QUIT) {
        try frame.renderOneFrame();

        if (!sdl3.SDL_PollEvent(&event) or event.type == sdl3.SDL_EVENT_QUIT) continue;
        switch (event.type) {
            sdl3.SDL_EVENT_WINDOW_RESIZED => {
                frame.update_swapchain = true;
            },
            sdl3.SDL_EVENT_MOUSE_MOTION => {
                frame.mouse_pos = .{ event.motion.x, event.motion.y };
            },
            sdl3.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button == sdl3.SDL_BUTTON_LEFT) {
                    frame.mouse_pos = .{ event.button.x, event.button.y };
                    frame.mouse_down = true;
                    frame.mouse_pressed = true;
                }
            },
            sdl3.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == sdl3.SDL_BUTTON_LEFT) {
                    frame.mouse_pos = .{ event.button.x, event.button.y };
                    frame.mouse_down = false;
                    frame.mouse_released = true;
                }
            },
            else => {},
        }
    }

    // wait for the GPU to finish the last submitted frame before the
    // caller's deferred cleanup starts destroying in-use resources
    try frame.window.sdlvk.vk.dev.deviceWaitIdle();
}

const PipelineData = struct {
    vk: *vkzig.Vulkan,
    pipeline: vklib.Pipeline = .null_handle,
    pipeline_layout: vklib.PipelineLayout = .null_handle,

    pub fn init(self: *PipelineData, surface: vkzig.VkSurface, shader_module: vklib.ShaderModule) !void {
        const dev = self.vk.dev;

        self.pipeline_layout = try dev.createPipelineLayout(&.{
            .set_layout_count = 0,
            .p_set_layouts = &.{},
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &.{.{
                .stage_flags = .{ .vertex_bit = true },
                .size = @sizeOf(PushConstants),
                .offset = 0,
            }},
        }, null);

        const pipeline_result = try dev.createGraphicsPipelines(.null_handle, &.{
            .{
                .p_next = &vklib.PipelineRenderingCreateInfo{
                    .color_attachment_count = 1,
                    .p_color_attachment_formats = @ptrCast(&surface.image_format),
                    .depth_attachment_format = .undefined,
                    .stencil_attachment_format = .undefined,
                    .view_mask = 0,
                },
                .stage_count = 2,
                .p_stages = &.{
                    .{ .stage = .{ .vertex_bit = true }, .module = shader_module, .p_name = "main" },
                    .{ .stage = .{ .fragment_bit = true }, .module = shader_module, .p_name = "main" },
                },
                .p_vertex_input_state = &.{
                    .vertex_binding_description_count = 1,
                    .p_vertex_binding_descriptions = &.{
                        .{ .binding = 0, .stride = @sizeOf(Vertex), .input_rate = .vertex },
                    },
                    .vertex_attribute_description_count = 8,
                    .p_vertex_attribute_descriptions = &.{
                        .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "pos") },
                        .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "local") },
                        .{ .location = 2, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "half_size") },
                        .{ .location = 3, .binding = 0, .format = .r32_sfloat, .offset = @offsetOf(Vertex, "radius") },
                        .{ .location = 4, .binding = 0, .format = .r32_sfloat, .offset = @offsetOf(Vertex, "border_width") },
                        .{ .location = 5, .binding = 0, .format = .r32_sfloat, .offset = @offsetOf(Vertex, "blur") },
                        .{ .location = 6, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "fill_color") },
                        .{ .location = 7, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "border_color") },
                    },
                },
                .p_input_assembly_state = &.{
                    .primitive_restart_enable = .false,
                    .topology = .triangle_list,
                },
                .p_viewport_state = &.{ .viewport_count = 1, .scissor_count = 1 },
                .p_rasterization_state = &.{
                    .line_width = 1.0,
                    .depth_bias_clamp = 0,
                    .depth_bias_constant_factor = 0,
                    .depth_bias_enable = .false,
                    .depth_bias_slope_factor = 0,
                    .front_face = .counter_clockwise,
                    .polygon_mode = .fill,
                    .rasterizer_discard_enable = .false,
                    .depth_clamp_enable = .false,
                    .cull_mode = .{},
                },
                .p_multisample_state = &.{
                    .rasterization_samples = .{ .@"1_bit" = true },
                    .min_sample_shading = 0,
                    .alpha_to_coverage_enable = .false,
                    .alpha_to_one_enable = .false,
                    .sample_shading_enable = .false,
                },
                .p_depth_stencil_state = &.{
                    .depth_test_enable = .false,
                    .depth_write_enable = .false,
                    .depth_compare_op = .always,
                    .depth_bounds_test_enable = .false,
                    .stencil_test_enable = .false,
                    .front = .{
                        .fail_op = .keep,
                        .pass_op = .keep,
                        .compare_op = .never,
                        .compare_mask = 0,
                        .depth_fail_op = .keep,
                        .reference = 0,
                        .write_mask = 0,
                    },
                    .back = .{
                        .write_mask = 0,
                        .compare_mask = 0,
                        .compare_op = .never,
                        .depth_fail_op = .keep,
                        .fail_op = .keep,
                        .pass_op = .keep,
                        .reference = 0,
                    },
                    .max_depth_bounds = 0,
                    .min_depth_bounds = 0,
                },
                .p_color_blend_state = &.{
                    .attachment_count = 1,
                    .p_attachments = &.{
                        .{
                            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
                            .alpha_blend_op = .add,
                            .blend_enable = .true,
                            .color_blend_op = .add,
                            .dst_alpha_blend_factor = .zero,
                            .dst_color_blend_factor = .one_minus_src_alpha,
                            .src_alpha_blend_factor = .one,
                            .src_color_blend_factor = .src_alpha,
                        },
                    },
                    .logic_op = .clear,
                    .blend_constants = @splat(0),
                    .logic_op_enable = .false,
                },
                .p_dynamic_state = &.{
                    .dynamic_state_count = 2,
                    .p_dynamic_states = &.{ .viewport, .scissor },
                },
                .layout = self.pipeline_layout,
                .base_pipeline_index = 0,
                .subpass = 0,
            },
        }, null, @ptrCast(&self.pipeline));
        std.debug.print("2d graphics pipeline: {t}\n", .{pipeline_result});
    }

    pub fn destroy(self: *PipelineData) void {
        const vk = self.vk;
        const dev = vk.dev;
        dev.destroyPipelineLayout(self.pipeline_layout, null);
        dev.destroyPipeline(self.pipeline, null);
    }
};

const VertexGpuBuffer = struct {
    buffer: vklib.Buffer,
    device_memory: vklib.DeviceMemory,
    mapped_memory: [*]Vertex,
};

const VertexBufferData = struct {
    vk: *vkzig.Vulkan,
    buffers: []VertexGpuBuffer = undefined,

    pub fn init(self: *VertexBufferData, max_frames_in_flight: u32) !void {
        const vk = self.vk;
        const dev = vk.dev;
        self.buffers = try vk.alloc.alloc(VertexGpuBuffer, max_frames_in_flight);
        for (self.buffers) |*gpu_buffer| {
            const vertex_buffer = try dev.createBuffer(&.{
                .size = @sizeOf(Vertex) * max_vertices,
                .usage = .{ .vertex_buffer_bit = true },
                .sharing_mode = .exclusive,
            }, null);
            const mem_data = try vk.allocBufferMemory(vertex_buffer, .{
                .host_visible_bit = true,
                .host_coherent_bit = true,
            }, null);

            gpu_buffer.mapped_memory = @ptrCast(@alignCast(try dev.mapMemory(mem_data.mem, 0, vklib.WHOLE_SIZE, .{})));
            gpu_buffer.device_memory = mem_data.mem;
            gpu_buffer.buffer = vertex_buffer;
        }
    }

    pub fn destroy(self: *VertexBufferData) void {
        const vk = self.vk;
        const dev = vk.dev;
        for (self.buffers) |gpu_buffer| {
            dev.unmapMemory(gpu_buffer.device_memory);
            vk.freeDevMemory(gpu_buffer.device_memory);
            dev.destroyBuffer(gpu_buffer.buffer, null);
        }
        vk.alloc.free(self.buffers);
    }
};

const TextGpuBuffer = struct {
    buffer: vklib.Buffer,
    device_memory: vklib.DeviceMemory,
    mapped_memory: [*]TextVertex,
};

const TextVertexBufferData = struct {
    vk: *vkzig.Vulkan,
    buffers: []TextGpuBuffer = undefined,

    pub fn init(self: *TextVertexBufferData, max_frames_in_flight: u32) !void {
        const vk = self.vk;
        const dev = vk.dev;
        self.buffers = try vk.alloc.alloc(TextGpuBuffer, max_frames_in_flight);
        for (self.buffers) |*gpu_buffer| {
            const vertex_buffer = try dev.createBuffer(&.{
                .size = @sizeOf(TextVertex) * max_text_vertices,
                .usage = .{ .vertex_buffer_bit = true },
                .sharing_mode = .exclusive,
            }, null);
            const mem_data = try vk.allocBufferMemory(vertex_buffer, .{
                .host_visible_bit = true,
                .host_coherent_bit = true,
            }, null);

            gpu_buffer.mapped_memory = @ptrCast(@alignCast(try dev.mapMemory(mem_data.mem, 0, vklib.WHOLE_SIZE, .{})));
            gpu_buffer.device_memory = mem_data.mem;
            gpu_buffer.buffer = vertex_buffer;
        }
    }

    pub fn destroy(self: *TextVertexBufferData) void {
        const vk = self.vk;
        const dev = vk.dev;
        for (self.buffers) |gpu_buffer| {
            dev.unmapMemory(gpu_buffer.device_memory);
            vk.freeDevMemory(gpu_buffer.device_memory);
            dev.destroyBuffer(gpu_buffer.buffer, null);
        }
        vk.alloc.free(self.buffers);
    }
};

const TextPipelineData = struct {
    vk: *vkzig.Vulkan,
    pipeline: vklib.Pipeline = .null_handle,
    pipeline_layout: vklib.PipelineLayout = .null_handle,

    pub fn init(self: *TextPipelineData, surface: vkzig.VkSurface, shader_module: vklib.ShaderModule, desc_set_layout: vklib.DescriptorSetLayout) !void {
        const dev = self.vk.dev;

        self.pipeline_layout = try dev.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = &.{desc_set_layout},
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &.{.{
                .stage_flags = .{ .vertex_bit = true },
                .size = @sizeOf(PushConstants),
                .offset = 0,
            }},
        }, null);

        const pipeline_result = try dev.createGraphicsPipelines(.null_handle, &.{
            .{
                .p_next = &vklib.PipelineRenderingCreateInfo{
                    .color_attachment_count = 1,
                    .p_color_attachment_formats = @ptrCast(&surface.image_format),
                    .depth_attachment_format = .undefined,
                    .stencil_attachment_format = .undefined,
                    .view_mask = 0,
                },
                .stage_count = 2,
                .p_stages = &.{
                    .{ .stage = .{ .vertex_bit = true }, .module = shader_module, .p_name = "main" },
                    .{ .stage = .{ .fragment_bit = true }, .module = shader_module, .p_name = "main" },
                },
                .p_vertex_input_state = &.{
                    .vertex_binding_description_count = 1,
                    .p_vertex_binding_descriptions = &.{
                        .{ .binding = 0, .stride = @sizeOf(TextVertex), .input_rate = .vertex },
                    },
                    .vertex_attribute_description_count = 3,
                    .p_vertex_attribute_descriptions = &.{
                        .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(TextVertex, "pos") },
                        .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(TextVertex, "uv") },
                        .{ .location = 2, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(TextVertex, "color") },
                    },
                },
                .p_input_assembly_state = &.{
                    .primitive_restart_enable = .false,
                    .topology = .triangle_list,
                },
                .p_viewport_state = &.{ .viewport_count = 1, .scissor_count = 1 },
                .p_rasterization_state = &.{
                    .line_width = 1.0,
                    .depth_bias_clamp = 0,
                    .depth_bias_constant_factor = 0,
                    .depth_bias_enable = .false,
                    .depth_bias_slope_factor = 0,
                    .front_face = .counter_clockwise,
                    .polygon_mode = .fill,
                    .rasterizer_discard_enable = .false,
                    .depth_clamp_enable = .false,
                    .cull_mode = .{},
                },
                .p_multisample_state = &.{
                    .rasterization_samples = .{ .@"1_bit" = true },
                    .min_sample_shading = 0,
                    .alpha_to_coverage_enable = .false,
                    .alpha_to_one_enable = .false,
                    .sample_shading_enable = .false,
                },
                .p_depth_stencil_state = &.{
                    .depth_test_enable = .false,
                    .depth_write_enable = .false,
                    .depth_compare_op = .always,
                    .depth_bounds_test_enable = .false,
                    .stencil_test_enable = .false,
                    .front = .{
                        .fail_op = .keep,
                        .pass_op = .keep,
                        .compare_op = .never,
                        .compare_mask = 0,
                        .depth_fail_op = .keep,
                        .reference = 0,
                        .write_mask = 0,
                    },
                    .back = .{
                        .write_mask = 0,
                        .compare_mask = 0,
                        .compare_op = .never,
                        .depth_fail_op = .keep,
                        .fail_op = .keep,
                        .pass_op = .keep,
                        .reference = 0,
                    },
                    .max_depth_bounds = 0,
                    .min_depth_bounds = 0,
                },
                .p_color_blend_state = &.{
                    .attachment_count = 1,
                    .p_attachments = &.{
                        .{
                            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
                            .alpha_blend_op = .add,
                            .blend_enable = .true,
                            .color_blend_op = .add,
                            .dst_alpha_blend_factor = .zero,
                            .dst_color_blend_factor = .one_minus_src_alpha,
                            .src_alpha_blend_factor = .one,
                            .src_color_blend_factor = .src_alpha,
                        },
                    },
                    .logic_op = .clear,
                    .blend_constants = @splat(0),
                    .logic_op_enable = .false,
                },
                .p_dynamic_state = &.{
                    .dynamic_state_count = 2,
                    .p_dynamic_states = &.{ .viewport, .scissor },
                },
                .layout = self.pipeline_layout,
                .base_pipeline_index = 0,
                .subpass = 0,
            },
        }, null, @ptrCast(&self.pipeline));
        std.debug.print("2d text graphics pipeline: {t}\n", .{pipeline_result});
    }

    pub fn destroy(self: *TextPipelineData) void {
        const vk = self.vk;
        const dev = vk.dev;
        dev.destroyPipelineLayout(self.pipeline_layout, null);
        dev.destroyPipeline(self.pipeline, null);
    }
};

/// The glyph atlas as a sampled GPU texture (single-channel coverage,
/// uploaded once at startup) plus the descriptor set the text pipeline
/// binds it through.
const AtlasTexture = struct {
    vk: *vkzig.Vulkan,
    image: vklib.Image = undefined,
    view: vklib.ImageView = undefined,
    sampler: vklib.Sampler = undefined,
    memory: vklib.DeviceMemory = undefined,
    desc_set_layout: vklib.DescriptorSetLayout = undefined,
    desc_pool: vklib.DescriptorPool = undefined,
    desc_set: vklib.DescriptorSet = .null_handle,

    pub fn init(self: *AtlasTexture, atlas: *const fontmod.Atlas, cmd_pool: vklib.CommandPool) !void {
        const vk = self.vk;
        const dev = vk.dev;

        self.image = try dev.createImage(&.{
            .image_type = .@"2d",
            .format = .r8_unorm,
            .extent = .{ .width = atlas.width, .height = atlas.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
            .initial_layout = .undefined,
            .sharing_mode = .exclusive,
        }, null);

        const mem_data = try vk.allocImageMemory(self.image, .{ .device_local_bit = true });
        self.memory = mem_data.mem;

        self.view = try dev.createImageView(&.{
            .image = self.image,
            .format = .r8_unorm,
            .view_type = .@"2d",
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .level_count = 1,
                .layer_count = 1,
                .base_array_layer = 0,
                .base_mip_level = 0,
            },
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        }, null);

        self.sampler = try dev.createSampler(&.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .nearest,
            .anisotropy_enable = .false,
            .max_anisotropy = 1,
            .max_lod = 0,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .border_color = .float_transparent_black,
            .compare_enable = .false,
            .compare_op = .never,
            .mip_lod_bias = 0,
            .min_lod = 0,
            .unnormalized_coordinates = .false,
        }, null);

        try self.upload(atlas, cmd_pool);
        try self.createDescriptor();
    }

    fn upload(self: *AtlasTexture, atlas: *const fontmod.Atlas, cmd_pool: vklib.CommandPool) !void {
        const vk = self.vk;
        const dev = vk.dev;
        const size: u64 = @as(u64, atlas.width) * atlas.height;

        const staging_buf = try dev.createBuffer(&.{
            .size = size,
            .usage = .{ .transfer_src_bit = true },
            .sharing_mode = .exclusive,
        }, null);
        defer dev.destroyBuffer(staging_buf, null);

        const staging_mem = try vk.allocBufferMemory(staging_buf, .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        }, null);
        defer vk.freeDevMemory(staging_mem.mem);

        const mapped = try dev.mapMemory(staging_mem.mem, 0, vklib.WHOLE_SIZE, .{});
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[0..size], atlas.pixels);
        dev.unmapMemory(staging_mem.mem);

        var cmd_buf: vklib.CommandBuffer = undefined;
        try dev.allocateCommandBuffers(&.{
            .command_pool = cmd_pool,
            .command_buffer_count = 1,
            .level = .primary,
        }, @ptrCast(&cmd_buf));

        try dev.beginCommandBuffer(cmd_buf, &.{ .flags = .{ .one_time_submit_bit = true } });
        dev.cmdPipelineBarrier2(cmd_buf, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = &.{.{
                .src_stage_mask = .{},
                .src_access_mask = .{},
                .dst_stage_mask = .{ .all_transfer_bit = true },
                .dst_access_mask = .{ .transfer_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .transfer_dst_optimal,
                .image = self.image,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .level_count = 1,
                    .layer_count = 1,
                    .base_array_layer = 0,
                    .base_mip_level = 0,
                },
                .src_queue_family_index = 0,
                .dst_queue_family_index = 0,
            }},
        });
        dev.cmdCopyBufferToImage(cmd_buf, staging_buf, self.image, .transfer_dst_optimal, &.{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = atlas.width, .height = atlas.height, .depth = 1 },
        }});
        dev.cmdPipelineBarrier2(cmd_buf, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = &.{.{
                .src_stage_mask = .{ .all_transfer_bit = true },
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_stage_mask = .{ .fragment_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .old_layout = .transfer_dst_optimal,
                .new_layout = .read_only_optimal,
                .image = self.image,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .level_count = 1,
                    .layer_count = 1,
                    .base_array_layer = 0,
                    .base_mip_level = 0,
                },
                .src_queue_family_index = 0,
                .dst_queue_family_index = 0,
            }},
        });
        try dev.endCommandBuffer(cmd_buf);

        const fence = try dev.createFence(&.{}, null);
        defer dev.destroyFence(fence, null);
        try dev.queueSubmit(vk.queue, &.{.{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmd_buf),
        }}, fence);
        if (try dev.waitForFences(&.{fence}, .true, std.math.maxInt(u64)) != .success) @panic("wait for fence failed");
    }

    fn createDescriptor(self: *AtlasTexture) !void {
        const dev = self.vk.dev;

        self.desc_set_layout = try dev.createDescriptorSetLayout(&.{
            .binding_count = 1,
            .p_bindings = &.{.{
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = 1,
                .stage_flags = .{ .fragment_bit = true },
                .binding = 0,
            }},
        }, null);
        self.desc_pool = try dev.createDescriptorPool(&.{
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = &.{.{ .type = .combined_image_sampler, .descriptor_count = 1 }},
        }, null);
        try dev.allocateDescriptorSets(&.{
            .descriptor_pool = self.desc_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &.{self.desc_set_layout},
        }, @ptrCast(&self.desc_set));
        dev.updateDescriptorSets(&.{.{
            .dst_set = self.desc_set,
            .dst_binding = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = &.{.{
                .sampler = self.sampler,
                .image_view = self.view,
                .image_layout = .read_only_optimal,
            }},
            .dst_array_element = 0,
            .p_buffer_info = &.{},
            .p_texel_buffer_view = &.{},
        }}, null);
    }

    pub fn destroy(self: *AtlasTexture) void {
        const vk = self.vk;
        const dev = vk.dev;
        dev.destroyDescriptorPool(self.desc_pool, null);
        dev.destroyDescriptorSetLayout(self.desc_set_layout, null);
        dev.destroySampler(self.sampler, null);
        dev.destroyImageView(self.view, null);
        vk.freeDevMemory(self.memory);
        dev.destroyImage(self.image, null);
    }
};
