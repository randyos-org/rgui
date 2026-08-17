// const rl = @import("raylib");
const sdl = @import("sdl3");
const sdlvk = @import("../sdl_vk.zig");

// 32x32 raw RGBA8 pixels (no PNG wrapper), generated at build time - see
// src/icon/__main__.zig. SDL has no built-in PNG decoder and this project
// has no image library dependency, so icon.png itself can't be loaded here.
const icon_rgba = @embedFile("icon.rgba");

/// setWindowIcon applies the embedded icon to the current window. Must be
/// called after the window is created.
pub fn setWindowIcon(window: *sdlvk.VkWindow) void {
    const img = sdl.SDL_CreateSurfaceFrom(
        32,
        32,
        @intCast(sdl.SDL_PIXELFORMAT_RGBA32),
        @ptrCast(@constCast(icon_rgba.ptr)),
        32 * 4,
    );
    defer sdl.SDL_DestroySurface(img);
    _ = sdl.SDL_SetWindowIcon(window.window, img);
}
