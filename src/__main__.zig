const std = @import("std");
const root = @import("root");

const console = @import("console.zig");
const icon = @import("icon/window.zig");
const sdl = @import("sdl.zig");
const sdl3 = @import("sdl3");
const vk_mod = @import("vulkan.zig");
const sdl_vk = @import("sdl_vk.zig");

const app_name = root.app_name;
const version = root.version;

pub fn main(init: std.process.Init) !void {
    const arena_alloc = init.arena.allocator();
    console.maybeAllocDebugConsole(init, arena_alloc);
    std.debug.print(app_name ++ " v" ++ version ++ " Starting...\n", .{});

    try sdl.initSdl();
    defer sdl.deinitSdl();

    var inst_exts = try vk_mod.initInstExts(arena_alloc);
    defer vk_mod.deinitInstExts(arena_alloc, &inst_exts);

    try sdl_vk.initSdlVk();
    defer sdl_vk.deinitSdlVk();
    const dispatch_wrapper = try sdl_vk.loadSdlBaseWrapper();
    try sdl_vk.addSdlInstExts(arena_alloc, &inst_exts);

    var vk = try vk_mod.Vulkan.init(app_name, inst_exts, dispatch_wrapper);
    defer vk.deinit();

    // make sure the vulkan object is valid
    try sdl_vk.checkPresentationSupport(vk);

    // create window
    const window = try sdl_vk.createVkWindow(app_name ++ " v" ++ version, 1280, 720);
    defer sdl_vk.deinitVkWindow(window);
    icon.setWindowIcon(window);
    var event: sdl3.SDL_Event = undefined;
    while (true) {
        // loop over messages in the queue; inner while breaks when all messages drained
        while (sdl3.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl3.SDL_EVENT_QUIT => return,
                else => {},
            }
        }
    }
}

fn loadBaseWrapper() !vk_mod.BaseWrapper {
    if (sdl.SDL_Vulkan_GetVkGetInstanceProcAddr()) |ptr| {
        return vk_mod.BaseWrapper.load(@as(vk_mod.PfnGetInstanceProcAddr, @ptrCast(ptr)));
    }
    return error.LoadBaseWrapperFailed;
}
