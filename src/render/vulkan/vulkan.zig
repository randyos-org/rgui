const std = @import("std");
const vklib = @import("vulkan");

const rstd = @import("rstd");
const zigstd = rstd.zigstd;
const Allocator = zigstd.Allocator;
const equal = zigstd.equal;

pub const InstExts = std.ArrayList([*:0]const u8);
pub const LayerNames = std.ArrayList([*:0]const u8);

pub fn initInstExts(alloc: Allocator) !InstExts {
    var inst_exts: InstExts = .empty;
    try inst_exts.append(alloc, vklib.extensions.ext_debug_utils.name);
    return inst_exts;
}

pub fn destroyInstExts(alloc: Allocator, inst_exts: *InstExts) void {
    inst_exts.deinit(alloc);
}

pub var inst_wrap: ?vklib.InstanceWrapper = null;
pub var dev_wrap: ?vklib.DeviceWrapper = null;

pub const VkDevMemInfo = struct {
    mem: vklib.DeviceMemory,
    size: u64,
};

pub const Vulkan = struct {
    alloc: Allocator = undefined,
    dispatcher: vklib.BaseWrapper = undefined,

    // app_info: vk.ApplicationInfo = undefined,
    // inst_info: vk.InstanceCreateInfo = undefined,
    enabled_layers: LayerNames = .empty,

    // inst_hdl: vk.Instance = undefined,
    // _inst_wrap: *vk.InstanceWrapper = undefined,
    inst: vklib.InstanceProxy = undefined,

    _debug_messenger: vklib.DebugUtilsMessengerEXT = undefined,

    physical_device: vklib.PhysicalDevice = undefined,
    device_mem: vklib.PhysicalDeviceMemoryProperties = undefined,
    graphics_queue_family: u32 = undefined,

    qf_priorities: []f32 = undefined,
    req_dev_exts: [][*:0]const u8 = undefined,

    // _dev_wrap: *vk.DeviceWrapper = undefined,
    dev: vklib.DeviceProxy = undefined,
    queue: vklib.Queue = undefined,

    pub fn init(self: *Vulkan, alloc: Allocator, app_name: [*:0]const u8, inst_exts: InstExts, dispatcher: vklib.BaseWrapper) !void {
        // Vulkan-Zig is designed to only support dynamic linking against Vulkan,
        // so it provides a series of "wrapper" and "proxy" objects to abstract
        // away function pointers with more Zig-native interfaces.
        //
        // The way these are constructed are by starting with a handle from a
        // low-level Vulkan create function.  That handle is then loaded into a
        // "wrapper" object, which uses the handle with a function pointer to the
        // underlying vkGet__ProcAddr function provided by the platform backend
        // (i.e. SDL, GLFW, etc.).  The wrapper object is then effectively a vtable
        // for that *type* of object.  The wrapper loader only uses the handle
        // to perform the Vulkan function lookups (e.g. test if the current
        // runtime platform supports a certain function or sets the function
        // pointer to null), but the handle is not stored in the wrapper.
        // In other words, the wrapper is more defining
        // platform-specific interfaces for Vulkan objects, but does not
        // instantiate a Zig-native object instance for them.
        //
        // Proxies are, therefore, Zig structs that map specific handles to the
        // corresponding wrapper objects.  Once created, the proxy object is the
        // one that will be actually handled by downstream Zig code wanting to
        // use Vulkan.

        self.alloc = alloc;
        self.dispatcher = dispatcher;
        self.enabled_layers = try getEnabledLayers(alloc, dispatcher);
        try self.initInst(app_name, inst_exts);
        try self.initVkDebugMsngr();
        try self.initPhysicalDev();
        try self.initGraphicsQueueFamily();
        try self.initDev();

        self.device_mem = self.inst.getPhysicalDeviceMemoryProperties(self.physical_device);
        self.queue = self.dev.getDeviceQueue(self.graphics_queue_family, 0);
    }

    pub fn destroy(self: *Vulkan) void {
        // don't forget that these lines should be in reverse order of the places they are created in init
        const alloc = self.alloc;
        const inst = self.inst;
        const dev = self.dev;

        dev.deviceWaitIdle() catch {
            std.debug.print("vkDeviceWaitIdle failed during VkSurface destroy\n", .{});
        };

        dev.destroyDevice(null);
        // alloc.destroy(self._dev_wrap);
        inst.destroyDebugUtilsMessengerEXT(self._debug_messenger, null);
        inst.destroyInstance(null);
        // alloc.destroy(self._inst_wrap);
        self.enabled_layers.deinit(alloc);
    }

    /// Requested layers that aren't installed would otherwise make
    /// vkCreateInstance fail with LayerNotPresent; only enable the
    /// ones actually available.
    fn getEnabledLayers(alloc: Allocator, dispatch_wrapper: vklib.BaseWrapper) !LayerNames {
        const wanted_layers = [_][*:0]const u8{
            "VK_LAYER_KHRONOS_validation",
            // "VK_LAYER_LUNARG_monitor",
        };

        const avail_layers = try dispatch_wrapper.enumerateInstanceLayerPropertiesAlloc(alloc);
        defer alloc.free(avail_layers);
        // std.debug.print("Available Vulkan layers:\n", .{});
        // for (avail_layers) |layer| {
        //     std.debug.print("  {s}\n", .{std.mem.sliceTo(&layer.layer_name, 0)});
        // }

        var enabled_layers: LayerNames = try .initCapacity(alloc, wanted_layers.len);
        errdefer enabled_layers.deinit(alloc);

        for (wanted_layers) |layer| {
            const wanted_name = std.mem.sliceTo(layer, 0);
            const is_avail = for (avail_layers) |avail| {
                if (equal(u8, wanted_name, std.mem.sliceTo(&avail.layer_name, 0))) break true;
            } else false;

            if (is_avail) {
                enabled_layers.appendAssumeCapacity(layer);
            } else {
                std.debug.print("Vulkan layer not available, skipping: {s}\n", .{wanted_name});
            }
        }

        return enabled_layers;
    }

    fn initInst(self: *Vulkan, app_name: [*:0]const u8, inst_exts: InstExts) !void {
        const enabled_layers = &self.enabled_layers;
        const vk_api_ver = vklib.makeApiVersion(0, 0, 0, 0);
        const inst_info: vklib.InstanceCreateInfo = .{
            .p_application_info = &.{
                .p_application_name = app_name,
                .application_version = vk_api_ver.toU32(),
                .p_engine_name = app_name,
                .engine_version = vk_api_ver.toU32(),
                .api_version = vklib.API_VERSION_1_4.toU32(),
            },

            .pp_enabled_layer_names = enabled_layers.items.ptr,
            .enabled_layer_count = @intCast(enabled_layers.items.len),

            .pp_enabled_extension_names = inst_exts.items.ptr,
            .enabled_extension_count = @intCast(inst_exts.items.len),
        };
        const inst_hdl = try self.dispatcher.createInstance(&inst_info, null);
        if (inst_wrap == null) {
            inst_wrap = vklib.InstanceWrapper.load(inst_hdl, self.dispatcher.dispatch.vkGetInstanceProcAddr.?);
        }
        self.inst = vklib.InstanceProxy.init(inst_hdl, &inst_wrap.?);
    }

    fn initVkDebugMsngr(self: *Vulkan) !void {
        const debug_info = vklib.DebugUtilsMessengerCreateInfoEXT{
            .message_severity = .{
                .warning_bit_ext = true,
                .error_bit_ext = true,
            },
            .message_type = .{
                .general_bit_ext = true,
                .validation_bit_ext = true,
                .performance_bit_ext = true,
            },
            .pfn_user_callback = &debugCallback,
            .p_user_data = null,
        };
        self._debug_messenger = try self.inst.createDebugUtilsMessengerEXT(&debug_info, null);
    }

    fn initPhysicalDev(self: *Vulkan) !void {
        const inst = self.inst;
        const devices = try inst.enumeratePhysicalDevicesAlloc(self.alloc);
        defer self.alloc.free(devices);
        if (devices.len == 0) return error.NoVkDevicesFound;
        self.physical_device = devices[0];

        // const dev_props = inst.getPhysicalDeviceProperties(self.physical_device);
        // std.debug.print("Device: {s}\n", .{dev_props.device_name});
    }

    fn initGraphicsQueueFamily(self: *Vulkan) !void {
        const alloc = self.alloc;
        const inst = self.inst;
        const physdev = self.physical_device;
        const families = try inst.getPhysicalDeviceQueueFamilyPropertiesAlloc(physdev, alloc);
        defer alloc.free(families);

        var found: ?u32 = null;
        for (families, 0..) |family, idx| {
            if (family.queue_flags.graphics_bit) {
                found = @intCast(idx);
                break;
            }
        }
        if (found == null) return error.NoVkGraphicsQueueFamilyFound;
        self.graphics_queue_family = found.?;
    }

    fn initDev(self: *Vulkan) !void {
        const qf_priorities = [_]f32{1.0};

        const qinfo = [_]vklib.DeviceQueueCreateInfo{.{
            .queue_family_index = self.graphics_queue_family,
            .queue_count = qf_priorities.len,
            .p_queue_priorities = &qf_priorities,
        }};

        const req_dev_exts = [_][*:0]const u8{
            vklib.extensions.khr_swapchain.name,
        };

        const dev_info: vklib.DeviceCreateInfo = .{
            .queue_create_info_count = @intCast(qinfo.len),
            .p_queue_create_infos = &qinfo,

            .enabled_extension_count = @intCast(req_dev_exts.len),
            .pp_enabled_extension_names = &req_dev_exts,

            .p_enabled_features = &.{
                .sampler_anisotropy = .true,
            },
            // constCast needed here since .p_next is expecting a non-const *anyopaque,
            // but anonymous structs are const by default in Zig
            .p_next = @constCast(&vklib.PhysicalDeviceVulkan13Features{
                .p_next = @constCast(&vklib.PhysicalDeviceVulkan12Features{
                    .p_next = @constCast(&vklib.PhysicalDeviceVulkan11Features{
                        .shader_draw_parameters = .true,
                    }),
                    .descriptor_indexing = .true,
                    .shader_sampled_image_array_non_uniform_indexing = .true,
                    .descriptor_binding_variable_descriptor_count = .true,
                    .runtime_descriptor_array = .true,
                    .buffer_device_address = .true,
                }),
                .synchronization_2 = .true,
                .dynamic_rendering = .true,
            }),
        };

        const dev_hdl = try self.inst.createDevice(self.physical_device, &dev_info, null);
        if (dev_wrap == null) {
            dev_wrap = vklib.DeviceWrapper.load(dev_hdl, self.inst.wrapper.dispatch.vkGetDeviceProcAddr.?);
        }
        self.dev = vklib.DeviceProxy.init(dev_hdl, &dev_wrap.?);
    }

    pub fn findMemoryTypeIndex(self: *Vulkan, reqs: vklib.MemoryRequirements, flags: vklib.MemoryPropertyFlags) !u32 {
        const mem = self.device_mem;
        for (mem.memory_types[0..mem.memory_type_count], 0..) |mem_type, i| {
            if (reqs.memory_type_bits & (@as(u32, 1)) << @truncate(i) != 0 and mem_type.property_flags.contains(flags)) {
                return @truncate(i);
            }
        }
        return error.NoSuitableMemoryType;
    }

    pub fn allocImageMemory(self: *Vulkan, img: vklib.Image, flags: vklib.MemoryPropertyFlags) !VkDevMemInfo {
        const dev = self.dev;
        const mem_req = dev.getImageMemoryRequirements(img);
        const mem = try dev.allocateMemory(&.{
            .allocation_size = mem_req.size,
            .memory_type_index = try self.findMemoryTypeIndex(mem_req, flags),
        }, null);
        try dev.bindImageMemory(img, mem, 0);
        return .{
            .mem = mem,
            .size = mem_req.size,
        };
    }

    pub fn allocBufferMemory(self: *Vulkan, buf: vklib.Buffer, flags: vklib.MemoryPropertyFlags, flags_info: ?vklib.MemoryAllocateFlagsInfo) !VkDevMemInfo {
        const dev = self.dev;
        const mem_req = dev.getBufferMemoryRequirements(buf);
        const mem = try dev.allocateMemory(&.{
            .allocation_size = mem_req.size,
            .memory_type_index = try self.findMemoryTypeIndex(mem_req, flags),
            .p_next = if (flags_info) |*info| info else null,
        }, null);
        try dev.bindBufferMemory(buf, mem, 0);
        return .{
            .mem = mem,
            .size = mem_req.size,
        };
    }

    pub fn freeDevMemory(self: *Vulkan, mem: vklib.DeviceMemory) void {
        self.dev.freeMemory(mem, null);
    }
};

fn debugCallback(
    severity: vklib.DebugUtilsMessageSeverityFlagsEXT,
    msg_type: vklib.DebugUtilsMessageTypeFlagsEXT,
    data: ?*const vklib.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.c) vklib.Bool32 {
    const sev_str = if (severity.verbose_bit_ext) "verbose" else if (severity.info_bit_ext) "info" else if (severity.warning_bit_ext) "warning" else if (severity.error_bit_ext) "error" else "unknown";
    const type_str = if (msg_type.general_bit_ext) "general" else if (msg_type.validation_bit_ext) "validation" else if (msg_type.performance_bit_ext) "performance" else if (msg_type.device_address_binding_bit_ext) "device addr" else "unknown";
    const message: [*c]const u8 = if (data) |debug_data| debug_data.p_message else "NO MESSAGE!";
    std.debug.print("[{s}][{s}]. Message\n  {s}\n", .{ sev_str, type_str, message });
    return .false;
}

pub const VkSurface = struct {
    alloc: Allocator = undefined,
    vk: *Vulkan = undefined,
    surface: vklib.SurfaceKHR = undefined,
    default_extent: vklib.Extent2D = undefined,

    // options
    image_format: vklib.Format = vklib.Format.b8g8r8a8_srgb,
    image_color_space: vklib.ColorSpaceKHR = vklib.ColorSpaceKHR.srgb_nonlinear_khr,
    max_frames_in_flight: u32 = 2,

    surface_caps: vklib.SurfaceCapabilitiesKHR = undefined,
    swapchain: vklib.SwapchainKHR = .null_handle,
    swap_img: []vklib.Image = undefined,
    swap_view: []vklib.ImageView = undefined,
    _swap_view_count: usize = 0,
    depth_format: vklib.Format = undefined,
    depth_img: vklib.Image = undefined,
    depth_img_mem: vklib.DeviceMemory = undefined,
    depth_view: vklib.ImageView = undefined,
    image_acquired_semaphores: []vklib.Semaphore = undefined,
    fences: []vklib.Fence = undefined,
    render_complete_semaphores: []vklib.Semaphore = undefined,
    cmd_pool: vklib.CommandPool = undefined,
    cmd_buf: []vklib.CommandBuffer = undefined,

    pub fn init(self: *VkSurface, alloc: Allocator, vk: *Vulkan, default_extent: vklib.Extent2D, max_frames_in_flight: ?u32) !void {
        self.alloc = alloc;
        self.vk = vk;
        self.default_extent = default_extent;
        if (max_frames_in_flight) |m| self.max_frames_in_flight = m;

        try self.setSurfaceCaps();
        try self.createSwapchain();
        try self.createSwapImages();
        try self.setDepthFormat();
        try self.createDepthImage();
        try self.createDepthImgMem();
        try self.createDepthImgView();
        try self.createSyncObjs();
        try self.createCmdBufs();
    }

    pub fn setSurfaceCaps(self: *VkSurface) !void {
        self.surface_caps = try self.vk.inst.getPhysicalDeviceSurfaceCapabilitiesKHR(self.vk.physical_device, self.surface);
    }

    pub fn getExtent(self: *VkSurface) vklib.Extent2D {
        const caps = self.surface_caps;
        return if (caps.current_extent.width != 0xFFFF_FFFF) caps.current_extent else self.default_extent;
    }

    pub fn destroy(self: *VkSurface) void {
        const alloc = self.alloc;
        const vk = self.vk;
        const dev = vk.dev;

        dev.deviceWaitIdle() catch {
            std.debug.print("vkDeviceWaitIdle failed during VkSurface destroy\n", .{});
        };

        alloc.free(self.cmd_buf);
        dev.destroyCommandPool(self.cmd_pool, null);
        for (self.render_complete_semaphores) |semaphore| dev.destroySemaphore(semaphore, null);
        alloc.free(self.render_complete_semaphores);
        for (self.fences) |fence| dev.destroyFence(fence, null);
        alloc.free(self.fences);
        for (self.image_acquired_semaphores) |semaphore| dev.destroySemaphore(semaphore, null);
        alloc.free(self.image_acquired_semaphores);
        self.destroySwapStack();
        dev.destroySwapchainKHR(self.swapchain, null);
        alloc.free(self.swap_view);
        alloc.free(self.swap_img);
        vk.inst.destroySurfaceKHR(self.surface, null);
    }

    pub fn createSwapchain(self: *VkSurface) !void {
        var swapchain_create_info = vklib.SwapchainCreateInfoKHR{
            .surface = self.surface,
            .min_image_count = self.surface_caps.min_image_count,
            .image_format = self.image_format,
            .image_color_space = self.image_color_space,
            .image_extent = self.getExtent(),
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .pre_transform = .{ .identity_bit_khr = true },
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = .fifo_khr,
            .image_sharing_mode = .exclusive,
            .clipped = .true,
            .old_swapchain = self.swapchain,
        };
        self.swapchain = try self.vk.dev.createSwapchainKHR(&swapchain_create_info, null);
    }

    pub fn createSwapImages(self: *VkSurface) !void {
        const alloc = self.alloc;
        const vk = self.vk;
        const dev = vk.dev;
        const swapchain = self.swapchain;
        self.swap_img = try dev.getSwapchainImagesAllocKHR(swapchain, alloc);
        if (self.swap_img.len == 0) return error.NoSwapchainImages;
        self._swap_view_count = 0;
        self.swap_view = try alloc.alloc(vklib.ImageView, self.swap_img.len);
        for (self.swap_img, 0..) |img, i| {
            self._swap_view_count += 1;
            self.swap_view[i] = try dev.createImageView(&.{
                .image = img,
                .format = self.image_format,
                .view_type = .@"2d",
                .components = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .level_count = 1,
                    .layer_count = 1,
                    .base_array_layer = 0,
                    .base_mip_level = 0,
                },
            }, null);
        }
    }

    pub fn destroySwapImageViews(self: *VkSurface) void {
        const dev = self.vk.dev;
        const count = self._swap_view_count;
        if (count == 0) return;
        for (self.swap_view[0..count]) |view| dev.destroyImageView(view, null);
    }

    fn setDepthFormat(self: *VkSurface) !void {
        const vk = self.vk;
        const inst = vk.inst;
        const phys_dev = vk.physical_device;
        const depth_format_list = [_]vklib.Format{ .d32_sfloat_s8_uint, .d24_unorm_s8_uint };
        self.depth_format = for (depth_format_list) |format| {
            var format_properties = vklib.FormatProperties2{ .format_properties = undefined };
            inst.getPhysicalDeviceFormatProperties2(phys_dev, format, &format_properties);
            if (format_properties.format_properties.optimal_tiling_features.depth_stencil_attachment_bit) {
                break format;
            }
        } else @panic("Required depth format(s) not supported");

        // std.debug.print("Depth format: {t}", .{self.depth_format});
    }

    pub fn createDepthImage(self: *VkSurface) !void {
        const vk = self.vk;
        const dev = vk.dev;
        const extent = self.getExtent();
        self.depth_img = try dev.createImage(&.{
            .image_type = .@"2d",
            .format = self.depth_format,
            .extent = .{
                .width = extent.width,
                .height = extent.height,
                .depth = 1,
            },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .depth_stencil_attachment_bit = true },
            .initial_layout = .undefined,
            .sharing_mode = .exclusive,
        }, null);
    }

    pub fn createDepthImgMem(self: *VkSurface) !void {
        const vk = self.vk;
        self.depth_img_mem = (try vk.allocImageMemory(self.depth_img, .{ .device_local_bit = true })).mem;
    }

    pub fn createDepthImgView(self: *VkSurface) !void {
        const vk = self.vk;
        const dev = vk.dev;
        self.depth_view = try dev.createImageView(&.{
            .image = self.depth_img,
            .view_type = .@"2d",
            .format = self.depth_format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .depth_bit = true },
                .level_count = 1,
                .layer_count = 1,
                .base_array_layer = 0,
                .base_mip_level = 0,
            },
        }, null);
    }

    fn createSyncObjs(self: *VkSurface) !void {
        const alloc = self.alloc;
        const dev = self.vk.dev;
        const fence_create_info: vklib.FenceCreateInfo = .{ .flags = .{ .signaled_bit = true } };
        const max_frames = self.max_frames_in_flight;

        self.fences = try alloc.alloc(vklib.Fence, max_frames);
        self.image_acquired_semaphores = try alloc.alloc(vklib.Semaphore, max_frames);
        for (0..max_frames) |i| {
            self.fences[i] = try dev.createFence(&fence_create_info, null);
            self.image_acquired_semaphores[i] = try dev.createSemaphore(&.{}, null);
        }

        self.render_complete_semaphores = try alloc.alloc(vklib.Semaphore, self.swap_img.len);
        for (self.render_complete_semaphores) |*ptr| {
            ptr.* = try dev.createSemaphore(&.{}, null);
        }
    }

    fn createCmdBufs(self: *VkSurface) !void {
        const vk = self.vk;
        const dev = vk.dev;
        const max_frames = self.max_frames_in_flight;
        self.cmd_pool = try dev.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = vk.graphics_queue_family,
        }, null);
        self.cmd_buf = try self.alloc.alloc(vklib.CommandBuffer, max_frames);
        try dev.allocateCommandBuffers(&.{
            .level = .primary,
            .command_pool = self.cmd_pool,
            .command_buffer_count = max_frames,
        }, self.cmd_buf.ptr);
    }

    pub fn destroySwapStack(self: *VkSurface) void {
        const vk = self.vk;
        const dev = vk.dev;
        dev.destroyImageView(self.depth_view, null);
        vk.freeDevMemory(self.depth_img_mem);
        dev.destroyImage(self.depth_img, null);
        self.destroySwapImageViews();
    }

    pub fn updateSwapchain(self: *VkSurface, default_extent: ?vklib.Extent2D) !void {
        const dev = self.vk.dev;

        try dev.deviceWaitIdle();
        if (default_extent) |extent| self.default_extent = extent;
        try self.setSurfaceCaps();

        // cache old swapchain handle so we can destroy it after creating the new one
        const old_swapchain = self.swapchain;
        try self.createSwapchain();

        // destroy old swapchain and its associated resources
        self.destroySwapStack();
        dev.destroySwapchainKHR(old_swapchain, null);

        // recreate swap stack
        try self.createSwapImages();
        try self.createDepthImage();
        try self.createDepthImgMem();
        try self.createDepthImgView();
    }
};
