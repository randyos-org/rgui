const std = @import("std");

pub const ZigCLink = struct {
    lib: *std.Build.Step.Compile,
    incl: std.Build.LazyPath,

    pub fn addLinkToModule(self: *const ZigCLink, mod: *std.Build.Module) void {
        mod.linkLibrary(self.lib);
        mod.addIncludePath(self.incl);
    }
};

pub const ZigCBind = struct {
    mod: *std.Build.Module,
    clink: ZigCLink,
};

pub const ZigCModule = struct {
    mod: *std.Build.Module,
    name: []const u8,

    pub fn addImportToModule(self: *const ZigCModule, mod: *std.Build.Module) void {
        mod.addImport(self.name, self.mod);
    }
};
