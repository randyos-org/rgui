//! Widget hot path. One instance = one flat-colored, hard-edged rect;
//! no border, no radius, no antialiasing. Carries the bulk of a
//! widget-heavy frame's instance count.
//!
//! Premultiplied alpha output, matching rgl.zig/glyph.zig.

const std = @import("std");
const spirv = std.spirv;
pub const shader_opts = @import("shader_opts");
const lib = @import("rstd").rgl.shaders.lib;

const Vec2 = lib.types.Vec2;
const Vec4 = lib.types.Vec4;
const param = lib.compile.param;
const input = lib.compile.input;

const param_color = param("color", Vec4, 0);

const main = lib.compile.exportShaderMain(&vert, &frag);
comptime { _ = main; }

// VK_VERTEX_INPUT_RATE_INSTANCE on the host side; dead in the frag compile.
const in_rect_pos = input("rect_pos", Vec2, 0);
const in_rect_size = input("rect_size", Vec2, 1);
const in_color = input("instance_color", Vec4, 2);

fn vert() callconv(.spirv_vertex) void {
    const corner = lib.coords.quadCorner(spirv.vertex_index);
    const pixel_pos = in_rect_pos.* + in_rect_size.* * corner;
    spirv.position_out.* = lib.coords.fromScreenToNdc(pixel_pos, lib.globals.screen_size);
    param_color.* = in_color.*;
}

fn frag() callconv(.{ .spirv_fragment = .{} }) void {
    const color = param_color.*;
    lib.compile.frag_color_out.* = lib.coords.rgbPreMulAlpha(lib.coords.rgb(color), color[3]);
}
