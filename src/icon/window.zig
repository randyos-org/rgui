// const rl = @import("raylib");

const icon_png = @embedFile("icon.png"); // imported from build dir

/// setWindowIcon applies the embedded icon to the current window. Must be
/// called after the window is created. raylib copies the pixels to the OS
/// immediately, so the image can be unloaded right away.
pub fn setWindowIcon() void {
    // const img = rl.LoadImageFromMemory(".png", icon_png, @intCast(icon_png.len));
    // if (img.data == null) return;
    // defer rl.UnloadImage(img);
    // rl.SetWindowIcon(img);
}
