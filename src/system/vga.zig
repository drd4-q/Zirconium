const std = @import("std");
const fb = @import("framebuffer.zig");

pub const VGA_WIDTH: usize = 80;
pub const VGA_HEIGHT: usize = 25;
pub const VGA_BUFFER: usize = 0xB8000;

pub const Color = enum(u8) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    pink = 13,
    yellow = 14,
    white = 15,
};

pub var cursor_row: usize = 0;
pub var cursor_col: usize = 0;
pub var fg_color: Color = .white;
pub var bg_color: Color = .black;

const MAX_COLS: usize = 80;
const MAX_ROWS: usize = 50;

// Text-mode scrollback
const SCROLLBACK_LINES: usize = 512;
var scrollback: [SCROLLBACK_LINES][MAX_COLS]u16 = undefined;
var sb_head: usize = 0;
var sb_count: usize = 0;

var screen_mirror: [MAX_ROWS][MAX_COLS]u16 = undefined;
var saved_screen: [MAX_ROWS][MAX_COLS]u16 = undefined;
var saved_cursor_row: usize = 0;
var saved_cursor_col: usize = 0;
pub var scroll_view: bool = false;
var view_offset: usize = 0; // how many lines from the end of scrollback we're viewing

pub fn initFb(mbi_ptr: u32) void {
    fb.initFromMultiboot(mbi_ptr);
}

pub fn isFbActive() bool {
    return fb.active;
}

pub fn getCols() usize {
    if (fb.active) return fb.cols;
    return VGA_WIDTH;
}

pub fn getRows() usize {
    if (fb.active) return fb.rows;
    return VGA_HEIGHT;
}

pub fn setResolution(w: u32, h: u32) void {
    fb.setResolution(w, h);
}

fn colorByte() u8 {
    return @intFromEnum(bg_color) << 4 | @intFromEnum(fg_color);
}

fn vgaEntry(ch: u8, clr: u8) u16 {
    return @as(u16, ch) | (@as(u16, clr) << 8);
}

fn textBuffer() [*]volatile u16 {
    return @ptrFromInt(VGA_BUFFER);
}

pub fn clear() void {
    if (fb.active) {
        fb.setColorFromVga(@intFromEnum(fg_color), @intFromEnum(bg_color));
        fb.clear();
        cursor_row = 0;
        cursor_col = 0;
        return;
    }
    const blank = vgaEntry(' ', colorByte());
    var y: usize = 0;
    while (y < VGA_HEIGHT) : (y += 1) {
        var x: usize = 0;
        while (x < VGA_WIDTH) : (x += 1) {
            textBuffer()[y * VGA_WIDTH + x] = blank;
        }
    }
    cursor_row = 0;
    cursor_col = 0;
}

fn newline() void {
    cursor_col = 0;
    cursor_row += 1;
    if (cursor_row >= getRows()) {
        if (fb.active) {
            fb.scrollUp();
            cursor_row = fb.rows - 1;
        } else {
            scroll();
            cursor_row = VGA_HEIGHT - 1;
        }
    }
}

fn scroll() void {
    if (!fb.active) {
        // Save top line to scrollback
        var x: usize = 0;
        while (x < VGA_WIDTH) : (x += 1) {
            scrollback[sb_head][x] = textBuffer()[x]; // row 0
        }
        sb_head = (sb_head + 1) % SCROLLBACK_LINES;
        if (sb_count < SCROLLBACK_LINES) sb_count += 1;
    }
    var y: usize = 1;
    while (y < VGA_HEIGHT) : (y += 1) {
        var x: usize = 0;
        while (x < VGA_WIDTH) : (x += 1) {
            textBuffer()[(y - 1) * VGA_WIDTH + x] = textBuffer()[y * VGA_WIDTH + x];
        }
    }
    const blank = vgaEntry(' ', colorByte());
    var x: usize = 0;
    while (x < VGA_WIDTH) : (x += 1) {
        textBuffer()[(VGA_HEIGHT - 1) * VGA_WIDTH + x] = blank;
    }
}

pub fn putChar(ch: u8) void {
    if (fb.active) {
        fb.setColorFromVga(@intFromEnum(fg_color), @intFromEnum(bg_color));
        fb.putChar(ch);
        cursor_row = fb.cursor_row;
        cursor_col = fb.cursor_col;
        return;
    }

    // Exit scroll view on any input
    if (scroll_view) {
        exitScrollViewText();
    }

    if (ch == '\n') {
        newline();
        return;
    }
    if (ch == '\r') {
        cursor_col = 0;
        return;
    }
    if (ch == '\t') {
        const next = (cursor_col + 8) & ~@as(usize, 7);
        if (next >= VGA_WIDTH) {
            newline();
        } else {
            cursor_col = next;
        }
        return;
    }
    textBuffer()[cursor_row * VGA_WIDTH + cursor_col] = vgaEntry(ch, colorByte());
    cursor_col += 1;
    if (cursor_col >= VGA_WIDTH) {
        newline();
    }
}

pub fn write(str: []const u8) void {
    for (str) |ch| {
        putChar(ch);
    }
}

pub fn setColor(fg_c: Color, bg_c: Color) void {
    fg_color = fg_c;
    bg_color = bg_c;
}

pub fn writeHex(value: u64) void {
    const hex = "0123456789ABCDEF";
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        putChar(hex[(value >> @intCast(i * 4)) & 0xF]);
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
            putChar(hex[nibble]);
        }
    }
}

pub fn writeDec(value: u64) void {
    if (value == 0) {
        putChar('0');
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
        putChar(buf[i]);
    }
}

fn syncMirrorFromBuffer() void {
    var y: usize = 0;
    while (y < VGA_HEIGHT) : (y += 1) {
        var x: usize = 0;
        while (x < VGA_WIDTH) : (x += 1) {
            screen_mirror[y][x] = textBuffer()[y * VGA_WIDTH + x];
        }
    }
}

fn restoreMirrorToBuffer() void {
    var y: usize = 0;
    while (y < VGA_HEIGHT) : (y += 1) {
        var x: usize = 0;
        while (x < VGA_WIDTH) : (x += 1) {
            textBuffer()[y * VGA_WIDTH + x] = screen_mirror[y][x];
        }
    }
}

pub fn scrollBackText(lines: usize) void {
    if (fb.active) return;
    if (sb_count == 0) return;

    if (!scroll_view) {
        syncMirrorFromBuffer();
        saved_screen = screen_mirror;
        saved_cursor_row = cursor_row;
        saved_cursor_col = cursor_col;
        scroll_view = true;
        view_offset = 0;
    }

    if (view_offset + lines <= sb_count) {
        view_offset += lines;
    } else {
        view_offset = sb_count;
    }

    renderScrollViewText();
}

pub fn scrollForwardText(lines: usize) void {
    if (fb.active) return;
    if (!scroll_view) return;

    if (view_offset > lines) {
        view_offset -= lines;
    } else {
        exitScrollViewText();
        return;
    }

    renderScrollViewText();
}

fn renderScrollViewText() void {
    // view_offset: 0 = newest scrollback line at bottom, sb_count = oldest at top
    // We show min(view_offset, VGA_HEIGHT) scrollback lines at top of screen
    // Then the saved screen below

    const num_sb = if (view_offset > VGA_HEIGHT) VGA_HEIGHT else view_offset;
    var screen_row: usize = 0;

    // Show scrollback lines (oldest visible at top)
    // The line at view_offset from the end is at screen row 0
    var i: usize = 0;
    while (i < num_sb) : (i += 1) {
        // sb_idx: index from oldest (0) to newest (sb_count-1)
        const sb_idx = sb_count - view_offset + i;
        const ring_idx = (sb_head + sb_idx) % SCROLLBACK_LINES;
        var x: usize = 0;
        while (x < VGA_WIDTH) : (x += 1) {
            textBuffer()[screen_row * VGA_WIDTH + x] = scrollback[ring_idx][x];
        }
        screen_row += 1;
    }

    // Show saved screen below scrollback
    var saved_row: usize = 0;
    while (screen_row < VGA_HEIGHT) : (screen_row += 1) {
        var x: usize = 0;
        while (x < VGA_WIDTH) : (x += 1) {
            textBuffer()[screen_row * VGA_WIDTH + x] = saved_screen[saved_row][x];
        }
        saved_row += 1;
    }
}

pub fn exitScrollViewText() void {
    if (fb.active) return;
    if (!scroll_view) return;
    scroll_view = false;
    screen_mirror = saved_screen;
    cursor_row = saved_cursor_row;
    cursor_col = saved_cursor_col;
    restoreMirrorToBuffer();
}
