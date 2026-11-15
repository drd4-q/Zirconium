//! The DDC reader: how a display's EDID is fetched over the VGA pins.
//!
//! Ported from the Linux kernel's `drivers/video/mfb.c` and the VGA
//! register definitions in `include/linux/vga.h`: the EDID lives at the
//! I2C address 0x50 and is read over the "display data channel" that the
//! VGA's graphics controller exposes as two bit-banged lines.
//!
//! The DDC is an I2C bus without a controller: the graphics controller's
//! registers hold the clock and the data line, and the software shifts the
//! bits in and out by hand.  That is what this module does.
//!
//! The lines only exist on a display adapter that is wired for them, so
//! every step can fail.  A failure means "this machine has no EDID", not
//! "the kernel is broken": the caller carries on with what it has.

const port_io = @import("../../arch/port.zig");

/// The graphics controller register port: the index goes here, the data
/// comes back from the port below it.
const GCR_INDEX: u16 = 0x3CE;
const GCR_DATA: u16 = 0x3CF;

/// The graphics controller register that enables the DDC lines.
const GCR_MISC: u8 = 0x07;
/// The bit in that register that switches the DDC lines on.
const GCR_MISC_I2C_ENABLE: u8 = 0x04;

/// The graphics controller register that holds the DDC lines.
const GCR_I2C: u8 = 0x08;
/// The DDC clock line.
const GCR_I2C_CLOCK: u8 = 0x01;
/// The DDC data line.
const GCR_I2C_DATA: u8 = 0x02;

/// The seven bit I2C address of the EDID.
const EDID_I2C_ADDRESS: u8 = 0x50;

/// The size of an EDID base block.
const EDID_LENGTH: usize = 128;

fn gcrRead(index: u8) u8 {
    port_io.outb(GCR_INDEX, index);
    return port_io.inb(GCR_DATA);
}

fn gcrWrite(index: u8, value: u8) void {
    port_io.outb(GCR_INDEX, index);
    port_io.outb(GCR_DATA, value);
}

/// Set or clear the DDC lines.
fn setLines(clock: bool, data: bool) void {
    var value = gcrRead(GCR_I2C);
    if (clock) {
        value |= GCR_I2C_CLOCK;
    } else {
        value &= ~GCR_I2C_CLOCK;
    }
    if (data) {
        value |= GCR_I2C_DATA;
    } else {
        value &= ~GCR_I2C_DATA;
    }
    gcrWrite(GCR_I2C, value);
}

/// Read the DDC data line.
fn readData() bool {
    return (gcrRead(GCR_I2C) & GCR_I2C_DATA) != 0;
}

/// The start condition: the data line goes low while the clock is high.
fn start() void {
    setLines(true, true);
    setLines(true, false);
}

/// The stop condition: the data line goes high while the clock is high.
fn stop() void {
    setLines(false, false);
    setLines(true, false);
    setLines(true, true);
}

/// Write one bit.
fn writeBit(bit: bool) void {
    setLines(false, bit);
    setLines(true, bit);
}

/// Read one bit.
fn readBit() bool {
    setLines(false, true);
    const bit = readData();
    setLines(true, true);
    return bit;
}

/// Read the acknowledge bit after a byte was written.
fn readAck() bool {
    // The master releases the data line and the slave pulls it low to say
    // "I got it".
    setLines(false, false);
    const ack = !readData();
    setLines(true, false);
    return ack;
}

/// Write one byte, most significant bit first.
fn writeByte(value: u8) void {
    var i: u4 = 0;
    while (i < 8) : (i += 1) {
        writeBit((value & (@as(u8, 0x80) >> @intCast(i))) != 0);
    }
}

/// Read one byte, most significant bit first.
fn readByte() u8 {
    var value: u8 = 0;
    var i: u4 = 0;
    while (i < 8) : (i += 1) {
        if (readBit()) value |= @as(u8, 0x80) >> @intCast(i);
    }
    return value;
}

/// Read the EDID of the display that is plugged in.
///
/// Returns null when the display does not answer - either because there is
/// none, or because the adapter has no DDC lines.
pub fn readEdid() ?[EDID_LENGTH]u8 {
    // Switch the DDC lines on.
    const misc = gcrRead(GCR_MISC);
    gcrWrite(GCR_MISC, misc | GCR_MISC_I2C_ENABLE);

    start();
    // The EDID answers at 0x50; the byte on the wire is the address with
    // the read bit set.
    writeByte(EDID_I2C_ADDRESS << 1);
    if (!readAck()) {
        stop();
        gcrWrite(GCR_MISC, misc);
        return null;
    }

    var edid: [EDID_LENGTH]u8 = undefined;
    for (&edid) |*byte| {
        byte.* = readByte();
        if (!readAck()) break;
    }
    stop();

    // Leave the registers as they were.
    gcrWrite(GCR_MISC, misc);

    return edid;
}
