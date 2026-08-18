const std = @import("std");

const utils = @import("../utils.zig");

pub fn addFreetype(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) utils.ZigModule {
    const dep = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .@"enable-libpng" = true,
    });
    return .{
        .mod = dep.module("freetype"),
        .name = "freetype",
        .clink = .{ .lib = dep.artifact("freetype") },
    };
}
