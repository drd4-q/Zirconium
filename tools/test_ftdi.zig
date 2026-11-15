//! Host-side test of the FTDI driver's arithmetic.
//!
//! The driver lives in `src/drivers/usb/serial/ftdi.zig`; only the parts
//! that do not need a USB device are imported here, so the test checks the
//! real code.
//!
//! Run it with:
//!
//!     zig run --dep ftdi -Mroot=tools/test_ftdi.zig \
//!         -Mftdi=src/drivers/usb/serial/ftdi_proto.zig
//!
//! The divisors are the values FTDI's own documentation gives: 0x4138 for
//! 9600 baud on an FT232 and 0x001A for 115200 baud.

const std = @import("std");

const ftdi = @import("ftdi");

var failures: u32 = 0;
var checks: u32 = 0;

fn checkEq(got: anytype, want: anytype, what: []const u8) void {
    checks += 1;
    if (got == want) return;
    failures += 1;
    std.debug.print("  FAIL: {s}: got 0x{x}, want 0x{x}\n", .{ what, got, want });
}

fn check(ok: bool, what: []const u8) void {
    checks += 1;
    if (ok) return;
    failures += 1;
    std.debug.print("  FAIL: {s}\n", .{what});
}

fn testBaudDivisors() void {
    std.debug.print("test: the baud rate divisors\n", .{});

    // The FT232: the divisors FTDI documents.  The first two are the
    // values from the FTDI application note; the other two come from the
    // same formula (48000000 / (2 * baud), the fraction in the top bits).
    checkEq(ftdi.divisor232am(9600), 0x4138, "9600 baud on an FT232");
    checkEq(ftdi.divisor232am(115200), 0x001A, "115200 baud on an FT232");
    checkEq(ftdi.divisor232am(19200), 0x809C, "19200 baud on an FT232");
    checkEq(ftdi.divisor232am(57600), 0xC034, "57600 baud on an FT232");

    // The high speed chips: the same formula over a 120 MHz clock, with
    // the fraction in its own table and the divide by 2.5 turned off.
    checkEq(ftdi.divisor2232h(115200) & 0xFFFF, 0xC068, "115200 baud on an FT2232H");
    checkEq(ftdi.divisor2232h(9600) & 0xFFFF, 0x04E2, "9600 baud on an FT2232H");
    checkEq(ftdi.divisor2232h(115200) & 0x20000, 0x20000, "the divide by 2.5 is off");
}

fn testChipDetection() void {
    std.debug.print("test: the chip of a product ID\n", .{});

    check(ftdi.chipFor(0x6001) == .ft232r, "0x6001 is an FT232R");
    check(ftdi.chipFor(0x6010) == .ft2232h, "0x6010 is an FT2232H");
    check(ftdi.chipFor(0x6011) == .ft4232h, "0x6011 is an FT4232H");
    check(ftdi.chipFor(0x6014) == .ft232h, "0x6014 is an FT232H");
    check(ftdi.chipFor(0x6015) == .ft_x, "0x6015 is an FT-X");
    check(ftdi.chipFor(0x1234) == null, "an unknown product is not an FTDI");
}

fn testStatusBits() void {
    std.debug.print("test: the status bits\n", .{});

    // The modem status byte: the clear to send, the data set ready, the
    // ring indicator and the remote line signal detect.
    checkEq(ftdi.ModemStatus.cts, 0x10, "the clear to send bit");
    checkEq(ftdi.ModemStatus.dsr, 0x20, "the data set ready bit");
    checkEq(ftdi.ModemStatus.ri, 0x40, "the ring indicator bit");
    checkEq(ftdi.ModemStatus.rlsd, 0x80, "the carrier detect bit");

    // The line status byte: the error bits.
    checkEq(ftdi.LineStatus.overrun, 0x02, "the overrun bit");
    checkEq(ftdi.LineStatus.parity, 0x04, "the parity error bit");
    checkEq(ftdi.LineStatus.framing, 0x08, "the framing error bit");
}

pub fn main() !void {
    std.debug.print("FTDI driver test\n", .{});
    testBaudDivisors();
    testChipDetection();
    testStatusBits();

    std.debug.print("\n{d} checks, {d} failures\n", .{ checks, failures });
    if (failures != 0) std.process.exit(1);
}
