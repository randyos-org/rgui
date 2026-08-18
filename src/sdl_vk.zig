const std = @import("std");

// external libraries
const sdl3 = @import("sdl3");
const vklib = @import("vulkan");
// zig wrappers
const sdlzig = @import("sdl.zig");
const vkzig = @import("vulkan.zig");

const InstExts = vkzig.InstExts;
const Vulkan = vkzig.Vulkan;
const VkSurface = vkzig.VkSurface;

pub const SdlVk = struct {
    // alloc: std.mem.Allocator,
    vk: Vulkan = .{},
    // inst_exts: InstExts = undefined,
    base_wrapper: vklib.BaseWrapper = undefined,

    pub fn init(self: *SdlVk, alloc: std.mem.Allocator, app_name: [*:0]const u8) !void {
        // const alloc = self.alloc;

        try sdlzig.initSdl();
        if (!sdl3.SDL_Vulkan_LoadLibrary(null)) return error.SdlLoadVulkanFailed;
        try self.loadSdlBaseWrapper();

        var inst_exts = try vkzig.initInstExts(alloc);
        defer vkzig.destroyInstExts(alloc, &inst_exts);
        try self.addSdlInstExts(alloc, &inst_exts);

        try self.vk.init(alloc, app_name, inst_exts, self.base_wrapper);

        // make sure the vulkan object is valid
        try self.checkPresentationSupport();
    }

    pub fn destroy(self: *SdlVk) void {
        // const alloc = self.alloc;

        self.vk.destroy();
        // vkzig.destroyInstExts(alloc, &self.inst_exts);
        sdl3.SDL_Vulkan_UnloadLibrary();
        sdlzig.destroySdl();
        // alloc.destroy(self);
    }

    fn addSdlInstExts(self: *SdlVk, alloc: std.mem.Allocator, inst_exts: *InstExts) !void {
        _ = self;
        var inst_ext_count: u32 = undefined;
        try inst_exts.appendSlice(alloc, @ptrCast(sdl3.SDL_Vulkan_GetInstanceExtensions(&inst_ext_count)[0..inst_ext_count]));
    }

    fn loadSdlBaseWrapper(self: *SdlVk) !void {
        if (sdl3.SDL_Vulkan_GetVkGetInstanceProcAddr()) |ptr| {
            self.base_wrapper = vklib.BaseWrapper.load(@as(vklib.PfnGetInstanceProcAddr, @ptrCast(ptr)));
        } else {
            return error.LoadBaseWrapperFailed;
        }
    }

    fn checkPresentationSupport(self: *const SdlVk) !void {
        const vk = self.vk;
        const vk_inst = vk.inst;
        const phys_dev = vk.physical_device;
        const queue_family = vk.graphics_queue_family;
        if (!sdl3.SDL_Vulkan_GetPresentationSupport(
            @as(sdl3.VkInstance, @ptrFromInt(@intFromEnum(vk_inst.handle))),
            @as(sdl3.VkPhysicalDevice, @ptrFromInt(@intFromEnum(phys_dev))),
            queue_family,
        )) {
            return error.NoVkPresentationSupport;
        }
    }
};

pub const VkWindow = struct {
    alloc: std.mem.Allocator,
    sdlvk: *SdlVk,
    window: *sdl3.SDL_Window = undefined,
    surface: VkSurface = .{},
    max_frames_in_flight: u32 = 2,

    live_repaint_ctx: ?*anyopaque = null,
    live_repaint_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn init(self: *VkWindow, window_title: [*:0]const u8, width: u32, height: u32) !*VkWindow {
        try self.createWindow(window_title, width, height);
        try self.createSurface();
        return self;
    }

    pub fn setLiveRepaint(self: *VkWindow, ctx: *anyopaque, callback: *const fn (ctx: *anyopaque) void) void {
        self.live_repaint_ctx = ctx;
        self.live_repaint_fn = callback;
        _ = sdl3.SDL_AddEventWatch(&liveRepaintWatch, self);
    }

    pub fn clearLiveRepaint(self: *VkWindow) void {
        sdl3.SDL_RemoveEventWatch(&liveRepaintWatch, self);
        self.live_repaint_ctx = null;
        self.live_repaint_fn = null;
    }

    fn liveRepaintWatch(userdata: ?*anyopaque, event: [*c]sdl3.SDL_Event) callconv(.c) bool {
        const self: *VkWindow = @ptrCast(@alignCast(userdata.?));
        if (event.*.type == sdl3.SDL_EVENT_WINDOW_EXPOSED) {
            if (self.live_repaint_fn) |f| f(self.live_repaint_ctx.?);
        }
        return true;
    }

    pub fn destroy(self: *VkWindow) void {
        self.surface.destroy();
        sdl3.SDL_DestroyWindow(self.window);
    }

    pub fn getWindowSize(self: *VkWindow) vklib.Extent2D {
        var width: c_int = 0;
        var height: c_int = 0;
        _ = sdl3.SDL_GetWindowSize(self.window, &width, &height);
        return .{ .width = @intCast(width), .height = @intCast(height) };
    }

    fn createWindow(self: *VkWindow, window_title: [*:0]const u8, width: u32, height: u32) !void {
        self.window = sdl3.SDL_CreateWindow(
            window_title,
            @intCast(width),
            @intCast(height),
            sdl3.SDL_WINDOW_VULKAN | sdl3.SDL_WINDOW_RESIZABLE,
        ) orelse return error.WindowCreateFailed;
    }

    fn createSurface(self: *VkWindow) !void {
        const vk = &self.sdlvk.vk;
        const inst = vk.inst;

        if (!sdl3.SDL_Vulkan_CreateSurface(self.window, @ptrFromInt(@intFromEnum(inst.handle)), null, @ptrCast(&self.surface.surface))) {
            return error.SurfaceCreationFailed;
        }
        try self.surface.init(self.alloc, vk, self.getWindowSize(), self.max_frames_in_flight);
    }
};
