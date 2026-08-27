const Build = @import("rstd").buildutils.Build;

/// A single font file vendored via a build.zig.zon dependency instead of
/// being tracked in this repo. The dependency itself has no build.zig -
/// it's fetched purely as data, and `addFont` below just lifts one file
/// out of it.
pub const Font = struct {
    /// Name of the dependency in build.zig.zon.
    dep_name: []const u8,
    /// Path of the font file inside the fetched dependency.
    src_path: []const u8,
    /// Filename to install it under in zig-out/fonts/.
    dest_name: ?[]const u8 = null,
};

/// The "Mono" variant keeps icon glyphs exactly one cell wide, which
/// matters for a monospace glyph atlas - the plain "NerdFont" variant
/// allows double-width icons and "NerdFontPropo" isn't monospaced at all.
pub const jetbrains_mono_nerd_font: Font = .{
    .dep_name = "nerd_font_jetbrains_mono",
    .src_path = "JetBrainsMonoNerdFontMono-Regular.ttf",
    // .dest_name = "JetBrainsMonoNerdFontMono-Regular.ttf",
};

pub const commit_mono_nerd_font: Font = .{
    .dep_name = "nerd_font_commit_mono",
    .src_path = "CommitMonoNerdFontMono-Regular.otf",
    // .dest_name = "CommitMonoNerdFontMono-Regular.otf",
};

pub const atkinson_hyperlegible_mono_nerd_font: Font = .{
    .dep_name = "nerd_font_atkinson_hyperlegible_mono",
    // The upstream release's internal font name is "Atkynson Mono", not
    // "Atkinson Hyperlegible Mono" -- that's what actually ships in the tarball.
    .src_path = "AtkynsonMonoNerdFontMono-Regular.otf",
    // .dest_name = "AtkinsonHyperlegibleMonoNerdFontMono-Regular.otf",
};

pub const arimo_nerd_font: Font = .{
    .dep_name = "nerd_font_arimo",
    .src_path = "ArimoNerdFont-Regular.ttf",
    // .dest_name = "ArimoNerdFont-Regular.ttf",
};

pub const ubuntu_nerd_font: Font = .{
    .dep_name = "nerd_font_ubuntu",
    .src_path = "UbuntuNerdFont-Regular.ttf",
    // .dest_name = "UbuntuNerdFont-Regular.ttf",
};

/// Installs `font` into zig-out/fonts/, fetched from its build.zig.zon
/// dependency rather than tracked in the repo.
pub fn addFont(b: *Build, font: Font) void {
    const dep = b.dependency(font.dep_name, .{});
    const dest_name = if (font.dest_name) |name| name else font.src_path;
    const install = b.addInstallFileWithDir(dep.path(font.src_path), .{ .custom = "fonts" }, dest_name);
    b.getInstallStep().dependOn(&install.step);
    // return &install.step;
}

pub fn addAllFonts(b: *Build) void {
    addFont(b, jetbrains_mono_nerd_font);
    addFont(b, commit_mono_nerd_font);
    addFont(b, atkinson_hyperlegible_mono_nerd_font);
    addFont(b, arimo_nerd_font);
    addFont(b, ubuntu_nerd_font);
}
