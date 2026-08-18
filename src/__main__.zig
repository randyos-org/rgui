const std = @import("std");
const root = @import("root");

const sdl3 = @import("sdl3");
const console = @import("console.zig");
const icon = @import("icon/window.zig");
const sdlzig = @import("sdl.zig");
const vkzig = @import("vulkan.zig");
const sdl_vk_mod = @import("sdl_vk.zig");
const demo3d = @import("demo/demo_3d.zig").demo3d;
const demo2d = @import("demo/demo_2d.zig").demo2d;
const demoRaster = @import("demo/demo_raster.zig").demoRaster;

const app_name = root.app_name;
const version = root.version;

pub fn main(init: std.process.Init) !void {
    const arena_alloc = init.arena.allocator();
    console.maybeAllocDebugConsole(init, arena_alloc);
    std.debug.print(app_name ++ " v" ++ version ++ " Starting...\n", .{});

    var sdl_vk: sdl_vk_mod.SdlVk = .{};
    try sdl_vk.init(arena_alloc, app_name);
    defer sdl_vk.destroy();

    // create window
    var window: sdl_vk_mod.VkWindow = .{
        .alloc = arena_alloc,
        .sdlvk = &sdl_vk,
    };
    _ = try window.init(app_name ++ " v" ++ version, 1280, 720);
    defer window.destroy();
    icon.setWindowIcon(&window);

    // now let's start drawing stuff
    // try demo3d(arena_alloc, init.io, &window);
    // try demo2d(arena_alloc, init.io, &window);
    try demoRaster(arena_alloc, init.io, &window);

    // var event: sdl3.SDL_Event = undefined;
    // outer: while (true) {
    //     // loop over messages in the queue; inner while breaks when all messages drained
    //     while (sdl3.SDL_PollEvent(&event)) {
    //         switch (event.type) {
    //             sdl3.SDL_EVENT_QUIT => break :outer,
    //             else => {},
    //         }
    //     }
    // }
    std.debug.print(app_name ++ " v" ++ version ++ " exiting gracefully\n", .{});
}
