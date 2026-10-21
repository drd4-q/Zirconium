/// The console facade the rest of the kernel talks to.
///
/// This used to be a full implementation of the VGA text console - its own
/// scrollback, its own screen mirror, its own cursor - with the framebuffer
/// driver carrying a *second*, subtly different copy of all of it.  The two
/// had drifted apart and the ~190 KB of BSS they used was duplicated.
///
/// Now there is one console engine (`gfx/console.zig`) that draws through a
/// `Surface`, and this file is only the stable name the rest of the tree
/// already uses.  `vga.write(...)` and friends behave exactly as before.
const gfx = @import("gfx/mod.zig");

pub const Color = gfx.Color;

pub const init = gfx.init;
pub const initFb = gfx.initFb;
pub const isFbActive = gfx.isFbActive;
pub const getCols = gfx.getCols;
pub const getRows = gfx.getRows;
pub const setColor = gfx.setColor;
pub const setResolution = gfx.setResolution;
pub const write = gfx.write;
pub const putChar = gfx.putChar;
pub const clear = gfx.clear;
pub const writeDec = gfx.writeDec;
pub const writeHex = gfx.writeHex;
pub const writeHexShort = gfx.writeHexShort;
pub const scrollBackText = gfx.scrollBackText;
pub const scrollForwardText = gfx.scrollForwardText;
pub const redrawAllText = gfx.redrawAllText;

/// The graphics backend, for callers that need the framebuffer directly.
pub const gfx_mod = gfx;

/// The console engine, for callers that need the grid or the scrollback.
pub const console = gfx.console;
