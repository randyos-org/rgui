const std = @import("std");

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

/// Installs `font` into zig-out/fonts/, fetched from its build.zig.zon
/// dependency rather than tracked in the repo.
pub fn addFont(b: *std.Build, font: Font) void {
    const dep = b.dependency(font.dep_name, .{});
    const dest_name = if (font.dest_name) |name| name else font.src_path;
    const install = b.addInstallFileWithDir(dep.path(font.src_path), .{ .custom = "fonts" }, dest_name);
    b.getInstallStep().dependOn(&install.step);
    // return &install.step;
}
