const std = @import("std");
pub const zon = @import("../build.zig.zon");

const win32 = @import("win32.zig");
const icon_mod = @import("icon.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);

    const w32 = win32.addWin32(b);
    const icon = icon_mod.addIcon(b, optimize);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/__root__.zig"),
        .target = target,
        .optimize = optimize,
        // .link_libc = true,
    });
    // mod.link_libcpp = true;
    mod.addOptions("build_options", build_options);
    w32.addImportToModule(mod);
    icon.addToModule(mod);

    const exe = b.addExecutable(.{
        .name = "rgui",
        .root_module = mod,
    });
    exe.subsystem = .windows;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the program");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
