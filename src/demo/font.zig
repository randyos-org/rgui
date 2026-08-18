const std = @import("std");

const freetype = @import("freetype");
const harfbuzz = @import("harfbuzz");

/// JetBrains Mono (OFL-licensed, see assets/JetBrainsMono-OFL.txt) - a
/// placeholder default font, loaded at runtime like the 3D demo's other
/// assets (obj/ktx files) rather than @embedFile'd, so swapping fonts
/// doesn't require a rebuild.
pub const default_font_path = "assets/JetBrainsMono-Regular.ttf";

pub fn loadFontFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
}

pub const ShapedGlyph = struct {
    glyph_index: u32,
    x_advance: f32,
    x_offset: f32,
    y_offset: f32,
};

pub const Bitmap = struct {
    width: u32,
    height: u32,
    /// Offsets from the pen position to the bitmap's top-left corner.
    left: i32,
    top: i32,
    /// Row-major 8bpp grayscale coverage, `pitch` bytes per row.
    pixels: []const u8,
    pitch: u32,
};

pub const Font = struct {
    ft_library: freetype.Library,
    ft_face: freetype.Face,
    hb_font: harfbuzz.Font,
    pixel_size: u32,

    pub fn init(font_data: []const u8, pixel_size: u32) !Font {
        var ft_library = try freetype.Library.init();
        errdefer ft_library.deinit();

        var ft_face = try ft_library.initMemoryFace(font_data, 0);
        errdefer ft_face.deinit();
        try ft_face.selectCharmap(.unicode);
        try ft_face.setCharSize(0, @intCast(pixel_size * 64), 0, 0);

        var hb_font = try harfbuzz.freetype.createFont(ft_face.handle);
        errdefer hb_font.destroy();
        harfbuzz.freetype.setFontFuncs(hb_font);
        hb_font.setScale(@intCast(pixel_size * 64), @intCast(pixel_size * 64));

        return .{
            .ft_library = ft_library,
            .ft_face = ft_face,
            .hb_font = hb_font,
            .pixel_size = pixel_size,
        };
    }

    pub fn deinit(self: *Font) void {
        self.hb_font.destroy();
        self.ft_face.deinit();
        self.ft_library.deinit();
    }

    /// Shapes `text` (plain Latin assumed) into positioned glyphs, in
    /// pixel units. Caller owns the returned slice.
    pub fn shape(self: *Font, alloc: std.mem.Allocator, text: []const u8) ![]ShapedGlyph {
        var buf = try harfbuzz.Buffer.create();
        defer buf.destroy();

        buf.addUTF8(text);
        buf.setDirection(.ltr);
        buf.setScript(.latin);
        buf.setLanguage(harfbuzz.Language.fromString("en"));

        harfbuzz.shape(self.hb_font, buf, null);

        const infos = buf.getGlyphInfos();
        const positions = buf.getGlyphPositions() orelse return &.{};

        const glyphs = try alloc.alloc(ShapedGlyph, infos.len);
        for (infos, positions, 0..) |info, pos, i| {
            glyphs[i] = .{
                .glyph_index = info.codepoint,
                .x_advance = @as(f32, @floatFromInt(pos.x_advance)) / 64.0,
                .x_offset = @as(f32, @floatFromInt(pos.x_offset)) / 64.0,
                .y_offset = @as(f32, @floatFromInt(pos.y_offset)) / 64.0,
            };
        }
        return glyphs;
    }

    /// Rasterizes `glyph_index` (a font glyph index, e.g. from `shape`,
    /// *not* a Unicode codepoint) to an 8bpp grayscale coverage bitmap.
    /// The returned bitmap borrows the face's glyph slot and is only valid
    /// until the next load/render call on this Font.
    pub fn rasterize(self: *Font, glyph_index: u32) !Bitmap {
        try self.ft_face.loadGlyph(glyph_index, .{ .render = true });
        const slot = self.ft_face.handle.*.glyph;
        const bitmap = slot.*.bitmap;
        const row_bytes: usize = @intCast(@abs(bitmap.pitch));
        const pixels: []const u8 = if (bitmap.rows == 0)
            &.{}
        else
            bitmap.buffer[0 .. row_bytes * bitmap.rows];

        return .{
            .width = bitmap.width,
            .height = bitmap.rows,
            .left = slot.*.bitmap_left,
            .top = slot.*.bitmap_top,
            .pixels = pixels,
            .pitch = @intCast(row_bytes),
        };
    }
};

/// Where a glyph's rasterized coverage lives in the atlas texture, plus
/// enough metrics to place it relative to a pen position.
pub const GlyphMetrics = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    w: f32,
    h: f32,
    /// Offsets from the pen position to the bitmap's top-left corner.
    bearing_x: f32,
    bearing_y: f32,
};

/// One CPU-side R8 coverage bitmap holding every rasterized glyph in
/// `char_range`, packed via simple shelf packing (rows of glyphs, each row
/// as tall as its tallest glyph) - plenty for a small fixed ASCII set at
/// one UI text size. Keyed by *glyph index* (not char code), matching what
/// HarfBuzz's shaping output (`ShapedGlyph.glyph_index`) hands back.
pub const Atlas = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    glyphs: std.AutoHashMapUnmanaged(u32, GlyphMetrics) = .empty,
    pixel_size: u32,

    pub fn build(alloc: std.mem.Allocator, font: *Font, char_range: []const u32, width: u32, height: u32) !Atlas {
        const pixels = try alloc.alloc(u8, width * height);
        @memset(pixels, 0);

        var self: Atlas = .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .pixel_size = font.pixel_size,
        };
        errdefer self.deinit(alloc);

        const padding: u32 = 1;
        var pen_x: u32 = padding;
        var pen_y: u32 = padding;
        var row_h: u32 = 0;

        for (char_range) |code| {
            const glyph_index = font.ft_face.getCharIndex(code) orelse continue;
            const bmp = try font.rasterize(glyph_index);

            if (pen_x + bmp.width + padding > width) {
                pen_x = padding;
                pen_y += row_h + padding;
                row_h = 0;
            }
            if (pen_y + bmp.height + padding > height) return error.GlyphAtlasFull;

            var row: u32 = 0;
            while (row < bmp.height) : (row += 1) {
                const src = bmp.pixels[row * bmp.pitch ..][0..bmp.width];
                const dst_offset = (pen_y + row) * width + pen_x;
                @memcpy(pixels[dst_offset..][0..bmp.width], src);
            }

            try self.glyphs.put(alloc, glyph_index, .{
                .u0 = @as(f32, @floatFromInt(pen_x)) / @as(f32, @floatFromInt(width)),
                .v0 = @as(f32, @floatFromInt(pen_y)) / @as(f32, @floatFromInt(height)),
                .u1 = @as(f32, @floatFromInt(pen_x + bmp.width)) / @as(f32, @floatFromInt(width)),
                .v1 = @as(f32, @floatFromInt(pen_y + bmp.height)) / @as(f32, @floatFromInt(height)),
                .w = @floatFromInt(bmp.width),
                .h = @floatFromInt(bmp.height),
                .bearing_x = @floatFromInt(bmp.left),
                .bearing_y = @floatFromInt(bmp.top),
            });

            pen_x += bmp.width + padding;
            row_h = @max(row_h, bmp.height);
        }

        return self;
    }

    pub fn deinit(self: *Atlas, alloc: std.mem.Allocator) void {
        self.glyphs.deinit(alloc);
        alloc.free(self.pixels);
    }
};

/// Printable ASCII (space through '~') - enough for widget captions.
pub const ascii_char_range: [95]u32 = blk: {
    var range: [95]u32 = undefined;
    for (&range, 0..) |*c, i| c.* = 32 + i;
    break :blk range;
};
