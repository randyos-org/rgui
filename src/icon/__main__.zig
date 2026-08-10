const std = @import("std");

const master_size: i32 = 1024; // high-res canvas; downsampled to each target size

const Color = struct { r: u8, g: u8, b: u8, a: u8 };

const Image = struct {
    width: i32,
    height: i32,
    data: []Color,

    fn init(allocator: std.mem.Allocator, width: i32, height: i32, fill: Color) !Image {
        const data = try allocator.alloc(Color, @intCast(width * height));
        @memset(data, fill);
        return .{ .width = width, .height = height, .data = data };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) {
        std.debug.print("usage: genicon <out.png> <out.ico>\n", .{});
        return error.InvalidArgs;
    }
    const png_path = args[1];
    const ico_path = args[2];

    var m = try Image.init(allocator, master_size, master_size, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

    // Background: full-bleed rounded tile, dark slate.
    fillRoundRect(&m, 0, 0, master_size, master_size, 200, .{ .r = 0x20, .g = 0x27, .b = 0x33, .a = 0xFF });

    const Bar = struct { x: f64, w: f64, col: Color };
    const bars = [_]Bar{
        .{ .x = 210, .w = 540, .col = .{ .r = 0xF2, .g = 0xB4, .b = 0x41, .a = 0xFF } }, // amber
        .{ .x = 330, .w = 300, .col = .{ .r = 0x2F, .g = 0xB6, .b = 0xA8, .a = 0xFF } }, // teal
        .{ .x = 210, .w = 470, .col = .{ .r = 0x4A, .g = 0x90, .b = 0xE2, .a = 0xFF } }, // blue
        .{ .x = 400, .w = 380, .col = .{ .r = 0xE0, .g = 0x55, .b = 0x5F, .a = 0xFF } }, // rose
    };
    const row_h: f64 = 110.0;
    const top: f64 = 285.0;
    const step: f64 = 150.0;
    for (bars, 0..) |b, i| {
        const y0 = top + @as(f64, @floatFromInt(i)) * step;
        fillRoundRect(&m, b.x, y0, b.x + b.w, y0 + row_h, row_h / 2, b.col);
    }

    // Emit PNG (256) and a multi-size ICO.
    const icon256 = try downsample(allocator, &m, 256);
    const png_bytes = try encodePNG(allocator, &icon256);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = png_path, .data = png_bytes });

    const sizes = [_]i32{ 16, 24, 32, 48, 64, 128, 256 };
    var imgs: [sizes.len]Image = undefined;
    for (sizes, 0..) |s, i| imgs[i] = try downsample(allocator, &m, s);

    try writeICO(allocator, io, ico_path, &imgs);
}

fn setPixel(img: *Image, x: i32, y: i32, c: Color) void {
    img.data[@intCast(y * img.width + x)] = c;
}

fn getPixel(img: *const Image, x: i32, y: i32) Color {
    return img.data[@intCast(y * img.width + x)];
}

/// fillRoundRect fills an axis-aligned rounded rectangle with hard edges
/// (the downsample step provides antialiasing). Alpha of col is blended
/// over dst.
fn fillRoundRect(dst: *Image, x0: f64, y0: f64, x1: f64, y1: f64, r: f64, col: Color) void {
    var y: i32 = @intFromFloat(y0);
    const y_end: i32 = @intFromFloat(y1);
    while (y < y_end) : (y += 1) {
        var x: i32 = @intFromFloat(x0);
        const x_end: i32 = @intFromFloat(x1);
        while (x < x_end) : (x += 1) {
            const fx = @as(f64, @floatFromInt(x)) + 0.5;
            const fy = @as(f64, @floatFromInt(y)) + 0.5;
            if (!insideRound(fx, fy, x0, y0, x1, y1, r)) continue;
            blendPixel(dst, x, y, col);
        }
    }
}

fn insideRound(px: f64, py: f64, x0: f64, y0: f64, x1: f64, y1: f64, r: f64) bool {
    // Clamp point to the inner rectangle (the rounded-corner centers box).
    const cx = @max(x0 + r, @min(px, x1 - r));
    const cy = @max(y0 + r, @min(py, y1 - r));
    const dx = px - cx;
    const dy = py - cy;
    return dx * dx + dy * dy <= r * r;
}

fn blendPixel(dst: *Image, x: i32, y: i32, c: Color) void {
    if (c.a == 0xFF) {
        setPixel(dst, x, y, c);
        return;
    }
    const a: f64 = @as(f64, @floatFromInt(c.a)) / 255.0;
    const bg = getPixel(dst, x, y);
    setPixel(dst, x, y, .{
        .r = @intFromFloat(@as(f64, @floatFromInt(c.r)) * a + @as(f64, @floatFromInt(bg.r)) * (1 - a)),
        .g = @intFromFloat(@as(f64, @floatFromInt(c.g)) * a + @as(f64, @floatFromInt(bg.g)) * (1 - a)),
        .b = @intFromFloat(@as(f64, @floatFromInt(c.b)) * a + @as(f64, @floatFromInt(bg.b)) * (1 - a)),
        .a = @intFromFloat(@min(255.0, @as(f64, @floatFromInt(c.a)) + @as(f64, @floatFromInt(bg.a)) * (1 - a))),
    });
}

/// downsample area-averages the master canvas down to an n x n image using
/// premultiplied alpha so transparent edges stay clean.
fn downsample(allocator: std.mem.Allocator, src: *const Image, n: i32) !Image {
    var out = try Image.init(allocator, n, n, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    const scale = @as(f64, @floatFromInt(master_size)) / @as(f64, @floatFromInt(n));

    var dy: i32 = 0;
    while (dy < n) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < n) : (dx += 1) {
            const sx0: i32 = @intFromFloat(@as(f64, @floatFromInt(dx)) * scale);
            const sy0: i32 = @intFromFloat(@as(f64, @floatFromInt(dy)) * scale);
            const sx1: i32 = @intFromFloat(@as(f64, @floatFromInt(dx + 1)) * scale);
            const sy1: i32 = @intFromFloat(@as(f64, @floatFromInt(dy + 1)) * scale);

            var pr: f64 = 0;
            var pg: f64 = 0;
            var pb: f64 = 0;
            var pa: f64 = 0;
            var count: f64 = 0;

            var sy = sy0;
            while (sy < sy1) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1) : (sx += 1) {
                    const c = getPixel(src, sx, sy);
                    const a: f64 = @as(f64, @floatFromInt(c.a)) / 255.0;
                    pr += @as(f64, @floatFromInt(c.r)) * a;
                    pg += @as(f64, @floatFromInt(c.g)) * a;
                    pb += @as(f64, @floatFromInt(c.b)) * a;
                    pa += @as(f64, @floatFromInt(c.a));
                    count += 1;
                }
            }
            if (count == 0) continue;

            const alpha = pa / count;
            var r: f64 = 0;
            var g: f64 = 0;
            var b: f64 = 0;
            if (pa > 0) {
                r = pr / (pa / 255.0);
                g = pg / (pa / 255.0);
                b = pb / (pa / 255.0);
            }
            setPixel(&out, dx, dy, .{
                .r = @intFromFloat(@min(255.0, r)),
                .g = @intFromFloat(@min(255.0, g)),
                .b = @intFromFloat(@min(255.0, b)),
                .a = @intFromFloat(@min(255.0, alpha)),
            });
        }
    }
    return out;
}

fn appendU16LE(list: *std.array_list.Managed(u8), v: u16) !void {
    try list.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
}
fn appendU32LE(list: *std.array_list.Managed(u8), v: u32) !void {
    try list.appendSlice(&std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
}
fn appendU32BE(list: *std.array_list.Managed(u8), v: u32) !void {
    try list.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, v)));
}

fn crc32(data: []const u8) u32 {
    var h: std.hash.Crc32 = .init();
    h.update(data);
    return h.final();
}

fn writeChunk(list: *std.array_list.Managed(u8), chunk_type: *const [4]u8, data: []const u8) !void {
    try appendU32BE(list, @intCast(data.len));
    const start = list.items.len;
    try list.appendSlice(chunk_type);
    try list.appendSlice(data);
    try appendU32BE(list, crc32(list.items[start..]));
}

/// encodePNG is a minimal, non-interlaced, filter-type-0 (None) RGBA8 PNG
/// encoder - just enough to round-trip genicon's own output through
/// icon.png/icon.ico. See https://www.w3.org/TR/png/ for the chunk layout.
fn encodePNG(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.appendSlice(&[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(img.width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(img.height), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: truecolor + alpha (RGBA)
    ihdr[10] = 0; // compression method: deflate
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // interlace method: none
    try writeChunk(&out, "IHDR", &ihdr);

    // Raw (pre-compression) scanlines: filter-type byte (0/None) + RGBA row bytes.
    const w: usize = @intCast(img.width);
    const h: usize = @intCast(img.height);
    var raw: std.array_list.Managed(u8) = .init(allocator);
    defer raw.deinit();
    var y: usize = 0;
    while (y < h) : (y += 1) {
        try raw.append(0); // filter type: None
        for (img.data[y * w .. (y + 1) * w]) |c| {
            try raw.appendSlice(&[_]u8{ c.r, c.g, c.b, c.a });
        }
    }

    var idat: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer idat.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&idat.writer, &window, .zlib, .default);
    try compressor.writer.writeAll(raw.items);
    try compressor.finish();
    try writeChunk(&out, "IDAT", idat.written());

    try writeChunk(&out, "IEND", &.{});
    return out.toOwnedSlice();
}

/// writeICO packs PNG-encoded images (Vista+ supports PNG entries) into one
/// .ico.
fn writeICO(allocator: std.mem.Allocator, io: std.Io, name: []const u8, imgs: []const Image) !void {
    const Entry = struct { w: i32, h: i32, png: []const u8 };
    var entries: std.array_list.Managed(Entry) = .init(allocator);
    defer entries.deinit();

    for (imgs) |im| {
        const png_bytes = try encodePNG(allocator, &im);
        try entries.append(.{ .w = im.width, .h = im.height, .png = png_bytes });
    }

    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();

    // ICONDIR
    try appendU16LE(&out, 0); // reserved
    try appendU16LE(&out, 1); // type: icon
    try appendU16LE(&out, @intCast(entries.items.len));

    var offset: u32 = 6 + 16 * @as(u32, @intCast(entries.items.len));
    for (entries.items) |e| {
        const dim = struct {
            fn f(v: i32) u8 {
                if (v >= 256) return 0; // 0 means 256 in the ICO spec
                return @intCast(v);
            }
        }.f;
        try out.append(dim(e.w));
        try out.append(dim(e.h));
        try out.append(0); // color palette
        try out.append(0); // reserved
        try appendU16LE(&out, 1); // planes
        try appendU16LE(&out, 32); // bpp
        try appendU32LE(&out, @intCast(e.png.len)); // bytes
        try appendU32LE(&out, offset); // offset
        offset += @intCast(e.png.len);
    }
    for (entries.items) |e| try out.appendSlice(e.png);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = out.items });
}
