const std = @import("std");

const sdl3 = @import("sdl3");
const vk = @import("vulkan");
const vkmod = @import("vulkan.zig");
const InstExts = vkmod.InstExts;
const Vulkan = vkmod.Vulkan;

pub fn initSdlVk() !void {
    if (!sdl3.SDL_Vulkan_LoadLibrary(null)) return error.SdlLoadVulkanFailed;
}

pub fn deinitSdlVk() void {
    sdl3.SDL_Vulkan_UnloadLibrary();
}

pub fn addSdlInstExts(alloc: std.mem.Allocator, inst_exts: *InstExts) !void {
    var inst_ext_count: u32 = undefined;
    try inst_exts.appendSlice(alloc, @ptrCast(sdl3.SDL_Vulkan_GetInstanceExtensions(&inst_ext_count)[0..inst_ext_count]));
}

pub fn loadSdlBaseWrapper() !vk.BaseWrapper {
    if (sdl3.SDL_Vulkan_GetVkGetInstanceProcAddr()) |ptr| {
        return vk.BaseWrapper.load(@as(vk.PfnGetInstanceProcAddr, @ptrCast(ptr)));
    }
    return error.LoadBaseWrapperFailed;
}

pub fn checkPresentationSupport(v: *const Vulkan) !void {
    const vk_inst = v.inst;
    const phys_dev = v.physical_device;
    const queue_family = v.graphics_queue_family;
    if (!sdl3.SDL_Vulkan_GetPresentationSupport(
        @as(sdl3.VkInstance, @ptrFromInt(@intFromEnum(vk_inst.handle))),
        @as(sdl3.VkPhysicalDevice, @ptrFromInt(@intFromEnum(phys_dev))),
        queue_family,
    )) {
        return error.NoVkPresentationSupport;
    }
}

pub fn createVkWindow(window_title: [*:0]const u8, width: u32, height: u32) !*sdl3.SDL_Window {
    return sdl3.SDL_CreateWindow(
        window_title,
        @intCast(width),
        @intCast(height),
        sdl3.SDL_WINDOW_VULKAN | sdl3.SDL_WINDOW_RESIZABLE,
    ) orelse return error.WindowCreateFailed;
}

pub fn deinitVkWindow(window: *sdl3.SDL_Window) void {
    sdl3.SDL_DestroyWindow(window);
}

pub fn getWindowSize(window: *sdl3.SDL_Window) vk.Extent2D {
    var width: u32 = 0;
    var height: u32 = 0;
    _ = sdl3.SDL_GetWindowSize(window, &width, &height);
    return .{ .width = width, .height = height };
}
