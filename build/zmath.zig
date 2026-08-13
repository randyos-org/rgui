const std = @import("std");

const utils = @import("utils.zig");

pub fn addZmath(b: *std.Build) utils.ZigModule {
    return .{ .mod = b.dependency("zmath", .{}).module("root"), .name = "zmath" };
}
