const build_options = @import("build_options");

const std = @import("std");
const console = @import("console.zig");
const icon = @import("icon/window.zig");

pub const version = build_options.version;

pub fn main(init: std.process.Init) !void {
    const persistent_allocator = init.arena.allocator();
    console.maybeAllocDebugConsole(init, persistent_allocator);
    std.debug.print("rgui v" ++ version ++ " Starting...\n", .{});

    // rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    // rl.InitWindow(1200, 800, "rgui v" ++ version);
    // defer rl.CloseWindow();
    icon.setWindowIcon();
}
