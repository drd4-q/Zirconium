/// VGA text-mode surface: the 80x25 character cell buffer at 0xB8000.
///
/// This is the fallback console.  It exists because a bootloader can hand over
/// no graphics mode at all (GRUB falling back to text, or a machine whose only
/// console is the firmware's).  It implements the same `Surface` interface as
/// the linear framebuffer, so the console engine does not care which one it is
/// talking to.
const std = @import("std");
const root = @import("root");
const font = @import("font.zig");
const palette = @import("palette.zig");
const surface_mod = @import("surface.zig");

pub const Surface = surface_mod.Surface;

pub const VGA_BUFFER: usize = 0xB8000;
pub const COLS: usize = 80;
pub const ROWS: usize = 25;

/// VGA text buffer cell: character in the low byte, attribute in the high byte.
pub const Cell = u16;

inline fn buffer() [*]volatile Cell {
    return @ptrFromInt(VGA_BUFFER);
}

pub inline fn cellAttr(fg: u8, bg: u8) u16 {
    const f: u16 = @intCast(fg & 0x0F);
    const b: u16 = @intCast(bg & 0x0F);
    return (b << 4) | f;
}

/// The colours the console is using.  The scroll path blanks the row it
/// exposes, and it has to blank it in the console's colours.
var console_fg: u8 = 7;
var console_bg: u8 = 0;

pub fn setConsoleColors(fg: u8, bg: u8) void {
    console_fg = fg;
    console_bg = bg;
}

pub fn putCellRaw(col: usize, row: usize, ch: u8, fg: u8, bg: u8) void {
    if (col >= COLS or row >= ROWS) return;
    buffer()[row * COLS + col] = @as(u16, ch) | (cellAttr(fg, bg) << 8);
}

pub fn readCellRaw(col: usize, row: usize) u16 {
    if (col >= COLS or row >= ROWS) return 0;
    return buffer()[row * COLS + col];
}

pub fn clearTo(bg: u8) void {
    const blank: Cell = @as(u16, ' ') | (cellAttr(0, bg) << 8);
    var i: usize = 0;
    while (i < COLS * ROWS) : (i += 1) {
        buffer()[i] = blank;
    }
}

// ─── Surface implementation ─────────────────────────────────────────

fn vtblCellWidth(ctx: *anyopaque) u32 {
    _ = ctx;
    return @intCast(font.GLYPH_W);
}

fn vtblCellHeight(ctx: *anyopaque) u32 {
    _ = ctx;
    return @intCast(font.GLYPH_H);
}

fn vtblGridCols(ctx: *anyopaque) u32 {
    _ = ctx;
    return COLS;
}

fn vtblGridRows(ctx: *anyopaque) u32 {
    _ = ctx;
    return ROWS;
}

fn vtblPutCell(ctx: *anyopaque, col: u32, row: u32, ch: u8, fg: u8, bg: u8) void {
    _ = ctx;
    putCellRaw(col, row, ch, fg, bg);
}

fn vtblClear(ctx: *anyopaque, bg: u8) void {
    _ = ctx;
    clearTo(bg);
}

fn vtblFlush(ctx: *anyopaque) void {
    _ = ctx;
    // Writes to 0xB8000 are immediately visible; nothing to push.
}

fn vtblScrollUp(ctx: *anyopaque, rows: u32, cols: u32) void {
    _ = ctx;
    scrollUp(rows, cols);
}

/// Scroll the text buffer up by `rows` cell rows, clearing the exposed rows.
pub fn scrollUp(rows: u32, cols: u32) void {
    if (rows == 0) return;
    const w = @min(@as(usize, cols), COLS);
    if (w == 0) return;
    const buf = buffer();
    var r: usize = 0;
    while (r + rows < ROWS) : (r += 1) {
        var c: usize = 0;
        while (c < w) : (c += 1) {
            buf[(r) * COLS + c] = buf[(r + rows) * COLS + c];
        }
    }
    // The exposed rows are blanked in the console's colours, the way the
    // framebuffer's scroll path blanks them in the background.
    const blank: u16 = @as(u16, ' ') | (cellAttr(console_fg, console_bg) << 8);
    var r2: usize = ROWS - rows;
    while (r2 < ROWS) : (r2 += 1) {
        var c: usize = 0;
        while (c < w) : (c += 1) {
            buf[r2 * COLS + c] = blank;
        }
    }
}

/// The VGA text surface instance.
pub var vga_surface_instance: struct {} = .{};

/// Surface handle for the VGA text buffer.
pub fn surface() Surface {
    return .{
        .ctx = @ptrCast(&vga_surface_instance),
        .vtable = &.{
            .cell_width = vtblCellWidth,
            .cell_height = vtblCellHeight,
            .grid_cols = vtblGridCols,
            .grid_rows = vtblGridRows,
            .put_cell = vtblPutCell,
            .clear = vtblClear,
            .flush = vtblFlush,
            .scroll_up = vtblScrollUp,
        },
    };
}
