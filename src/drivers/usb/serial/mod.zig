//! The USB serial adapters.
//!
//! The FTDI chips are the common ones; the driver is a port of Linux's
//! `drivers/usb/serial/ftdi_sio.c`.

pub const ftdi = @import("ftdi.zig");
