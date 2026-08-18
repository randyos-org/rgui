const std = @import("std");

const vklib = @import("vulkan");
const sdl3 = @import("sdl3");

const vkzig = @import("../vulkan.zig");
const sdl_vk_mod = @import("../sdl_vk.zig");
const fontmod = @import("font.zig");
const canvasmod = @import("canvas.zig");

const shader_module_src align(@alignOf(u32)) = @embedFile("shader_raster_module").*;

const font_pixel_size: u32 = 20;

const Canvas = canvasmod.Canvas;
const Color = canvasmod.Color;

const PushConstants = struct {
    canvas_size: [2]f32,
    window_offset: [2]f32,
};

const white: Color = .{ 255, 255, 255, 255 };
const black: Color = .{ 0, 0, 0, 255 };
const demo_rect_color: Color = .{ 200, 60, 60, 255 };
const demo_circle_color: Color = .{ 60, 120, 200, 255 };
const default_brush_color: Color = black;
const default_brush_radius: f32 = 4.0;
const min_brush_radius: f32 = 1.0;
const max_brush_radius: f32 = 40.0;

pub fn demoRaster(alloc: std.mem.Allocator, io: std.Io, window: *sdl_vk_mod.VkWindow) !void {
    const vk = &window.sdlvk.vk;
    const dev = vk.dev;

    // The canvas is allocated once at the physical display's resolution
    // and never resized - the window is just a moving/resizing viewport
    // onto this one fixed, desktop-space surface (see RasterGpu below).
    const display_bounds = try getPrimaryDisplayBounds();
    var canvas = try Canvas.init(alloc, @intCast(display_bounds.w), @intCast(display_bounds.h));
    defer canvas.deinit(alloc);

    const font_data = try fontmod.loadFontFile(alloc, io, fontmod.default_font_path);
    defer alloc.free(font_data);
    var font = try fontmod.Font.init(font_data, font_pixel_size);
    defer font.deinit();

    var window_x: c_int = 0;
    var window_y: c_int = 0;
    _ = sdl3.SDL_GetWindowPosition(window.window, &window_x, &window_y);
    try seedDemoContent(&canvas, &font, alloc, @floatFromInt(window_x), @floatFromInt(window_y));

    var raster_gpu: RasterGpu = .{ .vk = vk };
    try raster_gpu.init(canvas.width, canvas.height, window.max_frames_in_flight);
    defer raster_gpu.destroy();

    const shader_module = try dev.createShaderModule(&.{
        .code_size = shader_module_src.len,
        .p_code = @ptrCast(&shader_module_src),
    }, null);
    defer dev.destroyShaderModule(shader_module, null);

    var pipeline_data: PipelineData = .{ .vk = vk };
    try pipeline_data.init(window.surface, shader_module, raster_gpu.desc_set_layout);
    defer pipeline_data.destroy();

    var frame: Frame = .{
        .window = window,
        .canvas = &canvas,
        .raster_gpu = &raster_gpu,
        .pipeline_data = pipeline_data,
        .window_pos = .{ @floatFromInt(window_x), @floatFromInt(window_y) },
    };
    try renderLoop(&frame);
}

fn getPrimaryDisplayBounds() !sdl3.SDL_Rect {
    const display_id = sdl3.SDL_GetPrimaryDisplay();
    var bounds: sdl3.SDL_Rect = undefined;
    if (!sdl3.SDL_GetDisplayBounds(display_id, &bounds)) return error.SdlGetDisplayBoundsFailed;
    return bounds;
}

/// Seeds the canvas with instructions plus a sample rect/circle, positioned
/// near the window's actual starting screen position so they're visible
/// immediately regardless of where the OS placed the window.
fn seedDemoContent(canvas: *Canvas, font: *fontmod.Font, alloc: std.mem.Allocator, origin_x: f32, origin_y: f32) !void {
    try canvas.drawText(font, alloc, "CPU raster demo - drag to paint, scroll to resize brush, 'C' to clear", origin_x + 20, origin_y + 40, black);
    canvas.fillRect(.{ .x = @intFromFloat(origin_x + 20), .y = @intFromFloat(origin_y + 70), .w = 120, .h = 80 }, demo_rect_color);
    canvas.fillCircle(origin_x + 220, origin_y + 110, 40, demo_circle_color);
}

/// The window's current sub-rectangle of the (much larger, fixed) canvas,
/// in both float (for the push constant) and int (for the copy region)
/// form.
const ViewRect = struct {
    offset: [2]f32,
    rect: canvasmod.Rect,
};

/// All per-frame render state, plus the app's own persistent input state
/// (mouse/paint tracking) - same ownership pattern as demo_2d.zig's Frame.
const Frame = struct {
    window: *sdl_vk_mod.VkWindow,
    canvas: *Canvas,
    raster_gpu: *RasterGpu,
    pipeline_data: PipelineData,

    frame_index: u32 = 0,
    update_swapchain: bool = false,

    /// Window's top-left corner in absolute desktop pixels, polled once per
    /// frame in renderOneFrame (SDL_EVENT_WINDOW_MOVED turned out to be
    /// unreliable, so this is the source of truth rather than an event
    /// handler).
    window_pos: [2]f32 = .{ 0, 0 },
    /// Forces the next frame's currently-visible region to be (re-)
    /// uploaded even if nothing was painted - set on window move/resize,
    /// since a newly-revealed region of the canvas may never have been
    /// copied to the GPU image at this window position before.
    window_moved_or_resized: bool = true,

    mouse_down: bool = false,
    last_paint_pos: [2]f32 = .{ 0, 0 },

    brush_radius: f32 = default_brush_radius,
    brush_color: Color = default_brush_color,

    fn viewForExtent(self: *Frame, window_extent: vklib.Extent2D) ViewRect {
        const canvas = self.canvas;
        const max_x = @as(f32, @floatFromInt(canvas.width)) - @as(f32, @floatFromInt(window_extent.width));
        const max_y = @as(f32, @floatFromInt(canvas.height)) - @as(f32, @floatFromInt(window_extent.height));
        const off_x = std.math.clamp(self.window_pos[0], 0, @max(max_x, 0));
        const off_y = std.math.clamp(self.window_pos[1], 0, @max(max_y, 0));
        return .{
            .offset = .{ off_x, off_y },
            .rect = .{
                .x = @intFromFloat(off_x),
                .y = @intFromFloat(off_y),
                .w = @intCast(@min(window_extent.width, canvas.width)),
                .h = @intCast(@min(window_extent.height, canvas.height)),
            },
        };
    }

    fn currentView(self: *Frame) ViewRect {
        const surface = &self.window.surface;
        return self.viewForExtent(surface.getExtent());
    }

    fn canvasPosFromLocal(self: *Frame, offset: [2]f32, local: [2]f32) [2]f32 {
        const canvas = self.canvas;
        return .{
            std.math.clamp(offset[0] + local[0], 0, @as(f32, @floatFromInt(canvas.width - 1))),
            std.math.clamp(offset[1] + local[1], 0, @as(f32, @floatFromInt(canvas.height - 1))),
        };
    }

    fn renderOneFrame(self: *Frame) !void {
        const window = self.window;
        const vk = &window.sdlvk.vk;
        const dev = vk.dev;
        const surface = &window.surface;
        const queue_family = vk.graphics_queue_family;
        const pipeline = self.pipeline_data.pipeline;
        const pipeline_layout = self.pipeline_data.pipeline_layout;
        const queue = vk.queue;
        const frame_index = self.frame_index;
        const canvas = self.canvas;
        const raster_gpu = self.raster_gpu;

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

        var poll_x: c_int = 0;
        var poll_y: c_int = 0;
        _ = sdl3.SDL_GetWindowPosition(window.window, &poll_x, &poll_y);
        const polled_pos: [2]f32 = .{ @floatFromInt(poll_x), @floatFromInt(poll_y) };
        if (polled_pos[0] != self.window_pos[0] or polled_pos[1] != self.window_pos[1]) {
            self.window_pos = polled_pos;
            self.window_moved_or_resized = true;
        }

        const window_extent = surface.getExtent();
        const view = self.viewForExtent(window_extent);

        // Build command buffer
        const cmd_buf = surface.cmd_buf[frame_index];
        try dev.resetCommandBuffer(cmd_buf, .{});
        try dev.beginCommandBuffer(cmd_buf, &.{ .flags = .{ .one_time_submit_bit = true } });

        if (canvas.dirty or self.window_moved_or_resized) {
            raster_gpu.recordUpload(cmd_buf, frame_index, canvas, view.rect);
            canvas.dirty = false;
            self.window_moved_or_resized = false;
        }

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
                    .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } },
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

        dev.cmdBindPipeline(cmd_buf, .graphics, pipeline);
        dev.cmdBindDescriptorSets(cmd_buf, .graphics, pipeline_layout, 0, &.{raster_gpu.desc_set}, null);
        dev.cmdPushConstants(
            cmd_buf,
            pipeline_layout,
            .{ .fragment_bit = true },
            0,
            @sizeOf(PushConstants),
            &PushConstants{
                .canvas_size = .{ @floatFromInt(canvas.width), @floatFromInt(canvas.height) },
                .window_offset = view.offset,
            },
        );
        dev.cmdDraw(cmd_buf, 3, 1, 0, 0);

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
            self.window_moved_or_resized = true;
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

    // Keeps the window repainting while it's being dragged/resized, same
    // as demo_2d.zig.
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
                if (frame.mouse_down) {
                    const view = frame.currentView();
                    const canvas_pos = frame.canvasPosFromLocal(view.offset, .{ event.motion.x, event.motion.y });
                    frame.canvas.strokeBrush(frame.last_paint_pos[0], frame.last_paint_pos[1], canvas_pos[0], canvas_pos[1], frame.brush_radius, frame.brush_color);
                    frame.last_paint_pos = canvas_pos;
                }
            },
            sdl3.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button == sdl3.SDL_BUTTON_LEFT) {
                    frame.mouse_down = true;
                    const view = frame.currentView();
                    const canvas_pos = frame.canvasPosFromLocal(view.offset, .{ event.button.x, event.button.y });
                    frame.last_paint_pos = canvas_pos;
                    frame.canvas.fillCircle(canvas_pos[0], canvas_pos[1], frame.brush_radius, frame.brush_color);
                }
            },
            sdl3.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == sdl3.SDL_BUTTON_LEFT) {
                    frame.mouse_down = false;
                }
            },
            sdl3.SDL_EVENT_MOUSE_WHEEL => {
                frame.brush_radius = std.math.clamp(frame.brush_radius + event.wheel.y * 2.0, min_brush_radius, max_brush_radius);
            },
            sdl3.SDL_EVENT_KEY_DOWN => {
                if (event.key.key == sdl3.SDLK_C) {
                    frame.canvas.clear(white);
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

    pub fn init(self: *PipelineData, surface: vkzig.VkSurface, shader_module: vklib.ShaderModule, desc_set_layout: vklib.DescriptorSetLayout) !void {
        const dev = self.vk.dev;

        self.pipeline_layout = try dev.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = &.{desc_set_layout},
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &.{.{
                .stage_flags = .{ .fragment_bit = true },
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
                    .vertex_binding_description_count = 0,
                    .p_vertex_binding_descriptions = &.{},
                    .vertex_attribute_description_count = 0,
                    .p_vertex_attribute_descriptions = &.{},
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
                            .blend_enable = .false,
                            .color_blend_op = .add,
                            .dst_alpha_blend_factor = .zero,
                            .dst_color_blend_factor = .zero,
                            .src_alpha_blend_factor = .zero,
                            .src_color_blend_factor = .zero,
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
        std.debug.print("raster graphics pipeline: {t}\n", .{pipeline_result});
    }

    pub fn destroy(self: *PipelineData) void {
        const vk = self.vk;
        const dev = vk.dev;
        dev.destroyPipelineLayout(self.pipeline_layout, null);
        dev.destroyPipeline(self.pipeline, null);
    }
};

/// The GPU-side half of the raster demo: a persistent, desktop-sized,
/// device-local image (never resized - see the sizing-strategy note in
/// this file's usage from demoRaster) plus one host-visible staging buffer
/// per frame-in-flight, each also sized to the full canvas as a safe fixed
/// upper bound for any window-sized sub-image.
const RasterGpu = struct {
    vk: *vkzig.Vulkan,
    width: u32 = 0,
    height: u32 = 0,
    image: vklib.Image = .null_handle,
    view: vklib.ImageView = .null_handle,
    sampler: vklib.Sampler = .null_handle,
    memory: vklib.DeviceMemory = .null_handle,
    desc_set_layout: vklib.DescriptorSetLayout = .null_handle,
    desc_pool: vklib.DescriptorPool = .null_handle,
    desc_set: vklib.DescriptorSet = .null_handle,
    staging_buffers: []StagingBuffer = &.{},
    /// The very first upload transitions the image from `.undefined`;
    /// every upload after that must transition from `.read_only_optimal`
    /// instead, since the image is a *persistent* absolute-space surface -
    /// only the currently-visible window-sized sub-rect gets overwritten
    /// each time, so treating the whole subresource as "don't care" on
    /// every transition would let the driver discard already-painted
    /// regions outside the copied rect.
    first_upload: bool = true,

    const StagingBuffer = struct {
        buffer: vklib.Buffer,
        memory: vklib.DeviceMemory,
        mapped: [*]u8,
    };

    pub fn init(self: *RasterGpu, width: u32, height: u32, max_frames_in_flight: u32) !void {
        const vk = self.vk;
        const dev = vk.dev;
        self.width = width;
        self.height = height;

        self.image = try dev.createImage(&.{
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = .{ .width = width, .height = height, .depth = 1 },
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
            .format = .r8g8b8a8_unorm,
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
            .mag_filter = .nearest,
            .min_filter = .nearest,
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

        try self.initStagingBuffers(max_frames_in_flight);
        try self.createDescriptor();
    }

    fn initStagingBuffers(self: *RasterGpu, max_frames_in_flight: u32) !void {
        const vk = self.vk;
        const dev = vk.dev;
        const size: u64 = @as(u64, self.width) * self.height * 4;

        self.staging_buffers = try vk.alloc.alloc(StagingBuffer, max_frames_in_flight);
        for (self.staging_buffers) |*sb| {
            const buffer = try dev.createBuffer(&.{
                .size = size,
                .usage = .{ .transfer_src_bit = true },
                .sharing_mode = .exclusive,
            }, null);
            const mem_data = try vk.allocBufferMemory(buffer, .{
                .host_visible_bit = true,
                .host_coherent_bit = true,
            }, null);
            sb.* = .{
                .buffer = buffer,
                .memory = mem_data.mem,
                .mapped = @ptrCast(@alignCast(try dev.mapMemory(mem_data.mem, 0, vklib.WHOLE_SIZE, .{}))),
            };
        }
    }

    fn createDescriptor(self: *RasterGpu) !void {
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

    /// Packs `canvas`'s `rect` sub-region (row stride = canvas width) into
    /// this frame's staging buffer (tightly packed, row stride = rect.w),
    /// then records the barrier/copy/barrier to blit just that
    /// window-sized rectangle into the persistent desktop-sized image at
    /// the matching offset.
    pub fn recordUpload(self: *RasterGpu, cmd_buf: vklib.CommandBuffer, frame_index: u32, canvas: *const Canvas, rect: canvasmod.Rect) void {
        const dev = self.vk.dev;
        const sb = self.staging_buffers[frame_index];

        const rect_w: usize = @intCast(rect.w);
        const rect_h: usize = @intCast(rect.h);
        const canvas_stride: usize = @as(usize, canvas.width) * 4;
        const row_bytes = rect_w * 4;
        var row: usize = 0;
        while (row < rect_h) : (row += 1) {
            const src_off = (@as(usize, @intCast(rect.y)) + row) * canvas_stride + @as(usize, @intCast(rect.x)) * 4;
            const dst_off = row * row_bytes;
            @memcpy(sb.mapped[dst_off..][0..row_bytes], canvas.pixels[src_off..][0..row_bytes]);
        }

        dev.cmdPipelineBarrier2(cmd_buf, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = &.{.{
                .src_stage_mask = if (self.first_upload) .{} else .{ .fragment_shader_bit = true },
                .src_access_mask = if (self.first_upload) .{} else .{ .shader_read_bit = true },
                .dst_stage_mask = .{ .all_transfer_bit = true },
                .dst_access_mask = .{ .transfer_write_bit = true },
                .old_layout = if (self.first_upload) .undefined else .read_only_optimal,
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
        self.first_upload = false;

        dev.cmdCopyBufferToImage(cmd_buf, sb.buffer, self.image, .transfer_dst_optimal, &.{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = rect.x, .y = rect.y, .z = 0 },
            .image_extent = .{ .width = @intCast(rect.w), .height = @intCast(rect.h), .depth = 1 },
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
    }

    pub fn destroy(self: *RasterGpu) void {
        const vk = self.vk;
        const dev = vk.dev;
        for (self.staging_buffers) |sb| {
            dev.unmapMemory(sb.memory);
            vk.freeDevMemory(sb.memory);
            dev.destroyBuffer(sb.buffer, null);
        }
        vk.alloc.free(self.staging_buffers);
        dev.destroyDescriptorPool(self.desc_pool, null);
        dev.destroyDescriptorSetLayout(self.desc_set_layout, null);
        dev.destroySampler(self.sampler, null);
        dev.destroyImageView(self.view, null);
        vk.freeDevMemory(self.memory);
        dev.destroyImage(self.image, null);
    }
};
