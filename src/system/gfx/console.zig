/// The text console.
///
/// One implementation, two backends.  The console owns the character grid,
/// the cursor, the colours and the scrollback; the *surface* owns how a cell
/// reaches the hardware (VGA text memory or a linear framebuffer).
///
/// The old code had two entirely separate consoles - `vga.zig` and the text
/// half of `framebuffer.zig` - each with its own scrollback ring, its own
/// screen mirror, its own cursor and its own scroll semantics.  They had
/// drifted apart, and the ~190 KB of BSS they used was duplicated.  Now there
/// is one console and switching backends is a pointer swap.
const std = @import("std");
const root = @import("root");
const surface_mod = @import("surface.zig");
const vga_text = @import("vga_text.zig");
const palette = @import("palette.zig");
const font = @import("font.zig");

const Surface = surface_mod.Surface;

/// Widest and tallest grid the console will use.  A 1920x1080 framebuffer
/// could hold 240x67 cells; the console stops at 160x60 so the cell mirror
/// and the scrollback stay a bounded, static allocation.
pub const MAX_COLS: usize = 160;
pub const MAX_ROWS: usize = 60;

/// How many lines of history are kept.
const SCROLLBACK_LINES: usize = 256;

/// Cell encoding: character in bits 0..7, foreground index in 8..11,
/// background index in 12..15.
pub const Cell = u16;

inline fn packCell(ch: u8, fgi: u8, bgi: u8) Cell {
    return @as(u16, ch) | (@as(u16, fgi & 0x0F) << 8) | (@as(u16, bgi & 0x0F) << 12);
}

inline fn cellChar(c: Cell) u8 {
    return @intCast(c & 0xFF);
}

inline fn cellFg(c: Cell) u8 {
    return @intCast((c >> 8) & 0x0F);
}

inline fn cellBg(c: Cell) u8 {
    return @intCast((c >> 12) & 0x0F);
}

// ─── State ──────────────────────────────────────────────────────────

/// Grid size in cells.
pub var cols: usize = 80;
pub var rows: usize = 25;

pub var cursor_row: usize = 0;
pub var cursor_col: usize = 0;

/// Current colours, as palette indices.
pub var fg: u8 = @intFromEnum(palette.Color.light_gray);
pub var bg: u8 = @intFromEnum(palette.Color.black);

/// True while the console is showing scrollback instead of the live screen.
pub var scroll_view: bool = false;

/// The live screen, mirrored so it can be restored after a scrollback view and
/// so the scrollback can be built from it.
var mirror: [MAX_ROWS][MAX_COLS]Cell = undefined;

/// The live screen as it was when the scrollback view was entered.
var saved_screen: [MAX_ROWS][MAX_COLS]Cell = undefined;
var saved_cursor_row: usize = 0;
var saved_cursor_col: usize = 0;

/// Scrollback ring.  Only the first `cols` cells of each line are used.
var scrollback: [SCROLLBACK_LINES][MAX_COLS]Cell = undefined;
var sb_head: usize = 0;
var sb_count: usize = 0;
/// How many lines back from the newest the scrollback view is showing.
var scroll_view_line: usize = 0;

/// The bound surface.  `have_surface` is false until something is bound, which
/// is the state the kernel is in before the video mode is known.
var surface: Surface = undefined;
var have_surface: bool = false;

// ─── Binding ────────────────────────────────────────────────────────

/// Bind a surface and adopt its grid size.
///
/// Rebinding re-renders the whole console, so switching from VGA text to a
/// linear framebuffer mid-session does not lose what was on screen.
pub fn setSurface(s: Surface) void {
    const first = !have_surface;
    surface = s;
    have_surface = true;
    updateGrid();
    if (!first) {
        // The previous content is meaningless on a new surface; start clean.
        clearMirror();
        cursor_row = 0;
        cursor_col = 0;
        redrawAll();
    }
}

/// Recompute the grid size from the bound surface, clamped to our maximum.
fn updateGrid() void {
    if (!have_surface) return;
    const c = surface.gridCols();
    const r = surface.gridRows();
    cols = @min(@as(usize, c), MAX_COLS);
    rows = @min(@as(usize, r), MAX_ROWS);
    if (cols == 0) cols = 1;
    if (rows == 0) rows = 1;
}

/// True when a surface is bound and the console can draw.
pub fn ready() bool {
    return have_surface;
}

/// Bind the VGA text buffer if nothing else has been bound yet.
///
/// The console is normally bound by `gfx.initFb()`, which runs before the
/// first `vga.write`.  This is the belt-and-braces path for a caller that
/// writes before the video mode is known: dropping the output silently would
/// be much harder to debug than showing it on the text buffer.
fn ensureBound() void {
    if (have_surface) return;
    surface = vga_text.surface();
    have_surface = true;
    updateGrid();
}

fn clearMirror() void {
    var r: usize = 0;
    while (r < MAX_ROWS) : (r += 1) {
        var c: usize = 0;
        while (c < MAX_COLS) : (c += 1) {
            mirror[r][c] = packCell(' ', fg, bg);
        }
    }
}

// ─── Output ─────────────────────────────────────────────────────────

/// Write one character at the cursor, handling the control characters.
pub fn putChar(ch: u8) void {
    ensureBound();

    if (scroll_view) exitScrollView();

    switch (ch) {
        '\n' => {
            cursor_col = 0;
            cursor_row += 1;
            if (cursor_row >= rows) {
                scrollUp();
                cursor_row = rows - 1;
            }
            return;
        },
        '\r' => {
            cursor_col = 0;
            return;
        },
        '\t' => {
            const next = (cursor_col + 8) & ~@as(usize, 7);
            if (next >= cols) {
                cursor_col = 0;
                cursor_row += 1;
                if (cursor_row >= rows) {
                    scrollUp();
                    cursor_row = rows - 1;
                }
            } else {
                cursor_col = next;
            }
            return;
        },
        else => {},
    }

    if (cursor_row < rows and cursor_col < cols) {
        mirror[cursor_row][cursor_col] = packCell(ch, fg, bg);
    }
    surface.putCell(@intCast(cursor_col), @intCast(cursor_row), ch, fg, bg);
    cursor_col += 1;
    if (cursor_col >= cols) {
        cursor_col = 0;
        cursor_row += 1;
        if (cursor_row >= rows) {
            scrollUp();
            cursor_row = rows - 1;
        }
    }
}

/// Write a string.  The surface is flushed once at the end, not per character.
pub fn write(str: []const u8) void {
    ensureBound();
    for (str) |ch| {
        putChar(ch);
    }
    surface.flush();
}

/// Erase the screen and reset the cursor.
pub fn clear() void {
    if (!have_surface) return;
    clearMirror();
    cursor_row = 0;
    cursor_col = 0;
    scroll_view = false;
    surface.clear(bg);
    surface.flush();
}

/// Scroll the console up by one row.
///
/// The surface scrolls its pixels (much cheaper than repainting every cell)
/// and then the exposed bottom row is repainted from the mirror.
pub fn scrollUp() void {
    if (!have_surface) return;
    if (rows == 0) return;

    // Push the top line into the scrollback.
    if (rows >= 1) {
        var c: usize = 0;
        while (c < cols and c < MAX_COLS) : (c += 1) {
            scrollback[sb_head][c] = mirror[0][c];
        }
        sb_head = (sb_head + 1) % SCROLLBACK_LINES;
        if (sb_count < SCROLLBACK_LINES) sb_count += 1;
    }

    // Shift the mirror up.
    var r: usize = 0;
    while (r + 1 < rows) : (r += 1) {
        mirror[r] = mirror[r + 1];
    }
    // Blank the exposed row.
    var c2: usize = 0;
    while (c2 < cols and c2 < MAX_COLS) : (c2 += 1) {
        mirror[rows - 1][c2] = packCell(' ', fg, bg);
    }

    // Scroll the surface pixels, then repaint the row that moved into place.
    surface.scrollUp(@intCast(rows), @intCast(cols));
    const last = rows - 1;
    var c3: usize = 0;
    while (c3 < cols) : (c3 += 1) {
        const cell = mirror[last][c3];
        surface.putCell(@intCast(c3), @intCast(last), cellChar(cell), cellFg(cell), cellBg(cell));
    }
    surface.flush();
}

// ─── Scrollback navigation ──────────────────────────────────────────

/// Page up through the scrollback.
pub fn scrollBack(lines: usize) void {
    if (!have_surface) return;
    if (sb_count == 0) return;

    if (!scroll_view) {
        // Remember the live screen so it can be restored.
        saved_screen = mirror;
        saved_cursor_row = cursor_row;
        saved_cursor_col = cursor_col;
        scroll_view = true;
        scroll_view_line = 0;
    }

    const max_back = sb_count;
    if (scroll_view_line + lines > max_back) {
        scroll_view_line = max_back;
    } else {
        scroll_view_line += lines;
    }

    renderScrollView();
}

/// Page down through the scrollback, back towards the live screen.
pub fn scrollForward(lines: usize) void {
    if (!have_surface) return;
    if (!scroll_view) return;

    if (lines >= scroll_view_line) {
        exitScrollView();
        return;
    }
    scroll_view_line -= lines;
    renderScrollView();
}

/// Leave the scrollback view and restore the live screen.
pub fn exitScrollView() void {
    if (!have_surface) return;
    if (!scroll_view) return;
    scroll_view = false;
    mirror = saved_screen;
    cursor_row = saved_cursor_row;
    cursor_col = saved_cursor_col;
    redrawAll();
}

/// Repaint the whole grid from the mirror.
pub fn redrawAll() void {
    if (!have_surface) return;
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        var c: usize = 0;
        while (c < cols) : (c += 1) {
            const cell = mirror[r][c];
            surface.putCell(@intCast(c), @intCast(r), cellChar(cell), cellFg(cell), cellBg(cell));
        }
    }
    surface.flush();
}

/// Draw the scrollback view: history at the top, live screen below.
fn renderScrollView() void {
    if (!have_surface) return;

    // How many history lines fit above the live screen.
    const live_rows = rows;
    var shown: usize = 0;
    while (shown < live_rows and scroll_view_line > shown) : (shown += 1) {}

    var r: usize = 0;
    while (r < shown) : (r += 1) {
        // The line `scroll_view_line` back from the newest is at the top.
        const sb_idx = sb_count - scroll_view_line + r;
        const ring_idx = (sb_head + SCROLLBACK_LINES - sb_count + sb_idx) % SCROLLBACK_LINES;
        var c: usize = 0;
        while (c < cols) : (c += 1) {
            const cell = scrollback[ring_idx][c];
            mirror[r][c] = cell;
            surface.putCell(@intCast(c), @intCast(r), cellChar(cell), cellFg(cell), cellBg(cell));
        }
    }

    // The live screen below the history.
    while (r < rows) : (r += 1) {
        var c: usize = 0;
        while (c < cols) : (c += 1) {
            const cell = saved_screen[r][c];
            surface.putCell(@intCast(c), @intCast(r), cellChar(cell), cellFg(cell), cellBg(cell));
        }
    }

    // Indicator in the bottom row.
    const indicator = "[Scrollback: PgUp/PgDn/Esc]";
    if (rows > 0 and cols >= indicator.len) {
        const row = rows - 1;
        const start = cols - indicator.len;
        for (indicator, 0..) |ch, i| {
            const c = start + i;
            mirror[row][c] = packCell(ch, @intFromEnum(palette.Color.light_cyan), @intFromEnum(palette.Color.black));
            surface.putCell(@intCast(c), @intCast(row), ch, @intFromEnum(palette.Color.light_cyan), @intFromEnum(palette.Color.black));
        }
    }

    surface.flush();
}

/// Number of scrollback lines currently stored.
pub fn scrollbackLines() usize {
    return sb_count;
}
