const std = @import("std");

pub const Slang = struct {
    shader_build_path: std.Build.LazyPath,
    shader_mod_name: []const u8,

    pub fn addToModule(self: *const Slang, mod: *std.Build.Module) void {
        mod.addAnonymousImport(self.shader_mod_name, .{ .root_source_file = self.shader_build_path });
    }
};

pub fn addSlang(b: *std.Build) Slang {
    const cmd = b.addSystemCommand(&.{
        "slangc",
        "-target",
        "spirv",
        "-o",
    });
    // goes with the -o arg
    const shader = cmd.addOutputFileArg("shader.spv");

    // add the path to the shader source file as an input arg
    cmd.addFileArg(b.path("shaders/shader.slang"));

    return Slang{
        .shader_build_path = shader,
        .shader_mod_name = "shader_module",
    };
}
