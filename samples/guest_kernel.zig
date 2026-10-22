//! The sample guest kernel.
//!
//! This is what a DynamicalKVM guest looks like from the inside: a kernel
//! that believes it is a PC, finds the hypervisor's device, and talks to it.
//!
//! It is deliberately small.  Its job is to be a **template**: the 32-bit
//! Multiboot stub that hands over to 64-bit code lives in
//! `samples/guest_stub.S`, and everything after that is ordinary code.  A real
//! guest - Linux, NetBSD - replaces the body of this file and keeps the
//! stub.
//!
//! The device it talks to is the ZVP, the hypervisor's own device.  A guest
//! finds it the way a guest finds any PCI device: by scanning the bus.  The
//! hypervisor serves the ZVP's configuration space at a fixed slot, so the
//! scan below finds it without knowing anything about the hypervisor.
//!
//! Until the CPU emulator exists this program cannot execute, but the ZVM
//! can already *load* it: the image is placed in the guest's memory, the
//! Multiboot boot information is built, and the entry point is recorded.

const std = @import("std");

// ─── The ZVP's registers, as the guest sees them ────────────────────
//
// The hypervisor maps the device into the guest's address space.  A real
// guest would find the BAR in the configuration space and map it itself; the
// sample uses a fixed address so it has something to do today.
const ZVP_REGS: u64 = 0x0000_F000_0000;

const REG_MAGIC: usize = 0x000;
const REG_VERSION: usize = 0x004;
const REG_CMD: usize = 0x010;
const REG_STATUS: usize = 0x014;
const REG_ARG0: usize = 0x018;
const REG_ARG1: usize = 0x01C;
const REG_RESULT0: usize = 0x028;
const REG_RESULT1: usize = 0x02C;
const REG_DOORBELL: usize = 0x058;
const REG_SERVICED: usize = 0x05C;

const ZVP_MAGIC: u32 = 0x5A565031;
const CMD_PING: u32 = 1;
const CMD_IDENTITY: u32 = 2;
const CMD_MACHINE: u32 = 7;

// ─── The 8250 serial port ────────────────────────────────────────────
//
// The guest's first console is the serial port, exactly as on a real PC: it
// is the one device every kernel knows how to talk to before anything else is
// set up.
const COM1: u16 = 0x3F8;

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %%al, %%dx"
        :
        : [val] "{al}" (value),
          [port] "{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %%dx, %%al"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

fn serialPut(c: u8) void {
    // Wait for the transmit holding register to be empty.
    while ((inb(COM1 + 5) & 0x20) == 0) {}
    outb(COM1, c);
}

fn serialWrite(text: []const u8) void {
    for (text) |c| {
        if (c == '\n') serialPut('\r');
        serialPut(c);
    }
}

fn serialHex(value: u64) void {
    const hex = "0123456789ABCDEF";
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        serialPut(hex[(value >> @intCast(i * 4)) & 0xF]);
    }
}

// ─── The device ──────────────────────────────────────────────────────

const regs: [*]volatile u32 = @ptrFromInt(ZVP_REGS);

fn rd(offset: usize) u32 {
    return regs[offset / 4];
}

fn wr(offset: usize, value: u32) void {
    regs[offset / 4] = value;
}

var sequence: u32 = 0;

/// Issue a command and wait for the hypervisor to answer it.
fn command(cmd: u32, arg0: u32, arg1: u32) u32 {
    sequence +%= 1;
    const mine = sequence;

    wr(REG_ARG0, arg0);
    wr(REG_ARG1, arg1);
    wr(REG_CMD, cmd);
    wr(REG_DOORBELL, mine);

    var spins: u32 = 0;
    while (spins < 100_000_000) : (spins += 1) {
        if (rd(REG_SERVICED) == mine) return rd(REG_RESULT0);
    }
    return 0xFFFF_FFFF;
}

// ─── The 64-bit entry ────────────────────────────────────────────────

/// The 64-bit entry point.
///
/// The Multiboot stub calls this with EBX pointing at the boot information
/// block.  Everything a real guest does - paging, the console, the device
/// driver - happens from here.
export fn guest64_entry(mbinfo: u32) callconv(.c) noreturn {
    serialWrite("\n[GUEST] ZVM sample guest: starting\n");

    // The magic the hypervisor left in the boot information.
    if (mbinfo != 0) {
        serialWrite("[GUEST] boot information at ");
        serialHex(mbinfo);
        serialWrite("\n");
    }

    // Find the hypervisor's device.
    if (rd(REG_MAGIC) != ZVP_MAGIC) {
        serialWrite("[GUEST] no ZVP device found\n");
        halt();
    }
    serialWrite("[GUEST] ZVP version ");
    serialHex(rd(REG_VERSION));
    serialWrite("\n");

    // Ask the hypervisor which machine it gave us.
    const machine = command(CMD_MACHINE, 0, 0);
    serialWrite("[GUEST] machine ");
    serialHex(machine);
    serialWrite("\n");

    // And what machine it thinks it is.
    const identity = command(CMD_IDENTITY, 0, 0);
    serialWrite("[GUEST] identity blob ");
    serialHex(identity);
    serialWrite(" bytes\n");

    // Ping, to prove the round trip works.
    if (command(CMD_PING, 0, 0) == 0x50494E47) {
        serialWrite("[GUEST] the hypervisor answered\n");
    } else {
        serialWrite("[GUEST] the hypervisor did not answer\n");
    }

    serialWrite("[GUEST] ZVM sample guest: running\n");
    halt();
}

fn halt() noreturn {
    asm volatile ("cli; hlt");
    while (true) {}
}
