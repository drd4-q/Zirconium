const std = @import("std");
const root = @import("root");

// Shadow buffer: all drawing happens here (fast RAM, packed 32-bit pixels),
// then flush() copies only the dirty region to the real framebuffer in one
// bulk pass. This avoids per-pixel volatile LFB writes and row-by-row
// redraws visible as flicker.
var shadow: [*]u32 = undefined;
var shadow_pixels: usize = 0;
/// Width the current shadow allocation was sized for.  Every shadow row is
/// indexed with the *current* fb_width, so a viewport change invalidates the
/// buffer unless the stride is re-synced.
var shadow_stride_px: u32 = 0;
var dirty_x0: u32 = 0;
var dirty_y0: u32 = 0;
var dirty_x1: u32 = 0;
var dirty_y1: u32 = 0;
var has_dirty: bool = false;

// Covers every resolution the shell's `resolution` command supports,
// plus common QEMU default modes like 1280x800 (GRUB may pick these on boot).
// Covers every resolution up to 4K (3840x2160)
const MAX_SHADOW_PIXELS: usize = 3840 * 2160;

/// Upper bound of the identity map built by src/entry.S (64 PDs x 2 MB pages).
const MAX_IDENTITY_MAP_BYTES: u64 = 64 * 1024 * 1024 * 1024;

// Static preallocated early shadow buffer for boot/init (1024x768x32bpp).
// Guarantees instant zero-lag drawing during early kernel initialization before PMM is online.
const EARLY_SHADOW_MAX: usize = 1024 * 768;
var early_shadow: [EARLY_SHADOW_MAX]u32 align(4096) = [_]u32{0} ** EARLY_SHADOW_MAX;
var using_early_shadow: bool = false;

// Static page tables for mapping framebuffer when fb_addr is above identity-mapped range
var early_page_tables: [16][512]u64 align(4096) = [_][512]u64{[_]u64{0} ** 512} ** 16;
var early_pt_used: usize = 0;

fn mapFbRange(paddr: u64, size: u64) void {
    if (paddr == 0 or size == 0) return;
    // entry.S identity-maps only the first 64 GB with its static tables.  A
    // framebuffer beyond that would be silently aliased somewhere else; refuse
    // instead of corrupting unrelated memory.
    if (paddr + size > MAX_IDENTITY_MAP_BYTES) {
        const serial = @import("serial.zig");
        serial.serialWrite("[FB] LFB range exceeds the 64 GB identity map; refusing to map\n");
        return;
    }
    const cr3 = asm volatile ("movq %%cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );
    const pml4: [*]u64 = @ptrFromInt(cr3 & 0x000FFFFFFFFFF000);

    var cur = paddr & ~@as(u64, 0x1FFFFF); // 2MB aligned
    const end = (paddr + size + 0x1FFFFF) & ~@as(u64, 0x1FFFFF);

    while (cur < end) : (cur += 0x200000) {
        const pml4_idx = (cur >> 39) & 0x1FF;
        const pdpt_idx = (cur >> 30) & 0x1FF;
        const pd_idx = (cur >> 21) & 0x1FF;

        var pdpt: [*]u64 = undefined;
        if (pml4[pml4_idx] & 1 != 0) {
            pdpt = @ptrFromInt(pml4[pml4_idx] & 0x000FFFFFFFFFF000);
        } else {
            if (early_pt_used >= early_page_tables.len) return;
            pdpt = &early_page_tables[early_pt_used];
            early_pt_used += 1;
            pml4[pml4_idx] = @intFromPtr(pdpt) | 0x03; // PRESENT | WRITE
        }

        var pd: [*]u64 = undefined;
        if (pdpt[pdpt_idx] & 1 != 0) {
            if (pdpt[pdpt_idx] & 0x80 != 0) continue; // 1GB page
            pd = @ptrFromInt(pdpt[pdpt_idx] & 0x000FFFFFFFFFF000);
        } else {
            if (early_pt_used >= early_page_tables.len) return;
            pd = &early_page_tables[early_pt_used];
            early_pt_used += 1;
            pdpt[pdpt_idx] = @intFromPtr(pd) | 0x03; // PRESENT | WRITE
        }

        // Map 2MB page (PRESENT | WRITE | LARGE_PAGE = 0x83)
        pd[pd_idx] = cur | 0x83;
        asm volatile ("invlpg (%[addr])"
            :
            : [addr] "r" (cur),
            : .{ .memory = true });
    }
}

fn allocShadow(pixels: u64) bool {
    const bytes = (pixels * 4 + 4095) & ~@as(u64, 4095);
    const pages = @as(usize, @intCast(bytes / 4096));
    const phys = root.pmm.allocPages(pages) orelse return false;
    shadow = @ptrFromInt(phys);
    shadow_pixels = @intCast(pixels);
    shadow_stride_px = fb_width;
    using_early_shadow = false;
    @memset(shadow[0..shadow_pixels], 0);
    return true;
}

fn ensureShadow() bool {
    const needed = @as(u64, fb_width) * fb_height;
    if (needed == 0 or needed > MAX_SHADOW_PIXELS) return false;

    if (shadow_pixels == 0) {
        // First activation. The static early buffer covers boot and every mode
        // up to 1024x768 without needing the PMM.
        if (needed <= EARLY_SHADOW_MAX) {
            shadow = &early_shadow;
            shadow_pixels = @intCast(needed);
            shadow_stride_px = fb_width;
            using_early_shadow = true;
            @memset(shadow[0..shadow_pixels], 0);
            return true;
        }
        if (root.pmm.free_pages == 0) return false;
        return allocShadow(needed);
    }

    if (shadow_stride_px == fb_width and needed <= shadow_pixels) return true;

    // The viewport changed. Re-stride in place when the existing allocation is
    // still large enough, otherwise get a bigger one from the PMM.  Keeping the
    // old buffer on PMM failure is safe: every write is bounded by
    // fb_width/fb_height, so a stale stride is never indexed out of range.
    if (needed <= shadow_pixels) {
        shadow_stride_px = fb_width;
        @memset(shadow[0..@intCast(needed)], 0);
        return true;
    }
    if (using_early_shadow and root.pmm.free_pages == 0) return false;
    return allocShadow(needed);
}

pub var fb_addr: u64 = 0;
pub var fb_pitch: u32 = 0;
pub var fb_width: u32 = 0;
pub var fb_height: u32 = 0;
pub var fb_bpp: u32 = 0;
pub var fb_type: u32 = 0;
/// Bytes per pixel on the real LFB: 4 for the classic XRGB8888 layout, 3 when
/// the bootloader only offered a 24bpp mode (common with VBE), 2 for RGB565.
/// Everything that touches the LFB goes through lfbPut/lfbGet or branches on
/// this.  16bpp matters on real hardware: when a 32bpp mode is unavailable GRUB
/// happily lands on a 16bpp mode, and refusing it would leave us with no LFB at
/// all (a black screen under UEFI, where the VGA text buffer is not displayed).
var fb_bytes_pp: u32 = 4;

inline fn lfbOffset(y: u32, x: u32) u64 {
    return @as(u64, y) * fb_pitch + @as(u64, x) * fb_bytes_pp;
}

/// True when the mode stores red in the LOW byte (memory order R,G,B).
///
/// Almost every PC display is B,G,R,X in memory, which is why this used to be
/// hardcoded - but a discrete GPU is free to report the opposite through the
/// multiboot channel fields, and then every colour comes out with red and blue
/// swapped. Deriving it from the reported field positions costs nothing and
/// removes the assumption. Defaults to B,G,R,X for the 16bpp and text paths,
/// which have no channel fields at all.
var fb_red_first: bool = false;

/// Write one RGB pixel straight to the LFB.
fn lfbPut(x: u32, y: u32, rgb: u32) void {
    if (fb_bytes_pp == 2) {
        // RGB565: 5 bits red, 6 green, 5 blue.
        const v: u16 = (@as(u16, @truncate(rgb >> 19)) << 11) |
            (@as(u16, @truncate(rgb >> 10)) << 5) |
            @as(u16, @truncate(rgb >> 3));
        const p: [*]volatile u16 = @ptrFromInt(fb_addr + lfbOffset(y, x));
        p[0] = v;
        return;
    }
    const p: [*]volatile u8 = @ptrFromInt(fb_addr + lfbOffset(y, x));
    if (fb_red_first) {
        p[0] = @truncate(rgb >> 16);
        p[1] = @truncate(rgb >> 8);
        p[2] = @truncate(rgb);
    } else {
        p[0] = @truncate(rgb);
        p[1] = @truncate(rgb >> 8);
        p[2] = @truncate(rgb >> 16);
    }
    if (fb_bytes_pp == 4) p[3] = 0;
}

/// Read one RGB pixel straight from the LFB.
fn lfbGet(x: u32, y: u32) u32 {
    if (fb_bytes_pp == 2) {
        const p: [*]volatile u16 = @ptrFromInt(fb_addr + lfbOffset(y, x));
        const v = p[0];
        return (@as(u32, (v >> 11) & 0x1F) << 19) |
            (@as(u32, (v >> 5) & 0x3F) << 10) |
            (@as(u32, v & 0x1F) << 3);
    }
    const p: [*]volatile u8 = @ptrFromInt(fb_addr + lfbOffset(y, x));
    if (fb_red_first) {
        return (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | @as(u32, p[2]);
    }
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

/// Official Multiboot 1 video mode table, reached through flag bit 11.
///
/// The spec's `graphics_table` pointer sits right after `apm_table` (bit 10), so
/// at byte 68 + 4.  Each entry is 20 bytes:
///   0 mode_type (0 = linear graphics, 1 = EGA text)
///   4 width      (pixels, or characters for a text mode)
///   8 height
///   12 depth     (bits per pixel)
///   16 frame_buffer_address (physical, valid for text modes too)
///
/// There is no count field, so entries are scanned until one stops looking like
/// a mode, bounded so a garbage pointer cannot walk the whole machine.  Returns
/// false when the table is absent or holds nothing usable, in which case the
/// caller stays in text mode.
fn tryVbeVideoTable(mbi: [*]const u8, flags: u32) bool {
    const serial = @import("serial.zig");
    if ((flags & (1 << 11)) == 0) return false;

    const ptr = @as(u32, @intCast(mbi[72])) |
        (@as(u32, @intCast(mbi[73])) << 8) |
        (@as(u32, @intCast(mbi[74])) << 16) |
        (@as(u32, @intCast(mbi[75])) << 24);
    if (ptr == 0) return false;
    serial.serialWrite("[FB] multiboot video table at 0x");
    serial.serialWriteHex(ptr);
    serial.serialWrite("\n");

    const t: [*]const u8 = @ptrFromInt(ptr);
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        const e = ptr + i * 20;
        const mode_type = @as(u32, @intCast(t[i * 20 + 0])) |
            (@as(u32, @intCast(t[i * 20 + 1])) << 8) |
            (@as(u32, @intCast(t[i * 20 + 2])) << 16) |
            (@as(u32, @intCast(t[i * 20 + 3])) << 24);
        const w = @as(u32, @intCast(t[i * 20 + 4])) |
            (@as(u32, @intCast(t[i * 20 + 5])) << 8) |
            (@as(u32, @intCast(t[i * 20 + 6])) << 16) |
            (@as(u32, @intCast(t[i * 20 + 7])) << 24);
        const h = @as(u32, @intCast(t[i * 20 + 8])) |
            (@as(u32, @intCast(t[i * 20 + 9])) << 8) |
            (@as(u32, @intCast(t[i * 20 + 10])) << 16) |
            (@as(u32, @intCast(t[i * 20 + 11])) << 24);
        const d = @as(u32, @intCast(t[i * 20 + 12])) |
            (@as(u32, @intCast(t[i * 20 + 13])) << 8) |
            (@as(u32, @intCast(t[i * 20 + 14])) << 16) |
            (@as(u32, @intCast(t[i * 20 + 15])) << 24);
        const a = @as(u32, @intCast(t[i * 20 + 16])) |
            (@as(u32, @intCast(t[i * 20 + 17])) << 8) |
            (@as(u32, @intCast(t[i * 20 + 18])) << 16) |
            (@as(u32, @intCast(t[i * 20 + 19])) << 24);

        // Stop at the first entry that is not a plausible mode, otherwise the
        // loop walks whatever follows the table in memory.
        if (mode_type > 1 or w == 0 or h == 0 or w > 16384 or h > 16384 or d > 64) break;

        serial.serialWrite("[FB]   table[");
        serial.serialWriteDec(i);
        serial.serialWrite("] type=");
        serial.serialWriteDec(mode_type);
        serial.serialWrite(" ");
        serial.serialWriteDec(w);
        serial.serialWrite("x");
        serial.serialWriteDec(h);
        serial.serialWrite("x");
        serial.serialWriteDec(d);
        serial.serialWrite(" @0x");
        serial.serialWriteHex(a);
        serial.serialWrite("\n");

        // First linear graphics mode wins: that is the one the bootloader set.
        if (mode_type == 0 and a != 0 and (d == 32 or d == 24 or d == 16)) {
            fb_addr = a;
            fb_width = w;
            fb_height = h;
            fb_bpp = d;
            fb_type = 2; // direct colour
            fb_pitch = w * (d / 8);
            serial.serialWrite("[FB] adopted table entry at 0x");
            serial.serialWriteHex(e);
            serial.serialWrite("\n");
            return true;
        }
    }
    serial.serialWrite("[FB] video table has no usable linear graphics mode\n");
    return false;
}

/// Log the raw multiboot video bytes.
///
/// The framebuffer fields live in GRUB's extension of the Multiboot 1 layout
/// rather than in the 2001 spec, and every consumer guesses at the offsets
/// differently - `framebuffer_depth` versus `framebuffer_bpp` is a 4-byte field
/// at 108 versus a 1-byte field at 112, and they are read as single bytes.  When
/// a machine behaves differently from QEMU there is no way to tell a misread
/// offset from a genuinely absent field except by looking at the bytes, so print
/// them.
fn dumpMbiVideo(mbi: [*]const u8, flags: u32) void {
    const serial = @import("serial.zig");
    serial.serialWrite("[FB] mbi_flags=0x");
    serial.serialWriteHex(flags);
    serial.serialWrite(" bit11=");
    serial.serialWriteDec(if ((flags & (1 << 11)) != 0) @as(u32, 1) else @as(u32, 0));
    serial.serialWrite(" bit12=");
    serial.serialWriteDec(if ((flags & (1 << 12)) != 0) @as(u32, 1) else @as(u32, 0));
    serial.serialWrite("\n");
    var hex: [128]u8 = undefined;
    var n: usize = 0;
    var off: usize = 80;
    while (off < 144) : (off += 1) {
        const b: u8 = mbi[off];
        const hi: u8 = (b >> 4) & 0xF;
        const lo: u8 = b & 0xF;
        hex[n] = if (hi < 10) hi + '0' else hi + 'a' - 10;
        hex[n + 1] = if (lo < 10) lo + '0' else lo + 'a' - 10;
        n += 2;
    }
    serial.serialWrite("[FB] mbi[80..144]=");
    serial.serialWrite(hex[0..n]);
    serial.serialWrite("\n");
}

pub fn initFromMultiboot(mbi_ptr: u32) void {
    const mbi: [*]const u8 = @ptrFromInt(mbi_ptr);
    const serial = @import("serial.zig");

    const flags = @as(u32, @intCast(mbi[0])) | (@as(u32, @intCast(mbi[1])) << 8) |
        (@as(u32, @intCast(mbi[2])) << 16) | (@as(u32, @intCast(mbi[3])) << 24);

    dumpMbiVideo(mbi, flags);

    if ((flags & (1 << 12)) == 0) {
        // Bit 12 is the GRUB extension.  The *official* Multiboot 1 spec has a
        // second, older video source that the driver never looked at: bit 11
        // points at a table of 20-byte entries of
        //   { mode_type, width, height, depth, frame_buffer_address }.
        // A bootloader that only implements the spec hands the framebuffer over
        // this way and no other, so ignoring it is how a perfectly capable
        // machine ends up in text mode.
        if (tryVbeVideoTable(mbi, flags)) {
            serial.serialWrite("[FB] source=multiboot bit 11 video table\n");
        } else {
            serial.serialWrite("[FB] No framebuffer info from bootloader (MBI flags=0x");
            serial.serialWriteHex(flags);
            serial.serialWrite(")\n");
            serial.serialWrite("[FB] GRUB handed us no video mode (it fell back to text).\n");
            serial.serialWrite("[FB] Under UEFI the VGA text buffer at 0xB8000 is NOT\n");
            serial.serialWrite("[FB] displayed by the firmware console -> black screen.\n");
            return;
        }
    } else {
        serial.serialWrite("[FB] source=multiboot bit 12 framebuffer\n");

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

        // Channel field positions/mask sizes, six bytes, so the byte order is
        // read rather than assumed.  red@0 means the mode is R,G,B in memory;
        // blue@0 (the usual PC layout) means B,G,R.
        const red_pos: u32 = mbi[112];
        const blue_pos: u32 = mbi[116];
        if (red_pos == 0 and blue_pos != 0) {
            fb_red_first = true;
        } else if (red_pos == 16 and blue_pos == 0) {
            fb_red_first = false;
        } else if (red_pos != 0 or blue_pos != 0) {
            serial.serialWrite("[FB] unusual channel layout red@");
            serial.serialWriteDec(red_pos);
            serial.serialWrite(" blue@");
            serial.serialWriteDec(blue_pos);
            serial.serialWrite(", assuming B,G,R\n");
        }
        serial.serialWrite("[FB] channels R@");
        serial.serialWriteDec(red_pos);
        serial.serialWrite("/");
        serial.serialWriteDec(mbi[113]);
        serial.serialWrite(" G@");
        serial.serialWriteDec(mbi[114]);
        serial.serialWrite("/");
        serial.serialWriteDec(mbi[115]);
        serial.serialWrite(" B@");
        serial.serialWriteDec(blue_pos);
        serial.serialWrite("/");
        serial.serialWriteDec(mbi[117]);
        serial.serialWrite(" byte_order=");
        serial.serialWrite(if (fb_red_first) "RGB" else "BGR");
        serial.serialWrite("\n");
    }

    if (fb_addr == 0 or fb_width == 0 or fb_height == 0) {
        serial.serialWrite("[FB] Degenerate framebuffer info; staying in text mode\n");
        return;
    }
    // Only packed RGB is supported.  GRUB/QEMU frequently hand out an
    // 800x600x24 VBE mode when the requested 32bpp one is unavailable, and real
    // hardware can be stuck on 16bpp (RGB565), so accept all three rather than
    // leaving the machine with no LFB at all.
    if (fb_bpp != 32 and fb_bpp != 24 and fb_bpp != 16) {
        serial.serialWrite("[FB] Unsupported depth ");
        serial.serialWriteDec(fb_bpp);
        serial.serialWrite("bpp (need 16, 24 or 32); staying in VGA text mode\n");
        return;
    }
    fb_bytes_pp = fb_bpp / 8;
    if (fb_pitch == 0) {
        fb_pitch = fb_width * fb_bytes_pp;
    }

    serial.serialWrite("[FB] LFB ");
    serial.serialWriteDec(fb_width);
    serial.serialWrite("x");
    serial.serialWriteDec(fb_height);
    serial.serialWrite("x");
    serial.serialWriteDec(fb_bpp);
    serial.serialWrite(" @0x");
    serial.serialWriteHex(@truncate(fb_addr));
    serial.serialWrite("\n");

    // Remember the real hardware geometry. fb_width/fb_height double as the
    // drawable viewport (see setViewport) and must never exceed these.
    boot_width = fb_width;
    boot_height = fb_height;
    boot_pitch = fb_pitch;
    viewport_scaled = false;

    // Ensure framebuffer range is identity-mapped in page tables (crucial if fb_addr >= 8GB)
    const total_fb_bytes = @as(u64, fb_pitch) * fb_height;
    mapFbRange(fb_addr, total_fb_bytes);

    cols = fb_width / char_w;
    rows = fb_height / char_h;
    if (cols > MAX_COLS) cols = MAX_COLS;
    if (rows > MAX_ROWS) rows = MAX_ROWS;

    active = true;
    clearMirror();
    // The LFB probe is deliberately NOT run here: initFromMultiboot runs
    // before the IDT is installed (main.zig calls vga.initFb ahead of
    // system_init), so touching a framebuffer the firmware reported but did not
    // actually map would be an unhandled page fault -> triple fault ->
    // immediate reboot, with nothing in the log. It is called from
    // probeLfbSafe() once exceptions can be reported.

    serial.serialWrite("[FB] pitch=");
    serial.serialWriteDec(fb_pitch);
    serial.serialWrite(" stride=");
    serial.serialWriteDec(fb_bytes_pp);
    serial.serialWrite("B type=");
    serial.serialWriteDec(fb_type);
    serial.serialWrite(" grid=");
    serial.serialWriteDec(cols);
    serial.serialWrite("x");
    serial.serialWriteDec(rows);
    serial.serialWrite(" mbi_flags=0x");
    serial.serialWriteHex(flags);
    serial.serialWrite("\n");
}

/// Verify the reported LFB is actually backed before anything draws to it.
///
/// A firmware can report a mode whose LFB lives outside the identity map, or
/// with a pitch that walks off the end of it. Touching that memory with no IDT
/// installed is a triple fault: the machine reboots and *nothing* reaches the
/// log, which is exactly the "forced mode reboots, keep hangs" signature seen
/// on real hardware. So this refuses anything it cannot vouch for and is called
/// from main.zig only after system_init has installed the IDT - a fault here is
/// then a reportable exception, not a silent reboot.
pub fn probeLfbSafe() void {
    const serial = @import("serial.zig");
    if (!active) {
        serial.serialWrite("[FB] probe SKIP: no framebuffer\n");
        return;
    }
    const total = @as(u64, fb_pitch) * fb_height;
    if (fb_pitch == 0 or fb_pitch > fb_width * fb_bytes_pp) {
        serial.serialWrite("[FB] probe SKIP: implausible pitch ");
        serial.serialWriteDec(fb_pitch);
        serial.serialWrite(" for width ");
        serial.serialWriteDec(fb_width);
        serial.serialWrite("\n");
        return;
    }
    // entry.S identity-maps the first 64 GB, so anything inside that window is
    // safe to touch without help from mapFbRange (which cannot map above it).
    if (fb_addr + total > MAX_IDENTITY_MAP_BYTES) {
        serial.serialWrite("[FB] probe SKIP: LFB at 0x");
        serial.serialWriteHex(@truncate(fb_addr));
        serial.serialWrite(" is outside the 64 GB identity map\n");
        return;
    }
    probeLfb(serial);
    testPattern();
}

/// Draw a recognisable full-screen pattern straight into the LFB, bypassing the
/// shadow buffer, then read several pixels back and log what came out.
///
/// This is the decisive test when the screen stays black: if the readback
/// matches what we wrote, the buffer really is writable and the hardware is
/// simply not scanning it out (a DisplayPort link that never came up after a
/// mode change, or a bootloader's address that is not the real scanout). If the
/// readback does not match, we are writing somewhere else entirely. A
/// black-on-black screen cannot tell those apart, a colour-bar test can.
///
/// Same idea as Linux's `fbcon` solid_fill / drm-kms-selftest colorimage.
pub fn testPattern() void {
    const serial = @import("serial.zig");
    if (!active) return;
    const total = @as(u64, fb_pitch) * fb_height;
    if (fb_addr + total > MAX_IDENTITY_MAP_BYTES) return;

    // 8 classic colour bars, full height, plus a white cross so a garbled
    // stride is obvious at a glance.
    const bars = [_]u32{ 0xFFFFFF, 0x00FFFF, 0x00FF00, 0xFF00FF, 0xFF0000, 0x0000FF, 0xFFFF00, 0xFFFFFF };
    const n_bars: u32 = @intCast(bars.len);
    const bar_w = fb_width / n_bars;
    var y: u32 = 0;
    while (y < fb_height) : (y += 1) {
        var b: u32 = 0;
        while (b < n_bars) : (b += 1) {
            const x0 = b * bar_w;
            const x1 = if (b + 1 == n_bars) fb_width else x0 + bar_w;
            const rgb = bars[b];
            var x = x0;
            while (x < x1) : (x += 1) lfbPut(x, y, rgb);
        }
    }
    const mid_x = fb_width / 2;
    const mid_y = fb_height / 2;
    var i: u32 = 0;
    while (i < fb_width) : (i += 1) {
        lfbPut(i, mid_y, 0x000000);
    }
    while (i < fb_height) : (i += 1) {
        lfbPut(mid_x, i, 0x000000);
    }

    // Read back a few probes across the bars.  The last one sits just right of
    // the vertical cross line, i.e. in bar 4.
    const samples = [_]struct { x: u32, y: u32, want: u32, name: []const u8 }{
        .{ .x = 1, .y = 1, .want = bars[0], .name = "bar0" },
        .{ .x = bar_w * 2, .y = 1, .want = bars[2], .name = "bar2" },
        .{ .x = bar_w * 4, .y = 1, .want = bars[4], .name = "bar4" },
        .{ .x = bar_w * 6, .y = 1, .want = bars[6], .name = "bar6" },
        .{ .x = @min(mid_x + 1, fb_width - 1), .y = 1, .want = bars[4], .name = "mid" },
    };
    var ok: u32 = 0;
    for (samples) |s| {
        if (s.x >= fb_width or s.y >= fb_height) continue;
        const got = lfbGet(s.x, s.y) & 0xFFFFFF;
        const pass = got == s.want;
        if (pass) ok += 1;
        serial.serialWrite("[FB] test ");
        serial.serialWrite(s.name);
        serial.serialWrite(" want=");
        serial.serialWriteHex(s.want);
        serial.serialWrite(" got=");
        serial.serialWriteHex(got);
        serial.serialWrite(if (pass) " OK\n" else " MISMATCH\n");
    }
    serial.serialWrite("[FB] test pattern written, ");
    serial.serialWriteDec(ok);
    serial.serialWrite(" of ");
    serial.serialWriteDec(samples.len);
    serial.serialWrite(" probes match\n");
}

/// Touch every page of the reported LFB and read one pixel back. Callers must
/// have verified the range is mapped and installed the IDT first.
fn probeLfb(serial: @TypeOf(@import("serial.zig"))) void {
    const total = @as(u64, fb_pitch) * fb_height;
    const step: u64 = 4096;
    var off: u64 = 0;
    while (off < total) : (off += step) {
        const p: [*]volatile u8 = @ptrFromInt(fb_addr + off);
        p[0] = p[0];
    }
    // Read/write round trip on a pixel we are about to clear anyway.
    const probe_rgb: u32 = 0x00A55A3C;
    lfbPut(0, 0, probe_rgb);
    const back = lfbGet(0, 0);
    serial.serialWrite("[FB] probe ");
    if ((back & 0xFFFFFF) == (probe_rgb & 0xFFFFFF)) {
        serial.serialWrite("OK, LFB is mapped and writable (");
    } else {
        serial.serialWrite("MISMATCH, expected ");
        serial.serialWriteHex(probe_rgb);
        serial.serialWrite(" got ");
        serial.serialWriteHex(back);
        serial.serialWrite(" (");
    }
    serial.serialWriteDec(total);
    serial.serialWrite(" bytes)\n");
}

/// Real hardware geometry reported by the bootloader.  fb_width/fb_height are
/// the current viewport and are always clamped to these.
pub var boot_width: u32 = 0;
pub var boot_height: u32 = 0;
pub var boot_pitch: u32 = 0;
/// True when the viewport is smaller than the mode GRUB actually set.
pub var viewport_scaled: bool = false;

/// Bytes per pixel of the real LFB (3 for 24bpp, 4 for 32bpp).
pub fn bytesPerPixel() u32 {
    return fb_bytes_pp;
}

/// Resize the drawable viewport.  The mode itself is owned by the firmware /
/// GRUB, so this only changes how much of the real LFB we address; anything
/// larger than the boot geometry is clamped instead of scribbling past the end
/// of the framebuffer.  Returns false when the request was clamped or refused.
pub fn setViewport(new_w: u32, new_h: u32) bool {
    if (!active) return false;
    if (boot_width == 0 or boot_height == 0) return false;
    const w = @min(new_w, boot_width);
    const h = @min(new_h, boot_height);
    if (w == 0 or h == 0) return false;

    const exact = (w == new_w and h == new_h);
    fb_width = w;
    fb_height = h;
    viewport_scaled = (w != boot_width or h != boot_height);

    cols = fb_width / char_w;
    rows = fb_height / char_h;
    if (cols > MAX_COLS) cols = MAX_COLS;
    if (rows > MAX_ROWS) rows = MAX_ROWS;
    cursor_row = 0;
    cursor_col = 0;
    clear();
    return exact;
}

/// Backwards-compatible alias: resizing only ever changes the viewport now.
pub fn setResolution(new_w: u32, new_h: u32) void {
    _ = setViewport(new_w, new_h);
}

pub fn clear() void {
    if (!active) return;
    const bg_col: u32 = (@as(u32, bg_r) << 16) | (@as(u32, bg_g) << 8) | @as(u32, bg_b);
    if (ensureShadow() and shadow_pixels != 0) {
        @memset(shadow[0..shadow_pixels], bg_col);
        markDirtyRect(0, 0, fb_width, fb_height);
    } else if (fb_bytes_pp == 2) {
        // 16bpp RGB565, one u16 per pixel.
        const bg16: u16 = (@as(u16, bg_r >> 3) << 11) |
            (@as(u16, bg_g >> 2) << 5) |
            @as(u16, bg_b >> 3);
        var y: u32 = 0;
        while (y < fb_height) : (y += 1) {
            const row: [*]volatile u16 = @ptrFromInt(fb_addr + @as(u64, y) * fb_pitch);
            var x: u32 = 0;
            while (x < fb_width) : (x += 1) row[x] = bg16;
        }
    } else if (fb_bytes_pp == 4) {
        // 32bpp: one u64 covers two BGRX pixels.
        const bg_val64: u64 = (@as(u64, bg_col) << 32) | bg_col;
        var y: u32 = 0;
        while (y < fb_height) : (y += 1) {
            const row_ptr: [*]volatile u64 = @ptrFromInt(fb_addr + @as(u64, y) * fb_pitch);
            const count64 = (@as(usize, fb_width) * 4) / 8;
            var i: usize = 0;
            while (i < count64) : (i += 1) {
                row_ptr[i] = bg_val64;
            }
            // An odd pixel count leaves a 4-byte tail.
            if (fb_width % 2 != 0) {
                const tail: [*]volatile u32 = @ptrFromInt(fb_addr + @as(u64, y) * fb_pitch + @as(u64, count64) * 8);
                tail[0] = bg_col;
            }
        }
    } else {
        // 24bpp: no padding word, so write B,G,R per pixel.
        var y: u32 = 0;
        while (y < fb_height) : (y += 1) {
            const row: [*]volatile u8 = @ptrFromInt(fb_addr + @as(u64, y) * fb_pitch);
            var x: u32 = 0;
            while (x < fb_width) : (x += 1) {
                row[x * 3 + 0] = bg_b;
                row[x * 3 + 1] = bg_g;
                row[x * 3 + 2] = bg_r;
            }
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
    // Clamp to the real LFB, not just the viewport: a stale dirty rect must
    // never write past the end of the mode GRUB set.
    const max_x = if (boot_width != 0) @min(fb_width, boot_width) else fb_width;
    const max_y = if (boot_height != 0) @min(fb_height, boot_height) else fb_height;
    const x1 = @min(dirty_x1, max_x);
    const y1 = @min(dirty_y1, max_y);
    has_dirty = false;
    if (x0 >= x1 or y0 >= y1) return;

    const w = x1 - x0;
    var y: u32 = y0;
    while (y < y1) : (y += 1) {
        const row_off = @as(u64, y) * fb_width + x0;
        const src: [*]const u32 = shadow + row_off;
        if (fb_bytes_pp == 4) {
            const dst: [*]volatile u32 = @ptrFromInt(fb_addr + @as(u64, y) * fb_pitch + @as(u64, x0) * 4);
            if (fb_red_first) {
                // The shadow holds 0x00RRGGBB, which lands in memory as B,G,R,X.
                // A mode reporting red at byte 0 needs the other order, so swap
                // here too - the fast path used to hardcode BGRX and render a
                // red-first mode with red and blue exchanged.
                var x: u32 = 0;
                while (x < w) : (x += 1) {
                    const c = src[x];
                    dst[x] = (c >> 16) | (c << 16);
                }
            } else {
                var x: u32 = 0;
                while (x < w) : (x += 1) {
                    dst[x] = src[x];
                }
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
    const fg_col: u32 = (@as(u32, fg_r) << 16) | (@as(u32, fg_g) << 8) | @as(u32, fg_b);
    const bg_col: u32 = (@as(u32, bg_r) << 16) | (@as(u32, bg_g) << 8) | @as(u32, bg_b);

    if (ensureShadow() and shadow_pixels != 0 and px + char_w <= fb_width and py + char_h <= fb_height) {
        var gy: usize = 0;
        while (gy < char_h) : (gy += 1) {
            const bits = glyph[gy];
            const row_ptr = shadow + @as(u64, py + @as(u32, @intCast(gy))) * fb_width + px;
            row_ptr[0] = if ((bits & 0x80) != 0) fg_col else bg_col;
            row_ptr[1] = if ((bits & 0x40) != 0) fg_col else bg_col;
            row_ptr[2] = if ((bits & 0x20) != 0) fg_col else bg_col;
            row_ptr[3] = if ((bits & 0x10) != 0) fg_col else bg_col;
            row_ptr[4] = if ((bits & 0x08) != 0) fg_col else bg_col;
            row_ptr[5] = if ((bits & 0x04) != 0) fg_col else bg_col;
            row_ptr[6] = if ((bits & 0x02) != 0) fg_col else bg_col;
            row_ptr[7] = if ((bits & 0x01) != 0) fg_col else bg_col;
        }
        markDirtyRect(px, py, char_w, char_h);
        return;
    }

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

/// Standard 16-colour VGA palette, shared by every mirror repaint.
const vga_palette = [_]u32{
    0x000000, 0x0000AA, 0x00AA00, 0x00AAAA,
    0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
    0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
    0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
};

fn redrawRow(row: usize) void {
    if (row >= rows) return;
    for (0..cols) |col| {
        const entry = screen_mirror[row][col];
        const ch: u8 = @intCast(entry & 0xFF);
        const fg = vga_palette[@intCast((entry >> 8) & 0x0F)];
        const bg = vga_palette[@intCast((entry >> 12) & 0x0F)];
        fg_r = @intCast((fg >> 16) & 0xFF);
        fg_g = @intCast((fg >> 8) & 0xFF);
        fg_b = @intCast(fg & 0xFF);
        bg_r = @intCast((bg >> 16) & 0xFF);
        bg_g = @intCast((bg >> 8) & 0xFF);
        bg_b = @intCast(bg & 0xFF);
        drawCharAt(col, row, if (ch == 0) ' ' else ch);
    }
}

/// Repaint the whole text console from the screen mirror and push it to the LFB
/// in one bulk flush.  Used by `screen redraw`, and to recover a console after
/// something scribbled on the LFB directly.  The global colours and cursor are
/// restored, so callers keep their palette.
pub fn redrawAllText() void {
    if (!active) return;
    const saved_fg = .{ fg_r, fg_g, fg_b };
    const saved_bg = .{ bg_r, bg_g, bg_b };
    const saved_cursor = .{ cursor_row, cursor_col };
    const saved_view = scroll_view;

    scroll_view = false;
    has_dirty = false;
    var r: usize = 0;
    while (r < rows) : (r += 1) redrawRow(r);

    fg_r = saved_fg[0];
    fg_g = saved_fg[1];
    fg_b = saved_fg[2];
    bg_r = saved_bg[0];
    bg_g = saved_bg[1];
    bg_b = saved_bg[2];
    cursor_row = saved_cursor[0];
    cursor_col = saved_cursor[1];
    scroll_view = saved_view;

    markDirtyRect(0, 0, fb_width, fb_height);
    flush();
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
            const src_lfb: [*]const volatile u8 = @ptrFromInt(fb_addr + @as(u64, py) * fb_pitch);
            const row_bytes = @as(usize, text_w) * fb_bytes_pp;
            var b: usize = 0;
            while (b < row_bytes) : (b += 1) {
                dst_lfb[b] = src_lfb[b];
            }
        }

        // Repaint the newly exposed bottom text row in shadow and flush it
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

fn putCharInternal(ch: u8) void {
    if (!active) return;

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
}

pub fn putChar(ch: u8) void {
    putCharInternal(ch);
    flush();
}

pub fn write(str: []const u8) void {
    for (str) |ch| {
        putCharInternal(ch);
    }
    flush();
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
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x18, 0x3C, 0x3C, 0x3C, 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x66, 0x66, 0x66, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x6C, 0x6C, 0xFE, 0x6C, 0x6C, 0xFE, 0x6C, 0x6C, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x18, 0x18, 0x7C, 0xC6, 0xC2, 0xC0, 0x7C, 0x06, 0x06, 0x86, 0xC6, 0x7C, 0x18, 0x18, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0xC2, 0xC6, 0x0C, 0x18, 0x30, 0x60, 0xC6, 0x86, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x38, 0x6C, 0x6C, 0x38, 0x76, 0xDC, 0xCC, 0xCC, 0xCC, 0x76, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x30, 0x30, 0x30, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x18, 0x30, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x02, 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xCE, 0xDE, 0xF6, 0xE6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x18, 0x38, 0x78, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0xC6, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0x06, 0x06, 0x3C, 0x06, 0x06, 0x06, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x0C, 0x1C, 0x3C, 0x6C, 0xCC, 0xFE, 0x0C, 0x0C, 0x0C, 0x1E, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0xC0, 0xC0, 0xC0, 0xFC, 0x06, 0x06, 0x06, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x38, 0x60, 0xC0, 0xC0, 0xFC, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0xC6, 0x06, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x30, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0x7E, 0x06, 0x06, 0x06, 0x0C, 0x78, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x60, 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0x0C, 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xDE, 0xDE, 0xDE, 0xDC, 0xC0, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x10, 0x38, 0x6C, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFC, 0x66, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x66, 0x66, 0xFC, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x66, 0xC2, 0xC0, 0xC0, 0xC0, 0xC0, 0xC2, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xF8, 0x6C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x6C, 0xF8, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0x66, 0x62, 0x68, 0x78, 0x68, 0x60, 0x62, 0x66, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0x66, 0x62, 0x68, 0x78, 0x68, 0x60, 0x60, 0x60, 0xF0, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x66, 0xC2, 0xC0, 0xC0, 0xC0, 0xCE, 0xC6, 0x66, 0x3A, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0xCC, 0xCC, 0xCC, 0x78, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xE6, 0x66, 0x6C, 0x6C, 0x78, 0x78, 0x6C, 0x66, 0x66, 0xE6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xF0, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x62, 0x66, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xEE, 0xFE, 0xFE, 0xD6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xE6, 0xF6, 0xFE, 0xDE, 0xCE, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFC, 0x66, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x60, 0xF0, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xD6, 0xDE, 0x7C, 0x0C, 0x0E, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFC, 0x66, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x66, 0xE6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0x60, 0x38, 0x0C, 0x06, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFF, 0xDB, 0x99, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x10, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xD6, 0xD6, 0xFE, 0xEE, 0x6C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0x6C, 0x7C, 0x38, 0x38, 0x7C, 0x6C, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0xC6, 0x86, 0x0C, 0x18, 0x30, 0x60, 0xC2, 0xC6, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x80, 0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x10, 0x38, 0x6C, 0xC6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00 },
    .{ 0x30, 0x30, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x78, 0x0C, 0x7C, 0xCC, 0xCC, 0xCC, 0x76, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xE0, 0x60, 0x60, 0x78, 0x6C, 0x66, 0x66, 0x66, 0x66, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7C, 0xC6, 0xC0, 0xC0, 0xC0, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x1C, 0x0C, 0x0C, 0x3C, 0x6C, 0xCC, 0xCC, 0xCC, 0xCC, 0x76, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7C, 0xC6, 0xFE, 0xC0, 0xC0, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x1C, 0x36, 0x32, 0x30, 0x78, 0x30, 0x30, 0x30, 0x30, 0x78, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x76, 0xCC, 0xCC, 0xCC, 0xCC, 0x7C, 0x0C, 0xCC, 0x78, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xE0, 0x60, 0x60, 0x6C, 0x76, 0x66, 0x66, 0x66, 0x66, 0xE6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x18, 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x06, 0x06, 0x00, 0x0E, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x66, 0x3C, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xE0, 0x60, 0x60, 0x66, 0x6C, 0x78, 0x78, 0x6C, 0x66, 0xE6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xEC, 0xFE, 0xD6, 0xD6, 0xD6, 0xD6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xDC, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xDC, 0x66, 0x66, 0x66, 0x66, 0x7C, 0x60, 0x60, 0xF0, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x76, 0xCC, 0xCC, 0xCC, 0xCC, 0x7C, 0x0C, 0x0C, 0x1E, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xDC, 0x76, 0x66, 0x60, 0x60, 0x60, 0xF0, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7C, 0xC6, 0x60, 0x38, 0x0C, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x10, 0x30, 0x30, 0xFC, 0x30, 0x30, 0x30, 0x30, 0x36, 0x1C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0x76, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x10, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6, 0xC6, 0xD6, 0xD6, 0xFE, 0xEE, 0x6C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6, 0x6C, 0x38, 0x38, 0x38, 0x6C, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7E, 0x06, 0x0C, 0xF8, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xFE, 0xCC, 0x18, 0x30, 0x60, 0xC6, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x0E, 0x18, 0x18, 0x18, 0x70, 0x18, 0x18, 0x18, 0x18, 0x0E, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x70, 0x18, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x18, 0x18, 0x70, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x76, 0xDC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
};

fn getGlyph(ch: u8) *const [16]u8 {
    if (ch >= 0x20 and ch <= 0x7E) {
        return &font_data[ch - 0x20];
    }
    return &font_data['?' - 0x20];
}
