const sdl3 = @import("sdl3");

pub fn initSdl() !void {
    if (!sdl3.SDL_Init(sdl3.SDL_INIT_VIDEO)) return error.SdlInitFailed;
}

pub fn destroySdl() void {
    sdl3.SDL_Quit();
}

pub fn getTickSecs() f64 {
    return @as(f64, @floatFromInt(sdl3.SDL_GetTicks())) / 1000.0;
}
