const std = @import("std");

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

fn colorByte() u8 {
    return @intFromEnum(bg_color) << 4 | @intFromEnum(fg_color);
}

fn vgaEntry(ch: u8, clr: u8) u16 {
    return @as(u16, ch) | (@as(u16, clr) << 8);
}

fn vgaBuffer() [*]volatile u16 {
    return @ptrFromInt(VGA_BUFFER);
}

pub fn clear() void {
    const blank = vgaEntry(' ', colorByte());
    var y: usize = 0;
    while (y < VGA_HEIGHT) : (y += 1) {
        var x: usize = 0;
        while (x < VGA_WIDTH) : (x += 1) {
            vgaBuffer()[y * VGA_WIDTH + x] = blank;
        }
    }
    cursor_row = 0;
    cursor_col = 0;
}

fn newline() void {
    cursor_col = 0;
    cursor_row += 1;
    if (cursor_row >= VGA_HEIGHT) {
        scroll();
        cursor_row = VGA_HEIGHT - 1;
    }
}

fn scroll() void {
    var y: usize = 1;
    while (y < VGA_HEIGHT) : (y += 1) {
        var x: usize = 0;
        while (x < VGA_WIDTH) : (x += 1) {
            vgaBuffer()[(y - 1) * VGA_WIDTH + x] = vgaBuffer()[y * VGA_WIDTH + x];
        }
    }
    const blank = vgaEntry(' ', colorByte());
    var x: usize = 0;
    while (x < VGA_WIDTH) : (x += 1) {
        vgaBuffer()[(VGA_HEIGHT - 1) * VGA_WIDTH + x] = blank;
    }
}

pub fn putChar(ch: u8) void {
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
    vgaBuffer()[cursor_row * VGA_WIDTH + cursor_col] = vgaEntry(ch, colorByte());
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
