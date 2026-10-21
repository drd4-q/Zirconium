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

pub const Surface = surface_mod.Surface;
pub const Color = palette.Color;

// ─── Active surface ─────────────────────────────────────────────────

/// Which backend the console is drawing into.
var active_surface: Surface = undefined;
var surface_bound: bool = false;

/// Bind the VGA text buffer as the console backend.
pub fn init() void {
    if (surface_bound) return;
    active_surface = vga_text.surface();
    surface_bound = true;
    console.setSurface(active_surface);
}

/// Push the console background colour into the framebuffer's scroll path,
/// which clears the exposed row itself.
fn syncFramebufferBackground() void {
    if (!fb.active) return;
    const c = palette.rgb(console.bg);
    fb.setConsoleBackground(@intCast((c >> 16) & 0xFF), @intCast((c >> 8) & 0xFF), @intCast(c & 0xFF));
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
}

/// Switch the console onto the VGA text buffer.
pub fn useText() void {
    active_surface = vga_text.surface();
    surface_bound = true;
    console.setSurface(active_surface);
}

// ─── Console API ────────────────────────────────────────────────────

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
    // The framebuffer's scroll path clears the exposed row with the console
    // background, so it has to know the current one.
    syncFramebufferBackground();
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
