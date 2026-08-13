const std = @import("std");

pub const Icon = struct {
    rc_build_path: std.Build.LazyPath,
    png_build_path: std.Build.LazyPath,
    png_name: []const u8,
    raw_build_path: std.Build.LazyPath,
    raw_name: []const u8,

    pub fn addToModule(self: *const Icon, mod: *std.Build.Module) void {
        mod.addWin32ResourceFile(.{ .file = self.rc_build_path });
        mod.addAnonymousImport(self.png_name, .{ .root_source_file = self.png_build_path });
        mod.addAnonymousImport(self.raw_name, .{ .root_source_file = self.raw_build_path });
    }
};

pub fn addIcon(b: *std.Build, optimize: std.builtin.OptimizeMode) Icon {
    // genicon draws the app icon and hands its outputs straight into the
    // build graph as LazyPaths - icon.png/icon.ico are never written into
    // the repo tree, so there's nothing to gitignore or accidentally
    // commit. See src/icon/__main__.zig. Pure Zig (std-only
    // PNG encoder, no image library) - still targets b.graph.host, not
    // whatever `-Dtarget=` the app is being cross-compiled for, because it
    // runs during the build itself (its output feeds icon.rc/the embedded
    // PNG) and must be executable on the machine doing the build.
    const png_name = "icon.png";
    const ico_name = "icon.ico";
    const rc_name = "icon.rc";
    const raw_name = "icon.rgba";

    const mod = b.createModule(.{
        .root_source_file = b.path("src/icon/__main__.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    // Source artwork genicon decodes and downsamples into the generated
    // icon sizes - lives in assets/ (outside src/icon/'s module root, so it
    // has to come in as a registered import rather than a relative
    // @embedFile) so the build doesn't depend on files outside this repo.
    mod.addAnonymousImport("avatar.png", .{
        .root_source_file = b.path("assets/randyos-avatar-alphabg.png"),
    });
    const exe = b.addExecutable(.{
        .name = "genicon",
        .root_module = mod,
    });
    const run = b.addRunArtifact(exe);

    // record the paths of the generated output files so the build graph knows about them
    const png_build_path = run.addOutputFileArg(png_name);
    const ico_build_path = run.addOutputFileArg(ico_name);
    const raw_build_path = run.addOutputFileArg(raw_name);

    // The .rc ICON directive references "icon.ico" by a bare name, resolved
    // relative to the .rc file's own directory - so the generated icon.ico
    // needs to sit next to a (likewise generated) icon.rc, not just exist
    // somewhere else in the cache under its own path.
    const rc_wf = b.addWriteFiles();
    const rc_build_path = rc_wf.add(rc_name, "1 ICON \"" ++ ico_name ++ "\"\n");
    _ = rc_wf.addCopyFile(ico_build_path, ico_name);

    // `zig build icon` - not needed for the app build itself (that already
    // depends on genicon's outputs above), but installs copies to zig-out/
    // so a human can open them after tweaking the drawing code.
    const icon_step = b.step("icon", "Regenerate icon.png/icon.ico into zig-out/ for inspection");
    icon_step.dependOn(&b.addInstallFileWithDir(png_build_path, .prefix, png_name).step);
    icon_step.dependOn(&b.addInstallFileWithDir(ico_build_path, .prefix, ico_name).step);
    icon_step.dependOn(&b.addInstallFileWithDir(raw_build_path, .prefix, raw_name).step);

    return .{
        .rc_build_path = rc_build_path,
        .png_build_path = png_build_path,
        .png_name = png_name,
        .raw_build_path = raw_build_path,
        .raw_name = raw_name,
    };
}
