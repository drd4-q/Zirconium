//! The legacy VGA text mode, programmed by hand.
//!
//! Ported from the Linux kernel's `arch/ppc/boot/vreset.c` ("Initialize VGA
//! control registers to 80x25 text mode"), with the register names from
//! `include/linux/vga.h` and the way the console uses the text buffer from
//! `arch/x86/kernel/video/vgacon.c`.
//!
//! This is the *software rendering* fallback.  The kernel paints the
//! characters into the text buffer at 0xB8000 itself - no adapter, no
//! framebuffer, no firmware help - so a machine that has no usable graphics
//! mode still shows a console.  The catch is that something has to scan that
//! buffer out: a machine whose display is driven by a discrete GPU has no
//! legacy VGA at all, and then the text buffer is not displayed either.  The
//! serial log is the console there.
//!
//! The register values are the ones Linux uses; they were obtained from real
//! hardware ("These values were obtained by booting Linux with text mode
//! firmware & then dumping the registers").
//!
//! One adapter cannot be driven this way: QEMU's Bochs VGA keeps the
//! graphics mode while its VBE extensions are enabled, because the VBE code
//! rewrites the graphics controller's miscellaneous register after every
//! write to it.  The legacy text mode is therefore not reachable there once
//! the firmware has switched to a VBE mode - which is QEMU's property, not
//! the machine's.  The registers are read back and logged, so the log says
//! what the adapter made of the programming.

const port_io = @import("../../arch/port.zig");
const serial = @import("../../system/serial.zig");

// ─── The register file ──────────────────────────────────────────────

/// The attribute controller: the index goes here, the data comes back from
/// the port below it.
const ATTR_INDEX: u16 = 0x3C0;
/// The sequencer, the graphics controller and the CRTC: an index port and
/// the data port right above it.
const SEQ_INDEX: u16 = 0x3C4;
const GCR_INDEX: u16 = 0x3CE;
const CRTC_INDEX: u16 = 0x3D4;
/// The data port of the indexed registers: right above the index port.
const GCR_DATA: u16 = 0x3CF;
/// The miscellaneous output register.  Its bit 0 decides whether the CRTC
/// is at 0x3B4 (monochrome) or at 0x3D4 (colour), so it is written first.
const MISC_OUTPUT: u16 = 0x3C2;
/// The DAC's write mask: which bits of a colour count.
const DAC_MASK: u16 = 0x3C6;
/// The input status register.  Reading it resets the flip-flop that decides
/// whether the next write to the attribute controller's index port is an
/// index or a value.
const INPUT_STATUS_1: u16 = 0x3DA;

/// The text buffer: 80x25 cells of a character and an attribute.
const TEXT_BUFFER: usize = 0xB8000;
const TEXT_COLS: usize = 80;
const TEXT_ROWS: usize = 25;

/// One register of the VGA: the port, the index and the value.
const Reg = struct { port: u16, index: u8, value: u8 };

/// The register set of the 80x25 text mode.
///
/// The order matters: the sequencer comes first (it resets the controller),
/// then the CRTC's timings, then the graphics controller's memory map.
const text_mode_regs = [_]Reg{
    // Sequencer
    .{ .port = SEQ_INDEX, .index = 0x01, .value = 0x00 }, // clocking mode
    .{ .port = SEQ_INDEX, .index = 0x02, .value = 0x03 }, // font map
    .{ .port = SEQ_INDEX, .index = 0x03, .value = 0x00 }, // character select
    .{ .port = SEQ_INDEX, .index = 0x04, .value = 0x02 }, // memory mode: 80x25 text

    // CRTC: the horizontal timings
    .{ .port = CRTC_INDEX, .index = 0x00, .value = 0x5F }, // horizontal total
    .{ .port = CRTC_INDEX, .index = 0x01, .value = 0x4F }, // horizontal display end
    .{ .port = CRTC_INDEX, .index = 0x02, .value = 0x50 }, // horizontal blank start
    .{ .port = CRTC_INDEX, .index = 0x03, .value = 0x82 }, // horizontal blank end
    .{ .port = CRTC_INDEX, .index = 0x04, .value = 0x55 }, // horizontal retrace start
    .{ .port = CRTC_INDEX, .index = 0x05, .value = 0x81 }, // horizontal retrace end
    // the vertical timings
    .{ .port = CRTC_INDEX, .index = 0x06, .value = 0xBF }, // vertical total
    .{ .port = CRTC_INDEX, .index = 0x07, .value = 0x1F }, // overflow
    .{ .port = CRTC_INDEX, .index = 0x08, .value = 0x00 }, // preset row scan
    .{ .port = CRTC_INDEX, .index = 0x09, .value = 0x4F }, // maximum scan line
    .{ .port = CRTC_INDEX, .index = 0x0A, .value = 0x0D }, // cursor start
    .{ .port = CRTC_INDEX, .index = 0x0B, .value = 0x0E }, // cursor end
    .{ .port = CRTC_INDEX, .index = 0x0C, .value = 0x00 },
    .{ .port = CRTC_INDEX, .index = 0x0D, .value = 0x00 },
    .{ .port = CRTC_INDEX, .index = 0x0E, .value = 0x00 }, // cursor location high
    .{ .port = CRTC_INDEX, .index = 0x0F, .value = 0x00 }, // cursor location low
    .{ .port = CRTC_INDEX, .index = 0x10, .value = 0x9C }, // vertical retrace start
    .{ .port = CRTC_INDEX, .index = 0x11, .value = 0x8E }, // vertical retrace end
    .{ .port = CRTC_INDEX, .index = 0x12, .value = 0x8F }, // vertical display end
    .{ .port = CRTC_INDEX, .index = 0x13, .value = 0x28 }, // logical width
    .{ .port = CRTC_INDEX, .index = 0x14, .value = 0x1F }, // underline location
    .{ .port = CRTC_INDEX, .index = 0x15, .value = 0x96 }, // vertical blank start
    .{ .port = CRTC_INDEX, .index = 0x16, .value = 0xB9 }, // vertical blank end
    .{ .port = CRTC_INDEX, .index = 0x17, .value = 0xA3 }, // mode control

    // Graphics controller
    .{ .port = GCR_INDEX, .index = 0x00, .value = 0x00 }, // set reset
    .{ .port = GCR_INDEX, .index = 0x01, .value = 0x00 }, // set data
    .{ .port = GCR_INDEX, .index = 0x02, .value = 0x00 }, // set mask
    .{ .port = GCR_INDEX, .index = 0x03, .value = 0x00 }, // data rotate
    .{ .port = GCR_INDEX, .index = 0x04, .value = 0x00 }, // read plane select
    .{ .port = GCR_INDEX, .index = 0x05, .value = 0x10 }, // mode register
    .{ .port = GCR_INDEX, .index = 0x06, .value = 0x0E }, // miscellaneous: the memory map
    .{ .port = GCR_INDEX, .index = 0x07, .value = 0x00 }, // miscellaneous
    .{ .port = GCR_INDEX, .index = 0x08, .value = 0xFF }, // bit mask
};

/// The sixteen palette registers of the attribute controller.
///
/// These are the standard VGA text colours: the low two bits are the
/// foreground intensity, the next two the background, and the top three the
/// colour itself.
const attr_palette = [16]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07,
    0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
};

// ─── Programming ────────────────────────────────────────────────────

fn outb(p: u16, v: u8) void {
    port_io.outb(p, v);
}

fn inb(p: u16) u8 {
    return port_io.inb(p);
}

/// Write one attribute controller register.
///
/// The attribute controller shares its index port with the data port: the
/// index is written first, and the flip-flop that decides which of the two
/// the next write goes to is reset by reading the input status register.
/// Bit 5 of the index turns the display on.
fn writeAttr(index: u8, value: u8, video_on: bool) void {
    _ = inb(INPUT_STATUS_1);
    const idx = (index & 0x1F) | (if (video_on) @as(u8, 0x20) else @as(u8, 0x00));
    outb(ATTR_INDEX, idx);
    outb(ATTR_INDEX, value);
}

/// True when a legacy VGA answers on the register ports.
///
/// The graphics controller's miscellaneous register decides how the legacy
/// VGA window is decoded, and its bits 3:4 are the memory map.  It reads as
/// all ones when there is no legacy VGA at all - which is the case on a
/// machine whose only display is a discrete GPU.
pub fn present() bool {
    outb(GCR_INDEX, 0x07);
    return inb(GCR_DATA) != 0xFF;
}

/// True when the adapter is already in the text mode.
fn alreadyTextMode() bool {
    outb(GCR_INDEX, 0x06);
    // The graphics controller's miscellaneous register: bit 0 clear means the
    // memory map is the text one.
    return (inb(GCR_DATA) & 0x01) == 0;
}

/// Program the 80x25 text mode.
///
/// Returns false when there is no legacy VGA to program - in which case
/// nothing is written anywhere, and the caller has to say so.
pub fn initTextMode() bool {
    if (!present()) {
        serial.serialWrite("[VGA] no legacy VGA: nothing can scan the text buffer out\n");
        return false;
    }

    const was_text = alreadyTextMode();

    // The miscellaneous output register first: its bit 0 selects the colour
    // CRTC ports (0x3D4), which the table below uses.
    outb(MISC_OUTPUT, 0x67);

    // Turn the video off while the registers are programmed: the sequencer's
    // register 1, bit 5.
    outb(SEQ_INDEX, 0x01);
    outb(SEQ_INDEX + 1, 0x20);

    for (text_mode_regs) |reg| {
        outb(reg.port, reg.index);
        outb(reg.port + 1, reg.value);
    }

    // Every bit of a colour counts.
    outb(DAC_MASK, 0xFF);

    // The attribute controller: the sixteen palette registers, then the mode
    // registers.  The last write turns the display on again.
    for (attr_palette, 0..) |value, i| {
        writeAttr(@intCast(i), value, false);
    }
    writeAttr(0x10, 0x0C, false); // mode control: text mode
    writeAttr(0x11, 0x00, false); // overscan: the border colour
    writeAttr(0x12, 0x0F, false); // the colour planes are enabled
    writeAttr(0x13, 0x08, false); // pixel panning
    writeAttr(0x14, 0x00, true); // colour select - and the display on

    // The video is on again.
    outb(SEQ_INDEX, 0x01);
    outb(SEQ_INDEX + 1, 0x00);

    // The buffer still holds whatever the firmware left there.
    clearTextBuffer();

    serial.serialWrite("[VGA] the legacy VGA is programmed for 80x25 text mode");
    if (was_text) {
        serial.serialWrite(" (it was in text mode already)");
    }
    serial.serialWrite("\n");
    logRegisters();
    return true;
}

/// Read the registers back and write them to the log.
///
/// The adapter is the only witness of what the programming did: a machine
/// that shows nothing after this has either no adapter at all or one that
/// ignores what it is told.
///
/// One adapter does ignore it: QEMU's Bochs VGA keeps the graphics mode
/// while its VBE extensions are enabled - the VBE code rewrites the
/// graphics controller's miscellaneous register after every write to it -
/// so the legacy text mode cannot be shown there once the firmware has
/// switched to a VBE mode.  That is a property of that adapter, not of the
/// machine: a real VGA has no such coupling.
fn logRegisters() void {
    // The sequencer's memory mode (register 4): 2 is the 80x25 text mode.
    outb(SEQ_INDEX, 0x04);
    const sr4 = inb(SEQ_INDEX + 1);

    // The graphics controller's miscellaneous register (register 6): bit 0
    // clear means the text buffer is the one that is displayed.
    outb(GCR_INDEX, 0x06);
    const gr6 = inb(GCR_DATA);

    // The attribute controller's index: bit 5 is the display enable.
    const ar_index = inb(ATTR_INDEX);

    serial.serialWrite("[VGA] registers: SR4=0x");
    writeHex8(sr4);
    serial.serialWrite(" GCR6=0x");
    writeHex8(gr6);
    serial.serialWrite(" AR=0x");
    writeHex8(ar_index);
    serial.serialWrite("\n");
}

/// One byte in hex.
fn writeHex8(v: u8) void {
    const hex = "0123456789ABCDEF";
    serial.serialWrite(&[_]u8{ hex[v >> 4], hex[v & 0xF] });
}

/// Clear the text buffer.
fn clearTextBuffer() void {
    const cells: [*]volatile u16 = @ptrFromInt(TEXT_BUFFER);
    var i: usize = 0;
    while (i < TEXT_COLS * TEXT_ROWS) : (i += 1) {
        cells[i] = 0x0720; // a space, light grey on black
    }
}
