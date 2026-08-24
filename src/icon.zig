const std = @import("std");

const rstd = @import("rstd");
const Image = rstd.rgl.Image;
const RGBA = rstd.rgl.color.RGBA;

const icon_rgba = @embedFile("icon.rgba");

pub const data: Image = .{
    .width = 32,
    .height = 32,
    // RGBA is a packed struct of four u8 fields, so the embedded bytes are
    // already byte-for-byte identical to the target layout - reinterpret
    // rather than copy. @constCast is safe here: this data is only ever
    // read, never written back through Image's (necessarily mutable) []RGBA.
    .data = @constCast(@alignCast(std.mem.bytesAsSlice(RGBA, icon_rgba))),
};
