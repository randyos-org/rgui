const std = @import("std");

const buildroot = @import("__root__.zig");
const rstdbuild = buildroot.rstd.buildutils;

pub fn addVulkan(b: *rstdbuild.Build) rstdbuild.ZigModule {
    // get the path to the vulkan registry XML file
    const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");

    // generate vulkan.zig from the registry XML file using vulkan-zig-generator.
    // this returns a compile step for the vulkan-zig-generator exe.
    const gen = b.dependency("vulkan", .{}).artifact("vulkan-zig-generator");

    // add a run step to run the vulkan-zig-generator exe
    // The output file is added to the build graph as a LazyPath, so that the build system knows about it and can track its dependencies.
    const cmd = b.addRunArtifact(gen);

    // pass it the registry XML file and telling it to output vulkan.zig.
    cmd.addFileArg(registry);

    // return a Zig module build object for the output vk.zig as "vulkan"
    return .{ .mod = b.addModule("vulkan-zig", .{
        .root_source_file = cmd.addOutputFileArg("vk.zig"),
    }), .name = "vulkan" };
}
