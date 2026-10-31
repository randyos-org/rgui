const std = @import("std");

const rstd = @import("rstd");
const RgbaImage = rstd.rgl.RgbaImage;
const RGBA = rstd.rgl.color.RGBA;

const icon_rgba = @embedFile("icon.rgba");

pub const data: RgbaImage = .{
    .width = 32,
    .height = 32,
    // RGBA is a packed struct of four u8 fields, so the embedded bytes are
    // already byte-for-byte identical to the target layout - reinterpret
    // rather than copy. @constCast is safe here: this data is only ever
    // read, never written back through RgbaImage's (necessarily mutable) []RGBA.
    .data = @alignCast(@constCast(rstd.bytes.viewAsSlice(RGBA, icon_rgba))),
};
