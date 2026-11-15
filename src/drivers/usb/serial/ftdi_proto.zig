//! The FTDI chip protocol: the vendor requests, the baud rate divisors and
//! the status bits.
//!
//! Ported from the Linux kernel's `drivers/usb/serial/ftdi_sio.h` and the
//! divisor functions in `ftdi_sio.c`.
//!
//! This file is free of kernel dependencies: it is the protocol, not the
//! transport, so `tools/test_ftdi.zig` can import it and check it on the
//! host.

/// The FTDI vendor ID.
pub const VENDOR_ID: u16 = 0x0403;

/// The product IDs of the chips this driver knows.
pub const ProductId = struct {
    pub const ft232r: u16 = 0x6001;
    pub const ft2232h: u16 = 0x6010;
    pub const ft4232h: u16 = 0x6011;
    pub const ft232h: u16 = 0x6014;
    pub const ft_x: u16 = 0x6015;
};

/// The chip families, from Linux's `enum ftdi_chip_type`.
pub const ChipType = enum {
    /// The oldest 232, with a 3 MHz clock and an 8 bit divisor.
    ft232a,
    /// The 232 with a 48 MHz clock and a 16 bit divisor.
    ft232b,
    /// The 2232C.
    ft2232c,
    /// The 232R, the most common one.
    ft232r,
    /// The high speed 2232H and 4232H, with a 120 MHz clock and a
    /// fractional divisor.
    ft2232h,
    ft4232h,
    ft232h,
    /// The FT-X series.
    ft_x,
};

/// The chip of a product ID.
pub fn chipFor(product_id: u16) ?ChipType {
    return switch (product_id) {
        ProductId.ft232r => .ft232r,
        ProductId.ft2232h => .ft2232h,
        ProductId.ft4232h => .ft4232h,
        ProductId.ft232h => .ft232h,
        ProductId.ft_x => .ft_x,
        else => null,
    };
}

/// The vendor requests.
pub const Request = struct {
    pub const reset: u8 = 0;
    pub const modem_ctrl: u8 = 1;
    pub const flow_ctrl: u8 = 2;
    pub const set_baudrate: u8 = 3;
    pub const set_data: u8 = 4;
    pub const get_modem_status: u8 = 5;
    pub const set_latency_timer: u8 = 9;
};

/// The request types: a vendor request, host to device (0x40) and device to
/// host (0xc0).
pub const REQ_TYPE_OUT: u8 = 0x40;
pub const REQ_TYPE_IN: u8 = 0xC0;

/// The values of the reset request.
pub const Reset = struct {
    pub const sio: u16 = 0;
    pub const purge_rx: u16 = 1;
    pub const purge_tx: u16 = 2;
};

/// The modem status bits, from `ftdi_sio.h`.
pub const ModemStatus = struct {
    pub const cts: u8 = 0x10;
    pub const dsr: u8 = 0x20;
    pub const ri: u8 = 0x40;
    pub const rlsd: u8 = 0x80;
};

/// The line status bits, from `ftdi_sio.h`.
pub const LineStatus = struct {
    pub const overrun: u8 = 0x02;
    pub const parity: u8 = 0x04;
    pub const framing: u8 = 0x08;
    /// The break condition.  `break` is a keyword, so the name differs.
    pub const break_condition: u8 = 0x10;
};

/// The bits of the modem control request.
pub const ModemCtrl = struct {
    pub const dtr: u8 = 0x01;
    pub const rts: u8 = 0x02;
};

/// The data format bits, from `ftdi_sio.h`.
pub const DataBits = struct {
    pub const stop_bits_1: u8 = 0x00;
    pub const stop_bits_2: u8 = 0x02;
    pub const parity_none: u8 = 0x00;
    pub const parity_mark: u8 = 0x10;
    pub const parity_space: u8 = 0x20;
    pub const parity_even: u8 = 0x30;
    pub const parity_odd: u8 = 0x40;
};

/// The baud rate divisor for the 232A and 232B families.
///
/// This is Linux's `ftdi_232am_baud_base_to_divisor()`: the divisor is
/// shifted three bits to the left and the fraction is coded into the top
/// bits.
pub fn divisor232am(baud: u32) u32 {
    const base: u32 = 48000000;
    var divisor3: u32 = (base + baud) / (2 * baud);
    if ((divisor3 & 0x7) == 7) divisor3 += 1;
    var value: u32 = divisor3 >> 3;
    const fraction = divisor3 & 0x7;
    if (fraction == 1) {
        value |= 0xC000;
    } else if (fraction >= 4) {
        value |= 0x4000;
    } else if (fraction != 0) {
        value |= 0x8000;
    } else if (value == 1) {
        value = 0;
    }
    return value;
}

/// The baud rate divisor for the high speed chips.
///
/// This is Linux's `ftdi_2232h_baud_base_to_divisor()`: the high speed
/// chips sample ten times instead of sixteen, and the fraction has its own
/// table.
pub fn divisor2232h(baud: u32) u32 {
    const base: u32 = 120000000;
    const divfrac = [_]u8{ 0, 3, 2, 4, 1, 5, 6, 7 };
    const divisor3: u32 = (8 * base + 5 * baud) / (10 * baud);
    var value: u32 = divisor3 >> 3;
    value |= @as(u32, divfrac[divisor3 & 0x7]) << 14;
    if (value == 1) {
        value = 0;
    } else if (value == 0x4001) {
        value = 1;
    }
    // This bit turns off the divide by 2.5, which reaches 12 Mbaud but
    // cannot go below 1200 baud.
    value |= 0x00020000;
    return value;
}
