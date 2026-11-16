//! The `console` shell command: where the console output goes.
//!
//! The console is the text grid on the screen.  A machine whose display
//! cannot be driven has none: the text buffer is not scanned out and there
//! is no framebuffer.  The serial port is then the console - and it can be
//! switched on at any time, which is the only way to see what the shell
//! does on a machine whose screen stays black.

const std = @import("std");
const root = @import("root");
const vga = root.vga;
const gfx = @import("../system/gfx/mod.zig");
const serial = root.serial;

/// Shell entry point: `console [serial on|serial off|status]`.
pub fn run(args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " \t");

    if (trimmed.len == 0 or eql(trimmed, "status") or eql(trimmed, "info")) {
        status();
        return;
    }

    if (eql(trimmed, "serial on") or eql(trimmed, "serial enable")) {
        gfx.setSerialConsole(true);
        vga.setColor(.light_green, .black);
        vga.write("\n  The console output is mirrored to the serial port.\n\n");
        vga.setColor(.white, .black);
        return;
    }

    if (eql(trimmed, "serial off") or eql(trimmed, "serial disable")) {
        gfx.setSerialConsole(false);
        vga.setColor(.light_green, .black);
        vga.write("\n  The console output is no longer mirrored to the serial port.\n\n");
        vga.setColor(.white, .black);
        return;
    }

    vga.setColor(.light_red, .black);
    vga.write("\n  Unknown subcommand '");
    vga.write(trimmed);
    vga.write("'\n");
    vga.setColor(.white, .black);
    usage();
}

fn status() void {
    vga.setColor(.cyan, .black);
    vga.write("\n  === Console ===\n\n");
    vga.setColor(.white, .black);

    vga.write("  Screen:     ");
    if (vga.isFbActive()) {
        vga.write("linear framebuffer");
    } else {
        vga.write("VGA text mode (software rendering)");
    }
    vga.write("\n");

    vga.write("  Serial:     ");
    if (gfx.serialConsole()) {
        vga.setColor(.light_green, .black);
        vga.write("the console output is mirrored here");
        vga.setColor(.white, .black);
    } else {
        vga.write("the debug log only");
    }
    vga.write("\n\n");
}

fn usage() void {
    vga.write("  Usage: console [serial on|serial off|status]\n");
    vga.write("    serial on   Mirror the console output to the serial port\n");
    vga.write("    serial off  Stop mirroring it\n\n");
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lx = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const ly = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (lx != ly) return false;
    }
    return true;
}
