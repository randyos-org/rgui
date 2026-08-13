const sdl3 = @import("sdl3");

pub fn initSdl() !void {
    if (!sdl3.SDL_Init(sdl3.SDL_INIT_VIDEO)) return error.SdlInitFailed;
}

pub fn deinitSdl() void {
    sdl3.SDL_Quit();
}
