/// Graphics and console facade.
///
/// Owns the *active surface* - the thing the console draws into - and exposes
/// the console API that the rest of the kernel uses.  The surface is chosen at
/// boot: a linear framebuffer if the firmware gave us a graphics mode, the
/// VGA text buffer otherwise.
///
/// `src/system/vga.zig` re-exports this module, so `vga.write(...)` and
/// friends keep working unchanged across the whole tree.
const std = @import("std");
const root = @import("root");

pub const fb = @import("../framebuffer.zig");
pub const console = @import("console.zig");
pub const vga_text = @import("vga_text.zig");
pub const surface_mod = @import("surface.zig");
pub const palette = @import("palette.zig");
pub const font = @import("font.zig");
pub const vga_mode = @import("../../drivers/video/vga_mode.zig");

pub const Surface = surface_mod.Surface;
pub const Color = palette.Color;

// ─── Active surface ─────────────────────────────────────────────────

/// Which backend the console is drawing into.
var active_surface: Surface = undefined;
var surface_bound: bool = false;

/// Bind the VGA text buffer as the console backend.
pub fn init() void {
    if (surface_bound) return;
    bindText();
}

/// Program the legacy VGA into the text mode and bind the text buffer.
///
/// The mode is programmed by hand: a machine whose firmware left the
/// adapter in a graphics mode shows nothing at all until the text mode is
/// set up again, and the text buffer is the only console that needs no
/// adapter.
fn bindText() void {
    _ = vga_mode.initTextMode();
    active_surface = vga_text.surface();
    surface_bound = true;
    console.setSurface(active_surface);
    logConsoleSurface("vga-text");
}

/// Push the console background colour into the framebuffer's scroll path,
/// which clears the exposed row itself.
fn syncFramebufferBackground() void {
    if (!fb.active) return;
    const c = palette.rgb(console.bg);
    fb.setConsoleBackground(@intCast((c >> 16) & 0xFF), @intCast((c >> 8) & 0xFF), @intCast(c & 0xFF));
}

/// Say which surface the console is drawing into, and how big its grid is.
///
/// A machine can report a working framebuffer and still show nothing: the
/// console may be bound to the text buffer, the grid may be one cell, or the
/// flush may never run.  This is the line that names the surface in the log.
fn logConsoleSurface(kind: []const u8) void {
    root.serial.serialWrite("[GFX] console surface=");
    root.serial.serialWrite(kind);
    root.serial.serialWrite(" grid=");
    root.serial.serialWriteDec(console.cols);
    root.serial.serialWrite("x");
    root.serial.serialWriteDec(console.rows);
    if (fb.active) {
        root.serial.serialWrite(" viewport=");
        root.serial.serialWriteDec(fb.fb_width);
        root.serial.serialWrite("x");
        root.serial.serialWriteDec(fb.fb_height);
        root.serial.serialWrite(" bpp=");
        root.serial.serialWriteDec(fb.fb_bpp);
    }
    root.serial.serialWrite("\n");
}

/// Discover the video mode the firmware set up and, if there is one, switch
/// the console onto the linear framebuffer.
///
/// Called very early - before the IDT exists - so it must not touch the
/// framebuffer memory itself.  The actual probe happens later, from
/// `probeLfbSafe()`, once a fault can be reported instead of rebooting the
/// machine silently.
pub fn initFb(mbi_ptr: u32) void {
    fb.initFromMultiboot(mbi_ptr);
    if (fb.active) {
        active_surface = fb.surface();
        surface_bound = true;
        console.setSurface(active_surface);
        syncFramebufferBackground();
        logConsoleSurface("framebuffer");
    } else {
        init();
    }
}

/// True when a linear framebuffer is in use.
pub fn isFbActive() bool {
    return fb.active;
}

/// Switch the console onto the framebuffer (or back to text).  Exposed for the
/// `screen` command and for tests.
pub fn useFramebuffer() void {
    if (!fb.active) return;
    active_surface = fb.surface();
    surface_bound = true;
    console.setSurface(active_surface);
    syncFramebufferBackground();
    logConsoleSurface("framebuffer");
}

/// Switch the console onto the VGA text buffer.
///
/// The legacy VGA is programmed into the 80x25 text mode first: without it
/// the text buffer is not displayed at all.  A machine that has no legacy
/// VGA (one whose display is driven by a discrete GPU) is left alone -
/// there is nothing the text buffer could be shown on.
pub fn useText() void {
    if (!vga_mode.present()) return;
    bindText();
}

/// Switch the console onto the text buffer, whatever the hardware says.
///
/// This is the last resort: the framebuffer is not usable and the serial
/// log is the only other console.  The text buffer is written even when no
/// legacy VGA answers - it costs nothing, and a machine whose adapter does
/// scan it out (an emulated one, for instance) shows the console.
pub fn useTextFallback() void {
    bindText();
}

// ─── Console API ────────────────────────────────────────────────────

/// Mirror the console output to the serial port.
///
/// A machine whose display cannot be driven has no console at all: the text
/// buffer is not scanned out and there is no framebuffer.  The serial port
/// is then the console - the shell is driven over it, so its output has to
/// come back the same way.  The mirror itself lives in the console engine,
/// which is where every character goes through.
pub fn setSerialConsole(on: bool) void {
    console.setSerialMirror(on);
}

/// True when the console output is mirrored to the serial port.
pub fn serialConsole() bool {
    return console.serial_mirror;
}

pub fn write(str: []const u8) void {
    console.write(str);
}

pub fn putChar(ch: u8) void {
    console.putChar(ch);
}

pub fn clear() void {
    console.clear();
}

pub fn getCols() usize {
    return console.cols;
}

pub fn getRows() usize {
    return console.rows;
}

pub fn setColor(fg_c: Color, bg_c: Color) void {
    console.fg = @intFromEnum(fg_c);
    console.bg = @intFromEnum(bg_c);
    // The scroll paths clear the exposed row with the console's colours, so
    // both surfaces have to know them.
    syncFramebufferBackground();
    vga_text.setConsoleColors(console.fg, console.bg);
}

pub fn writeDec(value: u64) void {
    if (value == 0) {
        console.putChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var v = value;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    while (i < 20) : (i += 1) {
        console.putChar(buf[i]);
    }
}

pub fn writeHex(value: u64) void {
    const hex = "0123456789ABCDEF";
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        console.putChar(hex[(value >> @intCast(i * 4)) & 0xF]);
    }
}

pub fn writeHexShort(value: u64) void {
    const hex = "0123456789ABCDEF";
    var started = false;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        const nibble: u8 = @intCast((value >> @intCast(i * 4)) & 0xF);
        if (nibble != 0 or started or i == 0) {
            started = true;
            console.putChar(hex[nibble]);
        }
    }
}

/// Page up through the scrollback.
pub fn scrollBackText(lines: usize) void {
    console.scrollBack(lines);
}

/// Page down through the scrollback.
pub fn scrollForwardText(lines: usize) void {
    console.scrollForward(lines);
}

/// Resize the drawable viewport of the framebuffer.
pub fn setResolution(w: u32, h: u32) void {
    fb.setViewport(w, h);
    if (fb.active) {
        console.setSurface(fb.surface());
    }
}

/// Repaint the whole console.
pub fn redrawAllText() void {
    console.redrawAll();
}
