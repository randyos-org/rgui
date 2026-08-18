const std = @import("std");
pub const zon = @import("../build.zig.zon");

const win32 = @import("win32.zig");
const icon_mod = @import("icon.zig");
const vulkan_mod = @import("vulkan.zig");
const sdl_mod = @import("sdl.zig");

// demo stuff
const zmath_mod = @import("demo/zmath.zig");
const ktx_mod = @import("demo/ktx.zig");
const slang_mod = @import("demo/slang.zig");
const freetype_mod = @import("demo/freetype.zig");
const harfbuzz_mod = @import("demo/harfbuzz.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);

    const w32 = win32.addWin32(b);
    const icon = icon_mod.addIcon(b, optimize);
    const vulkan = vulkan_mod.addVulkan(b);
    const sdl = sdl_mod.addSdl3(b, target, optimize);

    // demo stuff
    const zm = zmath_mod.addZmath(b);
    const ktx = ktx_mod.addKtx(b, target, optimize);
    const slang = slang_mod.addSlang(b, "shaders/shader.slang", "shader_module");
    const slang_2d = slang_mod.addSlang(b, "shaders/shader_2d.slang", "shader_2d_module");
    const slang_2d_text = slang_mod.addSlang(b, "shaders/shader_2d_text.slang", "shader_2d_text_module");
    const slang_raster = slang_mod.addSlang(b, "shaders/shader_raster.slang", "shader_raster_module");
    const freetype = freetype_mod.addFreetype(b, target, optimize);
    const harfbuzz = harfbuzz_mod.addHarfbuzz(b, target, optimize);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/__root__.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", build_options);
    w32.addImportToModule(mod);
    icon.addToModule(mod);
    vulkan.addImportToModule(mod);
    sdl.addImportToModule(mod);

    // demo stuff
    zm.addImportToModule(mod);
    ktx.addImportToModule(mod);
    slang.addToModule(mod);
    slang_2d.addToModule(mod);
    slang_2d_text.addToModule(mod);
    slang_raster.addToModule(mod);
    freetype.addImportToModule(mod);
    harfbuzz.addImportToModule(mod);

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
