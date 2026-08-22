const std = @import("std");
const root = @import("root");

// Shadow buffer: all drawing happens here (fast RAM, packed 32-bit pixels),
// then flush() copies only the dirty region to the real framebuffer in one
// bulk pass. This avoids per-pixel volatile LFB writes and row-by-row
// redraws visible as flicker.
var shadow: [*]u32 = undefined;
var shadow_pixels: usize = 0;
var dirty_x0: u32 = 0;
var dirty_y0: u32 = 0;
var dirty_x1: u32 = 0;
var dirty_y1: u32 = 0;
var has_dirty: bool = false;

// Covers every resolution the shell's `resolution` command supports,
// plus common QEMU default modes like 1280x800 (GRUB may pick these on boot).
const MAX_SHADOW_PIXELS: usize = 1920 * 1080;

fn ensureShadow() bool {
    if (shadow_pixels != 0) return true;
    // PMM isn't ready until after system_init; retry lazily on first draw.
    // (free_pages stays 0 until pmm.init runs — allocating before then would
    //  corrupt the uninitialized PMM bitmap.)
    if (root.pmm.free_pages == 0) return false;
    const pixels = @as(u64, fb_width) * fb_height;
    if (pixels > MAX_SHADOW_PIXELS) return false;
    const bytes = (pixels * 4 + 4095) & ~@as(u64, 4095);
    const pages = @as(usize, @intCast(bytes / 4096));
    const phys = root.pmm.allocPages(pages) orelse return false;
    shadow = @ptrFromInt(phys);
    shadow_pixels = @intCast(pixels);
    @memset(shadow[0..shadow_pixels], 0);
    return true;
}

pub var fb_addr: u64 = 0;
pub var fb_pitch: u32 = 0;
pub var fb_width: u32 = 0;
pub var fb_height: u32 = 0;
pub var fb_bpp: u32 = 0;
pub var fb_type: u32 = 0;
/// Bytes per pixel on the real LFB: 4 for the classic XRGB8888 layout, 3 when
/// the bootloader only offered a 24bpp mode (common with VBE). Everything that
/// touches the LFB goes through lfbPut/lfbGet or branches on this.
var fb_bytes_pp: u32 = 4;

inline fn lfbOffset(y: u32, x: u32) u64 {
    return @as(u64, y) * fb_pitch + @as(u64, x) * fb_bytes_pp;
}

/// Write one RGB pixel straight to the LFB.
fn lfbPut(x: u32, y: u32, rgb: u32) void {
    const p: [*]volatile u8 = @ptrFromInt(fb_addr + lfbOffset(y, x));
    p[0] = @truncate(rgb);
    p[1] = @truncate(rgb >> 8);
    p[2] = @truncate(rgb >> 16);
    if (fb_bytes_pp == 4) p[3] = 0;
}

/// Read one RGB pixel straight from the LFB.
fn lfbGet(x: u32, y: u32) u32 {
    const p: [*]volatile u8 = @ptrFromInt(fb_addr + lfbOffset(y, x));
    return (@as(u32, p[2]) << 16) | (@as(u32, p[1]) << 8) | @as(u32, p[0]);
}

pub var cols: usize = 80;
pub var rows: usize = 25;
pub const char_w: usize = 8;
pub const char_h: usize = 16;

pub var cursor_row: usize = 0;
pub var cursor_col: usize = 0;
pub var fg_r: u8 = 255;
pub var fg_g: u8 = 255;
pub var fg_b: u8 = 255;
pub var bg_r: u8 = 0;
pub var bg_g: u8 = 0;
pub var bg_b: u8 = 0;

pub var active: bool = false;

// Screen mirror: tracks what's on screen for scrollback
const MAX_COLS: usize = 80;
const MAX_ROWS: usize = 50;
var screen_mirror: [MAX_ROWS][MAX_COLS]u16 = undefined; // char | (fg_color << 8) | (bg_color << 12)
var screen_dirty: bool = false;

fn clearMirror() void {
    var r: usize = 0;
    while (r < MAX_ROWS) : (r += 1) {
        var c: usize = 0;
        while (c < MAX_COLS) : (c += 1) {
            screen_mirror[r][c] = 0;
        }
    }
}

// Scrollback buffer
const SCROLLBACK_LINES: usize = 512;
var scrollback: [SCROLLBACK_LINES][MAX_COLS]u16 = undefined;
var sb_head: usize = 0;
var sb_count: usize = 0;

// Saved live screen for returning from scrollback
var saved_screen: [MAX_ROWS][MAX_COLS]u16 = undefined;
var saved_cursor_row: usize = 0;
var saved_cursor_col: usize = 0;
pub var scroll_view: bool = false;
pub var scroll_view_line: usize = 0; // which line in scrollback is at top of screen

pub fn initFromMultiboot(mbi_ptr: u32) void {
    const mbi: [*]const u8 = @ptrFromInt(mbi_ptr);
    const serial = @import("serial.zig");

    const flags = @as(u32, @intCast(mbi[0])) | (@as(u32, @intCast(mbi[1])) << 8) |
        (@as(u32, @intCast(mbi[2])) << 16) | (@as(u32, @intCast(mbi[3])) << 24);
    if ((flags & (1 << 12)) == 0) {
        serial.serialWrite("[FB] No framebuffer info from bootloader (MBI flags=0x");
        serial.serialWriteHex(flags);
        serial.serialWrite("); staying in VGA text mode\n");
        return;
    }

    fb_addr = @as(u64, @intCast(mbi[88])) |
        (@as(u64, @intCast(mbi[89])) << 8) |
        (@as(u64, @intCast(mbi[90])) << 16) |
        (@as(u64, @intCast(mbi[91])) << 24) |
        (@as(u64, @intCast(mbi[92])) << 32) |
        (@as(u64, @intCast(mbi[93])) << 40) |
        (@as(u64, @intCast(mbi[94])) << 48) |
        (@as(u64, @intCast(mbi[95])) << 56);

    fb_pitch = @as(u32, @intCast(mbi[96])) |
        (@as(u32, @intCast(mbi[97])) << 8) |
        (@as(u32, @intCast(mbi[98])) << 16) |
        (@as(u32, @intCast(mbi[99])) << 24);

    fb_width = @as(u32, @intCast(mbi[100])) |
        (@as(u32, @intCast(mbi[101])) << 8) |
        (@as(u32, @intCast(mbi[102])) << 16) |
        (@as(u32, @intCast(mbi[103])) << 24);

    fb_height = @as(u32, @intCast(mbi[104])) |
        (@as(u32, @intCast(mbi[105])) << 8) |
        (@as(u32, @intCast(mbi[106])) << 16) |
        (@as(u32, @intCast(mbi[107])) << 24);

    fb_bpp = @as(u32, @intCast(mbi[108]));

    fb_type = @as(u32, @intCast(mbi[109]));

    if (fb_addr == 0 or fb_width == 0 or fb_height == 0) {
        serial.serialWrite("[FB] Degenerate framebuffer info; staying in text mode\n");
        return;
    }
    // Only packed RGB is supported. GRUB/QEMU frequently hand out an
    // 800x600x24 VBE mode when the requested 32bpp one is unavailable, so
    // accept both rather than drawing invisibly.
    if (fb_bpp != 32 and fb_bpp != 24) {
        serial.serialWrite("[FB] Unsupported depth ");
        serial.serialWriteDec(fb_bpp);
        serial.serialWrite("bpp (need 24 or 32); staying in text mode\n");
        return;
    }
    fb_bytes_pp = fb_bpp / 8;

    serial.serialWrite("[FB] LFB ");
    serial.serialWriteDec(fb_width);
    serial.serialWrite("x");
    serial.serialWriteDec(fb_height);
    serial.serialWrite("x");
    serial.serialWriteDec(fb_bpp);
    serial.serialWrite(" @0x");
    serial.serialWriteHex(@truncate(fb_addr));
    serial.serialWrite("\n");

    cols = fb_width / char_w;
    rows = fb_height / char_h;
    if (cols > MAX_COLS) cols = MAX_COLS;
    if (rows > MAX_ROWS) rows = MAX_ROWS;

    active = true;
    clearMirror();
}

pub fn setResolution(new_w: u32, new_h: u32) void {
    if (!active) return;
    fb_width = new_w;
    fb_height = new_h;
    cols = fb_width / char_w;
    rows = fb_height / char_h;
    if (cols > MAX_COLS) cols = MAX_COLS;
    if (rows > MAX_ROWS) rows = MAX_ROWS;
    cursor_row = 0;
    cursor_col = 0;
    clear();
}

pub fn clear() void {
    if (!active) return;
    var y: u32 = 0;
    while (y < fb_height) : (y += 1) {
        var x: u32 = 0;
        while (x < fb_width) : (x += 1) {
            putPixel(x, y, bg_r, bg_g, bg_b);
        }
    }
    clearMirror();
    cursor_row = 0;
    cursor_col = 0;
    scroll_view = false;
    flush();
}

pub fn setColorRGB(fg: u32, bg: u32) void {
    fg_r = @intCast((fg >> 16) & 0xFF);
    fg_g = @intCast((fg >> 8) & 0xFF);
    fg_b = @intCast(fg & 0xFF);
    bg_r = @intCast((bg >> 16) & 0xFF);
    bg_g = @intCast((bg >> 8) & 0xFF);
    bg_b = @intCast(bg & 0xFF);
}

pub fn setColorFromVga(fg_vga: u8, bg_vga: u8) void {
    const table = [_]u32{
        0x000000, 0x0000AA, 0x00AA00, 0x00AAAA,
        0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
        0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
        0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
    };
    setColorRGB(table[fg_vga & 0x0F], table[bg_vga & 0x0F]);
}

pub fn putPixel(x: u32, y: u32, r: u8, g: u8, b: u8) void {
    if (x >= fb_width or y >= fb_height) return;
    if (ensureShadow() and x < fb_width and y < fb_height) {
        shadow[@as(u64, y) * fb_width + x] = (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
        markDirty(x, y);
        return;
    }
    lfbPut(x, y, (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b));
}

pub fn getPixel(x: u32, y: u32) u32 {
    if (x >= fb_width or y >= fb_height) return 0;
    if (shadow_pixels != 0 and x < fb_width and y < fb_height) {
        return shadow[@as(u64, y) * fb_width + x];
    }
    return lfbGet(x, y);
}

// LFB-only accessors: bypass the shadow buffer and dirty tracking entirely.
// Used for the mouse cursor so it updates at its own rate (directly on the
// real framebuffer) instead of being batched into the screen renderer's
// shadow -> flush pipeline.
pub fn rawPutPixel(x: u32, y: u32, r: u8, g: u8, b: u8) void {
    if (x >= fb_width or y >= fb_height) return;
    lfbPut(x, y, (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b));
}

pub fn rawPixel(x: u32, y: u32) u32 {
    if (x >= fb_width or y >= fb_height) return 0;
    return lfbGet(x, y);
}

pub fn markDirtyRect(x: u32, y: u32, w: u32, h: u32) void {
    if (w == 0 or h == 0) return;
    const x1 = x + w;
    const y1 = y + h;
    if (!has_dirty) {
        dirty_x0 = x;
        dirty_y0 = y;
        dirty_x1 = x1;
        dirty_y1 = y1;
        has_dirty = true;
    } else {
        if (x < dirty_x0) dirty_x0 = x;
        if (y < dirty_y0) dirty_y0 = y;
        if (x1 > dirty_x1) dirty_x1 = x1;
        if (y1 > dirty_y1) dirty_y1 = y1;
    }
}

fn markDirty(x: u32, y: u32) void {
    markDirtyRect(x, y, 1, 1);
}

/// Copy the dirty shadow region to the real framebuffer in bulk.
pub fn flush() void {
    if (!has_dirty or shadow_pixels == 0) return;
    const x0 = dirty_x0;
    const y0 = dirty_y0;
    const x1 = @min(dirty_x1, fb_width);
    const y1 = @min(dirty_y1, fb_height);
    has_dirty = false;
    if (x0 >= x1 or y0 >= y1) return;

    const w = x1 - x0;
    var y: u32 = y0;
    while (y < y1) : (y += 1) {
        const row_off = @as(u64, y) * fb_width + x0;
        const src: [*]const u32 = shadow + row_off;
        if (fb_bytes_pp == 4) {
            const dst: [*]volatile u32 = @ptrFromInt(fb_addr + @as(u64, y) * fb_pitch + @as(u64, x0) * 4);
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                dst[x] = src[x];
            }
        } else {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                lfbPut(x0 + x, y, src[x]);
            }
        }
    }
}

pub fn fillRect(px: u32, py: u32, pw: u32, ph: u32, r: u8, g: u8, b: u8) void {
    if (px >= fb_width or py >= fb_height or pw == 0 or ph == 0) return;
    const x0 = px;
    const y0 = py;
    const x1 = @min(px + pw, fb_width);
    const y1 = @min(py + ph, fb_height);
    const w = x1 - x0;
    const col: u32 = (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);

    if (ensureShadow() and shadow_pixels != 0) {
        var y: u32 = y0;
        while (y < y1) : (y += 1) {
            const row = shadow + @as(u64, y) * fb_width + x0;
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                row[x] = col;
            }
        }
        markDirtyRect(x0, y0, w, y1 - y0);
        return;
    }

    var y: u32 = y0;
    while (y < y1) : (y += 1) {
        if (fb_bytes_pp == 4) {
            const offset = @as(u64, y) * fb_pitch + @as(u64, x0) * 4;
            const ptr: [*]volatile u8 = @ptrFromInt(fb_addr + offset);
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                ptr[x * 4] = b;
                ptr[x * 4 + 1] = g;
                ptr[x * 4 + 2] = r;
                ptr[x * 4 + 3] = 0;
            }
        } else {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                lfbPut(x0 + x, y, col);
            }
        }
    }
}

pub fn drawRectBorder(px: u32, py: u32, pw: u32, ph: u32, thickness: u32, r: u8, g: u8, b: u8) void {
    fillRect(px, py, pw, thickness, r, g, b);
    fillRect(px, py + ph - thickness, pw, thickness, r, g, b);
    fillRect(px, py, thickness, ph, r, g, b);
    fillRect(px + pw - thickness, py, thickness, ph, r, g, b);
}

pub fn drawGlyph(px: u32, py: u32, ch: u8, fr: u8, fg: u8, fb_col: u8, br: u8, bg: u8, bb: u8) void {
    if (px + char_w > fb_width or py + char_h > fb_height) return;
    const glyph = getGlyph(ch);
    const fg_pixel: u32 = (@as(u32, fr) << 16) | (@as(u32, fg) << 8) | @as(u32, fb_col);
    const bg_pixel: u32 = (@as(u32, br) << 16) | (@as(u32, bg) << 8) | @as(u32, bb);

    if (ensureShadow() and shadow_pixels != 0) {
        var gy: usize = 0;
        while (gy < char_h) : (gy += 1) {
            const bits = glyph[gy];
            const row = shadow + @as(u64, py + @as(u32, @intCast(gy))) * fb_width + px;
            var gx: usize = 0;
            while (gx < char_w) : (gx += 1) {
                if ((@as(u8, 0x80) >> @intCast(gx)) & bits != 0) {
                    row[gx] = fg_pixel;
                } else {
                    row[gx] = bg_pixel;
                }
            }
        }
        markDirtyRect(px, py, @as(u32, @intCast(char_w)), @as(u32, @intCast(char_h)));
        return;
    }

    var gy: usize = 0;
    while (gy < char_h) : (gy += 1) {
        const bits = glyph[gy];
        var gx: usize = 0;
        while (gx < char_w) : (gx += 1) {
            const x = px + @as(u32, @intCast(gx));
            const y = py + @as(u32, @intCast(gy));
            if ((@as(u8, 0x80) >> @intCast(gx)) & bits != 0) {
                putPixel(x, y, fr, fg, fb_col);
            } else {
                putPixel(x, y, br, bg, bb);
            }
        }
    }
}

pub fn drawString(px: u32, py: u32, s: []const u8, fr: u8, fg: u8, fb_col: u8, br: u8, bg: u8, bb: u8) void {
    if (py + char_h > fb_height or px >= fb_width or s.len == 0) return;
    const fg_pixel: u32 = (@as(u32, fr) << 16) | (@as(u32, fg) << 8) | @as(u32, fb_col);
    const bg_pixel: u32 = (@as(u32, br) << 16) | (@as(u32, bg) << 8) | @as(u32, bb);

    const max_chars = @min(s.len, @as(usize, @intCast((fb_width - px) / char_w)));
    if (max_chars == 0) return;

    if (ensureShadow() and shadow_pixels != 0) {
        var c_idx: usize = 0;
        while (c_idx < max_chars) : (c_idx += 1) {
            const ch = s[c_idx];
            const ch_x = px + @as(u32, @intCast(c_idx * char_w));
            const glyph = getGlyph(ch);

            var gy: usize = 0;
            while (gy < char_h) : (gy += 1) {
                const bits = glyph[gy];
                const row = shadow + @as(u64, py + @as(u32, @intCast(gy))) * fb_width + ch_x;
                var gx: usize = 0;
                while (gx < char_w) : (gx += 1) {
                    if ((@as(u8, 0x80) >> @intCast(gx)) & bits != 0) {
                        row[gx] = fg_pixel;
                    } else {
                        row[gx] = bg_pixel;
                    }
                }
            }
        }
        markDirtyRect(px, py, @as(u32, @intCast(max_chars * char_w)), @as(u32, @intCast(char_h)));
        return;
    }

    var x = px;
    for (s[0..max_chars]) |ch| {
        drawGlyph(x, py, ch, fr, fg, fb_col, br, bg, bb);
        x += char_w;
    }
}

fn makeEntry(ch: u8) u16 {
    const fg8 = vgaTo8(fg_r, fg_g, fg_b);
    const bg8 = vgaTo8(bg_r, bg_g, bg_b);
    return @as(u16, ch) | (@as(u16, fg8) << 8) | (@as(u16, bg8) << 12);
}

fn vgaTo8(r: u8, g: u8, b: u8) u8 {
    // Convert RGB to nearest VGA 4-bit color
    const luminance: u32 = @as(u32, r) + @as(u32, g) + @as(u32, b);
    if (luminance < 60) return 0; // black
    if (r > 200 and g < 80 and b < 80) return 4; // red
    if (r < 80 and g > 200 and b < 80) return 2; // green
    if (r < 80 and g < 80 and b > 200) return 1; // blue
    if (r > 200 and g > 200 and b < 80) return 14; // yellow
    if (r > 200 and g < 80 and b > 200) return 5; // magenta
    if (r < 80 and g > 200 and b > 200) return 3; // cyan
    if (r > 200 and g > 200 and b > 200) return 15; // white
    if (luminance < 200) return 8; // dark_gray
    return 7; // light_gray
}

fn drawCharAt(col: usize, row: usize, ch: u8) void {
    if (col >= cols or row >= rows) return;
    const px = @as(u32, @intCast(col * char_w));
    const py = @as(u32, @intCast(row * char_h));

    const glyph = getGlyph(ch);

    var gy: usize = 0;
    while (gy < char_h) : (gy += 1) {
        const bits = glyph[gy];
        var gx: usize = 0;
        while (gx < char_w) : (gx += 1) {
            if ((@as(u8, 0x80) >> @intCast(gx)) & bits != 0) {
                putPixel(px + @as(u32, @intCast(gx)), py + @as(u32, @intCast(gy)), fg_r, fg_g, fg_b);
            } else {
                putPixel(px + @as(u32, @intCast(gx)), py + @as(u32, @intCast(gy)), bg_r, bg_g, bg_b);
            }
        }
    }
}

fn redrawRow(row: usize) void {
    if (row >= rows) return;
    for (0..cols) |col| {
        const entry = screen_mirror[row][col];
        const ch: u8 = @intCast(entry & 0xFF);
        const fg4: u8 = @intCast((entry >> 8) & 0x0F);
        const bg4: u8 = @intCast((entry >> 12) & 0x0F);
        const fgt = [_]u32{ 0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA, 0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF };
        const fg = fgt[fg4];
        const bg = fgt[bg4];
        fg_r = @intCast((fg >> 16) & 0xFF);
        fg_g = @intCast((fg >> 8) & 0xFF);
        fg_b = @intCast(fg & 0xFF);
        bg_r = @intCast((bg >> 16) & 0xFF);
        bg_g = @intCast((bg >> 8) & 0xFF);
        bg_b = @intCast(bg & 0xFF);
        drawCharAt(col, row, if (ch == 0) ' ' else ch);
    }
}

pub fn scrollUp() void {
    if (!active) return;

    // Save top line to scrollback
    scrollback[sb_head] = screen_mirror[0];
    sb_head = (sb_head + 1) % SCROLLBACK_LINES;
    if (sb_count < SCROLLBACK_LINES) sb_count += 1;

    // Shift screen mirror up
    var y: usize = 0;
    while (y < rows - 1) : (y += 1) {
        screen_mirror[y] = screen_mirror[y + 1];
    }
    // Clear bottom row in mirror
    {
        var c: usize = 0;
        while (c < MAX_COLS) : (c += 1) {
            screen_mirror[rows - 1][c] = 0;
        }
    }

    // Physically shift the LFB + shadow text region up by one 16px row
    // instead of repainting every row: the bulk of the screen never gets
    // rewritten, so scrolling only flushes the newly exposed bottom row
    // (avoids a full-screen rewrite per newline = constant flicker).
    // When there is no shadow buffer (oversized fb), fall back to repainting
    // every row straight from the mirror.
    const text_w = cols * char_w;
    const row_px = char_h;
    if (rows > 1 and shadow_pixels != 0) {
        var py: usize = row_px;
        while (py < rows * row_px) : (py += 1) {
            const dst_sh: [*]u32 = shadow + @as(u64, py - row_px) * fb_width;
            const src_sh: [*]const u32 = shadow + @as(u64, py) * fb_width;
            @memcpy(dst_sh[0..text_w], src_sh[0..text_w]);

            // Byte-wise row copy works for any bpp since both rows start at
            // x=0 (offsets are just y * pitch).
            const dst_lfb: [*]volatile u8 = @ptrFromInt(fb_addr + @as(u64, py - row_px) * fb_pitch);
            const src_lfb: [*]volatile const u8 = @ptrFromInt(fb_addr + @as(u64, py) * fb_pitch);
            const row_bytes = @as(usize, text_w) * fb_bytes_pp;
            var b: usize = 0;
            while (b < row_bytes) : (b += 1) {
                dst_lfb[b] = src_lfb[b];
            }
        }

        // Repaint the newly exposed bottom text row (goes through putPixel →
        // shadow, so only this row becomes dirty and gets flushed).
        const bottom_y0: u32 = @intCast((rows - 1) * char_h);
        fillRect(0, bottom_y0, @intCast(text_w), @intCast(char_h), bg_r, bg_g, bg_b);
        flush();
    } else {
        // No shadow buffer: redraw every row directly to the LFB.
        for (0..rows) |ry| {
            redrawRow(ry);
        }
    }
}

pub fn putChar(ch: u8) void {
    if (!active) return;

    // Exit scroll view on any input
    if (scroll_view) {
        exitScrollView();
    }

    if (ch == '\n') {
        cursor_col = 0;
        cursor_row += 1;
        if (cursor_row >= rows) {
            scrollUp();
            cursor_row = rows - 1;
        }
        return;
    }
    if (ch == '\r') {
        cursor_col = 0;
        return;
    }
    if (ch == '\t') {
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
    }

    // Update screen mirror
    if (cursor_row < rows and cursor_col < cols) {
        screen_mirror[cursor_row][cursor_col] = makeEntry(ch);
    }
    drawCharAt(cursor_col, cursor_row, ch);
    cursor_col += 1;
    if (cursor_col >= cols) {
        cursor_col = 0;
        cursor_row += 1;
        if (cursor_row >= rows) {
            scrollUp();
            cursor_row = rows - 1;
        }
    }
    flush();
}

pub fn write(str: []const u8) void {
    for (str) |ch| {
        putChar(ch);
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

// Scrollback navigation
pub fn scrollBack(lines: usize) void {
    if (!active or sb_count == 0) return;

    if (!scroll_view) {
        // Save current live screen
        saved_screen = screen_mirror;
        saved_cursor_row = cursor_row;
        saved_cursor_col = cursor_col;
        scroll_view = true;
        // Start viewing from the most recent scrollback line
        scroll_view_line = sb_count;
    }

    if (scroll_view_line >= lines) {
        scroll_view_line -= lines;
    } else {
        scroll_view_line = 1;
    }

    renderScrollView();
}

pub fn scrollForward(lines: usize) void {
    if (!active or !scroll_view) return;

    scroll_view_line += lines;
    if (scroll_view_line >= sb_count) {
        exitScrollView();
        return;
    }

    renderScrollView();
}

fn renderScrollView() void {
    // Render scrollback lines onto screen
    var screen_row: usize = 0;
    var sb_idx: usize = sb_count - scroll_view_line;
    // sb_idx is the line at the top of the screen

    while (screen_row < rows and sb_idx < sb_count) : (screen_row += 1) {
        const ring_idx = (sb_head + SCROLLBACK_LINES - sb_count + sb_idx) % SCROLLBACK_LINES;
        screen_mirror[screen_row] = scrollback[ring_idx];
        redrawRow(screen_row);
        sb_idx += 1;
    }
    // Restore saved screen below scrollback lines
    while (screen_row < rows) : (screen_row += 1) {
        screen_mirror[screen_row] = saved_screen[screen_row];
        redrawRow(screen_row);
    }

    // Show indicator
    const fgt = [_]u32{ 0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA, 0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF };
    fg_r = @intCast((fgt[11] >> 16) & 0xFF);
    fg_g = @intCast((fgt[11] >> 8) & 0xFF);
    fg_b = @intCast(fgt[11] & 0xFF);
    bg_r = @intCast((fgt[0] >> 16) & 0xFF);
    bg_g = @intCast((fgt[0] >> 8) & 0xFF);
    bg_b = @intCast(fgt[0] & 0xFF);

    // Draw "[Page X/Y]" indicator at bottom
    var indicator_buf: [32]u8 = undefined;
    const indicator = "[Scrollback: PgUp/PgDn/Esc]";
    for (indicator, 0..) |ch, i| {
        if (i < 32) indicator_buf[i] = ch;
    }
    const ind_len = indicator.len;
    var ix: usize = 0;
    while (ix < ind_len and ix < cols) : (ix += 1) {
        if (rows > 0) {
            const r = rows - 1;
            screen_mirror[r][cols - 1 - (ind_len - 1 - ix)] = makeEntry(indicator_buf[ix]);
            drawCharAt(cols - 1 - (ind_len - 1 - ix), r, indicator_buf[ix]);
        }
    }
    flush();
}

pub fn exitScrollView() void {
    if (!active or !scroll_view) return;
    scroll_view = false;
    // Restore live screen
    screen_mirror = saved_screen;
    cursor_row = saved_cursor_row;
    cursor_col = saved_cursor_col;
    for (0..rows) |ry| {
        redrawRow(ry);
    }
    flush();
}

// VGA 8x16 bitmap font (CP437 glyphs for printable ASCII 0x20-0x7E)
const font_data = [95][16]u8{
    .{ 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x18,0x3C,0x3C,0x3C,0x18,0x18,0x18,0x00,0x18,0x18,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x66,0x66,0x66,0x24,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x6C,0x6C,0xFE,0x6C,0x6C,0xFE,0x6C,0x6C,0x00,0x00,0x00,0x00,0x00 },
    .{ 0x18,0x18,0x7C,0xC6,0xC2,0xC0,0x7C,0x06,0x06,0x86,0xC6,0x7C,0x18,0x18,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0xC2,0xC6,0x0C,0x18,0x30,0x60,0xC6,0x86,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x38,0x6C,0x6C,0x38,0x76,0xDC,0xCC,0xCC,0xCC,0x76,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x30,0x30,0x30,0x60,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x0C,0x18,0x30,0x30,0x30,0x30,0x30,0x30,0x18,0x0C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x30,0x18,0x0C,0x0C,0x0C,0x0C,0x0C,0x0C,0x18,0x30,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x18,0x30,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFE,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x02,0x06,0x0C,0x18,0x30,0x60,0xC0,0x80,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x7C,0xC6,0xC6,0xCE,0xDE,0xF6,0xE6,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x18,0x38,0x78,0x18,0x18,0x18,0x18,0x18,0x18,0x7E,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x7C,0xC6,0x06,0x0C,0x18,0x30,0x60,0xC0,0xC6,0xFE,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x7C,0xC6,0x06,0x06,0x3C,0x06,0x06,0x06,0xC6,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x0C,0x1C,0x3C,0x6C,0xCC,0xFE,0x0C,0x0C,0x0C,0x1E,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xFE,0xC0,0xC0,0xC0,0xFC,0x06,0x06,0x06,0xC6,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x38,0x60,0xC0,0xC0,0xFC,0xC6,0xC6,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xFE,0xC6,0x06,0x06,0x0C,0x18,0x30,0x30,0x30,0x30,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x7C,0xC6,0xC6,0xC6,0x7C,0xC6,0xC6,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x7C,0xC6,0xC6,0xC6,0x7E,0x06,0x06,0x06,0x0C,0x78,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x18,0x18,0x30,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x0C,0x18,0x30,0x60,0xC0,0x60,0x30,0x18,0x0C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x7E,0x00,0x00,0x7E,0x00,0x00,0x00,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x60,0x30,0x18,0x0C,0x06,0x0C,0x18,0x30,0x60,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x7C,0xC6,0xC6,0x0C,0x18,0x18,0x18,0x00,0x18,0x18,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x7C,0xC6,0xC6,0xDE,0xDE,0xDE,0xDC,0xC0,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x10,0x38,0x6C,0xC6,0xC6,0xFE,0xC6,0xC6,0xC6,0xC6,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xFC,0x66,0x66,0x66,0x7C,0x66,0x66,0x66,0x66,0xFC,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x3C,0x66,0xC2,0xC0,0xC0,0xC0,0xC0,0xC2,0x66,0x3C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xF8,0x6C,0x66,0x66,0x66,0x66,0x66,0x66,0x6C,0xF8,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xFE,0x66,0x62,0x68,0x78,0x68,0x60,0x62,0x66,0xFE,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xFE,0x66,0x62,0x68,0x78,0x68,0x60,0x60,0x60,0xF0,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x3C,0x66,0xC2,0xC0,0xC0,0xC0,0xCE,0xC6,0x66,0x3A,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xC6,0xC6,0xC6,0xC6,0xFE,0xC6,0xC6,0xC6,0xC6,0xC6,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x3C,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x1E,0x0C,0x0C,0x0C,0x0C,0x0C,0xCC,0xCC,0xCC,0x78,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xE6,0x66,0x6C,0x6C,0x78,0x78,0x6C,0x66,0x66,0xE6,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xF0,0x60,0x60,0x60,0x60,0x60,0x60,0x62,0x66,0xFE,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xC6,0xEE,0xFE,0xFE,0xD6,0xC6,0xC6,0xC6,0xC6,0xC6,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xC6,0xE6,0xF6,0xFE,0xDE,0xCE,0xC6,0xC6,0xC6,0xC6,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x7C,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xFC,0x66,0x66,0x66,0x7C,0x60,0x60,0x60,0x60,0xF0,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x7C,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xD6,0xDE,0x7C,0x0C,0x0E,0x00,0x00 },
    .{ 0x00,0x00,0xFC,0x66,0x66,0x66,0x7C,0x6C,0x66,0x66,0x66,0xE6,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x7C,0xC6,0xC6,0x60,0x38,0x0C,0x06,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xFF,0xDB,0x99,0x18,0x18,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0x6C,0x38,0x10,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xC6,0xC6,0xC6,0xC6,0xC6,0xD6,0xD6,0xFE,0xEE,0x6C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xC6,0xC6,0x6C,0x7C,0x38,0x38,0x7C,0x6C,0xC6,0xC6,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xC6,0xC6,0xC6,0x6C,0x38,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xFE,0xC6,0x86,0x0C,0x18,0x30,0x60,0xC2,0xC6,0xFE,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x3C,0x30,0x30,0x30,0x30,0x30,0x30,0x30,0x30,0x3C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x80,0xC0,0x60,0x30,0x18,0x0C,0x06,0x02,0x00,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00,0x00,0x00,0x00 },
    .{ 0x10,0x38,0x6C,0xC6,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF,0x00,0x00,0x00 },
    .{ 0x30,0x30,0x18,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x78,0x0C,0x7C,0xCC,0xCC,0xCC,0x76,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0xE0,0x60,0x60,0x78,0x6C,0x66,0x66,0x66,0x66,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x7C,0xC6,0xC0,0xC0,0xC0,0xC6,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x1C,0x0C,0x0C,0x3C,0x6C,0xCC,0xCC,0xCC,0xCC,0x76,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x7C,0xC6,0xFE,0xC0,0xC0,0xC6,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x1C,0x36,0x32,0x30,0x78,0x30,0x30,0x30,0x30,0x78,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x76,0xCC,0xCC,0xCC,0xCC,0x7C,0x0C,0xCC,0x78,0x00,0x00 },
    .{ 0x00,0x00,0xE0,0x60,0x60,0x6C,0x76,0x66,0x66,0x66,0x66,0xE6,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x18,0x18,0x00,0x38,0x18,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x06,0x06,0x00,0x0E,0x06,0x06,0x06,0x06,0x06,0x06,0x66,0x3C,0x00,0x00 },
    .{ 0x00,0x00,0xE0,0x60,0x60,0x66,0x6C,0x78,0x78,0x6C,0x66,0xE6,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x38,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0xEC,0xFE,0xD6,0xD6,0xD6,0xD6,0xC6,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0xDC,0x66,0x66,0x66,0x66,0x66,0x66,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x7C,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0xDC,0x66,0x66,0x66,0x66,0x7C,0x60,0x60,0xF0,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x76,0xCC,0xCC,0xCC,0xCC,0x7C,0x0C,0x0C,0x1E,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0xDC,0x76,0x66,0x60,0x60,0x60,0xF0,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0x7C,0xC6,0x60,0x38,0x0C,0xC6,0x7C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x10,0x30,0x30,0xFC,0x30,0x30,0x30,0x30,0x36,0x1C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC,0x76,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0xC6,0xC6,0xC6,0xC6,0x6C,0x38,0x10,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0xC6,0xC6,0xD6,0xD6,0xFE,0xEE,0x6C,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0xC6,0x6C,0x38,0x38,0x38,0x6C,0xC6,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0xC6,0xC6,0xC6,0xC6,0xC6,0x7E,0x06,0x0C,0xF8,0x00,0x00 },
    .{ 0x00,0x00,0x00,0x00,0x00,0xFE,0xCC,0x18,0x30,0x60,0xC6,0xFE,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x0E,0x18,0x18,0x18,0x70,0x18,0x18,0x18,0x18,0x0E,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x18,0x18,0x18,0x18,0x00,0x18,0x18,0x18,0x18,0x18,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x70,0x18,0x18,0x18,0x0E,0x18,0x18,0x18,0x18,0x70,0x00,0x00,0x00,0x00 },
    .{ 0x00,0x00,0x76,0xDC,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 },
};

fn getGlyph(ch: u8) *const [16]u8 {
    if (ch >= 0x20 and ch <= 0x7E) {
        return &font_data[ch - 0x20];
    }
    return &font_data['?' - 0x20];
}
