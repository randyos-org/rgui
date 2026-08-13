const std = @import("std");

const utils = @import("utils.zig");

pub fn addKtx(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) utils.ZigModule {
    return .{ .mod = b.dependency("mr_ktx2", .{
        .target = target,
        .optimize = optimize,
    }).module("mr_ktx2"), .name = "ktx" };
}
