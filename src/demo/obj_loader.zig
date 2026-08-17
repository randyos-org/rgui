// adapted from: https://codeberg.org/Mr_Nobody/HowToVulkan_zig/src/commit/cbd4e71c00bb215f3cf1c1cc16ababc873fb8ab0/src/obj_loader.zig
const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const assert = std.debug.assert;
const parseFloat = std.fmt.parseFloat;
const parseInt = std.fmt.parseInt;

const Attribute = enum { v, vn, vt, f };

const Index = struct {
    v_index: u32,
    vn_index: ?u32,
    vt_index: ?u32,
};

const ObjFile = struct {
    v_list: []f32,
    vn_list: []f32,
    vt_list: []f32,
    mesh: []Index,

    pub fn init(v_list: []f32, vn_list: []f32, vt_list: []f32, mesh: []Index) ObjFile {
        return ObjFile{ .v_list = v_list, .vn_list = vn_list, .vt_list = vt_list, .mesh = mesh };
    }
    pub fn deinit(self: ObjFile, allocator: Allocator) void {
        allocator.free(self.v_list);
        allocator.free(self.vn_list);
        allocator.free(self.vt_list);
        allocator.free(self.mesh);
    }
};

pub fn loadObj(allocator: Allocator, io: Io, path: []const u8) !ObjFile {
    const file = try Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const reader = &file_reader.interface;

    var v_list: std.ArrayList(f32) = .empty;
    defer v_list.deinit(allocator);

    var vn_list: std.ArrayList(f32) = .empty;
    defer vn_list.deinit(allocator);

    var vt_list: std.ArrayList(f32) = .empty;
    defer vt_list.deinit(allocator);

    var index_list: std.ArrayList(Index) = .empty;
    defer index_list.deinit(allocator);

    var indices = try std.ArrayList(Index).initCapacity(allocator, 3);
    defer indices.deinit(allocator);

    while (try reader.takeDelimiter('\n')) |line| {
        var line_iter = std.mem.splitAny(u8, line, &.{ ' ', '\r', '\n' });
        if (std.meta.stringToEnum(Attribute, line_iter.first())) |attribute| {
            switch (attribute) {
                .v => try takeFloats(&line_iter, &v_list, allocator),
                .vn => try takeFloats(&line_iter, &vn_list, allocator),
                .vt => try takeFloats(&line_iter, &vt_list, allocator),
                .f => {
                    while (line_iter.next()) |chunk| {
                        if (chunk.len == 0) continue;
                        try indices.append(allocator, try takeIndex(chunk));
                    }
                    switch (indices.items.len) {
                        0, 1, 2 => return error.InvalidFace,
                        3 => try index_list.appendSlice(allocator, indices.items),
                        4 => try triangulateQuad(&v_list, &indices, &index_list, allocator),
                        else => return error.NgonTriangulationNotImplementd,
                    }

                    indices.clearRetainingCapacity();
                },
            }
        }
    }

    return ObjFile.init(
        try v_list.toOwnedSlice(allocator),
        try vn_list.toOwnedSlice(allocator),
        try vt_list.toOwnedSlice(allocator),
        try index_list.toOwnedSlice(allocator),
    );
}

fn takeFloats(iter: *std.mem.SplitIterator(u8, .any), list: *std.ArrayList(f32), allocator: Allocator) !void {
    while (iter.next()) |chunk| {
        if (chunk.len == 0) continue;
        try list.append(allocator, try parseFloat(f32, chunk));
    }
}

fn takeIndex(str: []const u8) !Index {
    var index_iter = std.mem.splitScalar(u8, str, '/');

    var v_index = try std.fmt.parseInt(u32, index_iter.first(), 10);
    var vt_index = if (index_iter.next()) |vt| try parseInt(u32, vt, 10) else null;
    var vn_index = if (index_iter.next()) |vn| try parseInt(u32, vn, 10) else null;

    if (v_index >= 1) v_index -= 1;
    if (vt_index != null and vt_index.? >= 1) vt_index.? -= 1;
    if (vn_index != null and vn_index.? >= 1) vn_index.? -= 1;

    return Index{ .v_index = v_index, .vn_index = vn_index, .vt_index = vt_index };
}

fn triangulateQuad(v_list: *std.ArrayList(f32), index_buffer: *std.ArrayList(Index), index_list: *std.ArrayList(Index), allocator: Allocator) !void {
    const i_0 = index_buffer.items[0];
    const i_1 = index_buffer.items[1];
    const i_2 = index_buffer.items[2];
    const i_3 = index_buffer.items[3];

    const v0x = v_list.items[i_0.v_index * 3 + 0];
    const v0y = v_list.items[i_0.v_index * 3 + 1];
    const v0z = v_list.items[i_0.v_index * 3 + 2];

    const v1x = v_list.items[i_1.v_index * 3 + 0];
    const v1y = v_list.items[i_1.v_index * 3 + 1];
    const v1z = v_list.items[i_1.v_index * 3 + 2];

    const v2x = v_list.items[i_2.v_index * 3 + 0];
    const v2y = v_list.items[i_2.v_index * 3 + 1];
    const v2z = v_list.items[i_2.v_index * 3 + 2];

    const v3x = v_list.items[i_3.v_index * 3 + 0];
    const v3y = v_list.items[i_3.v_index * 3 + 1];
    const v3z = v_list.items[i_3.v_index * 3 + 2];

    // There are two candidates to split the quad into two triangles.
    //
    // candidate a | candidate b
    //    ┌──┐          ┌──┐
    //    │╲ │          │ ╱│
    //    │ ╲│          │╱ │
    //    └──┘          └──┘
    //
    // Choose the shortest edge.

    const ax = v2x - v0x;
    const ay = v2y - v0y;
    const az = v2z - v0z;

    const bx = v3x - v1x;
    const by = v3y - v1y;
    const bz = v3z - v1z;

    const a = ax * ax + ay * ay + az * az;
    const b = bx * bx + by * by + bz * bz;

    if (a < b) {
        // [0,1,2],[0,2,3]
        try index_list.appendSlice(allocator, &.{ i_0, i_1, i_2, i_0, i_2, i_3 });
    } else {
        // [0,1,3],[1,2,3]
        try index_list.appendSlice(allocator, &.{ i_0, i_1, i_3, i_1, i_2, i_3 });
    }
}
