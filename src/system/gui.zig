const std = @import("std");
const root = @import("root");
const vga = root.vga;
const fb = @import("framebuffer.zig");
const mouse = @import("../drivers/mouse.zig");
const kb = @import("../drivers/keyboard.zig");
const timer = @import("../drivers/timer.zig");
const pmm = root.pmm;
const vfs = @import("../fs/vfs.zig");
const net = @import("../net/mod.zig");
const scheduler = root.scheduler;
const tty_mod = @import("tty.zig");
const dillo_prog = @import("../programs/dillo.zig");

const TITLE_H: i32 = 18;
const BORDER: i32 = 1;
const TASKBAR_H: i32 = 26;
const MAX_WINDOWS: usize = 12;

const ContentType = enum(u8) {
    clock,
    system,
    about,
    terminal,
    calculator,
    notepad,
    launcher,
    dillo,
};

const Window = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 200,
    h: i32 = 140,
    saved_x: i32 = 0,
    saved_y: i32 = 0,
    saved_w: i32 = 200,
    saved_h: i32 = 140,
    is_maximized: bool = false,
    title: [32]u8 = undefined,
    title_len: usize = 0,
    content: ContentType = .about,
    tty_id: u8 = 1,
    focused: bool = false,
    visible: bool = true,
};

var windows: [MAX_WINDOWS]Window = undefined;
var num_windows: usize = 0;
var drag_index: i32 = -1;
var drag_mode: enum { none, moving, resizing } = .none;
var drag_off_x: i32 = 0;
var drag_off_y: i32 = 0;
var prev_left: bool = false;
var prev_right: bool = false;
var drag_button: enum { none, left, right } = .none;
var cursor_drawn: bool = false;
var cursor_x: i32 = 0;
var cursor_y: i32 = 0;
var next_clock_tick: u64 = 0;
var next_gui_tty: u8 = 1;

// Start menu state
var start_menu_open: bool = false;
const START_BTN_X: i32 = 4;
const START_BTN_W: i32 = 64;
const START_BTN_H: i32 = 20;
const MENU_ITEM_H: i32 = 22;
const MENU_W: i32 = 210;
const MENU_ITEMS_COUNT: usize = 9;
const menu_items = [_][]const u8{
    "[w] Dillo Web Browser",
    "[>] New Terminal (tty+1)",
    "[*] Clock & Uptime",
    "[@] System Monitor",
    "[#] Calculator",
    "[=] Notepad",
    "[+] Program Launcher",
    "[i] About Zirconium",
    "[x] Exit to Shell",
};

// Calculator window state
var calc_display: [32]u8 = undefined;
var calc_len: usize = 0;
var calc_val1: i64 = 0;
var calc_op: u8 = 0;
var calc_new_num: bool = true;

// Notepad window state
const NOTE_MAX_LINES: usize = 12;
const NOTE_LINE_LEN: usize = 40;
var note_lines: [NOTE_MAX_LINES][NOTE_LINE_LEN]u8 = undefined;
var note_lens: [NOTE_MAX_LINES]usize = [_]usize{0} ** NOTE_MAX_LINES;
var note_cur_line: usize = 0;

// ----- Window management -----

fn createWindow(c: ContentType, x: i32, y: i32, w: i32, h: i32, title: []const u8, tty_id: u8) void {
    if (num_windows >= MAX_WINDOWS) return;
    const win = &windows[num_windows];
    win.* = .{};
    win.content = c;
    win.x = x;
    win.y = y;
    win.w = w;
    win.h = h;
    win.saved_x = x;
    win.saved_y = y;
    win.saved_w = w;
    win.saved_h = h;
    win.is_maximized = false;
    win.tty_id = tty_id;
    win.title_len = @min(title.len, 32);
    @memcpy(win.title[0..win.title_len], title[0..win.title_len]);
    win.focused = true;
    win.visible = true;
    allFocused(num_windows);
    num_windows += 1;
}

fn openOrCreateWindow(c: ContentType) void {
    const sw = @as(i32, @intCast(fb.fb_width));
    const sh = @as(i32, @intCast(fb.fb_height));

    if (c == .terminal) {
        const assigned_tty = next_gui_tty;
        next_gui_tty = (next_gui_tty % (@as(u8, @intCast(tty_mod.MAX_TTYS)) - 1)) + 1;

        var title_buf: [32]u8 = undefined;
        const prefix = "Terminal (tty";
        @memcpy(title_buf[0..prefix.len], prefix);
        title_buf[prefix.len] = '0' + assigned_tty;
        title_buf[prefix.len + 1] = ')';
        const title_len = prefix.len + 2;

        const offset_x: i32 = 30 + @as(i32, @intCast((num_windows % 5) * 20));
        const offset_y: i32 = 40 + @as(i32, @intCast((num_windows % 5) * 20));
        createWindow(.terminal, offset_x, offset_y, 440, 270, title_buf[0..title_len], assigned_tty);
        return;
    }

    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (windows[i].content == c) {
            windows[i].visible = true;
            allFocused(i);
            return;
        }
    }

    switch (c) {
        .terminal => {},
        .dillo => createWindow(.dillo, 50, 40, 520, 340, "Dillo Web Browser", 0),
        .calculator => createWindow(.calculator, sw - 210, 50, 180, 190, "Calculator", 0),
        .notepad => createWindow(.notepad, @divTrunc(sw, 2) - 140, @divTrunc(sh, 3), 280, 200, "Notepad", 0),
        .launcher => createWindow(.launcher, 50, 90, 300, 200, "Program Launcher", 0),
        .system => createWindow(.system, sw - 220, 50, 200, 160, "System Monitor", 0),
        .clock => createWindow(.clock, 50, 50, 180, 120, "Clock", 0),
        .about => createWindow(.about, @divTrunc(sw, 2) - 120, @divTrunc(sh, 4), 240, 140, "Welcome", 0),
    }
}

fn topmostAt(gx: i32, gy: i32) i32 {
    var best: i32 = -1;
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (!windows[i].visible) continue;
        if (gx >= windows[i].x and gx < windows[i].x + windows[i].w and
            gy >= windows[i].y and gy < windows[i].y + windows[i].h)
        {
            best = @intCast(i);
        }
    }
    if (best >= 0 and !windows[@intCast(best)].focused) {
        var k: usize = 0;
        while (k < num_windows) : (k += 1) {
            if (windows[k].focused and
                gx >= windows[k].x and gx < windows[k].x + windows[k].w and
                gy >= windows[k].y and gy < windows[k].y + windows[k].h)
            {
                return @intCast(k);
            }
        }
    }
    return best;
}

fn allFocused(fi: usize) void {
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        windows[i].focused = (i == fi);
    }
}

// ----- Cursor (High-Contrast Arrow Pointer with Crisp Border) -----

const CURSOR_W: usize = 12;
const CURSOR_H: usize = 18;

const CURSOR_PIXELS = [CURSOR_H][CURSOR_W]u8{
    [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 2, 1, 0, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 2, 2, 1, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 2, 2, 2, 1, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
    [_]u8{ 1, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 0 },
    [_]u8{ 1, 2, 2, 1, 2, 2, 1, 0, 0, 0, 0, 0 },
    [_]u8{ 1, 2, 1, 0, 1, 2, 2, 1, 0, 0, 0, 0 },
    [_]u8{ 1, 1, 0, 0, 1, 2, 2, 1, 0, 0, 0, 0 },
    [_]u8{ 1, 0, 0, 0, 0, 1, 2, 2, 1, 0, 0, 0 },
    [_]u8{ 0, 0, 0, 0, 0, 1, 2, 2, 1, 0, 0, 0 },
    [_]u8{ 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0 },
    [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};
var cursor_bg: [CURSOR_W * CURSOR_H]u32 = undefined;

fn saveCursorBg(x: i32, y: i32) void {
    const sw = fb.fb_width;
    const sh = fb.fb_height;
    var cy: usize = 0;
    while (cy < CURSOR_H) : (cy += 1) {
        const py = y + @as(i32, @intCast(cy));
        if (py >= 0 and py < sh) {
            const src_off: u64 = @as(u64, @intCast(py)) * fb.fb_pitch;
            const src: [*]volatile u32 = @ptrFromInt(fb.fb_addr + src_off);
            var cx: usize = 0;
            while (cx < CURSOR_W) : (cx += 1) {
                const px = x + @as(i32, @intCast(cx));
                if (px >= 0 and px < sw) {
                    cursor_bg[cy * CURSOR_W + cx] = src[@intCast(px)];
                } else {
                    cursor_bg[cy * CURSOR_W + cx] = 0;
                }
            }
        } else {
            var cx: usize = 0;
            while (cx < CURSOR_W) : (cx += 1) {
                cursor_bg[cy * CURSOR_W + cx] = 0;
            }
        }
    }
}

fn restoreCursorBg() void {
    const sw = fb.fb_width;
    const sh = fb.fb_height;
    var cy: usize = 0;
    while (cy < CURSOR_H) : (cy += 1) {
        const py = cursor_y + @as(i32, @intCast(cy));
        if (py >= 0 and py < sh) {
            const dst_off: u64 = @as(u64, @intCast(py)) * fb.fb_pitch;
            const dst: [*]volatile u32 = @ptrFromInt(fb.fb_addr + dst_off);
            var cx: usize = 0;
            while (cx < CURSOR_W) : (cx += 1) {
                const px = cursor_x + @as(i32, @intCast(cx));
                if (px >= 0 and px < sw) {
                    dst[@intCast(px)] = cursor_bg[cy * CURSOR_W + cx];
                }
            }
        }
    }
}

fn drawCursorShape() void {
    const sw = fb.fb_width;
    const sh = fb.fb_height;
    var cy: usize = 0;
    while (cy < CURSOR_H) : (cy += 1) {
        const py = cursor_y + @as(i32, @intCast(cy));
        if (py < 0 or py >= sh) continue;
        const dst_off: u64 = @as(u64, @intCast(py)) * fb.fb_pitch;
        const dst: [*]volatile u32 = @ptrFromInt(fb.fb_addr + dst_off);

        var cx: usize = 0;
        while (cx < CURSOR_W) : (cx += 1) {
            const px = cursor_x + @as(i32, @intCast(cx));
            if (px < 0 or px >= sw) continue;
            const code = CURSOR_PIXELS[cy][cx];
            if (code == 1) {
                dst[@intCast(px)] = 0x000000;
            } else if (code == 2) {
                dst[@intCast(px)] = 0xFFFFFF;
            }
        }
    }
}

fn restoreCursor() void {
    if (!cursor_drawn) return;
    restoreCursorBg();
    cursor_drawn = false;
}

fn drawCursor() void {
    if (cursor_drawn) restoreCursorBg();
    cursor_x = mouse.mx;
    cursor_y = mouse.my;
    saveCursorBg(cursor_x, cursor_y);
    drawCursorShape();
    cursor_drawn = true;
}

// ----- Drawing Helpers -----

fn fmtDec(val: u64, buf: []u8) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = buf.len;
    var v = val;
    while (v > 0 and i > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    return buf[i..];
}

fn drawWindowBody(win: *Window) void {
    const body_y = win.y + TITLE_H + BORDER;
    const body_h = win.h - TITLE_H - BORDER;
    const body_color: u32 = 0x1A1C23;
    fb.fillRect(@intCast(win.x + BORDER), @intCast(body_y), @intCast(win.w - 2 * BORDER), @intCast(body_h), @intCast((body_color >> 16) & 0xFF), @intCast((body_color >> 8) & 0xFF), @intCast(body_color & 0xFF));

    const tx = win.x + 8;
    var line_y = body_y + 6;

    switch (win.content) {
        .dillo => {
            const dillo = dillo_prog.getDillo();

            // Navigation toolbar (URL input + Go button)
            fb.fillRect(@intCast(win.x + 6), @intCast(body_y + 4), @intCast(win.w - 12), 24, 30, 36, 50);
            fb.drawRectBorder(@intCast(win.x + 6), @intCast(body_y + 4), @intCast(win.w - 12), 24, 1, 60, 80, 120);

            // Nav buttons [<] [>] [R]
            fb.drawString(@intCast(win.x + 10), @intCast(body_y + 8), "< > R", 180, 200, 240, 30, 36, 50);

            // URL input box
            const url_box_x = win.x + 58;
            const url_box_w = win.w - 110;
            fb.fillRect(@intCast(url_box_x), @intCast(body_y + 6), @intCast(url_box_w), 20, 18, 22, 32);
            fb.drawRectBorder(@intCast(url_box_x), @intCast(body_y + 6), @intCast(url_box_w), 20, 1, 70, 95, 140);
            if (dillo.url_len > 0) {
                fb.drawString(@intCast(url_box_x + 6), @intCast(body_y + 8), dillo.url_buf[0..dillo.url_len], 255, 255, 255, 18, 22, 32);
            }
            if (win.focused) {
                fb.drawString(@intCast(url_box_x + 6 + @as(i32, @intCast(dillo.url_len)) * 8), @intCast(body_y + 8), "|", 100, 200, 255, 18, 22, 32);
            }

            // Go Button
            const go_x = win.x + win.w - 46;
            fb.fillRect(@intCast(go_x), @intCast(body_y + 6), 38, 20, 40, 80, 150);
            fb.drawRectBorder(@intCast(go_x), @intCast(body_y + 6), 38, 20, 1, 80, 130, 220);
            fb.drawString(@intCast(go_x + 8), @intCast(body_y + 8), "Go", 255, 255, 255, 40, 80, 150);

            // Bookmarks toolbar
            const bmy = body_y + 32;
            fb.drawString(@intCast(win.x + 10), @intCast(bmy), "[ Home ]", 140, 200, 255, 26, 28, 35);
            fb.drawString(@intCast(win.x + 85), @intCast(bmy), "[ Kernel ]", 140, 200, 255, 26, 28, 35);
            fb.drawString(@intCast(win.x + 175), @intCast(bmy), "[ Local Disk ]", 140, 200, 255, 26, 28, 35);
            fb.drawString(@intCast(win.x + 295), @intCast(bmy), "[ 10.0.2.2 ]", 140, 200, 255, 26, 28, 35);

            // HTML Web page display area
            const view_y = body_y + 52;
            const view_h = body_h - 74;
            fb.fillRect(@intCast(win.x + 6), @intCast(view_y), @intCast(win.w - 12), @intCast(view_h), 16, 20, 30);
            fb.drawRectBorder(@intCast(win.x + 6), @intCast(view_y), @intCast(win.w - 12), @intCast(view_h), 1, 40, 50, 70);

            var dy = view_y + 6;
            var idx: usize = 0;
            while (idx < dillo.line_count and dy < view_y + view_h - 18) : (idx += 1) {
                const col = dillo.line_colors[idx];
                fb.drawString(@intCast(win.x + 12), @intCast(dy), dillo.lines[idx][0..dillo.line_lens[idx]], @intCast((col >> 16) & 0xFF), @intCast((col >> 8) & 0xFF), @intCast(col & 0xFF), 16, 20, 30);
                dy += 18;
            }

            // Status bar at bottom
            const sty = win.y + win.h - 18;
            fb.fillRect(@intCast(win.x + 6), @intCast(sty), @intCast(win.w - 12), 14, 12, 14, 20);
            if (dillo.status_len > 0) {
                fb.drawString(@intCast(win.x + 10), @intCast(sty - 1), dillo.status_buf[0..dillo.status_len], 140, 220, 140, 12, 14, 20);
            }
        },
        .clock => {
            var tbuf: [32]u8 = undefined;
            timer.formatTime(tbuf[0..9]);
            fb.drawString(@intCast(tx), @intCast(line_y), tbuf[0..8], 240, 240, 240, 26, 28, 35);
            line_y += 22;
            fb.drawString(@intCast(tx), @intCast(line_y), "Uptime: ", 170, 170, 170, 26, 28, 35);
            const up = fmtDec(timer.ticks / 100, tbuf[0..]);
            fb.drawString(@intCast(tx + 64), @intCast(line_y), up, 140, 220, 140, 26, 28, 35);
            fb.drawString(@intCast(tx + 64 + @as(i32, @intCast(up.len)) * 8), @intCast(line_y), " sec", 120, 120, 120, 26, 28, 35);
            line_y += 22;
            fb.drawString(@intCast(tx), @intCast(line_y), "Timer: 100 Hz PIT", 150, 180, 200, 26, 28, 35);
        },
        .system => {
            var tbuf: [32]u8 = undefined;
            fb.drawString(@intCast(tx), @intCast(line_y), "Pages Free: ", 180, 180, 180, 26, 28, 35);
            const free = fmtDec(pmm.free_pages, tbuf[0..]);
            fb.drawString(@intCast(tx + 96), @intCast(line_y), free, 120, 220, 120, 26, 28, 35);
            line_y += 20;
            fb.drawString(@intCast(tx), @intCast(line_y), "Total Pages:", 180, 180, 180, 26, 28, 35);
            const total = fmtDec(pmm.total_pages, tbuf[0..]);
            fb.drawString(@intCast(tx + 96), @intCast(line_y), total, 140, 180, 240, 26, 28, 35);
            line_y += 20;
            fb.drawString(@intCast(tx), @intCast(line_y), "Resolution: ", 180, 180, 180, 26, 28, 35);
            const rw = fmtDec(fb.fb_width, tbuf[0..]);
            fb.drawString(@intCast(tx + 96), @intCast(line_y), rw, 220, 220, 120, 26, 28, 35);
            line_y += 20;
            fb.drawString(@intCast(tx), @intCast(line_y), "Mouse: (", 180, 180, 180, 26, 28, 35);
            const mxv = fmtDec(@as(u64, @intCast(mouse.mx)), tbuf[0..]);
            const myv = fmtDec(@as(u64, @intCast(mouse.my)), tbuf[0..]);
            var xpos = tx + 64;
            fb.drawString(@intCast(xpos), @intCast(line_y), mxv, 220, 220, 120, 26, 28, 35);
            xpos += @as(i32, @intCast(mxv.len)) * 8;
            fb.drawString(@intCast(xpos), @intCast(line_y), ",", 180, 180, 180, 26, 28, 35);
            xpos += 8;
            fb.drawString(@intCast(xpos), @intCast(line_y), myv, 220, 220, 120, 26, 28, 35);
            xpos += @as(i32, @intCast(myv.len)) * 8;
            fb.drawString(@intCast(xpos), @intCast(line_y), ")", 180, 180, 180, 26, 28, 35);
        },
        .terminal => {
            fb.fillRect(@intCast(win.x + BORDER), @intCast(body_y), @intCast(win.w - 2 * BORDER), @intCast(body_h), 12, 14, 18);
            const cur_tty = tty_mod.get(win.tty_id);

            const vis_cols = @min(cur_tty.cols, @as(usize, @intCast(@divTrunc(win.w - 2 * BORDER - 8, 8))));
            const vis_rows = @min(cur_tty.rows, @as(usize, @intCast(@divTrunc(body_h - 8, 16))));

            const vga_colors = [_]u32{
                0x000000, 0x0000AA, 0x00AA00, 0x00AAAA,
                0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
                0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
                0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
            };

            var r: usize = 0;
            while (r < vis_rows) : (r += 1) {
                const py = body_y + 4 + @as(i32, @intCast(r * 16));
                var c: usize = 0;
                while (c < vis_cols) : (c += 1) {
                    const entry = cur_tty.buffer[r][c];
                    const ch: u8 = @intCast(entry & 0xFF);
                    const fg_idx: usize = @intCast((entry >> 8) & 0x0F);
                    const bg_idx: usize = @intCast((entry >> 12) & 0x0F);

                    const fg_col = vga_colors[fg_idx];
                    const bg_col = if (bg_idx == 0) 0x0C0E12 else vga_colors[bg_idx];

                    const px = tx + @as(i32, @intCast(c * 8));
                    fb.drawGlyph(@intCast(px), @intCast(py), if (ch == 0) ' ' else ch,
                        @intCast((fg_col >> 16) & 0xFF), @intCast((fg_col >> 8) & 0xFF), @intCast(fg_col & 0xFF),
                        @intCast((bg_col >> 16) & 0xFF), @intCast((bg_col >> 8) & 0xFF), @intCast(bg_col & 0xFF));
                }
            }

            // Draw cursor in TTY terminal
            if (win.focused and cur_tty.cursor_row < vis_rows and cur_tty.cursor_col < vis_cols) {
                const cpx = tx + @as(i32, @intCast(cur_tty.cursor_col * 8));
                const cpy = body_y + 4 + @as(i32, @intCast(cur_tty.cursor_row * 16));
                fb.drawString(@intCast(cpx), @intCast(cpy), "_", 240, 240, 240, 12, 14, 18);
            }
        },
        .calculator => {
            fb.fillRect(@intCast(win.x + 8), @intCast(body_y + 6), @intCast(win.w - 16), 24, 10, 12, 16);
            fb.drawRectBorder(@intCast(win.x + 8), @intCast(body_y + 6), @intCast(win.w - 16), 24, 1, 60, 80, 120);
            if (calc_len > 0) {
                fb.drawString(@intCast(win.x + 14), @intCast(body_y + 10), calc_display[0..calc_len], 240, 240, 140, 10, 12, 16);
            } else {
                fb.drawString(@intCast(win.x + 14), @intCast(body_y + 10), "0", 180, 180, 180, 10, 12, 16);
            }

            const btn_labels = [_][]const u8{
                "7", "8", "9", "/",
                "4", "5", "6", "*",
                "1", "2", "3", "-",
                "C", "0", "=", "+",
            };

            var row: usize = 0;
            while (row < 4) : (row += 1) {
                var col: usize = 0;
                while (col < 4) : (col += 1) {
                    const bx = win.x + 10 + @as(i32, @intCast(col * 38));
                    const by = body_y + 36 + @as(i32, @intCast(row * 28));
                    fb.fillRect(@intCast(bx), @intCast(by), 32, 22, 40, 48, 62);
                    fb.drawRectBorder(@intCast(bx), @intCast(by), 32, 22, 1, 70, 85, 110);
                    const idx = row * 4 + col;
                    fb.drawString(@intCast(bx + 12), @intCast(by + 3), btn_labels[idx], 240, 240, 240, 40, 48, 62);
                }
            }
        },
        .notepad => {
            fb.fillRect(@intCast(win.x + BORDER), @intCast(body_y), @intCast(win.w - 2 * BORDER), @intCast(body_h), 18, 22, 28);
            var i: usize = 0;
            while (i <= note_cur_line and i < NOTE_MAX_LINES) : (i += 1) {
                const ny = body_y + 6 + @as(i32, @intCast(i * 18));
                if (note_lens[i] > 0) {
                    fb.drawString(@intCast(tx), @intCast(ny), note_lines[i][0..note_lens[i]], 230, 230, 230, 18, 22, 28);
                }
                if (i == note_cur_line and win.focused) {
                    fb.drawString(@intCast(tx + @as(i32, @intCast(note_lens[i])) * 8), @intCast(ny), "|", 140, 200, 255, 18, 22, 28);
                }
            }
        },
        .launcher => {
            fb.drawString(@intCast(tx), @intCast(line_y), "FAT16 Programs (/mnt/disk):", 120, 200, 255, 26, 28, 35);
            line_y += 20;

            const progs = [_][]const u8{
                "1. /mnt/disk/hello.exe (Win32 PE)",
                "2. /mnt/disk/hello_linux (Linux ELF)",
                "3. /mnt/disk/busybox (Multi-call)",
            };
            for (progs) |p| {
                fb.drawString(@intCast(tx), @intCast(line_y), p, 200, 200, 200, 26, 28, 35);
                line_y += 18;
            }
            line_y += 6;
            fb.drawString(@intCast(tx), @intCast(line_y), "Open Terminal (tty1) to run them!", 140, 220, 140, 26, 28, 35);
        },
        .about => {
            fb.drawString(@intCast(tx), @intCast(line_y), "Zirconium OS GUI v0.4.0", 100, 200, 255, 26, 28, 35);
            line_y += 22;
            fb.drawString(@intCast(tx), @intCast(line_y), "Click 'Apps' for menu.", 200, 200, 200, 26, 28, 35);
            line_y += 20;
            fb.drawString(@intCast(tx), @intCast(line_y), "Drag windows by titlebar.", 180, 180, 180, 26, 28, 35);
            line_y += 20;
            fb.drawString(@intCast(tx), @intCast(line_y), "Resize: drag bottom-right.", 140, 220, 140, 26, 28, 35);
            line_y += 20;
            fb.drawString(@intCast(tx), @intCast(line_y), "Press Esc to exit GUI.", 220, 160, 120, 26, 28, 35);
        },
    }

    // Draw bottom-right resize grip
    const rx = win.x + win.w - 12;
    const ry = win.y + win.h - 12;
    fb.fillRect(@intCast(rx + 6), @intCast(ry + 6), 2, 2, 140, 170, 210);
    fb.fillRect(@intCast(rx + 2), @intCast(ry + 6), 2, 2, 140, 170, 210);
    fb.fillRect(@intCast(rx + 6), @intCast(ry + 2), 2, 2, 140, 170, 210);
}

fn drawWindow(win: *Window) void {
    if (!win.visible) return;
    const border_color: u32 = if (win.focused) 0x4080E0 else 0x404450;
    fb.drawRectBorder(@intCast(win.x), @intCast(win.y), @intCast(win.w), @intCast(win.h), @intCast(BORDER), @intCast((border_color >> 16) & 0xFF), @intCast((border_color >> 8) & 0xFF), @intCast(border_color & 0xFF));

    const bar_color: u32 = if (win.focused) 0x24488A else 0x303440;
    fb.fillRect(@intCast(win.x + BORDER), @intCast(win.y + BORDER), @intCast(win.w - 2 * BORDER), @intCast(TITLE_H - BORDER), @intCast((bar_color >> 16) & 0xFF), @intCast((bar_color >> 8) & 0xFF), @intCast(bar_color & 0xFF));
    const title_color: u32 = if (win.focused) 0xFFFFFF else 0xB0B0C0;
    fb.drawString(@intCast(win.x + 6), @intCast(win.y + BORDER + 2), win.title[0..win.title_len], @intCast((title_color >> 16) & 0xFF), @intCast((title_color >> 8) & 0xFF), @intCast(title_color & 0xFF), @intCast((bar_color >> 16) & 0xFF), @intCast((bar_color >> 8) & 0xFF), @intCast(bar_color & 0xFF));

    // Maximize / Restore button [□]
    const max_x = win.x + win.w - 34;
    const max_y = win.y + 2;
    fb.fillRect(@intCast(max_x), @intCast(max_y), 14, 14, 50, 90, 150);
    fb.drawRectBorder(@intCast(max_x), @intCast(max_y), 14, 14, 1, 100, 150, 220);
    fb.fillRect(@intCast(max_x + 3), @intCast(max_y + 3), 8, 8, 220, 230, 255);

    // Close button [X]
    const close_x = win.x + win.w - 18;
    const close_y = win.y + 2;
    fb.fillRect(@intCast(close_x), @intCast(close_y), 14, 14, 180, 50, 50);
    fb.drawString(@intCast(close_x + 3), @intCast(close_y - 1), "x", 255, 255, 255, 180, 50, 50);

    drawWindowBody(win);
}

fn drawStartMenu() void {
    if (!start_menu_open) return;
    const ty = @as(i32, @intCast(fb.fb_height)) - TASKBAR_H;
    const menu_h = @as(i32, @intCast(MENU_ITEMS_COUNT * MENU_ITEM_H + 28));
    const my = ty - menu_h - 2;

    fb.fillRect(START_BTN_X, @intCast(my), @as(u32, @intCast(MENU_W)), @as(u32, @intCast(menu_h)), 24, 28, 38);
    fb.drawRectBorder(START_BTN_X, @intCast(my), @as(u32, @intCast(MENU_W)), @as(u32, @intCast(menu_h)), 2, 70, 110, 180);

    // Menu Header
    fb.fillRect(START_BTN_X + 2, @intCast(my + 2), @as(u32, @intCast(MENU_W - 4)), 20, 36, 50, 80);
    fb.drawString(START_BTN_X + 8, @intCast(my + 4), "=== Applications ===", 100, 220, 255, 36, 50, 80);

    var i: usize = 0;
    while (i < MENU_ITEMS_COUNT) : (i += 1) {
        const item_y = my + 24 + @as(i32, @intCast(i * MENU_ITEM_H));
        const hovered = (mouse.mx >= START_BTN_X and mouse.mx < START_BTN_X + MENU_W and
            mouse.my >= item_y and mouse.my < item_y + MENU_ITEM_H);

        if (hovered) {
            fb.fillRect(START_BTN_X + 3, @intCast(item_y), @as(u32, @intCast(MENU_W - 6)), @as(u32, @intCast(MENU_ITEM_H - 2)), 50, 90, 160);
            fb.drawString(START_BTN_X + 8, @intCast(item_y + 2), menu_items[i], 255, 255, 255, 50, 90, 160);
        } else {
            fb.drawString(START_BTN_X + 8, @intCast(item_y + 2), menu_items[i], 200, 210, 230, 24, 28, 38);
        }
    }
}

fn drawTaskbar() void {
    const ty = @as(i32, @intCast(fb.fb_height)) - TASKBAR_H;
    fb.fillRect(0, @intCast(ty), fb.fb_width, @as(u32, @intCast(TASKBAR_H)), 18, 20, 28);
    fb.fillRect(0, @intCast(ty), fb.fb_width, 2, 60, 90, 150);

    // Start / Apps button
    const btn_bg: u32 = if (start_menu_open) 0x3068C0 else 0x253B60;
    fb.fillRect(START_BTN_X, @intCast(ty + 3), @as(u32, @intCast(START_BTN_W)), @as(u32, @intCast(START_BTN_H)), @intCast((btn_bg >> 16) & 0xFF), @intCast((btn_bg >> 8) & 0xFF), @intCast(btn_bg & 0xFF));
    fb.drawRectBorder(START_BTN_X, @intCast(ty + 3), @as(u32, @intCast(START_BTN_W)), @as(u32, @intCast(START_BTN_H)), 1, 80, 140, 230);
    fb.drawString(START_BTN_X + 8, @intCast(ty + 6), "[ Apps ]", 240, 240, 255, @intCast((btn_bg >> 16) & 0xFF), @intCast((btn_bg >> 8) & 0xFF), @intCast(btn_bg & 0xFF));

    // Taskbar app buttons
    var btn_x: i32 = START_BTN_X + START_BTN_W + 12;
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (!windows[i].visible) continue;
        const wbtn_bg: u32 = if (windows[i].focused) 0x304870 else 0x1E2430;
        fb.fillRect(@intCast(btn_x), @intCast(ty + 3), 96, @as(u32, @intCast(START_BTN_H)), @intCast((wbtn_bg >> 16) & 0xFF), @intCast((wbtn_bg >> 8) & 0xFF), @intCast(wbtn_bg & 0xFF));
        fb.drawRectBorder(@intCast(btn_x), @intCast(ty + 3), 96, @as(u32, @intCast(START_BTN_H)), 1, 60, 80, 110);
        const slen = @min(windows[i].title_len, 11);
        fb.drawString(@intCast(btn_x + 6), @intCast(ty + 6), windows[i].title[0..slen], 210, 220, 240, @intCast((wbtn_bg >> 16) & 0xFF), @intCast((wbtn_bg >> 8) & 0xFF), @intCast(wbtn_bg & 0xFF));
        btn_x += 104;
    }

    drawTaskbarClock();
    drawStartMenu();
}

fn drawTaskbarClock() void {
    const ty = @as(i32, @intCast(fb.fb_height)) - TASKBAR_H;
    var tbuf: [32]u8 = undefined;
    timer.formatTime(tbuf[0..9]);
    const time_width = 9 * 8;
    const xpos_time: i32 = @as(i32, @intCast(fb.fb_width)) - @as(i32, @intCast(time_width)) - 12;
    fb.fillRect(@intCast(xpos_time - 4), @intCast(ty + 4), @as(u32, @intCast(time_width + 8)), @as(u32, @intCast(TASKBAR_H - 8)), 18, 20, 28);
    fb.drawString(@intCast(xpos_time), @intCast(ty + 6), tbuf[0..8], 140, 220, 140, 18, 20, 28);
}

fn drawDesktopRect(px: i32, py: i32, pw: i32, ph: i32) void {
    const x0: i32 = if (px < 0) 0 else px;
    const y0: i32 = if (py < 0) 0 else py;
    const x1: i32 = @min(px + pw, @as(i32, @intCast(fb.fb_width)));
    const y1: i32 = @min(py + ph, @as(i32, @intCast(fb.fb_height)));
    const h = fb.fb_height;
    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        const t: u32 = @intCast(y);
        const r: u8 = @intCast(16 + @as(u32, (t * 2) / (h + 1)));
        const g: u8 = @intCast(22 + @as(u32, (t * 3) / (h + 1)));
        const b: u8 = @intCast(38 + @as(u32, (t * 6) / (h + 1)));
        if (x1 > x0) fb.fillRect(@intCast(x0), @intCast(y), @intCast(x1 - x0), 1, r, g, b);
    }
}

fn drawDesktop() void {
    drawDesktopRect(0, 0, @intCast(fb.fb_width), @intCast(fb.fb_height));
}

fn winIntersects(rx: i32, ry: i32, rw: i32, rh: i32, w: *const Window) bool {
    return w.x < rx + rw and rx < w.x + w.w and w.y < ry + rh and ry < w.y + w.h;
}

fn redrawRect(rx: i32, ry: i32, rw: i32, rh: i32) void {
    if (rw <= 0 or rh <= 0) return;
    drawDesktopRect(rx, ry, rw, rh);
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (!windows[i].visible) continue;
        if (windows[i].focused) continue;
        if (winIntersects(rx, ry, rw, rh, &windows[i])) drawWindow(&windows[i]);
    }
    i = 0;
    while (i < num_windows) : (i += 1) {
        if (!windows[i].visible) continue;
        if (!windows[i].focused) continue;
        if (winIntersects(rx, ry, rw, rh, &windows[i])) drawWindow(&windows[i]);
    }
    const taskbar_y = @as(i32, @intCast(fb.fb_height)) - TASKBAR_H;
    if (ry + rh > taskbar_y or start_menu_open) drawTaskbar();
}

fn redrawAll() void {
    restoreCursor();
    drawDesktop();
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (!windows[i].focused) drawWindow(&windows[i]);
    }
    i = 0;
    while (i < num_windows) : (i += 1) {
        if (windows[i].focused) drawWindow(&windows[i]);
    }
    drawTaskbar();
    fb.flush();
    drawCursor();
}

fn clockWindow() ?*Window {
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (windows[i].visible and windows[i].content == .clock) return &windows[i];
    }
    return null;
}

fn redrawWindowOnly(win: *Window) void {
    if (!win.visible) return;
    restoreCursor();
    drawWindow(win);
    fb.flush();
    drawCursor();
}

fn focusedWindow() ?*Window {
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (windows[i].visible and windows[i].focused) return &windows[i];
    }
    return null;
}

// ----- Public Entry Point -----

pub fn run() void {
    if (!fb.active) {
        vga.setColor(.light_red, .black);
        vga.write("  GUI requires a framebuffer (no text mode).\n");
        vga.setColor(.white, .black);
        return;
    }

    tty_mod.init();

    num_windows = 0;
    drag_index = -1;
    drag_mode = .none;
    prev_left = false;
    prev_right = false;
    drag_button = .none;
    cursor_drawn = false;
    start_menu_open = false;
    next_clock_tick = timer.ticks;
    next_gui_tty = 1;

    calc_len = 0;
    calc_val1 = 0;
    calc_op = 0;
    calc_new_num = true;

    note_cur_line = 0;
    note_lens = [_]usize{0} ** NOTE_MAX_LINES;
    const note_init = "Zirconium Notes";
    @memcpy(note_lines[0][0..note_init.len], note_init);
    note_lens[0] = note_init.len;

    const sw = @as(i32, @intCast(fb.fb_width));
    const sh = @as(i32, @intCast(fb.fb_height));

    drawDesktop();

    createWindow(.about, @divTrunc(sw, 2) - 120, @divTrunc(sh, 4), 240, 140, "Welcome", 0);
    createWindow(.terminal, 30, 40, 440, 270, "Terminal (tty1)", 1);
    createWindow(.dillo, 50, 40, 520, 340, "Dillo Web Browser", 0);
    createWindow(.clock, sw - 190, 40, 160, 110, "Clock", 0);

    redrawAll();
    mouse.debug_log = false;

    while (true) {
        if (kb.pollKey()) |k| {
            if (k == 0x1B) break; // Esc quits GUI

            if (focusedWindow()) |fwin| {
                if (fwin.content == .terminal) {
                    const cur_tty = tty_mod.get(fwin.tty_id);
                    if (cur_tty.handleKey(k)) {
                        redrawWindowOnly(fwin);
                    }
                } else if (fwin.content == .dillo) {
                    const dillo = dillo_prog.getDillo();
                    if (k == '\n' or k == '\r') {
                        dillo.loadUrl(dillo.url_buf[0..dillo.url_len]);
                        redrawWindowOnly(fwin);
                    } else if (k == 0x08) {
                        if (dillo.url_len > 0) {
                            dillo.url_len -= 1;
                            redrawWindowOnly(fwin);
                        }
                    } else if (k >= 0x20 and k < 0x7F and dillo.url_len < 120) {
                        dillo.url_buf[dillo.url_len] = k;
                        dillo.url_len += 1;
                        redrawWindowOnly(fwin);
                    }
                } else if (fwin.content == .notepad) {
                    if (k == '\n' or k == '\r') {
                        if (note_cur_line < NOTE_MAX_LINES - 1) {
                            note_cur_line += 1;
                            redrawWindowOnly(fwin);
                        }
                    } else if (k == 0x08) {
                        if (note_lens[note_cur_line] > 0) {
                            note_lens[note_cur_line] -= 1;
                            redrawWindowOnly(fwin);
                        } else if (note_cur_line > 0) {
                            note_cur_line -= 1;
                            redrawWindowOnly(fwin);
                        }
                    } else if (k >= 0x20 and k < 0x7F and note_lens[note_cur_line] < NOTE_LINE_LEN - 1) {
                        note_lines[note_cur_line][note_lens[note_cur_line]] = k;
                        note_lens[note_cur_line] += 1;
                        redrawWindowOnly(fwin);
                    }
                }
            }
        }

        const px = mouse.mx;
        const py = mouse.my;

        if (px != cursor_x or py != cursor_y) {
            if (drag_index >= 0 and @as(usize, @intCast(drag_index)) < num_windows) {
                const w = &windows[@intCast(drag_index)];
                const ox = w.x;
                const oy = w.y;
                const ow = w.w;
                const oh = w.h;

                if (drag_mode == .moving) {
                    w.x = px - drag_off_x;
                    w.y = py - drag_off_y;
                    if (w.x < 0) w.x = 0;
                    if (w.y < 0) w.y = 0;
                    if (w.x + w.w > sw) w.x = sw - w.w;
                    if (w.y + w.h > sh - TASKBAR_H) w.y = sh - TASKBAR_H - w.h;

                    if (w.x != ox or w.y != oy) {
                        restoreCursor();
                        const rx0 = @min(ox, w.x);
                        const ry0 = @min(oy, w.y);
                        const rx1 = @max(ox + w.w, w.x + w.w);
                        const ry1 = @max(oy + w.h, w.y + w.h);
                        redrawRect(rx0, ry0, rx1 - rx0, ry1 - ry0);
                        fb.flush();
                        drawCursor();
                    }
                } else if (drag_mode == .resizing) {
                    const new_w = @max(160, @min(sw - w.x, px - w.x + drag_off_x));
                    const new_h = @max(80, @min(sh - TASKBAR_H - w.y, py - w.y + drag_off_y));

                    if (new_w != ow or new_h != oh) {
                        w.w = new_w;
                        w.h = new_h;
                        w.saved_w = new_w;
                        w.saved_h = new_h;
                        restoreCursor();
                        const rx0 = w.x;
                        const ry0 = w.y;
                        const rw = @max(ow, w.w) + 2;
                        const rh = @max(oh, w.h) + 2;
                        redrawRect(rx0, ry0, rw, rh);
                        fb.flush();
                        drawCursor();
                    }
                }
            } else {
                restoreCursor();
                cursor_x = px;
                cursor_y = py;
                saveCursorBg(cursor_x, cursor_y);
                drawCursorShape();
                cursor_drawn = true;
            }
        }

        const left_pressed = mouse.left_button and !prev_left;
        const right_pressed = mouse.right_button and !prev_right;

        if (left_pressed or right_pressed) {
            const ty = sh - TASKBAR_H;

            // Check Start / Apps button click
            if (px >= START_BTN_X and px < START_BTN_X + START_BTN_W and py >= ty) {
                start_menu_open = !start_menu_open;
                redrawAll();
            } else if (start_menu_open) {
                const menu_h = @as(i32, @intCast(MENU_ITEMS_COUNT * MENU_ITEM_H + 28));
                const my = ty - menu_h - 2;

                if (px >= START_BTN_X and px < START_BTN_X + MENU_W and py >= my and py < ty) {
                    const item_idx = @as(usize, @intCast(@divTrunc(py - (my + 24), MENU_ITEM_H)));
                    start_menu_open = false;
                    switch (item_idx) {
                        0 => openOrCreateWindow(.dillo),
                        1 => openOrCreateWindow(.terminal),
                        2 => openOrCreateWindow(.clock),
                        3 => openOrCreateWindow(.system),
                        4 => openOrCreateWindow(.calculator),
                        5 => openOrCreateWindow(.notepad),
                        6 => openOrCreateWindow(.launcher),
                        7 => openOrCreateWindow(.about),
                        8 => break, // Exit GUI
                        else => {},
                    }
                    redrawAll();
                } else {
                    start_menu_open = false;
                    redrawAll();
                }
            } else if (drag_index < 0) {
                const hit = topmostAt(px, py);
                if (hit >= 0) {
                    allFocused(@intCast(hit));
                    const w = &windows[@intCast(hit)];

                    // Check [X] close button click
                    const close_x = w.x + w.w - 18;
                    const close_y = w.y + 2;
                    // Check [□] Maximize / Restore button click
                    const max_x = w.x + w.w - 34;
                    const max_y = w.y + 2;
                    // Check Bottom-Right Resize Grip Handle click
                    const resize_hit = (px >= w.x + w.w - 16 and px <= w.x + w.w and
                        py >= w.y + w.h - 16 and py <= w.y + w.h);

                    if (px >= close_x and px < close_x + 14 and py >= close_y and py < close_y + 14) {
                        w.visible = false;
                        redrawAll();
                    } else if (px >= max_x and px < max_x + 14 and py >= max_y and py < max_y + 14) {
                        if (w.is_maximized) {
                            w.x = w.saved_x;
                            w.y = w.saved_y;
                            w.w = w.saved_w;
                            w.h = w.saved_h;
                            w.is_maximized = false;
                        } else {
                            w.saved_x = w.x;
                            w.saved_y = w.y;
                            w.saved_w = w.w;
                            w.saved_h = w.h;
                            w.x = 4;
                            w.y = 4;
                            w.w = sw - 8;
                            w.h = sh - TASKBAR_H - 8;
                            w.is_maximized = true;
                        }
                        redrawAll();
                    } else if (resize_hit) {
                        drag_index = hit;
                        drag_mode = .resizing;
                        drag_button = if (left_pressed) .left else .right;
                        drag_off_x = w.w - (px - w.x);
                        drag_off_y = w.h - (py - w.y);
                        redrawAll();
                    } else if (py < w.y + TITLE_H) {
                        drag_index = hit;
                        drag_mode = .moving;
                        drag_button = if (left_pressed) .left else .right;
                        drag_off_x = px - w.x;
                        drag_off_y = py - w.y;
                        redrawAll();
                    } else {
                        // Body interaction for Dillo browser
                        if (w.content == .dillo) {
                            const body_y = w.y + TITLE_H + BORDER;
                            const dillo = dillo_prog.getDillo();

                            // Click Go button
                            const go_x = w.x + w.w - 46;
                            if (px >= go_x and px < go_x + 38 and py >= body_y + 6 and py < body_y + 26) {
                                dillo.loadUrl(dillo.url_buf[0..dillo.url_len]);
                                redrawWindowOnly(w);
                            }

                            // Bookmarks click
                            const bmy = body_y + 32;
                            if (py >= bmy and py < bmy + 16) {
                                if (px >= w.x + 10 and px < w.x + 70) {
                                    dillo.loadUrl("about:dillo");
                                    redrawWindowOnly(w);
                                } else if (px >= w.x + 85 and px < w.x + 155) {
                                    dillo.loadUrl("about:kernel");
                                    redrawWindowOnly(w);
                                } else if (px >= w.x + 175 and px < w.x + 270) {
                                    dillo.loadUrl("file:///mnt/disk/hello.txt");
                                    redrawWindowOnly(w);
                                } else if (px >= w.x + 295 and px < w.x + 390) {
                                    dillo.loadUrl("http://10.0.2.2/");
                                    redrawWindowOnly(w);
                                }
                            }

                            // Click links in content area
                            const view_y = body_y + 52;
                            for (dillo.links[0..dillo.link_count]) |lk| {
                                const lk_y = view_y + 6 + @as(i32, @intCast(lk.line_idx * 18));
                                if (py >= lk_y and py < lk_y + 16 and px >= w.x + 12 and px < w.x + w.w - 20) {
                                    dillo.loadUrl(lk.url[0..lk.url_len]);
                                    redrawWindowOnly(w);
                                    break;
                                }
                            }
                        } else if (w.content == .calculator) {
                            const body_y = w.y + TITLE_H + BORDER;
                            var row: usize = 0;
                            while (row < 4) : (row += 1) {
                                var col: usize = 0;
                                while (col < 4) : (col += 1) {
                                    const bx = w.x + 10 + @as(i32, @intCast(col * 38));
                                    const by = body_y + 36 + @as(i32, @intCast(row * 28));
                                    if (px >= bx and px < bx + 32 and py >= by and py < by + 22) {
                                        const bidx = row * 4 + col;
                                        handleCalcClick(bidx);
                                        redrawWindowOnly(w);
                                    }
                                }
                            }
                        }
                        redrawAll();
                    }
                }
            }
        } else if (drag_index >= 0) {
            const held = if (drag_button == .left) mouse.left_button else mouse.right_button;
            if (!held) {
                drag_index = -1;
                drag_mode = .none;
            }
        }

        prev_left = mouse.left_button;
        prev_right = mouse.right_button;

        if (timer.ticks >= next_clock_tick) {
            next_clock_tick = timer.ticks + 100;
            restoreCursor();
            if (clockWindow()) |w| {
                redrawRect(w.x, w.y, w.w, w.h);
            }
            drawTaskbarClock();
            fb.flush();
            drawCursor();
        }

        asm volatile ("pause");
    }

    redrawAll();
    vga.clear();
}

fn handleCalcClick(bidx: usize) void {
    const chars = "789/456*123-C0=+";
    if (bidx >= chars.len) return;
    const ch = chars[bidx];

    if (ch >= '0' and ch <= '9') {
        if (calc_new_num or calc_len == 0) {
            calc_display[0] = ch;
            calc_len = 1;
            calc_new_num = false;
        } else if (calc_len < 10) {
            calc_display[calc_len] = ch;
            calc_len += 1;
        }
    } else if (ch == 'C') {
        calc_len = 0;
        calc_val1 = 0;
        calc_op = 0;
        calc_new_num = true;
    } else if (ch == '+' or ch == '-' or ch == '*' or ch == '/') {
        calc_val1 = parseCalc();
        calc_op = ch;
        calc_new_num = true;
    } else if (ch == '=') {
        const val2 = parseCalc();
        var res: i64 = val2;
        if (calc_op == '+') res = calc_val1 + val2;
        if (calc_op == '-') res = calc_val1 - val2;
        if (calc_op == '*') res = calc_val1 * val2;
        if (calc_op == '/' and val2 != 0) res = @divTrunc(calc_val1, val2);

        var buf: [32]u8 = undefined;
        const ures: u64 = if (res < 0) @intCast(-res) else @intCast(res);
        const sres = fmtDec(ures, buf[0..]);
        var off: usize = 0;
        if (res < 0) {
            calc_display[0] = '-';
            off = 1;
        }
        @memcpy(calc_display[off..][0..sres.len], sres);
        calc_len = off + sres.len;
        calc_new_num = true;
        calc_op = 0;
    }
}

fn parseCalc() i64 {
    if (calc_len == 0) return 0;
    var v: i64 = 0;
    for (calc_display[0..calc_len]) |c| {
        if (c >= '0' and c <= '9') {
            v = v * 10 + @as(i64, @intCast(c - '0'));
        }
    }
    return v;
}