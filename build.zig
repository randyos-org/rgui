//! Build script entry point
pub const buildroot = @import("build/__root__.zig").build;
pub const build = buildroot.build;
pub const zon = buildroot.zon;
