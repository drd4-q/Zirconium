//! The EDID parser.
//!
//! Ported from the Linux kernel's `drivers/gpu/drm/drm_edid.c` and the
//! `struct edid` / `struct detailed_pixel_timing` layouts in
//! `include/drm/drm_edid.h`.  The EDID is what a display tells the host
//! about itself: who made it, what it is called, what modes it can do and
//! how big its active area is.
//!
//! The file is deliberately free of any kernel dependency: it is pure
//! parsing, so `tools/test_edid.zig` can import it and check it against
//! known blobs on the host, without a machine.
//!
//! The layout of the base block (VESA E-EDID 1.4, section 3.4):
//!
//!     0..7    the header: 00 FF FF FF FF FF FF 00
//!     8..9    the manufacturer ID, three letters in five bits each
//!    10..11   the product code, little endian
//!    12..15   the serial number, little endian
//!    16       the week of manufacture (0xff = unspecified)
//!    17       the year of manufacture, minus 1990
//!    18       the EDID version
//!    19       the EDID revision
//!    20       the video input parameters
//!    21..22   the screen size in centimetres (or the aspect ratio)
//!    23       the gamma
//!    24       the supported features
//!    25..34   the chromaticity coordinates
//!    35..37   the established timings
//!    38..53   the standard timings
//!    54..125  the four 18 byte descriptors
//!    126      the number of extension blocks
//!    127      the checksum

const std = @import("std");

/// The size of the EDID base block.
pub const EDID_LENGTH: usize = 128;

/// The header every base block starts with.
pub const EDID_HEADER: [8]u8 = .{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };

/// The size of one descriptor block.
pub const DESCRIPTOR_LENGTH: usize = 18;

/// The descriptor types, from Linux's `EDID_DETAIL_*`.
pub const Detail = struct {
    pub const monitor_name: u8 = 0xFC;
    pub const monitor_range: u8 = 0xFD;
    pub const monitor_serial: u8 = 0xFF;
    pub const monitor_string: u8 = 0xFE;
    /// The type of a detailed timing descriptor.
    pub const detailed_timing: u8 = 0xFE;
};

/// The bits of the "misc" byte of a detailed timing, from Linux's
/// `DRM_EDID_PT_*`.
pub const Pt = struct {
    pub const hsync_positive: u8 = 1 << 1;
    pub const vsync_positive: u8 = 1 << 2;
    pub const separate_sync: u8 = 3 << 3;
    pub const stereo: u8 = 1 << 5;
    pub const interlaced: u8 = 1 << 7;
};

/// A display mode, in the shape the DRM code uses.
pub const Mode = struct {
    /// The pixel clock in kHz.
    clock_khz: u32 = 0,
    h_active: u16 = 0,
    v_active: u16 = 0,
    h_sync_start: u16 = 0,
    h_sync_end: u16 = 0,
    h_total: u16 = 0,
    v_sync_start: u16 = 0,
    v_sync_end: u16 = 0,
    v_total: u16 = 0,
    /// The size of the active area in millimetres.
    h_size_mm: u16 = 0,
    v_size_mm: u16 = 0,
    interlaced: bool = false,
    /// True when the display uses separate horizontal and vertical syncs.
    separate_sync: bool = false,

    /// The refresh rate in Hz, from the totals and the pixel clock.
    ///
    /// This is Linux's `drm_mode_vrefresh()`: the clock over the total
    /// number of pixels, rounded to the nearest whole hertz.
    pub fn refreshRate(self: Mode) u32 {
        if (self.h_total == 0 or self.v_total == 0) return 0;
        const total = @as(u64, self.h_total) * self.v_total;
        if (total == 0) return 0;
        // clock_khz is in kHz, so the rate is clock * 1000 / (h * v).
        const rate = (@as(u64, self.clock_khz) * 1000 + total / 2) / total;
        return @intCast(rate);
    }

    /// The name of the mode, the way the DRM code names it.
    pub fn name(self: Mode, buf: []u8) []const u8 {
        if (buf.len < 32) return "";
        const n = std.fmt.bufPrint(buf, "{d}x{d}", .{ self.h_active, self.v_active }) catch return "";
        return n;
    }

    /// The area of the mode, the way Linux compares modes
    /// (`MODE_SIZE()` in drm_edid.c).
    pub fn area(self: Mode) u32 {
        return @as(u32, self.h_active) * self.v_active;
    }
};

/// The established timings, the fixed list the EDID can switch on with a
/// single bit.  Linux keeps the same list in `drm_edid.c`.
pub const EstablishedMode = struct {
    w: u16,
    h: u16,
    refresh: u16,
    /// The pixel clock in kHz.
    clock_khz: u32,
    interlaced: bool = false,
};

pub const ESTABLISHED_MODES = [_]EstablishedMode{
    .{ .w = 800, .h = 600, .refresh = 60, .clock_khz = 40000 },
    .{ .w = 800, .h = 600, .refresh = 56, .clock_khz = 36000 },
    .{ .w = 640, .h = 480, .refresh = 75, .clock_khz = 31500 },
    .{ .w = 640, .h = 480, .refresh = 72, .clock_khz = 31500 },
    .{ .w = 640, .h = 480, .refresh = 67, .clock_khz = 30240 },
    .{ .w = 640, .h = 480, .refresh = 60, .clock_khz = 25175 },
    .{ .w = 720, .h = 400, .refresh = 88, .clock_khz = 35500 },
    .{ .w = 720, .h = 400, .refresh = 70, .clock_khz = 28320 },
    .{ .w = 1280, .h = 1024, .refresh = 75, .clock_khz = 135000 },
    .{ .w = 1024, .h = 768, .refresh = 75, .clock_khz = 78750 },
    .{ .w = 1024, .h = 768, .refresh = 70, .clock_khz = 75000 },
    .{ .w = 1024, .h = 768, .refresh = 60, .clock_khz = 65000 },
    .{ .w = 1024, .h = 768, .refresh = 43, .clock_khz = 44900, .interlaced = true },
    .{ .w = 832, .h = 624, .refresh = 75, .clock_khz = 57284 },
    .{ .w = 800, .h = 600, .refresh = 75, .clock_khz = 49500 },
    .{ .w = 800, .h = 600, .refresh = 72, .clock_khz = 50000 },
    .{ .w = 1152, .h = 864, .refresh = 75, .clock_khz = 108000 },
};

/// The parsed EDID.
pub const Edid = struct {
    /// The raw base block.
    raw: [EDID_LENGTH]u8 = @splat(0),
    /// The manufacturer's three letter code, upper case.
    manufacturer: [3]u8 = @splat(0),
    /// The manufacturer's own product code.
    product_code: u16 = 0,
    /// The serial number.
    serial_number: u32 = 0,
    /// The week of manufacture (0xff = unspecified).
    week: u8 = 0,
    /// The year of manufacture.
    year: u16 = 0,
    /// The EDID version and revision.
    version: u8 = 0,
    revision: u8 = 0,
    /// The width and height of the screen in centimetres.
    h_size_cm: u8 = 0,
    v_size_cm: u8 = 0,
    /// True when the size fields hold an aspect ratio rather than a size.
    size_is_aspect_ratio: bool = false,
    /// The gamma in hundredths.
    gamma: u16 = 100,
    /// True when the display takes a digital input.
    digital_input: bool = false,
    /// The number of extension blocks the base block announces.
    extension_count: u8 = 0,

    /// The monitor's name, if it has one.
    name_buf: [13]u8 = @splat(0),
    name_len: usize = 0,
    /// The monitor's serial number as a string, if it has one.
    serial_buf: [13]u8 = @splat(0),
    serial_len: usize = 0,

    /// The detailed timings the descriptors hold.
    modes: [8]Mode = @splat(.{}),
    mode_count: usize = 0,

    /// Parse an EDID.
    ///
    /// The block is accepted when the header is right and the checksum
    /// adds up, exactly like Linux's `edid_block_valid()`.
    pub fn parse(data: []const u8) ?Edid {
        if (data.len < EDID_LENGTH) return null;
        if (!isValidHeader(data[0..EDID_LENGTH])) return null;
        if (checksum(data[0..EDID_LENGTH]) != 0) return null;

        var self = Edid{};
        @memcpy(self.raw[0..], data[0..EDID_LENGTH]);

        self.manufacturer = decodeManufacturerId(self.raw[8..10]);
        self.product_code = readU16Le(self.raw[10..12]);
        self.serial_number = readU32Le(self.raw[12..16]);
        self.week = self.raw[16];
        self.year = @as(u16, self.raw[17]) + 1990;
        self.version = self.raw[18];
        self.revision = self.raw[19];
        self.digital_input = (self.raw[20] & 0x80) != 0;
        self.extension_count = self.raw[126];

        // Bytes 21 and 22 are the screen size in centimetres, unless the
        // video input parameters say they hold an aspect ratio.
        self.size_is_aspect_ratio = (self.raw[20] & 0x0E) == 0x0E;
        self.h_size_cm = self.raw[21];
        self.v_size_cm = self.raw[22];
        self.gamma = @as(u16, self.raw[23]) + 100;

        self.parseDescriptors();
        return self;
    }

    /// The four descriptor blocks of the base block.
    fn parseDescriptors(self: *Edid) void {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const base = 54 + i * DESCRIPTOR_LENGTH;
            const block = self.raw[base .. base + DESCRIPTOR_LENGTH];

            // A detailed timing has a pixel clock; everything else is a
            // display descriptor, whose type is in byte 3 and whose text
            // starts in byte 5 (Linux's `struct detailed_non_pixel`).
            if (block[0] == 0 and block[1] == 0 and block[2] == 0) {
                if (block[3] == Detail.monitor_name) {
                    self.setName(block[5..18]);
                } else if (block[3] == Detail.monitor_serial) {
                    self.setSerial(block[5..18]);
                }
                continue;
            }

            const mode = parseDetailedTiming(block);
            if (mode.h_active == 0 or mode.v_active == 0) continue;
            if (self.mode_count >= self.modes.len) break;
            self.modes[self.mode_count] = mode;
            self.mode_count += 1;
        }
    }

    fn setName(self: *Edid, text: []const u8) void {
        const n = textLength(text);
        @memcpy(self.name_buf[0..n], text[0..n]);
        self.name_len = n;
    }

    fn setSerial(self: *Edid, text: []const u8) void {
        const n = textLength(text);
        @memcpy(self.serial_buf[0..n], text[0..n]);
        self.serial_len = n;
    }

    /// The monitor's name.
    pub fn name(self: *const Edid) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// The monitor's serial number, as the string the EDID carries.
    pub fn serialString(self: *const Edid) []const u8 {
        return self.serial_buf[0..self.serial_len];
    }

    /// The preferred mode.
    ///
    /// Linux does not believe the EDID's own "preferred" bit: its
    /// `edid_fixup_preferred()` picks the largest mode and, among the modes
    /// of the same size, the one with the highest refresh rate.  This does
    /// the same.
    pub fn preferredMode(self: *const Edid) ?Mode {
        if (self.mode_count == 0) return null;

        var best: usize = 0;
        var i: usize = 1;
        while (i < self.mode_count) : (i += 1) {
            const candidate = self.modes[i];
            const current = self.modes[best];
            if (candidate.area() > current.area()) {
                best = i;
            } else if (candidate.area() == current.area() and
                candidate.refreshRate() > current.refreshRate())
            {
                best = i;
            }
        }
        return self.modes[best];
    }

    /// The established timings the EDID switches on.
    ///
    /// Byte 35 holds the first eight modes, byte 36 the next seven and
    /// byte 37 the last one, the same layout Linux uses.
    pub fn establishedModes(self: *const Edid, out: []Mode) usize {
        var count: usize = 0;
        const bits = [_]u8{ self.raw[35], self.raw[36], self.raw[37] };
        var byte_index: usize = 0;
        while (byte_index < bits.len) : (byte_index += 1) {
            var bit: u4 = 0;
            while (bit < 8) : (bit += 1) {
                if (bits[byte_index] & (@as(u8, 1) << @intCast(bit)) == 0) continue;
                const index = byte_index * 8 + bit;
                if (index >= ESTABLISHED_MODES.len) break;
                const est = ESTABLISHED_MODES[index];
                if (count >= out.len) return count;

                out[count] = Mode{
                    .clock_khz = est.clock_khz,
                    .h_active = est.w,
                    .v_active = est.h,
                    .h_total = est.w,
                    .v_total = est.h,
                    .interlaced = est.interlaced,
                };
                count += 1;
            }
        }
        return count;
    }
};

/// The length of a descriptor text, up to the terminating newline.
fn textLength(text: []const u8) usize {
    var n: usize = 0;
    while (n < text.len and text[n] != 0x0A) : (n += 1) {}
    return n;
}

/// Is the header of a base block the one the specification demands?
pub fn isValidHeader(data: []const u8) bool {
    if (data.len < EDID_HEADER.len) return false;
    for (EDID_HEADER, 0..) |b, i| {
        if (data[i] != b) return false;
    }
    return true;
}

/// The checksum of a block: the sum of all its bytes must be zero modulo
/// 256.  Linux calls this `edid_block_compute_checksum()`.
pub fn checksum(data: []const u8) u8 {
    var sum: u8 = 0;
    for (data) |b| sum +%= b;
    return sum;
}

/// Decode the manufacturer ID.
///
/// The two bytes hold three letters, five bits each, with the top bit of
/// the first byte always set.  Linux calls this
/// `drm_edid_decode_mfg_id()`.
pub fn decodeManufacturerId(raw: []const u8) [3]u8 {
    var out: [3]u8 = @splat(0);
    if (raw.len < 2) return out;

    const value = (@as(u16, raw[0]) << 8) | raw[1];
    out[0] = letter((value >> 10) & 0x1F);
    out[1] = letter((value >> 5) & 0x1F);
    out[2] = letter(value & 0x1F);
    return out;
}

fn letter(code: u16) u8 {
    // 1 means "A", 2 means "B" and so on.
    if (code == 0) return ' ';
    return @intCast('A' + code - 1);
}

/// Parse one detailed timing descriptor.
///
/// The layout is `struct detailed_pixel_timing` from Linux's
/// `include/drm/drm_edid.h`, and the conversion into a mode follows
/// `drm_edid.c`'s detailed timing parser line for line.
pub fn parseDetailedTiming(block: []const u8) Mode {
    var mode = Mode{};
    if (block.len < DESCRIPTOR_LENGTH) return mode;

    mode.clock_khz = @as(u32, readU16Le(block[0..2])) * 10;

    const hactive = (@as(u16, block[4] & 0xF0) << 4) | block[2];
    const vactive = (@as(u16, block[7] & 0xF0) << 4) | block[5];
    const hblank = (@as(u16, block[4] & 0x0F) << 8) | block[3];
    const vblank = (@as(u16, block[7] & 0x0F) << 8) | block[6];
    const hsync_offset = (@as(u16, block[11] & 0xC0) << 2) | block[8];
    const hsync_pulse = (@as(u16, block[11] & 0x30) << 4) | block[9];
    const vsync_offset = (@as(u16, block[11] & 0x0C) << 2) | (block[10] >> 4);
    const vsync_pulse = (@as(u16, block[11] & 0x03) << 4) | (block[10] & 0x0F);

    // Linux ignores the tiny modes.
    if (hactive < 64 or vactive < 64) return mode;

    mode.h_active = hactive;
    mode.h_sync_start = hactive + hsync_offset;
    mode.h_sync_end = mode.h_sync_start + hsync_pulse;
    mode.h_total = hactive + hblank;

    mode.v_active = vactive;
    mode.v_sync_start = vactive + vsync_offset;
    mode.v_sync_end = mode.v_sync_start + vsync_pulse;
    mode.v_total = vactive + vblank;

    // Some EDIDs have bogus sync end values.
    if (mode.h_sync_end > mode.h_total) mode.h_sync_end = mode.h_total;
    if (mode.v_sync_end > mode.v_total) mode.v_sync_end = mode.v_total;

    mode.h_size_mm = (@as(u16, block[14] & 0xF0) << 4) | block[12];
    mode.v_size_mm = (@as(u16, block[14] & 0x0F) << 8) | block[13];

    const misc = block[17];
    mode.interlaced = (misc & Pt.interlaced) != 0;
    mode.separate_sync = (misc & Pt.separate_sync) == Pt.separate_sync;

    return mode;
}

fn readU16Le(data: []const u8) u16 {
    if (data.len < 2) return 0;
    return @as(u16, data[0]) | (@as(u16, data[1]) << 8);
}

fn readU32Le(data: []const u8) u32 {
    if (data.len < 4) return 0;
    return @as(u32, data[0]) | (@as(u32, data[1]) << 8) |
        (@as(u32, data[2]) << 16) | (@as(u32, data[3]) << 24);
}
