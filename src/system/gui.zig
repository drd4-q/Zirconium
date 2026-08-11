const std = @import("std");
const root = @import("root");
const vga = root.vga;
const fb = @import("framebuffer.zig");
const mouse = @import("../drivers/mouse.zig");
const kb = @import("../drivers/keyboard.zig");
const timer = @import("../drivers/timer.zig");
const pmm = root.pmm;

const TITLE_H: i32 = 18;
const BORDER: i32 = 1;
const TASKBAR_H: i32 = 26;
const MAX_WINDOWS: usize = 4;

const ContentType = enum(u8) {
    clock,
    system,
    about,
};

const Window = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 160,
    h: i32 = 120,
    title: [32]u8 = undefined,
    title_len: usize = 0,
    content: ContentType = .about,
    focused: bool = false,
    visible: bool = true,
};

var windows: [MAX_WINDOWS]Window = undefined;
var num_windows: usize = 0;
var drag_index: i32 = -1;
var drag_off_x: i32 = 0;
var drag_off_y: i32 = 0;
var prev_left: bool = false;
var cursor_drawn: bool = false;
var cursor_x: i32 = 0;
var cursor_y: i32 = 0;
var next_clock_tick: u64 = 0;

// ----- Window management -----

fn createWindow(c: ContentType, x: i32, y: i32, w: i32, h: i32, title: []const u8) void {
    if (num_windows >= MAX_WINDOWS) return;
    const win = &windows[num_windows];
    win.* = .{};
    win.content = c;
    win.x = x;
    win.y = y;
    win.w = w;
    win.h = h;
    win.title_len = @min(title.len, 32);
    @memcpy(win.title[0..win.title_len], title[0..win.title_len]);
    num_windows += 1;
}

fn topmostAt(gx: i32, gy: i32) i32 {
    // Draw order: last created is on top; focused windows render last.
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
        // Unfocused windows render first, so the last focused one wins ties.
        var k: usize = 0;
        while (k < num_windows) : (k += 1) {
            if (windows[k].focused and
                gx >= windows[k].x and gx < windows[k].x + windows[k].w and
                gy >= windows[k].y and gy < windows[k].y + windows[k].h)
            {
                best = @intCast(k);
                return best;
            }
        }
        var j: usize = 0;
        while (j < num_windows) : (j += 1) {
            if (j == @as(usize, @intCast(best))) continue;
            if (windows[j].focused) continue;
            if (!windows[j].visible) continue;
            if (gx >= windows[j].x and gx < windows[j].x + windows[j].w and
                gy >= windows[j].y and gy < windows[j].y + windows[j].h)
            {
                best = @intCast(j);
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

// ----- Cursor (XOR with saved background) -----

const CURSOR_W: usize = 12;
const CURSOR_H: usize = 16;
const CURSOR_MASK = [CURSOR_H]u16{
    0b100000000000,
    0b110000000000,
    0b111000000000,
    0b111100000000,
    0b111110000000,
    0b111111000000,
    0b111111100000,
    0b111111110000,
    0b111111111000,
    0b111111111100,
    0b111111100000,
    0b110111100000,
    0b110011000000,
    0b100011000000,
    0b000011000000,
    0b000011000000,
};
var cursor_bg: [CURSOR_W * CURSOR_H]u32 = undefined;

fn inBounds(x: i32, y: i32) bool {
    return x >= 0 and y >= 0 and @as(u32, @intCast(x)) < fb.fb_width and @as(u32, @intCast(y)) < fb.fb_height;
}

fn saveCursorBg(x: i32, y: i32) void {
    var cy: usize = 0;
    while (cy < CURSOR_H) : (cy += 1) {
        var cx: usize = 0;
        while (cx < CURSOR_W) : (cx += 1) {
            const px = x + @as(i32, @intCast(cx));
            const py = y + @as(i32, @intCast(cy));
            cursor_bg[cy * CURSOR_W + cx] = if (inBounds(px, py)) getDisplayed(px, py) else 0;
        }
    }
}

fn restoreCursorBg() void {
    var cy: usize = 0;
    while (cy < CURSOR_H) : (cy += 1) {
        var cx: usize = 0;
        while (cx < CURSOR_W) : (cx += 1) {
            const px = cursor_x + @as(i32, @intCast(cx));
            const py = cursor_y + @as(i32, @intCast(cy));
            if (inBounds(px, py)) putDisplayed(px, py, cursor_bg[cy * CURSOR_W + cx]);
        }
    }
}

fn drawCursorShape() void {
    var cy: usize = 0;
    while (cy < CURSOR_H) : (cy += 1) {
        const row = CURSOR_MASK[cy];
        var cx: usize = 0;
        while (cx < CURSOR_W) : (cx += 1) {
            if ((row >> @intCast(CURSOR_W - 1 - cx)) & 1 != 0) {
                const px = cursor_x + @as(i32, @intCast(cx));
                const py = cursor_y + @as(i32, @intCast(cy));
                if (inBounds(px, py)) {
                    const c = getDisplayed(px, py) ^ 0x00FFFFFF;
                    putDisplayed(px, py, c);
                }
            }
        }
    }
}

// The cursor writes straight to the LFB (no shadow, no dirty tracking), so it
// updates at the interval the mouse delivers packets — its own pace, "faster
// than the screen" renderer. Any screen redraw must restore the cursor first,
// flush, then re-draw the cursor last so it always stays on top.
fn getDisplayed(x: i32, y: i32) u32 {
    return fb.rawPixel(@intCast(x), @intCast(y));
}

fn putDisplayed(x: i32, y: i32, color: u32) void {
    fb.rawPutPixel(@intCast(x), @intCast(y), @intCast((color >> 16) & 0xFF), @intCast((color >> 8) & 0xFF), @intCast(color & 0xFF));
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

// ----- Drawing -----

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
    const body_color: u32 = 0x2A2A2A;
    fb.fillRect(@intCast(win.x + BORDER), @intCast(body_y), @intCast(win.w - 2 * BORDER), @intCast(body_h), @intCast((body_color >> 16) & 0xFF), @intCast((body_color >> 8) & 0xFF), @intCast(body_color & 0xFF));

    const tx = win.x + 8;
    var line_y = body_y + 6;

    switch (win.content) {
        .clock => {
            var tbuf: [32]u8 = undefined;
            timer.formatTime(tbuf[0..9]);
            fb.drawString(@intCast(tx), @intCast(line_y), tbuf[0..8], 230, 230, 230, 42, 42, 42);
            line_y += 22;
            fb.drawString(@intCast(tx), @intCast(line_y), "Uptime: ", 180, 180, 180, 42, 42, 42);
            const up = fmtDec(timer.ticks / 100, tbuf[0..]);
            fb.drawString(@intCast(tx + 64), @intCast(line_y), up, 180, 180, 180, 42, 42, 42);
            line_y += 22;
            fb.drawString(@intCast(tx + 64 + @as(i32, @intCast(up.len)) * 8), @intCast(line_y - 22), " sec", 120, 120, 120, 42, 42, 42);
        },
        .system => {
            var tbuf: [32]u8 = undefined;
            fb.drawString(@intCast(tx), @intCast(line_y), "Pages free:", 200, 200, 200, 42, 42, 42);
            const free = fmtDec(pmm.free_pages, tbuf[0..]);
            fb.drawString(@intCast(tx + 94), @intCast(line_y), free, 140, 220, 140, 42, 42, 42);
            line_y += 22;
            fb.drawString(@intCast(tx), @intCast(line_y), "/ total:", 200, 200, 200, 42, 42, 42);
            const total = fmtDec(pmm.total_pages, tbuf[0..]);
            fb.drawString(@intCast(tx + 94), @intCast(line_y), total, 140, 220, 140, 42, 42, 42);
            line_y += 22;
            fb.drawString(@intCast(tx), @intCast(line_y), "Mouse: (", 200, 200, 200, 42, 42, 42);
            const mxv = fmtDec(@as(u64, @intCast(mouse.mx)), tbuf[0..]);
            const myv = fmtDec(@as(u64, @intCast(mouse.my)), tbuf[0..]);
            var xpos = tx + 64;
            fb.drawString(@intCast(xpos), @intCast(line_y), mxv, 220, 220, 120, 42, 42, 42);
            xpos += @as(i32, @intCast(mxv.len)) * 8;
            fb.drawString(@intCast(xpos), @intCast(line_y), ", ", 200, 200, 200, 42, 42, 42);
            xpos += 16;
            fb.drawString(@intCast(xpos), @intCast(line_y), myv, 220, 220, 120, 42, 42, 42);
            xpos += @as(i32, @intCast(myv.len)) * 8;
            fb.drawString(@intCast(xpos), @intCast(line_y), ")", 200, 200, 200, 42, 42, 42);
        },
        .about => {
            fb.drawString(@intCast(tx), @intCast(line_y), "Zirconium GUI", 100, 200, 255, 42, 42, 42);
            line_y += 22;
            fb.drawString(@intCast(tx), @intCast(line_y), "Drag title bars.", 180, 180, 180, 42, 42, 42);
            line_y += 22;
            fb.drawString(@intCast(tx), @intCast(line_y), "Esc = back to shell", 180, 180, 180, 42, 42, 42);
        },
    }
}

fn drawWindow(win: *Window) void {
    if (!win.visible) return;
    const border_color: u32 = if (win.focused) 0x4068C8 else 0x505050;
    fb.drawRectBorder(@intCast(win.x), @intCast(win.y), @intCast(win.w), @intCast(win.h), @intCast(BORDER), @intCast((border_color >> 16) & 0xFF), @intCast((border_color >> 8) & 0xFF), @intCast(border_color & 0xFF));

    const bar_color: u32 = if (win.focused) 0x2A4AA0 else 0x404040;
    fb.fillRect(@intCast(win.x + BORDER), @intCast(win.y + BORDER), @intCast(win.w - 2 * BORDER), @intCast(TITLE_H - BORDER), @intCast((bar_color >> 16) & 0xFF), @intCast((bar_color >> 8) & 0xFF), @intCast(bar_color & 0xFF));
    const title_color: u32 = if (win.focused) 0xFFFFFF else 0xC0C0C0;
    fb.drawString(@intCast(win.x + 6), @intCast(win.y + BORDER + 2), win.title[0..win.title_len], @intCast((title_color >> 16) & 0xFF), @intCast((title_color >> 8) & 0xFF), @intCast(title_color & 0xFF), @intCast((bar_color >> 16) & 0xFF), @intCast((bar_color >> 8) & 0xFF), @intCast(bar_color & 0xFF));

    drawWindowBody(win);
}

fn drawTaskbar() void {
    const ty = @as(i32, @intCast(fb.fb_height)) - TASKBAR_H;
    fb.fillRect(0, @intCast(ty), fb.fb_width, @as(u32, @intCast(TASKBAR_H)), 20, 20, 30);
    fb.fillRect(0, @intCast(ty), fb.fb_width, 2, 90, 90, 120);
    fb.drawString(12, @intCast(ty + 6), "Zirconium GUI  -  Esc: quit", 170, 200, 220, 20, 20, 30);

    drawTaskbarClock();
}

fn drawTaskbarClock() void {
    // Localized update: only repaint the time text region in the taskbar
    // (avoids a full-width strip flush every second = band flicker).
    const ty = @as(i32, @intCast(fb.fb_height)) - TASKBAR_H;
    var tbuf: [32]u8 = undefined;
    timer.formatTime(tbuf[0..9]);
    const time_width = 9 * 8;
    const xpos_time: i32 = @as(i32, @intCast(fb.fb_width)) - @as(i32, @intCast(time_width)) - 12;
    fb.fillRect(@intCast(xpos_time - 4), @intCast(ty + 4), @as(u32, @intCast(time_width + 8)), @as(u32, @intCast(TASKBAR_H - 8)), 20, 20, 30);
    fb.drawString(@intCast(xpos_time), @intCast(ty + 6), tbuf[0..8], 140, 220, 140, 20, 20, 30);
}

fn drawDesktopRect(px: i32, py: i32, pw: i32, ph: i32) void {
    // Vertical gradient desktop, clipped to (px,py,pw,ph)
    const x0: i32 = if (px < 0) 0 else px;
    const y0: i32 = if (py < 0) 0 else py;
    const x1: i32 = @min(px + pw, @as(i32, @intCast(fb.fb_width)));
    const y1: i32 = @min(py + ph, @as(i32, @intCast(fb.fb_height)));
    const h = fb.fb_height;
    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        const t: u32 = @intCast(y);
        const r: u8 = @intCast(24 + @as(u32, (t * 2) / (h + 1)));
        const g: u8 = @intCast(30 + @as(u32, (t * 3) / (h + 1)));
        const b: u8 = @intCast(46 + @as(u32, (t * 5) / (h + 1)));
        if (x1 > x0) fb.fillRect(@intCast(x0), @intCast(y), @intCast(x1 - x0), 1, r, g, b);
    }
}

fn drawDesktop() void {
    drawDesktopRect(0, 0, @intCast(fb.fb_width), @intCast(fb.fb_height));
}

// Restore the desktop underneath a window so it can be moved/redrawn
// without repainting the whole screen.
fn eraseWindow(win: *Window) void {
    drawDesktopRect(win.x, win.y, win.w, win.h);
}

fn redrawAll() void {
    restoreCursor();
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (!windows[i].focused) drawWindow(&windows[i]);
    }
    i = 0;
    while (i < num_windows) : (i += 1) {
        if (windows[i].focused) drawWindow(&windows[i]);
    }
    drawTaskbar();
    // Cursor goes straight to the LFB and must be drawn AFTER the screen
    // flush, otherwise the flush would repaint over it.
    fb.flush();
    drawCursor();
}

fn clockWindow() ?*Window {
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (windows[i].content == .clock) return &windows[i];
    }
    return null;
}

pub fn run() void {
    if (!fb.active) {
        vga.setColor(.light_red, .black);
        vga.write("  GUI requires a framebuffer (no text mode).\n");
        vga.setColor(.white, .black);
        return;
    }

    num_windows = 0;
    drag_index = -1;
    prev_left = false;
    cursor_drawn = false;
    next_clock_tick = timer.ticks;

    const sw = @as(i32, @intCast(fb.fb_width));
    const sh = @as(i32, @intCast(fb.fb_height));

    drawDesktop();

    createWindow(.about, @divTrunc(sw, 2) - 120, @divTrunc(sh, 3), 200, 120, "Welcome");
    createWindow(.clock, 70, 70, 160, 110, "Clock");
    createWindow(.system, sw - 200 - 50, 70, 180, 130, "System");

    redrawAll();

    while (true) {
        if (kb.pollKey()) |k| {
            if (k == 0x1B) break; // Esc
        }

        const px = mouse.mx;
        const py = mouse.my;

        if (px != cursor_x or py != cursor_y) {
            if (drag_index >= 0 and @as(usize, @intCast(drag_index)) < num_windows) {
                const w = &windows[@intCast(drag_index)];
                const ox = w.x;
                const oy = w.y;
                w.x = px - drag_off_x;
                w.y = py - drag_off_y;
                if (w.x < 0) w.x = 0;
                if (w.y < 0) w.y = 0;
                if (w.x + w.w > sw) w.x = sw - w.w;
                if (w.y + w.h > sh - TASKBAR_H) w.y = sh - TASKBAR_H - w.h;
                if (w.x != ox or w.y != oy) {
                    // Localized redraw: restore desktop under the old spot,
                    // paint the window at the new spot, cursor on top.
                    restoreCursor();
                    eraseWindow(w);
                    drawWindow(w);
                    fb.flush();
                    drawCursor();
                }
            } else {
                // Pure cursor move: writes straight to the LFB, so it needs no
                // flush and tracks the mouse at packet rate — faster than the
                // screen renderer.
                restoreCursor();
                cursor_x = px;
                cursor_y = py;
                saveCursorBg(cursor_x, cursor_y);
                drawCursorShape();
                cursor_drawn = true;
            }
        }

        if (mouse.left_button and !prev_left) {
            if (drag_index < 0) {
                const hit = topmostAt(px, py);
                if (hit >= 0) {
                    allFocused(@intCast(hit));
                    const w = &windows[@intCast(hit)];
                    if (py < w.y + TITLE_H) {
                        drag_index = hit;
                        drag_off_x = px - w.x;
                        drag_off_y = py - w.y;
                    }
                    // Focus changed: refresh window chrome (borders/title bars).
                    redrawAll();
                }
            }
        }
        if (!mouse.left_button and prev_left) {
            drag_index = -1;
        }
        prev_left = mouse.left_button;

        if (timer.ticks >= next_clock_tick) {
            next_clock_tick = timer.ticks + 100; // 100 Hz ticks = ~1 s
            restoreCursor();
            if (clockWindow()) |w| {
                eraseWindow(w);
                drawWindow(w);
            }
            drawTaskbarClock();
            fb.flush();
            drawCursor();
        }

        // High-frequency cursor tracking: instead of blocking in HLT until the
        // next PIT/mouse IRQ (which paces the cursor at the interrupt rate and
        // looks jerky), spin on PAUSE so every mouse sample is caught and the
        // cursor is redrawn at ~GHz poll speed, the instant mx/my change.
        asm volatile ("pause");
    }

    redrawAll();
    vga.clear();
}