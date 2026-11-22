/// Linear frame buffer surface.
///
/// Owns everything that is specific to a video mode: how the mode was
/// discovered, how a pixel is laid out in memory, and the shadow buffer that
/// decouples drawing from the (slow, volatile) real framebuffer.
///
/// The shadow always stores pixels as 0x00RRGGBB regardless of the mode's
/// native byte order; `pack()` converts on the way out.  That is what makes a
/// scroll correct: the old code copied shadow rows into the LFB byte-wise,
/// which wrote red into the blue channel of every 24/32bpp mode.
const std = @import("std");
const root = @import("root");
const font = @import("gfx/font.zig");
const palette = @import("gfx/palette.zig");
const surface_mod = @import("gfx/surface.zig");

const serial = root.serial;

pub const Surface = surface_mod.Surface;

// ─── Mode state ─────────────────────────────────────────────────────

pub var active: bool = false;

/// True once the framebuffer has been checked and may be written to.
///
/// **Nothing is drawn to the framebuffer before this is true.**  A loader
/// can hand out an address that the kernel cannot use - a display adapter's
/// register file, for instance - and writing a whole screen of pixels there
/// is how a machine hangs: the write never comes back.
///
/// Until the probe has passed, the console renders into the shadow buffer
/// (which is ordinary RAM) and nothing is pushed out.
pub var verified: bool = false;

/// Physical address of the linear frame buffer.
pub var fb_addr: u64 = 0;
/// Bytes per scanline, as reported by the firmware.  May exceed
/// `width * bytes_pp`; the extra bytes are padding and must be skipped.
pub var fb_pitch: u32 = 0;
pub var fb_width: u32 = 0;
pub var fb_height: u32 = 0;
pub var fb_bpp: u32 = 0;
/// Multiboot framebuffer type: 0 = indexed, 1 = direct colour, 2 = RGB.
pub var fb_type: u32 = 0;

/// The geometry the firmware actually programmed.  The viewport (fb_width /
/// fb_height) is always clamped to this.
pub var boot_width: u32 = 0;
pub var boot_height: u32 = 0;
pub var boot_pitch: u32 = 0;
/// True when the viewport is smaller than the mode the firmware set.
pub var viewport_scaled: bool = false;

/// Bytes per pixel in the real framebuffer: 2 for RGB565, 3 for 24bpp,
/// 4 for 32bpp.
var fb_bytes_pp: u32 = 4;

/// True when the mode stores red in the LOW byte (memory order R,G,B).
///
/// Almost every PC display is B,G,R,X in memory, which is why this used to be
/// hardcoded - but a discrete GPU is free to report the opposite through the
/// multiboot channel fields, and then every colour comes out with red and blue
/// swapped.  Deriving it from the reported field positions costs nothing.
var fb_red_first: bool = false;

// ─── Shadow buffer ──────────────────────────────────────────────────

var shadow: [*]u32 = undefined;
/// Number of pixels the current shadow allocation can hold.
var shadow_pixels: usize = 0;
/// Row stride of the shadow, in pixels.  Always equals the viewport width
/// once `ensureShadow()` has succeeded; every shadow access goes through
/// `shadowIndex()`, so there is exactly one place that decides the stride.
var shadow_stride_px: u32 = 0;
var dirty_x0: u32 = 0;
var dirty_y0: u32 = 0;
var dirty_x1: u32 = 0;
var dirty_y1: u32 = 0;
var has_dirty: bool = false;

/// Number of shadow-to-LFB pushes that actually reached the hardware.
///
/// This is the line between "the console drew" and "the console's pixels
/// reached the screen": a probe can pass and the console can hold a full
/// grid of text, but if this stays at zero the flush path never ran.
pub var flush_count: u64 = 0;
pub var flushed_bytes: u64 = 0;
var first_flush_logged: bool = false;

/// True when the framebuffer's physical range is mapped in the kernel's
/// address space.
///
/// The firmware can hand out a framebuffer that lives far above the memory
/// the boot page tables identity-map: a discrete GPU's framebuffer BAR at
/// 8 TB is perfectly normal.  The range is mapped on demand (see
/// `vmm.mapRange`), and this flag says whether that worked.
pub var fb_mapped: bool = false;

/// Covers every resolution up to 4K (3840x2160).
const MAX_SHADOW_PIXELS: usize = 3840 * 2160;

/// Static preallocated early shadow buffer for boot/init (1024x768x32bpp).
/// Guarantees instant zero-lag drawing during early kernel initialization
/// before the PMM is online.
const EARLY_SHADOW_MAX: usize = 1024 * 768;
var early_shadow: [EARLY_SHADOW_MAX]u32 align(4096) = @splat(0);
var using_early_shadow: bool = false;

// ─── Page table mapping ─────────────────────────────────────────────

/// Map the framebuffer's physical range so that it can be written to.
///
/// The address the firmware reported is used as it is: the range is mapped
/// at the identity virtual address, which is the only way to keep the rest
/// of the driver (and every other user of the address) unchanged.
///
/// Returns false when the mapping could not be built.
fn mapFbRange(paddr: u64, size: u64) bool {
    if (paddr == 0 or size == 0) return false;
    if (root.vmm.mapRange(paddr, size)) return true;
    serial.serialWrite("[FB] the LFB range at 0x");
    serial.serialWriteHex(@truncate(paddr));
    serial.serialWrite(" cannot be mapped\n");
    return false;
}

// ─── Shadow allocation ──────────────────────────────────────────────

fn allocShadow(pixels: u64) bool {
    const bytes = (pixels * 4 + 4095) & ~@as(u64, 4095);
    const pages = @as(usize, @intCast(bytes / 4096));
    const phys = root.pmm.allocPages(pages) orelse return false;
    // Release the previous PMM allocation.  Not doing so leaks the whole buffer
    // on every `resolution` change that needs a bigger one, which on real
    // hardware is several megabytes per attempt.
    if (shadow_pixels != 0 and !using_early_shadow) {
        const old_pages = (shadow_pixels * 4 + 4095) / 4096;
        root.pmm.freePages(@intFromPtr(shadow), old_pages);
    }
    shadow = @ptrFromInt(phys);
    shadow_pixels = @intCast(pixels);
    shadow_stride_px = fb_width;
    using_early_shadow = false;
    @memset(shadow[0..shadow_pixels], 0);
    return true;
}

/// Make sure the shadow can back the current viewport.
///
/// Returns false when the shadow is missing or too small, in which case the
/// caller must fall back to drawing straight into the LFB.  Every shadow
/// access in this file is guarded by this function - the old code checked
/// `shadow_pixels != 0`, which is not the same thing and let a viewport change
/// write past the end of the allocation.
pub fn ensureShadow() bool {
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

    // The viewport changed.  Re-stride in place when the existing allocation is
    // still large enough, otherwise get a bigger one from the PMM.
    if (needed <= shadow_pixels) {
        shadow_stride_px = fb_width;
        @memset(shadow[0..@intCast(needed)], 0);
        return true;
    }
    if (using_early_shadow and root.pmm.free_pages == 0) return false;
    return allocShadow(needed);
}

/// Offset of pixel (x, y) inside the shadow.  The stride is `shadow_stride_px`,
/// never `fb_width` directly: the two can differ for a moment during a
/// viewport change and using the wrong one walks off the allocation.
inline fn shadowIndex(x: u32, y: u32) usize {
    return @as(usize, y) * shadow_stride_px + x;
}

/// True when the shadow is present and big enough for the current viewport.
///
/// `ensureShadow()` has to be called *first*: it is what allocates the shadow
/// the first time round.  Testing `shadow_pixels != 0` before that call
/// short-circuits on the very first draw, the shadow is never allocated, and
/// every subsequent draw lands straight in the LFB - which is invisible until
/// something needs the shadow, i.e. a scroll.
inline fn shadowUsable() bool {
    return ensureShadow();
}

// ─── Pixel packing ──────────────────────────────────────────────────

/// Convert a 0x00RRGGBB shadow pixel into the word the mode wants.
inline fn packPixel32(rgb: u32) u32 {
    if (!fb_red_first) return rgb;
    return ((rgb & 0x0000FF) << 16) | (rgb & 0x0000FF00) | ((rgb >> 16) & 0xFF);
}

/// Write one RGB pixel straight to the LFB.
fn lfbPut(x: u32, y: u32, rgb: u32) void {
    // Nothing goes to the framebuffer before the probe has checked it: the
    // address the loader handed out may belong to a device, and a write
    // there can block the machine for good.
    if (!verified) return;
    lfbPutRaw(x, y, rgb);
}

/// Write a pixel without the verification check.
///
/// Only the probe uses this: it has to write one pixel to find out whether
/// the framebuffer is there at all.
fn lfbPutRaw(x: u32, y: u32, rgb: u32) void {
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

inline fn lfbOffset(y: u32, x: u32) u64 {
    return @as(u64, y) * fb_pitch + @as(u64, x) * fb_bytes_pp;
}

// ─── Mode discovery ─────────────────────────────────────────────────

inline fn rd16(p: [*]const u8, off: usize) u32 {
    return @as(u32, p[off]) | (@as(u32, p[off + 1]) << 8);
}

inline fn rd32(p: [*]const u8, off: usize) u32 {
    return @as(u32, p[off]) |
        (@as(u32, p[off + 1]) << 8) |
        (@as(u32, p[off + 2]) << 16) |
        (@as(u32, p[off + 3]) << 24);
}

/// Multiboot 1 flag bit 11: the VBE table, i.e. `vbe_control_info` at mbi+72
/// and `vbe_mode_info` at mbi+76.
///
/// This is the *spec* video source.  The driver used to ignore it completely
/// and declare "no framebuffer info" whenever bit 12 was clear, which is wrong
/// for any loader that implements the spec rather than GRUB's extension.  Under
/// UEFI it is never set - GRUB gates `fill_vbe_info()` behind
/// GRUB_MACHINE_HAS_VBE - but under BIOS it is exactly what describes the
/// current mode.
///
/// The mode info block is the standard VESA VBE 3.0 structure, and only the
/// linear fields are read: a banked mode has no usable framebuffer.
///   18 x_resolution (u16)      40 phys_base_addr (u32)
///   20 y_resolution (u16)      50 lin_bytes_per_scan_line (u16)
///   25 bits_per_pixel (u8)     54..59 lin_{red,green,blue}_{mask_size,field_position}
///   27 memory_model (u8)
fn tryVbeInfo(mbi: [*]const u8, flags: u32) bool {
    if ((flags & (1 << 11)) == 0) return false;

    const ptr = rd32(mbi, 76);
    if (ptr == 0) {
        serial.serialWrite("[FB] bit 11 set but vbe_mode_info is null\n");
        return false;
    }
    const m: [*]const u8 = @ptrFromInt(ptr);
    const w = rd16(m, 18);
    const h = rd16(m, 20);
    const bpp = @as(u32, m[25]);
    const model = @as(u32, m[27]);
    const phys = rd32(m, 40);
    const lin_pitch = rd16(m, 50);

    serial.serialWrite("[FB] VBE mode info at 0x");
    serial.serialWriteHex(ptr);
    serial.serialWrite(": ");
    serial.serialWriteDec(w);
    serial.serialWrite("x");
    serial.serialWriteDec(h);
    serial.serialWrite("x");
    serial.serialWriteDec(bpp);
    serial.serialWrite(" model=");
    serial.serialWriteDec(model);
    serial.serialWrite(" phys=0x");
    serial.serialWriteHex(phys);
    serial.serialWrite(" lin_pitch=");
    serial.serialWriteDec(lin_pitch);
    serial.serialWrite("\n");

    // A direct-colour (0) or packed (6) memory model with a linear address and
    // a packed depth is the only thing this driver can drive.  Model 7 is YUV.
    if (phys == 0 or w == 0 or h == 0) return false;
    if (model != 0 and model != 6) {
        serial.serialWrite("[FB] VBE memory model ");
        serial.serialWriteDec(model);
        serial.serialWrite(" is not packed RGB; ignoring\n");
        return false;
    }
    if (bpp != 32 and bpp != 24 and bpp != 16) return false;

    fb_addr = phys;
    fb_width = w;
    fb_height = h;
    fb_bpp = bpp;
    fb_type = 1; // direct colour
    fb_pitch = if (lin_pitch != 0) lin_pitch else w * (bpp / 8);
    applyChannelOrder(@as(u8, @intCast(m[55])), @as(u8, @intCast(m[57])), @as(u8, @intCast(m[59])), bpp);
    return true;
}

/// Read six channel bytes at `off` and apply them if they look like a real
/// packed layout.  Returns false when they do not, so the caller can try the
/// other candidate offset.
fn readChannels(mbi: [*]const u8, off: usize, bpp: u32) bool {
    const rs = mbi[off + 1];
    const gs = mbi[off + 3];
    const bs = mbi[off + 5];
    const rp = mbi[off];
    const gp = mbi[off + 2];
    const bp = mbi[off + 4];
    // Every mask must be non-empty and no field may start at or past the pixel.
    if (rs == 0 or gs == 0 or bs == 0) return false;
    if (rp >= bpp or gp >= bpp or bp >= bpp) return false;
    applyChannelOrder(rp, gp, bp, bpp);
    return true;
}

/// Decide the in-memory byte order from the reported channel field positions
/// and record it.  A position of 0 for red means the mode is R,G,B in memory;
/// blue at 0 - nearly every PC display - means B,G,R.
fn applyChannelOrder(red_pos: u8, green_pos: u8, blue_pos: u8, bpp: u32) void {
    if (red_pos < bpp and green_pos < bpp and blue_pos < bpp) {
        fb_red_first = (red_pos == 0 and blue_pos != 0);
    }
    serial.serialWrite("[FB] channels R@");
    serial.serialWriteDec(red_pos);
    serial.serialWrite(" G@");
    serial.serialWriteDec(green_pos);
    serial.serialWrite(" B@");
    serial.serialWriteDec(blue_pos);
    serial.serialWrite(" byte_order=");
    serial.serialWrite(if (fb_red_first) "RGB" else "BGR");
    serial.serialWrite("\n");
}

/// Log the raw multiboot video bytes.
///
/// The framebuffer fields live in GRUB's extension of the Multiboot 1 layout
/// rather than in the 2001 spec, and every consumer guesses at the offsets
/// differently.  When a machine behaves differently from QEMU there is no way
/// to tell a misread offset from a genuinely absent field except by looking at
/// the bytes, so print them.
fn dumpMbiVideo(mbi: [*]const u8, flags: u32) void {
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

/// Take the framebuffer of a display adapter over PCI.
///
/// A display adapter that has been programmed by a firmware can leave a
/// linear framebuffer in one of its memory BARs; the geometry comes from
/// the adapter itself (see `drivers/video/pcidisplay.zig`).
///
/// The shadow buffer is released: it was sized for the old mode, and
/// `ensureShadow()` grows it for the new one.
pub fn initLinear(addr: u64, width: u32, height: u32, pitch: u32, bpp: u32) bool {
    if (addr == 0 or width == 0 or height == 0 or pitch == 0) return false;
    if (bpp != 16 and bpp != 24 and bpp != 32) return false;

    // The adapter's memory can live above the window the boot page tables
    // identity-map.  Map it where it is, so the address can be used as it
    // is.
    if (!mapFbRange(addr, @as(u64, pitch) * height)) return false;
    fb_mapped = true;

    fb_addr = addr;
    fb_width = width;
    fb_height = height;
    fb_pitch = pitch;
    fb_bpp = bpp;
    fb_bytes_pp = bpp / 8;
    fb_type = 1; // direct colour
    active = true;

    // The shadow was sized for the old mode: release it, so that
    // `ensureShadow()` allocates one for the new geometry.
    if (shadow_pixels != 0 and !using_early_shadow) {
        const old_pages = (shadow_pixels * 4 + 4095) / 4096;
        root.pmm.freePages(@intFromPtr(shadow), old_pages);
    }
    shadow_pixels = 0;
    shadow_stride_px = 0;
    using_early_shadow = false;
    has_dirty = false;

    serial.serialWrite("[FB] source=PCI display adapter, ");
    serial.serialWriteDec(width);
    serial.serialWrite("x");
    serial.serialWriteDec(height);
    serial.serialWrite("x");
    serial.serialWriteDec(bpp);
    serial.serialWrite(" at 0x");
    serial.serialWriteHex(addr);
    serial.serialWrite("\n");
    return true;
}

pub fn initFromMultiboot(mbi_ptr: u32) void {
    const mbi: [*]const u8 = @ptrFromInt(mbi_ptr);

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
        if (tryVbeInfo(mbi, flags)) {
            serial.serialWrite("[FB] source=multiboot bit 11 VBE mode info\n");
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

        // Channel field positions, six bytes.  The spec puts them at 110, but
        // GRUB's `struct multiboot_info` is not packed: the union holding them
        // contains a u32 palette address, so the compiler aligns it to 4 and they
        // actually land at 112.  Both are tried and the one that yields
        // self-consistent field positions wins, rather than trusting either.
        if (!readChannels(mbi, 110, fb_bpp)) {
            _ = readChannels(mbi, 112, fb_bpp);
        }
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

    // Ensure framebuffer range is mapped in the page tables (crucial if
    // fb_addr is above the 64 GB the boot tables identity-map - a discrete
    // GPU's framebuffer BAR at 8 TB is normal).
    const total_fb_bytes = @as(u64, fb_pitch) * fb_height;
    if (!mapFbRange(fb_addr, total_fb_bytes)) {
        serial.serialWrite("[FB] the LFB cannot be mapped; staying in text mode\n");
        active = false;
        return;
    }
    fb_mapped = true;

    active = true;

    serial.serialWrite("[FB] the LFB range is mapped (");
    serial.serialWriteDec(total_fb_bytes / 1024);
    serial.serialWrite(" KiB at its own address)\n");

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
    serial.serialWrite("\n");
}

// ─── LFB probe ──────────────────────────────────────────────────────

/// Verify the reported LFB is actually backed before anything draws to it.
///
/// A firmware can report a mode whose LFB lives outside the identity map, or
/// with a pitch that walks off the end of it. Touching that memory with no IDT
/// installed is a triple fault: the machine reboots and *nothing* reaches the
/// log, which is exactly the "forced mode reboots, keep hangs" signature seen
/// on real hardware. So this refuses anything it cannot vouch for and is called
/// from main.zig only after system_init has installed the IDT.
/// Probe the framebuffer the loader handed us.
///
/// Returns true when the framebuffer can be used.  A false return is **not**
/// fatal: the console falls back to the legacy VGA text mode, where the
/// kernel paints the characters itself, and the boot goes on.  A machine
/// whose display adapter cannot be driven still runs, and the reason ends
/// up in the kernel log.
pub fn probeLfbSafe() bool {
    if (!active) {
        serial.serialWrite("[FB] probe SKIP: no framebuffer\n");
        return false;
    }
    // A pitch LARGER than width*bpp is normal and must be accepted: 24bpp VBE
    // modes and anything with a scanline pad report one.  The dangerous
    // direction is a pitch too SMALL, where lfbOffset walks into the next
    // scanline and eventually off the end of the aperture.
    const min_pitch = fb_width * fb_bytes_pp;
    if (fb_pitch == 0 or fb_pitch < min_pitch) {
        serial.serialWrite("[FB] probe SKIP: pitch ");
        serial.serialWriteDec(fb_pitch);
        serial.serialWrite(" is below width*bytes_pp=");
        serial.serialWriteDec(min_pitch);
        serial.serialWrite(" (rows would shear and the last row runs off the LFB)\n");
        active = false;
        return false;
    }
    if (fb_pitch - min_pitch >= fb_width) {
        serial.serialWrite("[FB] note: pitch has ");
        serial.serialWriteDec(fb_pitch - min_pitch);
        serial.serialWrite(" bytes of padding per scanline\n");
    }
    // The range has to be mapped before anything is written to it: a loader
    // that hands out a framebuffer the kernel cannot reach would otherwise be
    // written to blind.  The console falls back to the VGA text mode and the
    // boot goes on.
    if (!fb_mapped) {
        serial.serialWrite("[FB] probe SKIP: the LFB at 0x");
        serial.serialWriteHex(@truncate(fb_addr));
        serial.serialWrite(" is not mapped - disabling the driver\n");
        active = false;
        return false;
    }

    // The page walk has to resolve the address to itself.  That is what says
    // the mapping is really there: a framebuffer the kernel cannot reach is
    // a black screen with a green probe in the log, and this is the line
    // that says which of the two it is.
    if (root.vmm.virtToPhys(fb_addr)) |phys| {
        if (phys != fb_addr) {
            serial.serialWrite("[FB] probe SKIP: the LFB address resolves to 0x");
            serial.serialWriteHex(@truncate(phys));
            serial.serialWrite(", not to itself - disabling the driver\n");
            active = false;
            return false;
        }
    } else {
        serial.serialWrite("[FB] probe SKIP: the LFB at 0x");
        serial.serialWriteHex(@truncate(fb_addr));
        serial.serialWrite(" does not resolve - disabling the driver\n");
        active = false;
        return false;
    }
    if (!probeLfb()) {
        active = false;
        return false;
    }

    // The framebuffer is good: from now on the console is pushed out.
    verified = true;
    return true;
}

fn probeLfb() bool {
    serial.serialWrite("[FB] probing LFB at 0x");
    serial.serialWriteHex(@truncate(fb_addr));
    serial.serialWrite("...\n");
    const saved = lfbGet(0, 0);
    lfbPutRaw(0, 0, 0x00FF00FF);
    const readback = lfbGet(0, 0);
    lfbPutRaw(0, 0, saved);
    if (readback == 0x00FF00FF) {
        serial.serialWrite("[FB] probe OK: LFB is readable and writable\n");
        return true;
    }
    serial.serialWrite("[FB] probe MISMATCH: wrote 0x00FF00FF, read 0x");
    serial.serialWriteHex(readback);
    serial.serialWrite("\n[FB] probe SKIP: LFB is not backed by the reported address\n");
    return false;
}

/// Draw a recognisable full-screen pattern straight into the LFB, bypassing the
/// shadow buffer, then read several pixels back and log what came out.
///
/// This is the decisive test when the screen stays black: if the readback
/// matches what we wrote, the buffer really is writable and the hardware is
/// simply not scanning it out. If the readback does not match, we are writing
/// somewhere else entirely. A black-on-black screen cannot tell those apart, a
/// colour-bar test can.
pub fn testPattern() void {
    if (!active) return;
    serial.serialWrite("[FB] drawing colour-bar test pattern...\n");
    const bar_colors = [8]u32{
        0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00,
        0xFF00FF, 0x00FFFF, 0xFFFFFF, 0x000000,
    };
    var y: u32 = 0;
    while (y < fb_height) : (y += 1) {
        var x: u32 = 0;
        while (x < fb_width) : (x += 1) {
            const band = (x * 8) / fb_width;
            const color = bar_colors[@min(band, 7)];
            lfbPut(x, y, color);
        }
    }
    // Read back a pixel from each band and compare.
    var ok: u32 = 0;
    var bad: u32 = 0;
    y = fb_height / 2;
    var band: u32 = 0;
    while (band < 8) : (band += 1) {
        const x = (fb_width * band) / 8 + 1;
        if (x >= fb_width) continue;
        const expect = bar_colors[band];
        const got = lfbGet(x, y);
        if (got == expect) {
            ok += 1;
        } else {
            bad += 1;
            serial.serialWrite("[FB] pattern band ");
            serial.serialWriteDec(band);
            serial.serialWrite(" expected 0x");
            serial.serialWriteHex(expect);
            serial.serialWrite(" got 0x");
            serial.serialWriteHex(got);
            serial.serialWrite("\n");
        }
    }
    serial.serialWrite("[FB] pattern readback: ");
    serial.serialWriteDec(ok);
    serial.serialWrite(" ok, ");
    serial.serialWriteDec(bad);
    serial.serialWrite(" mismatched\n");
}

// ─── Viewport ───────────────────────────────────────────────────────

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

    return exact;
}

/// Backwards-compatible alias: resizing only ever changes the viewport now.
pub fn setResolution(new_w: u32, new_h: u32) void {
    _ = setViewport(new_w, new_h);
}

// ─── Primitives ─────────────────────────────────────────────────────

pub fn putPixel(x: u32, y: u32, r: u8, g: u8, b: u8) void {
    if (x >= fb_width or y >= fb_height) return;
    const col: u32 = (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    if (shadowUsable()) {
        shadow[shadowIndex(x, y)] = col;
        markDirty(x, y);
        return;
    }
    lfbPut(x, y, col);
}

pub fn getPixel(x: u32, y: u32) u32 {
    if (x >= fb_width or y >= fb_height) return 0;
    // ensureShadow(), not `shadow_pixels != 0`: after a viewport change the
    // allocation can still exist while being too small for the new geometry.
    if (shadowUsable()) {
        return shadow[shadowIndex(x, y)];
    }
    return lfbGet(x, y);
}

/// LFB-only accessors: bypass the shadow buffer and dirty tracking entirely.
/// Used for the mouse cursor so it updates at its own rate instead of being
/// batched into the screen renderer's shadow -> flush pipeline.
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
    // Saturating: a wrapping x1 would shrink the rect instead of growing it.
    const x1 = x +| w;
    const y1 = y +| h;
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
    // The framebuffer has not been checked yet: the console keeps
    // rendering into the shadow buffer and nothing is pushed out.
    if (!verified) return;
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
    // The shadow can be smaller than the current geometry: clear() falls back to
    // drawing straight to the LFB when the PMM cannot grow the buffer.
    if (!ensureShadow()) return;
    // Refuse rather than read past the allocation.  `shadowIndex` uses
    // shadow_stride_px, so the bound has to be expressed in the same units.
    if (@as(u64, y1) * shadow_stride_px > shadow_pixels) return;

    const w = x1 - x0;
    flush_count +%= 1;
    flushed_bytes +%= @as(u64, w) * (y1 - y0) * fb_bytes_pp;
    if (!first_flush_logged) {
        first_flush_logged = true;
        serial.serialWrite("[FB] first flush: ");
        serial.serialWriteDec(w);
        serial.serialWrite("x");
        serial.serialWriteDec(y1 - y0);
        serial.serialWrite(" at ");
        serial.serialWriteDec(x0);
        serial.serialWrite(",");
        serial.serialWriteDec(y0);
        serial.serialWrite(" addr=0x");
        serial.serialWriteHex(@truncate(fb_addr));
        serial.serialWrite(" bytes=");
        serial.serialWriteDec(@as(u64, w) * (y1 - y0) * fb_bytes_pp);
        serial.serialWrite(" bpp=");
        serial.serialWriteDec(fb_bpp);
        serial.serialWrite("\n");
    }
    var y: u32 = y0;
    while (y < y1) : (y += 1) {
        const row_off = shadowIndex(x0, y);
        const src: [*]const u32 = shadow + row_off;
        if (fb_bytes_pp == 4 and !fb_red_first) {
            // Fast path: the mode's native order is the same as the shadow's.
            const dst: [*]volatile u32 = @ptrFromInt(fb_addr + @as(u64, y) * fb_pitch + @as(u64, x0) * 4);
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                dst[x] = src[x];
            }
        } else if (fb_bytes_pp == 4) {
            const dst: [*]volatile u32 = @ptrFromInt(fb_addr + @as(u64, y) * fb_pitch + @as(u64, x0) * 4);
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                dst[x] = packPixel32(src[x]);
            }
        } else {
            // 16bpp and 24bpp go through the shared byte packer, so the mode's
            // channel order is honoured here as well.
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
    // Saturating, not wrapping: `px + pw` overflowing u32 would wrap to a small
    // value, make x1 < x0, and turn w into a multi-gigabyte write.
    const x1 = @min(px +| pw, fb_width);
    const y1 = @min(py +| ph, fb_height);
    const w = x1 - x0;
    const col: u32 = (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);

    if (shadowUsable()) {
        var y: u32 = y0;
        while (y < y1) : (y += 1) {
            const row = shadow + shadowIndex(x0, y);
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
            const ptr: [*]volatile u32 = @ptrFromInt(fb_addr + offset);
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                ptr[x] = packPixel32(col);
            }
        } else {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                lfbPut(x0 + x, y, col);
            }
        }
    }
}

/// Blit a 0x00RRGGBB pixel buffer into the shadow, scaled to fit a rectangle.
///
/// Nearest-neighbour: a virtual display is usually a different size from the
/// window it is shown in, and a guest's own output must not be filtered - the
/// compositor shows exactly the pixels the guest produced, just at a
/// different scale.  The destination is clipped to the viewport.
pub fn blitScaled(
    src: [*]const u32,
    src_stride_px: u32,
    src_w: u32,
    src_h: u32,
    dst_x: u32,
    dst_y: u32,
    dst_w: u32,
    dst_h: u32,
) void {
    if (src_w == 0 or src_h == 0 or dst_w == 0 or dst_h == 0) return;
    if (!shadowUsable()) return;

    const x0 = dst_x;
    const y0 = dst_y;
    const x1 = @min(dst_x + dst_w, fb_width);
    const y1 = @min(dst_y + dst_h, fb_height);
    if (x0 >= x1 or y0 >= y1) return;

    var dy = y0;
    while (dy < y1) : (dy += 1) {
        const sy = ((dy - y0) * src_h) / dst_h;
        const srow = src + @as(usize, sy) * src_stride_px;
        const drow = shadow + shadowIndex(x0, dy);
        var dx = x0;
        while (dx < x1) : (dx += 1) {
            const sx = ((dx - x0) * src_w) / dst_w;
            drow[dx - x0] = srow[sx];
        }
    }
    markDirtyRect(x0, y0, x1 - x0, y1 - y0);
}

pub fn drawRectBorder(px: u32, py: u32, pw: u32, ph: u32, thickness: u32, r: u8, g: u8, b: u8) void {
    if (thickness == 0 or pw == 0 or ph == 0) return;
    fillRect(px, py, pw, thickness, r, g, b);
    fillRect(px, py + ph -| thickness, pw, thickness, r, g, b);
    fillRect(px, py, thickness, ph, r, g, b);
    fillRect(px + pw -| thickness, py, thickness, ph, r, g, b);
}

/// Blit one glyph with explicit RGB colours (the GUI's entry point).
pub fn drawGlyph(px: u32, py: u32, ch: u8, fr: u8, fg: u8, fb_col: u8, br: u8, bg: u8, bb: u8) void {
    if (px + font.GLYPH_W > fb_width or py + font.GLYPH_H > fb_height) return;
    const glyph = font.glyph(ch);
    const fg_pixel: u32 = (@as(u32, fr) << 16) | (@as(u32, fg) << 8) | @as(u32, fb_col);
    const bg_pixel: u32 = (@as(u32, br) << 16) | (@as(u32, bg) << 8) | @as(u32, bb);

    if (shadowUsable()) {
        var gy: usize = 0;
        while (gy < font.GLYPH_H) : (gy += 1) {
            const bits = glyph[gy];
            const row = shadow + shadowIndex(px, py + @as(u32, @intCast(gy)));
            var gx: usize = 0;
            while (gx < font.GLYPH_W) : (gx += 1) {
                if ((@as(u8, 0x80) >> @intCast(gx)) & bits != 0) {
                    row[gx] = fg_pixel;
                } else {
                    row[gx] = bg_pixel;
                }
            }
        }
        markDirtyRect(px, py, @as(u32, @intCast(font.GLYPH_W)), @as(u32, @intCast(font.GLYPH_H)));
        return;
    }

    var gy: usize = 0;
    while (gy < font.GLYPH_H) : (gy += 1) {
        const bits = glyph[gy];
        var gx: usize = 0;
        while (gx < font.GLYPH_W) : (gx += 1) {
            const on = ((@as(u8, 0x80) >> @intCast(gx)) & bits) != 0;
            lfbPut(px + @as(u32, @intCast(gx)), py + @as(u32, @intCast(gy)), if (on) fg_pixel else bg_pixel);
        }
    }
}

/// Blit a string with explicit RGB colours (the GUI's entry point).
pub fn drawString(px: u32, py: u32, s: []const u8, fr: u8, fg: u8, fb_col: u8, br: u8, bg: u8, bb: u8) void {
    var x = px;
    for (s) |ch| {
        if (x + font.GLYPH_W > fb_width) break;
        drawGlyph(x, py, ch, fr, fg, fb_col, br, bg, bb);
        x += font.GLYPH_W;
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
    const s: *FbSurface = @ptrCast(@alignCast(ctx));
    return s.gridCols();
}

fn vtblGridRows(ctx: *anyopaque) u32 {
    const s: *FbSurface = @ptrCast(@alignCast(ctx));
    return s.gridRows();
}

fn vtblPutCell(ctx: *anyopaque, col: u32, row: u32, ch: u8, fg: u8, bg: u8) void {
    const s: *FbSurface = @ptrCast(@alignCast(ctx));
    s.putCell(col, row, ch, fg, bg);
}

fn vtblClear(ctx: *anyopaque, bg: u8) void {
    const s: *FbSurface = @ptrCast(@alignCast(ctx));
    s.clear(bg);
}

fn vtblFlush(ctx: *anyopaque) void {
    _ = ctx;
    flush();
}

/// Scroll the shadow's text region up by `rows` cell rows.
///
/// Only the *shadow* is scrolled; the real framebuffer is refreshed by the
/// normal flush path, which repacks every pixel according to the mode's
/// channel order.  The old implementation copied shadow rows straight into the
/// LFB byte-wise, which wrote the red channel into the blue slot of every
/// 24/32bpp mode - a scroll visibly swapped red and blue.
fn vtblScrollUp(ctx: *anyopaque, rows: u32, cols: u32) void {
    _ = ctx;
    scrollRegionUp(rows, cols);
}

/// Background colour used when the console scrolls a region.  Kept in sync
/// with the console engine through `setConsoleBackground`.
var bg_r: u8 = 0;
var bg_g: u8 = 0;
var bg_b: u8 = 0;

pub fn setConsoleBackground(r: u8, g: u8, b: u8) void {
    bg_r = r;
    bg_g = g;
    bg_b = b;
}

/// Scroll the console's text region up by one cell row.
pub fn scrollRegionUp(rows: u32, cols: u32) void {
    if (!active) return;
    if (!shadowUsable()) return;
    if (rows == 0) return; // the console scrolls one row at a time

    const cell_h: u32 = @intCast(font.GLYPH_H);
    const cell_w: u32 = @intCast(font.GLYPH_W);
    const region_w = @min(cols * cell_w, fb_width);
    const region_h = @min(rows * cell_h, fb_height);
    if (region_h <= cell_h) return;

    // Move every cell row up by one, then blank the exposed bottom cell row.
    // Blanking only its last pixel row used to leave the previous bottom text
    // in place, so every scroll duplicated the line above it - the console
    // engine considers the mirror's row blank and does not repaint it.  The
    // exposed *cell* row is `cell_h` pixel rows tall and all of them have to
    // go (the VGA text surface blanks its whole exposed row the same way).
    const stride = shadow_stride_px;
    var y: u32 = 0;
    while (y + cell_h < region_h) : (y += 1) {
        const dst = shadow + @as(usize, y) * stride;
        const src = shadow + @as(usize, y + cell_h) * stride;
        @memcpy(dst[0..region_w], src[0..region_w]);
    }
    const bg_col: u32 = (@as(u32, bg_r) << 16) | (@as(u32, bg_g) << 8) | @as(u32, bg_b);
    var exposed: u32 = region_h - cell_h;
    while (exposed < region_h) : (exposed += 1) {
        const row = shadow + @as(usize, exposed) * stride;
        @memset(row[0..region_w], bg_col);
    }
    markDirtyRect(0, 0, region_w, region_h);
}

/// State owned by the framebuffer surface.
pub const FbSurface = struct {
    /// Cached grid size, refreshed from the viewport when it changes.
    grid_cols: u32 = 0,
    grid_rows: u32 = 0,
    grid_width: u32 = 0,
    grid_height: u32 = 0,

    pub fn gridCols(self: *FbSurface) u32 {
        self.refreshGrid();
        return self.grid_cols;
    }

    pub fn gridRows(self: *FbSurface) u32 {
        self.refreshGrid();
        return self.grid_rows;
    }

    fn refreshGrid(self: *FbSurface) void {
        if (self.grid_width == fb_width and self.grid_height == fb_height) return;
        self.grid_width = fb_width;
        self.grid_height = fb_height;
        self.grid_cols = fb_width / @as(u32, @intCast(font.GLYPH_W));
        self.grid_rows = fb_height / @as(u32, @intCast(font.GLYPH_H));
        if (self.grid_cols == 0) self.grid_cols = 1;
        if (self.grid_rows == 0) self.grid_rows = 1;
    }

    /// Paint one character cell with palette-indexed colours.
    pub fn putCell(self: *FbSurface, col: u32, row: u32, ch: u8, fg: u8, bg: u8) void {
        _ = self;
        const px = col * @as(u32, @intCast(font.GLYPH_W));
        const py = row * @as(u32, @intCast(font.GLYPH_H));
        if (px + @as(u32, @intCast(font.GLYPH_W)) > fb_width or
            py + @as(u32, @intCast(font.GLYPH_H)) > fb_height) return;
        const fg_rgb = palette.rgb(fg);
        const bg_rgb = palette.rgb(bg);
        const c = palette.split(fg_rgb);
        const b = palette.split(bg_rgb);
        drawGlyph(px, py, ch, c.r, c.g, c.b, b.r, b.g, b.b);
    }

    pub fn clear(self: *FbSurface, bg: u8) void {
        _ = self;
        const b = palette.split(palette.rgb(bg));
        clearTo(b.r, b.g, b.b);
    }
};

/// Erase the whole viewport to one colour, through the shadow when possible.
pub fn clearTo(r: u8, g: u8, b: u8) void {
    if (!active) return;
    const col: u32 = (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    if (shadowUsable()) {
        @memset(shadow[0..shadow_pixels], col);
        markDirtyRect(0, 0, fb_width, fb_height);
        return;
    }
    // No shadow: paint the LFB directly.
    var y: u32 = 0;
    while (y < fb_height) : (y += 1) {
        var x: u32 = 0;
        while (x < fb_width) : (x += 1) {
            lfbPut(x, y, col);
        }
    }
    has_dirty = false;
}

/// Size of one character cell, in pixels.  The console grid is derived from
/// these, so every consumer that needs the cell size reads it from here.
pub const char_w: usize = font.GLYPH_W;
pub const char_h: usize = font.GLYPH_H;

/// The framebuffer surface.  A single static instance is enough: the
/// framebuffer is a singleton resource.
pub var fb_surface_instance: FbSurface = .{};

/// Surface handle for the framebuffer.
pub fn surface() Surface {
    return .{
        .ctx = @ptrCast(&fb_surface_instance),
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
