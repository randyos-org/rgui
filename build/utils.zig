const std = @import("std");

pub const ZigCLink = struct {
    lib: *std.Build.Step.Compile,
    incl: ?std.Build.LazyPath = null,

    pub fn addLinkToModule(self: *const ZigCLink, mod: *std.Build.Module) void {
        mod.linkLibrary(self.lib);
        if (self.incl) |incl| mod.addIncludePath(incl);
    }
};

pub const ZigCBind = struct {
    mod: *std.Build.Module,
    clink: ZigCLink,
};

pub const ZigModule = struct {
    mod: *std.Build.Module,
    name: []const u8,
    /// Set when `mod` is a thin Zig wrapper over a compiled C/C++ library
    /// (freetype, harfbuzz) - the underlying library still has to be
    /// linked into whatever consumes this module, since importing the
    /// wrapper module alone only pulls in type/function declarations.
    clink: ?ZigCLink = null,

    pub fn addImportToModule(self: *const ZigModule, mod: *std.Build.Module) void {
        mod.addImport(self.name, self.mod);
        if (self.clink) |clink| clink.addLinkToModule(mod);
    }
};
