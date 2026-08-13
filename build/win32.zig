const std = @import("std");

const utils = @import("utils.zig");

pub fn addWin32(b: *std.Build) utils.ZigModule {
    return .{ .mod = b.dependency("win32", .{}).module("win32"), .name = "win32" };
}
