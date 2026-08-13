const std = @import("std");

const vk = @import("vulkan");
// const sdl = @import("sdl3");

pub const InstExts = std.ArrayList([*:0]const u8);
pub const LayerNames = std.ArrayList([*:0]const u8);

pub fn initInstExts(alloc: std.mem.Allocator) !InstExts {
    var inst_exts: InstExts = .empty;
    try inst_exts.append(alloc, vk.extensions.ext_debug_utils.name);
    return inst_exts;
}

pub fn deinitInstExts(alloc: std.mem.Allocator, inst_exts: *InstExts) void {
    inst_exts.deinit(alloc);
}

pub var inst_wrap: ?vk.InstanceWrapper = null;
pub var dev_wrap: ?vk.DeviceWrapper = null;

pub const Vulkan = struct {
    alloc: std.mem.Allocator = undefined,
    dispatcher: vk.BaseWrapper = undefined,

    // app_info: vk.ApplicationInfo = undefined,
    // inst_info: vk.InstanceCreateInfo = undefined,
    enabled_layers: LayerNames = .empty,

    // inst_hdl: vk.Instance = undefined,
    // _inst_wrap: *vk.InstanceWrapper = undefined,
    inst: vk.InstanceProxy = undefined,

    _debug_messenger: vk.DebugUtilsMessengerEXT = undefined,

    physical_device: vk.PhysicalDevice = undefined,
    device_mem: vk.PhysicalDeviceMemoryProperties = undefined,
    graphics_queue_family: u32 = undefined,

    qf_priorities: []f32 = undefined,
    req_dev_exts: [][*:0]const u8 = undefined,

    // _dev_wrap: *vk.DeviceWrapper = undefined,
    dev: vk.DeviceProxy = undefined,
    queue: vk.Queue = undefined,

    pub fn init(app_name: [*:0]const u8, inst_exts: InstExts, dispatcher: vk.BaseWrapper) !*Vulkan {
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

        const alloc = std.heap.page_allocator;
        const v = try alloc.create(Vulkan);
        v.* = Vulkan{
            .alloc = alloc,
            .dispatcher = dispatcher,
            .enabled_layers = try getEnabledLayers(alloc, dispatcher),
        };
        try v.initInst(app_name, inst_exts);
        try v.initVkDebugMsngr();
        try v.initPhysicalDev();
        try v.initGraphicsQueueFamily();
        try v.initDev();

        v.device_mem = v.inst.getPhysicalDeviceMemoryProperties(v.physical_device);
        v.queue = v.dev.getDeviceQueue(v.graphics_queue_family, 0);

        return v;
    }

    pub fn deinit(self: *Vulkan) void {
        // don't forget that these lines should be in reverse order of the places they are created in init
        const alloc = self.alloc;
        const inst = self.inst;
        const dev = self.dev;

        dev.destroyDevice(null);
        // alloc.destroy(self._dev_wrap);
        inst.destroyDebugUtilsMessengerEXT(self._debug_messenger, null);
        inst.destroyInstance(null);
        // alloc.destroy(self._inst_wrap);
        self.enabled_layers.deinit(alloc);
        alloc.destroy(self);
    }

    /// Requested layers that aren't installed would otherwise make
    /// vkCreateInstance fail with LayerNotPresent; only enable the
    /// ones actually available.
    fn getEnabledLayers(alloc: std.mem.Allocator, dispatch_wrapper: vk.BaseWrapper) !LayerNames {
        const wanted_layers = [_][*:0]const u8{ "VK_LAYER_KHRONOS_validation", "VK_LAYER_LUNARG_monitor" };

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
                if (std.mem.eql(u8, wanted_name, std.mem.sliceTo(&avail.layer_name, 0))) break true;
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
        const vk_api_ver = vk.makeApiVersion(0, 0, 0, 0);
        const inst_info: vk.InstanceCreateInfo = .{
            .p_application_info = &.{
                .p_application_name = app_name,
                .application_version = vk_api_ver.toU32(),
                .p_engine_name = app_name,
                .engine_version = vk_api_ver.toU32(),
                .api_version = vk.API_VERSION_1_4.toU32(),
            },

            .pp_enabled_layer_names = enabled_layers.items.ptr,
            .enabled_layer_count = @intCast(enabled_layers.items.len),

            .pp_enabled_extension_names = inst_exts.items.ptr,
            .enabled_extension_count = @intCast(inst_exts.items.len),
        };
        const inst_hdl = try self.dispatcher.createInstance(&inst_info, null);
        if (inst_wrap == null) {
            inst_wrap = vk.InstanceWrapper.load(inst_hdl, self.dispatcher.dispatch.vkGetInstanceProcAddr.?);
        }
        self.inst = vk.InstanceProxy.init(inst_hdl, &inst_wrap.?);
    }

    fn initVkDebugMsngr(self: *Vulkan) !void {
        const debug_info = vk.DebugUtilsMessengerCreateInfoEXT{
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

        const dev_props = inst.getPhysicalDeviceProperties(self.physical_device);
        std.debug.print("Device: {s}\n", .{dev_props.device_name});
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

        const qinfo = [_]vk.DeviceQueueCreateInfo{.{
            .queue_family_index = self.graphics_queue_family,
            .queue_count = qf_priorities.len,
            .p_queue_priorities = &qf_priorities,
        }};

        const req_dev_exts = [_][*:0]const u8{
            vk.extensions.khr_swapchain.name,
        };

        const dev_info: vk.DeviceCreateInfo = .{
            .queue_create_info_count = @intCast(qinfo.len),
            .p_queue_create_infos = &qinfo,

            .enabled_extension_count = @intCast(req_dev_exts.len),
            .pp_enabled_extension_names = &req_dev_exts,

            .p_enabled_features = &.{
                .sampler_anisotropy = .true,
            },
            // constCast needed here since .p_next is expecting a non-const *anyopaque,
            // but anonymous structs are const by default in Zig
            .p_next = @constCast(&vk.PhysicalDeviceVulkan13Features{
                .p_next = @constCast(&vk.PhysicalDeviceVulkan12Features{
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
            dev_wrap = vk.DeviceWrapper.load(dev_hdl, self.inst.wrapper.dispatch.vkGetDeviceProcAddr.?);
        }
        self.dev = vk.DeviceProxy.init(dev_hdl, &dev_wrap.?);
    }
};

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    msg_type: vk.DebugUtilsMessageTypeFlagsEXT,
    data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    const sev_str = if (severity.verbose_bit_ext) "verbose" else if (severity.info_bit_ext) "info" else if (severity.warning_bit_ext) "warning" else if (severity.error_bit_ext) "error" else "unknown";
    const type_str = if (msg_type.general_bit_ext) "general" else if (msg_type.validation_bit_ext) "validation" else if (msg_type.performance_bit_ext) "performance" else if (msg_type.device_address_binding_bit_ext) "device addr" else "unknown";
    const message: [*c]const u8 = if (data) |debug_data| debug_data.p_message else "NO MESSAGE!";
    std.debug.print("[{s}][{s}]. Message\n  {s}\n", .{ sev_str, type_str, message });
    return .false;
}
