const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");
const win32 = @import("win32");

const console = @import("console.zig");
const icon = @import("icon.zig");
const randygl = @import("zep/__root__.zig");

const app_name = root.app_name;
const version = root.version;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const debug_console = console.maybeAllocDebugConsole(init);
    if (!debug_console) {
        try console.redirectStdioToFile(allocator, "test.log");
    }
    std.debug.print(app_name ++ " v" ++ version ++ " Starting...\n", .{});

    if (true) {
        const shader_smoke_test = @import("render/vulkan/shader_smoke_test.zig");
        shader_smoke_test.run(allocator) catch |err| {
            std.debug.print("shader_smoke_test.run failed: {t}\n", .{err});
            return err;
        };
        return;
    }

    var context = try randygl.RandyGL.create(allocator, init.environ_map, "rgui-hello", 1, false);
    defer context.destroy();
    // defer randygl.destroyDefaultFont();

    const renderer = try context.createWindowRenderer(1280, 720, app_name ++ " v" ++ version, .default, .default, icon.data);
    defer renderer.destroy();

    const window = renderer.getWindow();

    // now let's start drawing stuff
    renderer.setClearColor(randygl.rgba(30, 30, 30, 255));
    outer: while (true) {
        const events = try window.getEvents();
        for (events) |*event| {
            switch (event.*) {
                .window_close => break :outer,
                else => {},
            }
        }

        //     const ready = try renderer.nextFrame();
        //     if (!ready) {
        //         try std.Io.sleep(randygl.util.io, .fromSeconds(1), .awake);
        //         continue;
        //     }

        //     try renderer.moveTo(400, 100);
        //     try renderer.lineTo(600, 400);
        //     try renderer.lineTo(200, 400);
        //     try renderer.close();
        //     try renderer.fill(&randygl.color(255, 0, 0, 255), null);

        //     try renderer.text("Hello, triangle!", 400, 450, .{ .horizontal = .center }, null, 48);
        //     try renderer.fill(&randygl.color(230, 230, 230, 255), null);
        //     _ = try renderer.render();
    }

    std.debug.print(app_name ++ " v" ++ version ++ " exiting gracefully\n", .{});
}
