const std = @import("std");

const utils = @import("utils.zig");

pub fn addSdl3(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) utils.ZigModule {
    return .{ .mod = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    }).module("sdl3"), .name = "sdl3" };
}
