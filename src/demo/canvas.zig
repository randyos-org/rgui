const std = @import("std");

const fontmod = @import("font.zig");

pub const Color = [4]u8;

/// Screen-space (or, for `demo_raster.zig`, desktop-space) rectangle in
/// integer pixels, origin top-left - the raster equivalent of
/// `widgets.zig`'s `Rect`.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// "Over" alpha compositing - the one blend path every drawing primitive
/// below shares, whether the source is an opaque brush dab or a
/// partially-covered text glyph pixel.
fn blendOver(dst: *[4]u8, src: Color) void {
    const a: u32 = src[3];
    if (a == 0) return;
    if (a == 255) {
        dst.* = src;
        return;
    }
    const inv = 255 - a;
    inline for (0..3) |i| {
        dst[i] = @intCast((@as(u32, src[i]) * a + @as(u32, dst[i]) * inv) / 255);
    }
    dst[3] = @intCast(a + (@as(u32, dst[3]) * inv) / 255);
}

/// A CPU-side RGBA8 pixel buffer with a handful of MS-Paint-style drawing
/// primitives (pixels/lines/brush strokes/filled shapes/text), independent
/// of Vulkan entirely - `demo_raster.zig` owns pushing the finished pixels
/// to the GPU.
pub const Canvas = struct {
    width: u32,
    height: u32,
    /// Row-major RGBA8, `width * height * 4` bytes.
    pixels: []u8,
    /// Set by every mutating call; the GPU uploader clears it once the
    /// currently-visible region has been re-uploaded.
    dirty: bool = true,

    pub fn init(alloc: std.mem.Allocator, width: u32, height: u32) !Canvas {
        const pixels = try alloc.alloc(u8, @as(usize, width) * height * 4);
        var self: Canvas = .{ .width = width, .height = height, .pixels = pixels };
        self.clear(.{ 255, 255, 255, 255 });
        return self;
    }

    pub fn deinit(self: *Canvas, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
    }

    /// Hard-sets every pixel to `color` (no blending - this is a reset,
    /// not a draw).
    pub fn clear(self: *Canvas, color: Color) void {
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) {
            self.pixels[i..][0..4].* = color;
        }
        self.dirty = true;
    }

    pub fn setPixel(self: *Canvas, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const idx = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4;
        blendOver(self.pixels[idx..][0..4], color);
        self.dirty = true;
    }

    /// Bresenham, 1px wide.
    pub fn drawLine(self: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32, color: Color) void {
        var ix0: i32 = @intFromFloat(@round(x0));
        var iy0: i32 = @intFromFloat(@round(y0));
        const ix1: i32 = @intFromFloat(@round(x1));
        const iy1: i32 = @intFromFloat(@round(y1));

        const dx = @abs(ix1 - ix0);
        const dy = -@abs(iy1 - iy0);
        const sx: i32 = if (ix0 < ix1) 1 else -1;
        const sy: i32 = if (iy0 < iy1) 1 else -1;
        var err = dx + dy;

        while (true) {
            self.setPixel(ix0, iy0, color);
            if (ix0 == ix1 and iy0 == iy1) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                ix0 += sx;
            }
            if (e2 <= dx) {
                err += dx;
                iy0 += sy;
            }
        }
    }

    pub fn fillRect(self: *Canvas, rect: Rect, color: Color) void {
        const x0 = @max(rect.x, 0);
        const y0 = @max(rect.y, 0);
        const x1 = @min(rect.x + rect.w, @as(i32, @intCast(self.width)));
        const y1 = @min(rect.y + rect.h, @as(i32, @intCast(self.height)));
        if (x0 >= x1 or y0 >= y1) return;

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                self.setPixel(x, y, color);
            }
        }
    }

    pub fn fillCircle(self: *Canvas, cx: f32, cy: f32, radius: f32, color: Color) void {
        if (radius <= 0) return;
        const r_sq = radius * radius;
        const icx: i32 = @intFromFloat(@round(cx));
        const icy: i32 = @intFromFloat(@round(cy));
        const ir: i32 = @intFromFloat(@ceil(radius));

        var dy: i32 = -ir;
        while (dy <= ir) : (dy += 1) {
            const fy: f32 = @floatFromInt(dy);
            const remaining = r_sq - fy * fy;
            if (remaining < 0) continue;
            const dx_max: i32 = @intFromFloat(@floor(@sqrt(remaining)));
            var dx: i32 = -dx_max;
            while (dx <= dx_max) : (dx += 1) {
                self.setPixel(icx + dx, icy + dy, color);
            }
        }
    }

    /// A round "brush" stroke from `(x0,y0)` to `(x1,y1)`: dabs a filled
    /// circle every half-radius step along the segment so fast mouse
    /// motion still leaves a continuous stroke instead of gapped dots.
    pub fn strokeBrush(self: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32, radius: f32, color: Color) void {
        const dx = x1 - x0;
        const dy = y1 - y0;
        const dist = @sqrt(dx * dx + dy * dy);
        const step: f32 = @max(radius * 0.5, 1.0);
        const steps: u32 = @intFromFloat(@ceil(dist / step));
        if (steps == 0) {
            self.fillCircle(x1, y1, radius, color);
            return;
        }

        var i: u32 = 0;
        while (i <= steps) : (i += 1) {
            const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            self.fillCircle(x0 + dx * t, y0 + dy * t, radius, color);
        }
    }

    /// Shapes `text` (via `fontmod.Font.shape`) and blits each glyph's
    /// rasterized coverage bitmap (`fontmod.Font.rasterize`) directly onto
    /// the canvas, tinted by `color` - no atlas involved, since this isn't
    /// a per-frame GPU vertex path like `widgets.zig`'s text rendering.
    pub fn drawText(self: *Canvas, font: *fontmod.Font, alloc: std.mem.Allocator, text: []const u8, x: f32, y: f32, color: Color) !void {
        const glyphs = try font.shape(alloc, text);
        defer alloc.free(glyphs);

        var pen_x = x;
        for (glyphs) |g| {
            const bmp = try font.rasterize(g.glyph_index);
            const x0: i32 = @intFromFloat(@round(pen_x + g.x_offset + @as(f32, @floatFromInt(bmp.left))));
            const y0: i32 = @intFromFloat(@round(y - g.y_offset - @as(f32, @floatFromInt(bmp.top))));

            var row: u32 = 0;
            while (row < bmp.height) : (row += 1) {
                var col: u32 = 0;
                while (col < bmp.width) : (col += 1) {
                    const coverage = bmp.pixels[row * bmp.pitch + col];
                    if (coverage == 0) continue;
                    const a: u8 = @intCast((@as(u32, color[3]) * coverage) / 255);
                    self.setPixel(x0 + @as(i32, @intCast(col)), y0 + @as(i32, @intCast(row)), .{ color[0], color[1], color[2], a });
                }
            }
            pen_x += g.x_advance;
        }
    }
};
