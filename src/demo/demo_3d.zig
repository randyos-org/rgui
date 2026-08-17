const std = @import("std");
const flate = std.compress.flate;

const vklib = @import("vulkan");
const zm = @import("zmath");
const ktx = @import("ktx");
const sdl3 = @import("sdl3");

const vkzig = @import("../vulkan.zig");
const sdl_vk_mod = @import("../sdl_vk.zig");
const obj = @import("obj_loader.zig");
const sdlzig = @import("../sdl.zig");

const shader_module_src align(@alignOf(u32)) = @embedFile("shader_module").*;

const Vertex = struct {
    pos: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
};

const ShaderData = struct {
    projection: zm.Mat,
    view: zm.Mat,
    models: [3]zm.Mat,
    light_pos: [4]f32,
    selected: u32,
};

const ShaderBuffer = struct {
    buffer: vklib.Buffer,
    device_memory: vklib.DeviceMemory,
    device_address: vklib.DeviceAddress,
    mapped_memory: *align(1) ShaderData,
};

const Texture = struct {
    image: vklib.Image,
    view: vklib.ImageView,
    sampler: vklib.Sampler,
    memory: vklib.DeviceMemory,
};

const ObjectRotation = struct {
    x: f32,
    y: f32,
};

pub fn demo3d(alloc: std.mem.Allocator, io: std.Io, window: *sdl_vk_mod.VkWindow) !void {
    const vk = &window.sdlvk.vk;
    const dev = vk.dev;

    var vertices: std.ArrayList(Vertex) = .empty;
    var indices: std.ArrayList(u16) = .empty;
    try loadObjData(alloc, io, &vertices, &indices);
    defer vertices.deinit(alloc);
    defer indices.deinit(alloc);

    const vb = try VertexBuffer.create(vk, vertices.items, indices.items);
    defer vb.destroy(vk);

    var shader_buffer_data: ShaderBufferData = .{
        .vk = vk,
    };
    try shader_buffer_data.init(window.max_frames_in_flight);
    defer shader_buffer_data.destroy();

    var texture_data: TextureData = .{
        .vk = vk,
    };
    try texture_data.init(alloc, io, window.surface.cmd_pool);
    defer texture_data.destroy();

    // Load shader
    const shader_module = try dev.createShaderModule(&.{
        .code_size = shader_module_src.len,
        .p_code = @ptrCast(&shader_module_src),
    }, null);
    defer dev.destroyShaderModule(shader_module, null);

    var pipeline_data: PipelineData = .{
        .vk = vk,
    };
    try pipeline_data.init(window.surface, shader_module, &texture_data);
    defer pipeline_data.destroy();

    try renderLoop(window, shader_buffer_data.shader_data_buffers.ptr, pipeline_data, vb, texture_data, indices.items);
}

fn renderLoop(window: *sdl_vk_mod.VkWindow, shader_data_buffers: [*]ShaderBuffer, pipeline_data: PipelineData, vb: VertexBuffer, texture_data: TextureData, indices: []const u16) !void {
    const vk = &window.sdlvk.vk;
    const dev = vk.dev;
    const surface = &window.surface;
    const queue_family = vk.graphics_queue_family;
    const pipeline = pipeline_data.pipeline;
    const pipeline_layout = pipeline_data.pipeline_layout;
    const desc_set = texture_data.desc_set;
    const vertex_buffer = vb.buffer;
    const queue = vk.queue;

    var last_tick: f64 = sdlzig.getTickSecs();
    var dt: f64 = last_tick;

    var event: sdl3.SDL_Event = undefined;
    var update_swapchain: bool = false;
    var frame_index: u32 = 0;
    var selected: u32 = 1;
    var zoom: f32 = -10;
    var object_rotations = [_]ObjectRotation{
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 0 },
    };

    while (event.type != sdl3.SDL_EVENT_QUIT) : (frame_index = (frame_index + 1) % window.max_frames_in_flight) {
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
                    update_swapchain = true;
                    break :val next_image.image_index;
                },
                else => |result| std.debug.panic("Failed to acquire next image: {t}", .{result}),
            }
        };

        // Update shader data
        var window_extent = surface.getExtent();
        const aspect = @as(f32, @floatFromInt(window_extent.width)) / @as(f32, @floatFromInt(window_extent.height));
        const projection = zm.perspectiveFovRh(std.math.degreesToRadians(45.0), aspect, 0.1, 32.0);
        const view = zm.translation(0, 0, zoom);

        var models: [3]zm.Mat = undefined;
        for (0..models.len) |i| {
            const position = zm.translation((@as(f32, @floatFromInt(i)) - 1) * 3, 0, 0);

            const rx = zm.rotationX(object_rotations[i].x);
            const ry = zm.rotationY(object_rotations[i].y);
            const rotation = zm.mul(rx, ry);

            models[i] = zm.mul(rotation, position);
        }

        shader_data_buffers[frame_index].mapped_memory.* = .{
            .light_pos = .{ 0, -10, 10, 0 },
            .projection = projection,
            .selected = selected,
            .models = models,
            .view = view,
        };

        // Build command buffer
        const cmd_buf = surface.cmd_buf[frame_index];
        try dev.resetCommandBuffer(cmd_buf, .{});
        try dev.beginCommandBuffer(cmd_buf, &.{ .flags = .{ .one_time_submit_bit = true } });
        dev.cmdPipelineBarrier2(cmd_buf, &.{
            .image_memory_barrier_count = 2,
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
                .{
                    .src_stage_mask = .{
                        .early_fragment_tests_bit = true,
                        .late_fragment_tests_bit = true,
                    },
                    .src_access_mask = .{ .depth_stencil_attachment_write_bit = true },
                    .dst_stage_mask = .{
                        .early_fragment_tests_bit = true,
                        .late_fragment_tests_bit = true,
                    },
                    .dst_access_mask = .{ .depth_stencil_attachment_write_bit = true },
                    .old_layout = .undefined,
                    .new_layout = .attachment_optimal,
                    .image = surface.depth_img,
                    .subresource_range = .{
                        .aspect_mask = .{ .depth_bit = true, .stencil_bit = true },
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
                    .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0.2, 1.0 } } },
                    .resolve_mode = .{},
                    .resolve_image_layout = .undefined,
                },
            },
            .p_depth_attachment = &.{
                .image_view = surface.depth_view,
                .image_layout = .attachment_optimal,
                .load_op = .clear,
                .store_op = .dont_care,
                .clear_value = .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } },
                .resolve_image_layout = .undefined,
                .resolve_mode = .{},
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
        dev.cmdBindPipeline(cmd_buf, .graphics, pipeline);
        dev.cmdSetScissor(cmd_buf, 0, &.{vklib.Rect2D{ .extent = window_extent, .offset = .{ .x = 0, .y = 0 } }});
        dev.cmdBindDescriptorSets(cmd_buf, .graphics, pipeline_layout, 0, &.{desc_set}, null);
        dev.cmdBindVertexBuffers(cmd_buf, 0, @ptrCast(&vertex_buffer), &.{0});
        dev.cmdBindIndexBuffer(cmd_buf, vertex_buffer, vb.v_buf_size, .uint16);
        dev.cmdPushConstants(
            cmd_buf,
            pipeline_layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(vklib.DeviceAddress),
            &shader_data_buffers[frame_index].device_address,
        );
        dev.cmdDrawIndexed(cmd_buf, @intCast(indices.len), 3, 0, 0, 0);
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
                update_swapchain = true;
            },
            else => std.debug.panic("Queue present not successful: {t}", .{present_result}),
        }

        // Event polling
        const next_tick = sdlzig.getTickSecs();
        dt = next_tick - last_tick;
        last_tick = next_tick;
        if (!sdl3.SDL_PollEvent(&event) or event.type == sdl3.SDL_EVENT_QUIT) continue;
        switch (event.type) {
            sdl3.SDL_EVENT_WINDOW_RESIZED => {
                update_swapchain = true;
            },
            sdl3.SDL_EVENT_MOUSE_MOTION => {
                if (event.button.button == sdl3.SDL_BUTTON_LEFT) {
                    object_rotations[shader_data_buffers[frame_index].mapped_memory.selected].x -= event.motion.yrel * @as(f32, @floatCast(dt));
                    object_rotations[shader_data_buffers[frame_index].mapped_memory.selected].y += event.motion.xrel * @as(f32, @floatCast(dt));
                }
            },
            sdl3.SDL_EVENT_KEY_DOWN => {
                switch (event.key.key) {
                    sdl3.SDLK_EQUALS, sdl3.SDLK_KP_EQUALS => {
                        selected = if (selected < 2) selected + 1 else 0;
                    },
                    sdl3.SDLK_MINUS, sdl3.SDLK_KP_MINUS => {
                        selected = if (selected > 0) selected - 1 else 2;
                    },
                    else => {},
                }
            },
            sdl3.SDL_EVENT_MOUSE_WHEEL => {
                zoom = std.math.clamp(zoom + (event.wheel.y * @as(f32, @floatCast(dt)) * 10.0), -20, -5);
            },
            else => {},
        }

        if (update_swapchain) {
            update_swapchain = false;
            window_extent = window.getWindowSize();
            try surface.updateSwapchain(window_extent);
        }
    }

    // wait for the GPU to finish the last submitted frame before the
    // caller's deferred cleanup starts destroying in-use resources
    try dev.deviceWaitIdle();
}

const PipelineData = struct {
    vk: *vkzig.Vulkan,
    pipeline: vklib.Pipeline = .null_handle,
    pipeline_layout: vklib.PipelineLayout = .null_handle,

    pub fn init(self: *PipelineData, surface: vkzig.VkSurface, shader_module: vklib.ShaderModule, texture_data: *TextureData) !void {
        const dev = self.vk.dev;
        const desc_set_layout = texture_data.desc_set_layout;

        self.pipeline_layout = try dev.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = &.{desc_set_layout},
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &.{.{
                .stage_flags = .{ .vertex_bit = true },
                .size = @sizeOf(vklib.DeviceAddress),
                .offset = 0,
            }},
        }, null);

        const pipeline_result = try dev.createGraphicsPipelines(.null_handle, &.{
            .{
                .p_next = &vklib.PipelineRenderingCreateInfo{
                    .color_attachment_count = 1,
                    .p_color_attachment_formats = @ptrCast(&surface.image_format),
                    .depth_attachment_format = surface.depth_format,
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
                    .vertex_attribute_description_count = 3,
                    .p_vertex_attribute_descriptions = &.{
                        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = 0 },
                        .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "normal") },
                        .{ .location = 2, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "uv") },
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
                },
                .p_multisample_state = &.{
                    .rasterization_samples = .{ .@"1_bit" = true },
                    .min_sample_shading = 0,
                    .alpha_to_coverage_enable = .false,
                    .alpha_to_one_enable = .false,
                    .sample_shading_enable = .false,
                },
                .p_depth_stencil_state = &.{
                    .depth_test_enable = .true,
                    .depth_write_enable = .true,
                    .depth_compare_op = .less_or_equal,
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
        std.debug.print("graphics pipeline: {t}\n", .{pipeline_result});
    }

    pub fn destroy(self: *PipelineData) void {
        const vk = self.vk;
        const dev = vk.dev;
        dev.destroyPipelineLayout(self.pipeline_layout, null);
        dev.destroyPipeline(self.pipeline, null);
    }
};

fn loadObjData(alloc: std.mem.Allocator, io: std.Io, vertices: *std.ArrayList(Vertex), indices: *std.ArrayList(u16)) !void {
    const obj_file = try obj.loadObj(alloc, io, try std.Io.Dir.cwd().realPathFileAlloc(io, "assets/suzanne.obj", alloc));
    defer obj_file.deinit(alloc);

    // Load vertex and index data
    try vertices.ensureTotalCapacityPrecise(alloc, obj_file.mesh.len);
    try indices.ensureTotalCapacityPrecise(alloc, obj_file.mesh.len);
    for (obj_file.mesh, 0..) |mesh_index, i| {
        vertices.appendAssumeCapacity(Vertex{
            .pos = @Vector(3, f32){
                obj_file.v_list[mesh_index.v_index * 3 + 0],
                -obj_file.v_list[mesh_index.v_index * 3 + 1],
                obj_file.v_list[mesh_index.v_index * 3 + 2],
            },
            .normal = @Vector(3, f32){
                obj_file.vn_list[mesh_index.vn_index.? * 3 + 0],
                -obj_file.vn_list[mesh_index.vn_index.? * 3 + 1],
                obj_file.vn_list[mesh_index.vn_index.? * 3 + 2],
            },
            .uv = @Vector(2, f32){
                obj_file.vt_list[mesh_index.vt_index.? * 2 + 0],
                1.0 - obj_file.vt_list[mesh_index.vt_index.? * 2 + 1],
            },
        });
        indices.appendAssumeCapacity(@intCast(i));
    }
}

const VertexBuffer = struct {
    vk: *vkzig.Vulkan = undefined,
    buffer: vklib.Buffer = undefined,
    mem: vklib.DeviceMemory = undefined,
    v_buf_size: usize = 0,

    pub fn destroy(self: *const VertexBuffer, vk: *vkzig.Vulkan) void {
        const dev = vk.dev;
        dev.unmapMemory(self.mem);
        vk.freeDevMemory(self.mem);
        dev.destroyBuffer(self.buffer, null);
    }

    pub fn create(vk: *vkzig.Vulkan, vertices: []const Vertex, indices: []const u16) !VertexBuffer {
        const dev = vk.dev;
        const v_buf_size = @sizeOf(Vertex) * vertices.len;
        const i_buf_size = @sizeOf(u16) * indices.len;

        const vertex_buffer = try dev.createBuffer(&.{
            .size = v_buf_size + i_buf_size,
            .sharing_mode = .exclusive,
            .usage = .{
                .vertex_buffer_bit = true,
                .index_buffer_bit = true,
            },
        }, null);
        // defer dev.destroyBuffer(vertex_buffer, null);

        const staging_mem = try vk.allocBufferMemory(vertex_buffer, .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        }, null);
        // defer vk.freeDevMemory(staging_mem);

        const data = try dev.mapMemory(staging_mem.mem, 0, vklib.WHOLE_SIZE, .{});
        // defer dev.unmapMemory(staging_mem.mem);
        const vertex_data: [*]Vertex = @ptrCast(@alignCast(data));
        @memcpy(vertex_data, vertices);
        const index_data: [*]u16 = @ptrCast(@alignCast(vertex_data[vertices.len..]));
        @memcpy(index_data, indices);

        return .{
            .vk = vk,
            .buffer = vertex_buffer,
            .mem = staging_mem.mem,
            .v_buf_size = v_buf_size,
        };
    }
};

const ShaderBufferData = struct {
    vk: *vkzig.Vulkan,
    shader_data_buffers: []ShaderBuffer = undefined,

    pub fn destroy(self: *ShaderBufferData) void {
        const vk = self.vk;
        const dev = vk.dev;
        for (self.shader_data_buffers) |buffer| {
            dev.unmapMemory(buffer.device_memory);
            vk.freeDevMemory(buffer.device_memory);
            dev.destroyBuffer(buffer.buffer, null);
        }
        vk.alloc.free(self.shader_data_buffers);
    }

    pub fn init(self: *ShaderBufferData, max_frames_in_flight: u32) !void {
        const vk = self.vk;
        const dev = vk.dev;
        self.shader_data_buffers = try vk.alloc.alloc(ShaderBuffer, max_frames_in_flight);
        for (self.shader_data_buffers) |*shader_buffer| {
            const uniform_buffer = try dev.createBuffer(&.{
                .size = @sizeOf(ShaderData),
                .usage = .{ .shader_device_address_bit = true },
                .sharing_mode = .exclusive,
            }, null);
            const buffer_memory = try vk.allocBufferMemory(uniform_buffer, .{
                .host_cached_bit = true,
                .host_coherent_bit = true,
            }, .{ .flags = .{
                .device_address_bit = true,
            }, .device_mask = 0 });

            shader_buffer.mapped_memory = @ptrCast(try dev.mapMemory(buffer_memory.mem, 0, @sizeOf(ShaderData), .{}));
            shader_buffer.device_address = dev.getBufferDeviceAddress(&.{ .buffer = uniform_buffer });
            shader_buffer.device_memory = buffer_memory.mem;
            shader_buffer.buffer = uniform_buffer;
        }
    }
};

const KtxLoader = struct {
    io: std.Io,
    file: std.Io.File = undefined,
    file_buf: [0x1000]u8 = undefined,
    file_reader: std.Io.File.Reader = undefined,
    interface: *std.Io.Reader = undefined,
    header: ktx.Header = undefined,
    level_count: u32 = 0,
    format: vklib.Format = undefined,
    // reader: flate.Decompress = undefined,
    level_buf: [1]ktx.Level = undefined,
    levels: ktx.Level.Index = undefined,
    size: u64 = 0,

    pub fn init(self: *KtxLoader, file_path: []const u8) !void {
        const io = self.io;

        self.file = try std.Io.Dir.cwd().openFile(io, file_path, .{});

        self.file_reader = self.file.reader(io, &self.file_buf);
        self.interface = &self.file_reader.interface;
        const interface = self.interface;

        self.header = try ktx.Header.take(interface);
        const header = self.header;

        self.level_count = header.level_count.toInt();
        self.format = @enumFromInt(@intFromEnum(header.format));

        self.levels = try header.takeLevelIndexShort(interface, &self.level_buf);
        try self.levels.discardUntilFirstLevel(header, interface);

        for (self.levels.items) |level| {
            self.size += level.uncompressed_byte_length;
        }
    }

    pub fn destroy(self: *KtxLoader) void {
        self.file.close(self.io);
    }
};

const TextureData = struct {
    vk: *vkzig.Vulkan,
    texture_descriptors: [3]vklib.DescriptorImageInfo = undefined,
    textures: [3]Texture = undefined,
    desc_set_layout: vklib.DescriptorSetLayout = undefined,
    desc_pool: vklib.DescriptorPool = undefined,
    desc_set: vklib.DescriptorSet = .null_handle,

    fn createImage(self: *TextureData, texture: *Texture, ktx_loader: *KtxLoader) !void {
        const header = ktx_loader.header;
        texture.image = try self.vk.dev.createImage(
            &.{
                .image_type = .@"2d",
                .format = ktx_loader.format,
                .extent = .{
                    .width = header.pixel_width,
                    .height = header.pixel_height,
                    .depth = 1,
                },
                .mip_levels = ktx_loader.level_count,
                .array_layers = 1,
                .samples = .{ .@"1_bit" = true },
                .tiling = .optimal,
                .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
                .initial_layout = .undefined,
                .sharing_mode = .exclusive,
            },
            null,
        );
    }

    fn createMem(self: *TextureData, texture: *Texture) !void {
        const mem_data = try self.vk.allocImageMemory(texture.image, .{ .device_local_bit = true });
        texture.memory = mem_data.mem;
    }

    fn createView(self: *TextureData, texture: *Texture, ktx_loader: *KtxLoader) !void {
        texture.view = try self.vk.dev.createImageView(
            &.{
                .image = texture.image,
                .format = ktx_loader.format,
                .view_type = .@"2d",
                .subresource_range = .{
                    .level_count = ktx_loader.level_count,
                    .aspect_mask = .{ .color_bit = true },
                    .base_array_layer = 0,
                    .base_mip_level = 0,
                    .layer_count = 1,
                },
                .components = .{
                    .a = .identity,
                    .b = .identity,
                    .g = .identity,
                    .r = .identity,
                },
            },
            null,
        );
    }

    fn createImgSrcBuf(self: *TextureData, ktx_loader: *KtxLoader) !vklib.Buffer {
        const dev = self.vk.dev;
        return try dev.createBuffer(
            &.{
                .size = ktx_loader.size,
                .usage = .{ .transfer_src_bit = true },
                .sharing_mode = .exclusive,
            },
            null,
        );
    }

    fn allocImgBuf(self: *TextureData, img_src_buf: vklib.Buffer) !vkzig.VkDevMemInfo {
        return try self.vk.allocBufferMemory(img_src_buf, .{
            .host_cached_bit = true,
            .host_coherent_bit = true,
        }, null);
    }

    fn mapAndCopyToBuffer(self: *TextureData, img_src_mem_data: vkzig.VkDevMemInfo, ktx_loader: *KtxLoader) !void {
        // src
        var decompress_buf: [flate.max_window_len]u8 = undefined;
        var decompress_reader = flate.Decompress.init(ktx_loader.interface, .zlib, &decompress_buf);

        // dest
        const mapped_mem = try self.vk.dev.mapMemory(img_src_mem_data.mem, 0, vklib.WHOLE_SIZE, .{});
        const mp: [*]u8 = @ptrCast(@alignCast(mapped_mem));
        var img_writer = std.Io.Writer.fixed(mp[0..img_src_mem_data.size]);

        // copy from reader to writer (src to dest)
        try decompress_reader.reader.streamExact(&img_writer, ktx_loader.size);
    }

    fn createCopyRegions(ktx_loader: *KtxLoader, copy_regions: *std.ArrayList(vklib.BufferImageCopy)) !void {
        const levels = ktx_loader.levels;
        var mip_offset: u64 = 0;
        var iter = levels.iterator();
        while (iter.next(ktx_loader.levels)) |level| {
            try copy_regions.appendBounded(.{
                .buffer_offset = mip_offset,
                .image_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = iter.i,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .image_extent = @bitCast(iter.currentExtent(ktx_loader.header)),
                .image_offset = .{ .x = 0, .y = 0, .z = 0 },
                .buffer_image_height = 0,
                .buffer_row_length = 0,
            });
            mip_offset += level.uncompressed_byte_length;
        }
        // return mip_offset;
    }

    fn allocCmdBuf(self: *TextureData, cmd_buf: *vklib.CommandBuffer, pool: vklib.CommandPool) !void {
        try self.vk.dev.allocateCommandBuffers(
            &.{
                .command_pool = pool,
                .command_buffer_count = 1,
                .level = .primary,
            },
            @ptrCast(cmd_buf),
        );
    }

    fn cmdLayoutToXferDstOpt(self: *TextureData, cmd_buf: vklib.CommandBuffer, img: vklib.Image, level_count: u32) void {
        self.vk.dev.cmdPipelineBarrier2(cmd_buf, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = &.{.{
                .src_stage_mask = .{},
                .src_access_mask = .{},
                .dst_stage_mask = .{ .all_transfer_bit = true },
                .dst_access_mask = .{ .transfer_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .transfer_dst_optimal,
                .image = img,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .level_count = level_count,
                    .layer_count = 1,
                    .base_array_layer = 0,
                    .base_mip_level = 0,
                },
                .src_queue_family_index = 0,
                .dst_queue_family_index = 0,
            }},
        });
    }

    fn cmdLayoutFromXferDstToReadOnly(self: *TextureData, cmd_buf: vklib.CommandBuffer, img: vklib.Image, level_count: u32) void {
        self.vk.dev.cmdPipelineBarrier2(cmd_buf, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = &.{.{
                .src_stage_mask = .{ .all_transfer_bit = true },
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_stage_mask = .{ .fragment_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .old_layout = .transfer_dst_optimal,
                .new_layout = .read_only_optimal,
                .image = img,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .level_count = level_count,
                    .layer_count = 1,
                    .base_array_layer = 0,
                    .base_mip_level = 0,
                },
                .src_queue_family_index = 0,
                .dst_queue_family_index = 0,
            }},
        });
    }

    fn createSampler(self: *TextureData, texture: *Texture, level_count: u32) !void {
        texture.sampler = try self.vk.dev.createSampler(
            &.{
                .mag_filter = .linear,
                .min_filter = .linear,
                .mipmap_mode = .linear,
                .anisotropy_enable = .true,
                .max_anisotropy = 8,
                .max_lod = @floatFromInt(level_count),
                .address_mode_u = .repeat,
                .address_mode_v = .repeat,
                .address_mode_w = .repeat,
                .border_color = .float_transparent_black,
                .compare_enable = .false,
                .compare_op = .never,
                .mip_lod_bias = 0,
                .min_lod = 0,
                .unnormalized_coordinates = .false,
            },
            null,
        );
    }

    fn createDescriptor(texture: *Texture) vklib.DescriptorImageInfo {
        return .{
            .sampler = texture.sampler,
            .image_view = texture.view,
            .image_layout = .read_only_optimal,
        };
    }

    fn createDescSetLayout(self: *TextureData, desc_count: u32) !vklib.DescriptorSetLayout {
        return try self.vk.dev.createDescriptorSetLayout(
            &.{
                .p_next = &vklib.DescriptorSetLayoutBindingFlagsCreateInfo{
                    .binding_count = 1,
                    .p_binding_flags = &.{.{ .variable_descriptor_count_bit = true }},
                },
                .binding_count = 1,
                .p_bindings = &.{.{
                    .descriptor_type = .combined_image_sampler,
                    .descriptor_count = desc_count,
                    .stage_flags = .{ .fragment_bit = true },
                    .binding = 0,
                }},
            },
            null,
        );
    }

    fn createDescPool(self: *TextureData, desc_count: u32) !vklib.DescriptorPool {
        return try self.vk.dev.createDescriptorPool(
            &.{
                .max_sets = 1,
                .pool_size_count = 1,
                .p_pool_sizes = &.{.{
                    .type = .combined_image_sampler,
                    .descriptor_count = desc_count,
                }},
            },
            null,
        );
    }

    fn allocDescSet(self: *TextureData, desc_count: u32, desc_pool: vklib.DescriptorPool, desc_set_layout: vklib.DescriptorSetLayout, desc_set: *vklib.DescriptorSet) !void {
        try self.vk.dev.allocateDescriptorSets(&.{
            .p_next = &vklib.DescriptorSetVariableDescriptorCountAllocateInfo{
                .descriptor_set_count = 1,
                .p_descriptor_counts = &.{desc_count},
            },
            .descriptor_pool = desc_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &.{desc_set_layout},
        }, @ptrCast(desc_set));
    }

    fn updateDescSet(self: *TextureData, desc_set: vklib.DescriptorSet, desc_count: u32) void {
        self.vk.dev.updateDescriptorSets(&.{.{
            .dst_set = desc_set,
            .dst_binding = 0,
            .descriptor_count = desc_count,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = &self.texture_descriptors,
            .dst_array_element = 0,
            .p_buffer_info = &.{},
            .p_texel_buffer_view = &.{},
        }}, null);
    }

    pub fn init(self: *TextureData, alloc: std.mem.Allocator, io: std.Io, pool: vklib.CommandPool) !void {
        const vk = self.vk;
        const dev = vk.dev;

        for (&self.textures, 0..) |*texture, i| {
            const file_name = try std.fmt.allocPrint(alloc, "assets/suzanne{d}.ktx", .{i});
            var ktx_loader: KtxLoader = .{
                .io = io,
            };
            try ktx_loader.init(file_name);
            defer ktx_loader.destroy();

            try self.createImage(texture, &ktx_loader);
            errdefer dev.destroyImage(texture.image, null);

            try self.createMem(texture);
            errdefer vk.freeDevMemory(texture.memory);

            try self.createView(texture, &ktx_loader);
            errdefer dev.destroyImageView(texture.view, null);

            // create GPU staging buffer and copy the KTX image data into it
            const img_src_buf = try self.createImgSrcBuf(&ktx_loader);
            defer dev.destroyBuffer(img_src_buf, null);

            const img_src_mem_data = try self.allocImgBuf(img_src_buf);
            const img_src_mem = img_src_mem_data.mem;
            defer vk.freeDevMemory(img_src_mem);

            try self.mapAndCopyToBuffer(img_src_mem_data, &ktx_loader);
            defer dev.unmapMemory(img_src_mem);

            // create one-shot command buffer to copy from GPU staging buffer to GPU image
            var cmd_buf_oneshot: vklib.CommandBuffer = undefined;
            try self.allocCmdBuf(&cmd_buf_oneshot, pool);

            try dev.beginCommandBuffer(cmd_buf_oneshot, &.{ .flags = .{ .one_time_submit_bit = true } });

            self.cmdLayoutToXferDstOpt(cmd_buf_oneshot, texture.image, ktx_loader.level_count);

            // copy commands
            var copy_regions = try std.ArrayList(vklib.BufferImageCopy).initCapacity(alloc, ktx_loader.level_count);
            defer copy_regions.deinit(alloc);

            try TextureData.createCopyRegions(&ktx_loader, &copy_regions);
            dev.cmdCopyBufferToImage(cmd_buf_oneshot, img_src_buf, texture.image, .transfer_dst_optimal, copy_regions.items);

            // make read-only for shader access
            self.cmdLayoutFromXferDstToReadOnly(cmd_buf_oneshot, texture.image, ktx_loader.level_count);

            try dev.endCommandBuffer(cmd_buf_oneshot);

            // submit command buffer and wait for it to finish
            const fence_one_time = try dev.createFence(&.{}, null);
            defer dev.destroyFence(fence_one_time, null);

            try dev.queueSubmit(vk.queue, &.{.{
                .command_buffer_count = 1,
                .p_command_buffers = @ptrCast(&cmd_buf_oneshot),
            }}, fence_one_time);
            if (try dev.waitForFences(&.{fence_one_time}, .true, std.math.maxInt(u64)) != .success) @panic("Wait for fences failed");

            try self.createSampler(texture, ktx_loader.level_count);
            self.texture_descriptors[i] = TextureData.createDescriptor(texture);
        }

        // Descriptor (indexing)
        const desc_count: u32 = @intCast(self.texture_descriptors.len);
        self.desc_set_layout = try self.createDescSetLayout(desc_count);
        self.desc_pool = try self.createDescPool(desc_count);
        try self.allocDescSet(desc_count, self.desc_pool, self.desc_set_layout, &self.desc_set);
        self.updateDescSet(self.desc_set, desc_count);
    }

    pub fn destroy(self: *TextureData) void {
        const vk = self.vk;
        const dev = vk.dev;
        dev.destroyDescriptorPool(self.desc_pool, null);
        dev.destroyDescriptorSetLayout(self.desc_set_layout, null);
        for (self.textures) |texture| {
            dev.destroySampler(texture.sampler, null);
            dev.destroyImageView(texture.view, null);
            vk.freeDevMemory(texture.memory);
            dev.destroyImage(texture.image, null);
        }
    }
};
