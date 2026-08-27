// const sysinfo = @import("builtin");
// const std = @import("std");

pub const main = @import("__main__.zig").main;
// pub const std_options = impl.std_options;
// pub const std_options_debug_io = impl.std_options_debug_io;

const build_options = @import("build_options");
pub const version = build_options.version;
pub const app_name = "rgui";

pub const render = @import("render/__root__.zig");
pub const icon = @import("icon.zig");
pub const console = @import("console.zig");
