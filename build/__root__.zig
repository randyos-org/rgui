const std = @import("std");

pub const zon = @import("../build.zig.zon");
pub const rstd = @import("rstd");

const vulkan_mod = @import("vulkan.zig");
const fonts_mod = @import("fonts.zig");

const rstdbuild = rstd.buildutils;
const Build = rstdbuild.Build;

pub fn build(b: *std.Build) !void {
    const target = rstdbuild.getTarget(b);
    const optimize = rstdbuild.getOptimize(b);
    const docs = rstdbuild.addDocs(b);

    const build_options = rstdbuild.addBuildOptionsModule(b, @tagName(zon.name), zon.version);

    const icon = try rstdbuild.Icon.addGenIconStep(
        b,
        optimize,
        b.path("src/logo/randyos-avatar-alphabg.png"),
        "icon.png",
        "icon.ico",
        "icon.rc",
        "icon.rgba",
    );
    const vulkan = vulkan_mod.addVulkan(b);
    // const slang = slang_mod.addSlang(b, "shaders/shader.slang", "shader_module");
    fonts_mod.addFont(b, fonts_mod.jetbrains_mono_nerd_font);
    fonts_mod.addFont(b, fonts_mod.commit_mono_nerd_font);
    fonts_mod.addFont(b, fonts_mod.atkinson_hyperlegible_mono_nerd_font);
    fonts_mod.addFont(b, fonts_mod.arimo_nerd_font);
    fonts_mod.addFont(b, fonts_mod.ubuntu_nerd_font);
    const rstd_mod = try rstdbuild.addRstd(b, target, docs);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/__root__.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    rstdbuild.addBuildOptsModToModule(build_options, mod);
    rstdbuild.addWin32ToModIfWinTgt(b, target, mod);
    icon.addToModule(mod);
    rstd_mod.addImportToModule(mod);
    vulkan.addImportToModule(mod);
    // slang.addToModule(mod);

    const exe = b.addExecutable(.{
        .name = "rgui",
        .root_module = mod,
    });
    exe.subsystem = .windows;
    docs.addCompileStepDocs(b, exe, "rgui");
    b.installArtifact(exe);
    try rstdbuild.addLinuxDesktopFile(b, target, icon.png_build_path, "rgui", "rgui", zon.version);

    const run_cmd = b.addRunArtifact(exe);
    const run_cmd_step = &run_cmd.step;
    run_cmd_step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the program");
    run_step.dependOn(run_cmd_step);
}
