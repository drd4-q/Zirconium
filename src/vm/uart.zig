//! A virtual 8250 serial port for a guest.
//!
//! The guest's console is a serial port, exactly as on a real PC: it is the
//! one device every kernel knows how to talk to before anything else is set
//! up.  Giving the guest the *host's* port would work right up to the moment
//! the guest programmed the divisor latch - and then the host's own log would
//! be running at whatever baud rate the guest chose, and the guest's
//! characters would be mixed into the host's output.
//!
//! So the guest gets its own 8250.  What it writes lands in a buffer, and the
//! hypervisor forwards that to the host's log with the guest's name on it.

const std = @import("std");

/// The COM1 port range the guest may use.
pub const COM1: u16 = 0x3F8;

/// The registers, at their offsets from the base.
const THR: u16 = 0; // transmit holding register (write)
const RBR: u16 = 0; // receive buffer register (read)
const IER: u16 = 1; // interrupt enable
const IIR: u16 = 2; // interrupt identification (read)
const FCR: u16 = 2; // FIFO control (write)
const LCR: u16 = 3; // line control
const MCR: u16 = 4; // modem control
const LSR: u16 = 5; // line status
const MSR: u16 = 6; // modem status
const SCR: u16 = 7; // scratch
const DLL: u16 = 0; // divisor latch low (when LCR.DLAB)
const DLM: u16 = 1; // divisor latch high (when LCR.DLAB)

/// The line status: the transmitter is always empty and the holding register
/// is always ready, so a guest that waits for it never spins.
const LSR_IDLE: u8 = 0x60;

pub const Uart = struct {
    ier: u8 = 0,
    iir: u8 = 0x01,
    lcr: u8 = 0x03,
    mcr: u8 = 0,
    msr: u8 = 0xB0,
    scr: u8 = 0,
    dll: u8 = 0x01,
    dlm: u8 = 0x00,
    /// The characters the guest has produced.
    out_buf: [512]u8 = undefined,
    out_len: usize = 0,
    out_pos: usize = 0,

    /// Read one of the guest's registers.
    ///
    /// The divisor latch overlaps offsets 0 and 1 and is selected by the line
    /// control register's DLAB bit - and **only** those two offsets.  The line
    /// control itself is at offset 3 whatever DLAB says, so a guest that sets
    /// DLAB and then clears it can still write the line control; redirecting
    /// every register instead leaves the guest unable to clear DLAB at all,
    /// and every later read of the status register returns nonsense.
    pub fn read(self: *Uart, port: u16) u8 {
        const offset = port - COM1;
        if ((self.lcr & 0x80) != 0 and (offset == DLL or offset == DLM)) {
            return if (offset == DLL) self.dll else self.dlm;
        }
        return switch (offset) {
            RBR => 0, // no input
            IIR => self.iir,
            LCR => self.lcr,
            MCR => self.mcr,
            LSR => LSR_IDLE,
            MSR => self.msr,
            SCR => self.scr,
            else => 0,
        };
    }

    /// Write one of the guest's registers.
    pub fn write(self: *Uart, port: u16, value: u8) void {
        const offset = port - COM1;
        if ((self.lcr & 0x80) != 0 and (offset == DLL or offset == DLM)) {
            // The divisor latch is selected: this is a baud rate setting, not
            // a character.
            if (offset == DLL) self.dll = value else self.dlm = value;
            return;
        }
        switch (offset) {
            THR => {
                if (self.out_len < self.out_buf.len) {
                    self.out_buf[self.out_len] = value;
                    self.out_len += 1;
                }
            },
            IER => self.ier = value,
            FCR => {}, // the FIFO control: nothing to do
            LCR => self.lcr = value,
            MCR => self.mcr = value,
            SCR => self.scr = value,
            else => {},
        }
    }

    /// The characters the guest has produced and the host has not taken yet.
    pub fn pending(self: *const Uart) []const u8 {
        return self.out_buf[self.out_pos..self.out_len];
    }

    /// Take the characters the guest has produced.
    pub fn take(self: *Uart) []const u8 {
        const text = self.out_buf[self.out_pos..self.out_len];
        self.out_pos = self.out_len;
        return text;
    }

    /// True when there is nothing left to hand over.
    pub fn drained(self: *const Uart) bool {
        return self.out_pos >= self.out_len;
    }
};
