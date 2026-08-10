const std = @import("std");
const win32 = @import("win32");
const build_options = @import("build_options");

const console = win32.system.console;
const fs = win32.storage.file_system;

/// The EXE is built with the GUI subsystem (see build/__root__.zig), so no
/// console is auto-allocated on launch - normal double-click/shortcut runs,
/// and just as importantly launches with no inherited console at all (e.g.
/// `zig build run` from some shells, or any other detached CreateProcess),
/// leave STD_OUTPUT_HANDLE/STD_ERROR_HANDLE unset. Left alone that's fatal:
/// raylib's own TraceLog is intercepted (src/raylib_log.zig) to avoid the C
/// runtime's stdio entirely, but Zig's own `std.debug.print` reads
/// STD_ERROR_HANDLE live out of the PEB on every call (`Io.File.stderr()`)
/// and does not tolerate it being absent the way the C runtime's own cached
/// stdio might.
///
/// Pass "--debug" on the command line to opt into a *visible* console
/// (reused from the parent process if there is one, else freshly
/// allocated). Either way - debug console or not - this always points
/// STD_OUTPUT_HANDLE/STD_ERROR_HANDLE at *some* valid, writable handle
/// before any other code in the process can print: the real console when
/// "--debug" is set, otherwise the NUL device, so every `std.debug.print`
/// call (this file's own callers included - no gating needed) silently
/// drains instead of touching an absent/invalid handle. Must run before any
/// prints - `SetStdHandle` is what updates the PEB field `Io.File.stderr()`
/// reads; `AllocConsole`/`AttachConsole` alone does not re-target a
/// GUI-subsystem process's (previously invalid) std handles to the console.
pub fn maybeAllocDebugConsole(init: std.process.Init, allocator: std.mem.Allocator) void {
    const args = init.minimal.args.toSlice(allocator) catch return;
    var debug_requested = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) {
            debug_requested = true;
            break;
        }
    }

    if (debug_requested and setupDebugConsole()) return;
    setStdHandlesToNul();
}

/// Attempts to attach/allocate a real console and point
/// STD_OUTPUT_HANDLE/STD_ERROR_HANDLE at it. Returns whether it succeeded.
fn setupDebugConsole() bool {
    // Prefer reusing whatever console launched us (e.g. `zig build run --
    // --debug` from an existing terminal) so output lands there instead of
    // popping a separate window. Falls back to allocating our own when
    // there's no parent console to attach to (double-click/shortcut launch).
    const attached = console.AttachConsole(console.ATTACH_PARENT_PROCESS) != 0;
    if (!attached and console.AllocConsole() == 0) return false;

    const conout = openHandle(std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"), true);
    if (conout == win32.foundation.INVALID_HANDLE_VALUE) return false;

    setStdHandles(conout);
    return true;
}

/// No console at all (or "--debug" wasn't passed, or setup above failed) -
/// point std handles at the NUL device instead of leaving them unset, so
/// any live-PEB-reading print always has somewhere safe to write.
fn setStdHandlesToNul() void {
    const nul = openHandle(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), false);
    if (nul == win32.foundation.INVALID_HANDLE_VALUE) return;
    setStdHandles(nul);
}

fn setStdHandles(handle: win32.foundation.HANDLE) void {
    _ = console.SetStdHandle(console.STD_OUTPUT_HANDLE, handle);
    _ = console.SetStdHandle(console.STD_ERROR_HANDLE, handle);
}

fn openHandle(name: [:0]const u16, read_too: bool) win32.foundation.HANDLE {
    // GENERIC_WRITE (plus GENERIC_READ for the console case), spelled out
    // field-by-field since zigwin32 flag structs are packed structs, not
    // plain ints to `|`.
    var access = fs.FILE_ACCESS_FLAGS{
        .FILE_WRITE_DATA = 1,
        .FILE_APPEND_DATA = 1,
        .FILE_WRITE_EA = 1,
        .FILE_WRITE_ATTRIBUTES = 1,
        .READ_CONTROL = 1,
        .SYNCHRONIZE = 1,
    };
    if (read_too) {
        access.FILE_READ_DATA = 1;
        access.FILE_READ_EA = 1;
        access.FILE_READ_ATTRIBUTES = 1;
    }
    const share_all = fs.FILE_SHARE_MODE{ .READ = 1, .WRITE = 1 };

    return fs.CreateFileW(name, access, share_all, null, fs.OPEN_EXISTING, .{}, null);
}
