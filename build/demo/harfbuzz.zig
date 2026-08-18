const std = @import("std");

const utils = @import("../utils.zig");

pub fn addHarfbuzz(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) utils.ZigModule {
    const dep = b.dependency("harfbuzz", .{
        .target = target,
        .optimize = optimize,
    });
    return .{
        .mod = dep.module("harfbuzz"),
        .name = "harfbuzz",
        .clink = .{ .lib = dep.artifact("harfbuzz") },
    };
}
