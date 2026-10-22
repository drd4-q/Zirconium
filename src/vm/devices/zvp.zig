//! The ZVP - the Zirconium Virtual Platform.
//!
//! This is the hypervisor's own device: the one piece of hardware every
//! guest is guaranteed to find, and the channel through which a guest talks
//! to the hypervisor that is running it.
//!
//! It is a PCI function with two memory-mapped BARs:
//!
//!   BAR0  the register block - commands, results and events.
//!   BAR1  a shared window - bulk data in both directions.
//!
//! The command protocol is deliberately simple, because it has to be usable
//! by a guest kernel that has just started and knows nothing about the host:
//!
//!   1. The guest writes its arguments into ARG0..ARG3.
//!   2. The guest writes the command number into CMD.
//!   3. The host notices, runs the command, writes the results into
//!      RESULT0/RESULT1, sets STATUS, and clears CMD.
//!   4. The guest polls STATUS until it is no longer "busy", then reads the
//!      results.
//!
//! The identity of the device is *per machine*: the vendor and device IDs
//! come from the machine's identity, so the guest's driver binds to an
//! ordinary vendor's driver and two guests never see the same device.

const std = @import("std");
const root = @import("root");
const pmm = root.pmm;
const serial = root.serial;
const identity_mod = @import("../identity.zig");
const proto = @import("../proto.zig");
const mmu_mod = @import("../mmu.zig");

pub const Identity = identity_mod.Identity;

// Everything about the register block, the commands and the status codes
// lives in `proto.zig`, which the guest driver includes as well: the two
// sides of the interface cannot drift apart.

pub const MAGIC = proto.MAGIC;
pub const VERSION = proto.VERSION;
pub const REGS_SIZE = proto.REGS_SIZE;
pub const WINDOW_SIZE = proto.WINDOW_SIZE;

pub const CMD_PING = proto.CMD_PING;
pub const CMD_IDENTITY = proto.CMD_IDENTITY;
pub const CMD_SET_ACCENT = proto.CMD_SET_ACCENT;
pub const CMD_POST = proto.CMD_POST;
pub const CMD_CLOCK = proto.CMD_CLOCK;
pub const CMD_OBSERVE = proto.CMD_OBSERVE;
pub const CMD_MACHINE = proto.CMD_MACHINE;
pub const MAX_CMD = proto.MAX_CMD;
pub const CMD_TRANSLATE = proto.CMD_TRANSLATE;
pub const CMD_READ_MEM = proto.CMD_READ_MEM;
pub const CMD_WRITE_MEM = proto.CMD_WRITE_MEM;

pub const STATUS_IDLE = proto.STATUS_IDLE;
pub const STATUS_BUSY = proto.STATUS_BUSY;
pub const STATUS_DONE = proto.STATUS_DONE;
pub const STATUS_ERROR = proto.STATUS_ERROR;

pub const EVENT_CLOCK_SYNC = proto.EVENT_CLOCK_SYNC;
pub const EVENT_RESET = proto.EVENT_RESET;

pub const Memory = mmu_mod.Memory;

const REG_MAGIC = proto.REG_MAGIC;
const REG_VERSION = proto.REG_VERSION;
const REG_CAPS = proto.REG_CAPS;
const REG_MAX_CMD = proto.REG_MAX_CMD;
const REG_CMD = proto.REG_CMD;
const REG_STATUS = proto.REG_STATUS;
const REG_ARG0 = proto.REG_ARG0;
const REG_ARG1 = proto.REG_ARG1;
const REG_ARG2 = proto.REG_ARG2;
const REG_RESULT0 = proto.REG_RESULT0;
const REG_RESULT1 = proto.REG_RESULT1;
const REG_EVENT = proto.REG_EVENT;
const REG_EVENT_ACK = proto.REG_EVENT_ACK;
const REG_HOST_CLOCK = proto.REG_HOST_CLOCK;
const REG_WINDOW_PHYS = proto.REG_WINDOW_PHYS;
const REG_WINDOW_SIZE = proto.REG_WINDOW_SIZE;
const REG_MACHINE_INDEX = proto.REG_MACHINE_INDEX;
const REG_PCI_VENDOR = proto.REG_PCI_VENDOR;
const REG_PCI_DEVICE = proto.REG_PCI_DEVICE;
const REG_RAM_BASE = proto.REG_RAM_BASE;
const REG_RAM_SIZE = proto.REG_RAM_SIZE;
const REG_DOORBELL = proto.REG_DOORBELL;
const REG_SERVICED = proto.REG_SERVICED;

// ─── The device ─────────────────────────────────────────────────────

pub const Zvp = struct {
    /// The machine this device belongs to.
    machine_index: u32 = 0,
    /// The identity the device presents.
    identity: Identity = .{},
    /// The guest's memory: its RAM and its page tables.  The device owns it
    /// because the device is the guest's window onto the machine.
    memory: Memory = .{},
    /// The PCI configuration space, as the guest's PCI model would serve it.
    config_space: [256]u8 = [_]u8{0} ** 256,
    /// The register block.
    regs: []u8 = &[_]u8{},
    /// The shared window.
    window: []u8 = &[_]u8{},
    /// Physical address of the register block.
    regs_phys: u64 = 0,
    /// Physical address of the shared window.
    window_phys: u64 = 0,
    /// The accent colour the host uses for this machine.
    accent: u32 = 0x40C0FF,
    /// The observation bits the guest reported.
    observations: u64 = 0,
    /// The last message the guest posted.
    last_message: [128]u8 = [_]u8{0} ** 128,
    last_message_len: usize = 0,
    /// How many commands have been executed.
    commands_served: u64 = 0,
    /// Set when a message is waiting to be written to the serial log.
    has_pending_log: bool = false,
    /// The doorbell sequence the hypervisor has already serviced.
    serviced_sequence: u32 = 0,

    /// Create the device for a machine.
    pub fn init(machine_index: u32, ident: Identity) !Zvp {
        const regs_phys = pmm.allocPages(REGS_SIZE / 4096) orelse return error.OutOfMemory;
        const window_phys = pmm.allocPages(WINDOW_SIZE / 4096) orelse {
            pmm.freePages(regs_phys, REGS_SIZE / 4096);
            return error.OutOfMemory;
        };

        var self: Zvp = .{
            .machine_index = machine_index,
            .identity = ident,
            .regs_phys = regs_phys,
            .window_phys = window_phys,
        };
        self.regs = @as([*]u8, @ptrFromInt(regs_phys))[0..REGS_SIZE];
        self.window = @as([*]u8, @ptrFromInt(window_phys))[0..WINDOW_SIZE];
        @memset(self.regs, 0);
        @memset(self.window, 0);
        self.buildConfigSpace();
        self.reset();
        return self;
    }

    pub fn deinit(self: *Zvp) void {
        if (self.regs_phys != 0) {
            pmm.freePages(self.regs_phys, REGS_SIZE / 4096);
            self.regs_phys = 0;
        }
        if (self.window_phys != 0) {
            pmm.freePages(self.window_phys, WINDOW_SIZE / 4096);
            self.window_phys = 0;
        }
    }

    /// Tell the device where the guest's RAM is.
    ///
    /// The RAM is allocated after the device exists - the partitioner decides
    /// how much each machine gets - so the registers that describe it have to
    /// be updated when it is.
    pub fn setMemory(self: *Zvp, mem: Memory) void {
        self.memory = mem;
        self.putReg(REG_RAM_BASE, @truncate(mem.ram_base));
        self.putReg(REG_RAM_SIZE, @truncate(mem.ram_bytes));
    }

    /// The protocol version the device speaks.
    pub fn version(self: *const Zvp) u32 {
        _ = self;
        return VERSION;
    }

    /// Put the registers into their reset state.
    pub fn reset(self: *Zvp) void {
        @memset(self.regs, 0);
        self.putReg(REG_MAGIC, MAGIC);
        self.putReg(REG_VERSION, VERSION);
        self.putReg(REG_CAPS, 0x0000_0007); // identity, accent, post
        self.putReg(REG_MAX_CMD, MAX_CMD);
        self.putReg(REG_STATUS, STATUS_IDLE);
        self.putReg(REG_WINDOW_PHYS, @truncate(self.window_phys));
        self.putReg(REG_WINDOW_SIZE, WINDOW_SIZE);
        self.putReg(REG_MACHINE_INDEX, self.machine_index);
        self.putReg(REG_PCI_VENDOR, self.identity.vendor_id);
        self.putReg(REG_PCI_DEVICE, self.identity.device_id);
        self.putReg(REG_RAM_BASE, @truncate(self.memory.ram_base));
        self.putReg(REG_RAM_SIZE, @truncate(self.memory.ram_bytes));
        self.putReg(REG_SERVICED, 0);
        self.serviced_sequence = 0;
        serial.serialWrite("[ZVM]   ZVP regs at 0x");
        serial.serialWriteHex(@intCast(@intFromPtr(self.regs.ptr)));
        serial.serialWrite(" magic=0x");
        serial.serialWriteHex(self.getReg(REG_MAGIC));
        serial.serialWrite(" version=0x");
        serial.serialWriteHex(self.getReg(REG_VERSION));
        serial.serialWrite("\n");
    }

    /// Build the PCI configuration space the guest will read.
    ///
    /// The device is a PCI function at bus 0, slot 0x1E - the slot a real
    /// chipset device would occupy.  The vendor and device IDs are the
    /// machine's own, so the guest sees a device from a vendor it has a
    /// driver for.
    fn buildConfigSpace(self: *Zvp) void {
        const cs = &self.config_space;
        @memset(cs, 0);

        // Vendor and device ID.
        putLe16(cs, 0x00, self.identity.vendor_id);
        putLe16(cs, 0x02, self.identity.device_id);
        // Command and status: memory space enabled, bus master.
        putLe16(cs, 0x04, 0x0006);
        putLe16(cs, 0x06, 0x0000);
        // Revision and class code: an OHCI USB controller with a companion.
        cs[0x08] = 0x01;
        cs[0x09] = @truncate(self.identity.class_code >> 16);
        cs[0x0A] = @truncate(self.identity.class_code >> 8);
        cs[0x0B] = @truncate(self.identity.class_code);
        // Header type 0 (normal device).
        cs[0x0E] = 0x00;
        // BAR0: a 64-bit memory BAR in the low 64 GB.
        putLe32(cs, 0x10, @as(u32, @truncate(self.regs_phys)) | 0x04);
        putLe32(cs, 0x14, @as(u32, @truncate(self.regs_phys >> 32)));
        // BAR2: the shared window, also 64-bit.
        putLe32(cs, 0x18, @as(u32, @truncate(self.window_phys)) | 0x04);
        putLe32(cs, 0x1C, @as(u32, @truncate(self.window_phys >> 32)));
        // Subsystem vendor and device.
        putLe16(cs, 0x2C, self.identity.subsystem_vendor);
        putLe16(cs, 0x2E, self.identity.subsystem_device);
        // Capabilities pointer: none.  A device with no capabilities is
        // ordinary; one that points at a vendor-specific structure is a
        // question a guest driver would ask.
        cs[0x34] = 0x00;
        // Interrupt line and pin: no interrupt.  The device is polled.
        cs[0x3C] = 0x00;
        cs[0x3D] = 0x00;
    }

    // ─── Register access ───────────────────────────────────────────

    fn putReg(self: *Zvp, offset: usize, value: u32) void {
        if (offset + 4 > self.regs.len) return;
        self.regs[offset + 0] = @truncate(value);
        self.regs[offset + 1] = @truncate(value >> 8);
        self.regs[offset + 2] = @truncate(value >> 16);
        self.regs[offset + 3] = @truncate(value >> 24);
    }

    fn getReg(self: *const Zvp, offset: usize) u32 {
        if (offset + 4 > self.regs.len) return 0;
        return @as(u32, self.regs[offset]) |
            (@as(u32, self.regs[offset + 1]) << 8) |
            (@as(u32, self.regs[offset + 2]) << 16) |
            (@as(u32, self.regs[offset + 3]) << 24);
    }

    /// Read a register, as the guest's MMIO read would.
    pub fn readReg(self: *const Zvp, offset: usize) u32 {
        switch (offset) {
            REG_HOST_CLOCK => {
                // The host's clock, which the guest can use to synchronise.
                const t = @import("../../drivers/timer.zig").tickCount();
                return @truncate(t);
            },
            REG_EVENT => return self.getReg(REG_EVENT),
            else => return self.getReg(offset),
        }
    }

    /// Write a register, as the guest's MMIO write would.
    pub fn writeReg(self: *Zvp, offset: usize, value: u32) void {
        switch (offset) {
            REG_CMD => {
                // The guest asked for a command.  Leave it in CMD; the host
                // services it and clears it.
                self.putReg(REG_CMD, value);
                self.putReg(REG_STATUS, STATUS_BUSY);
                return;
            },
            REG_EVENT_ACK => {
                self.putReg(REG_EVENT, self.getReg(REG_EVENT) & ~value);
                return;
            },
            else => {},
        }
        self.putReg(offset, value);
    }

    /// Service a pending command.
    ///
    /// Called from the hypervisor's device poll.  A guest that has written
    /// CMD gets its command run here, and the results are waiting in
    /// RESULT0/RESULT1 when the host next services it.
    ///
    /// This runs from the tick handler, so it must not block: no serial
    /// output, no waiting.  A command that wants to talk to the operator
    /// leaves the message behind and `flushLog()` writes it out later, from
    /// the deferred path.
    pub fn service(self: *Zvp) void {
        // Only act on a *new* doorbell.  A command that arrives while the
        // previous one is still being serviced is refused rather than
        // interleaved with it.
        const doorbell = self.getReg(REG_DOORBELL);
        if (doorbell == self.serviced_sequence) return;
        self.serviced_sequence = doorbell;

        const cmd = self.getReg(REG_CMD);
        if (cmd == 0) {
            self.putReg(REG_SERVICED, doorbell);
            return;
        }
        if (cmd > MAX_CMD) {
            self.putReg(REG_RESULT0, 0xFFFF_FFFF);
            self.putReg(REG_RESULT1, 0);
            self.putReg(REG_STATUS, STATUS_ERROR);
            self.putReg(REG_SERVICED, doorbell);
            self.commands_served += 1;
            return;
        }

        const arg0 = self.getReg(REG_ARG0);
        const arg1 = self.getReg(REG_ARG1);
        const arg2 = self.getReg(REG_ARG2);

        var result0: u32 = 0;
        var result1: u32 = 0;
        var status: u32 = STATUS_DONE;

        switch (cmd) {
            CMD_PING => {
                result0 = 0x50494E47; // "PING"
                result1 = @truncate(self.commands_served);
            },
            CMD_IDENTITY => {
                // The identity blob goes into the shared window, and the
                // result says how much of it is valid.
                const n = self.identity.writeBlob(self.window);
                result0 = @intCast(n);
                result1 = self.identity.vendor_id;
            },
            CMD_SET_ACCENT => {
                self.accent = arg0;
                result0 = self.accent;
            },
            CMD_POST => {
                // A message from the guest, in the shared window.  It is
                // copied out and logged later: the tick handler must not
                // write to a serial port.
                const offset = @min(@as(usize, arg0), self.window.len);
                var len: usize = 0;
                while (offset + len < self.window.len and len < self.last_message.len) : (len += 1) {
                    const c = self.window[offset + len];
                    if (c == 0) break;
                    self.last_message[len] = c;
                }
                self.last_message_len = len;
                self.has_pending_log = true;
                result0 = @intCast(len);
                result1 = 0;
            },
            CMD_CLOCK => {
                result0 = @truncate(@import("../../drivers/timer.zig").tickCount());
                result1 = 0;
            },
            CMD_OBSERVE => {
                // The guest reports what it found while probing: a bit in
                // ARG0 and a value in ARG1.  The hypervisor uses this to
                // choose the machine it should have shown the guest.
                if (arg0 < 64) {
                    if (arg1 != 0) {
                        self.observations |= @as(u64, 1) << @intCast(arg0);
                    } else {
                        self.observations &= ~(@as(u64, 1) << @intCast(arg0));
                    }
                }
                result0 = @truncate(self.observations);
            },
            CMD_MACHINE => {
                result0 = self.machine_index;
                result1 = self.identity.device_id;
            },
            CMD_TRANSLATE => {
                // Translate a guest virtual address through the guest's own
                // page tables.  ARG0 is the address, ARG1 is the guest's CR3
                // (a guest physical address).
                var mem = self.memory;
                mem.cr3_gpa = arg1;
                if (mem.translate(arg0)) |host_pa| {
                    result0 = @truncate(host_pa);
                    result1 = 0;
                } else |err| {
                    result0 = 0xFFFF_FFFF;
                    result1 = mmu_mod.translateErrorCode(err);
                }
            },
            CMD_READ_MEM => {
                // Read a word out of the guest's RAM.  ARG0 is the guest
                // physical address.  The result registers are 32 bits wide,
                // so the value comes back in two of them: RESULT0 is the
                // low half and RESULT1 the high half.
                if (self.memory.readWord(arg0)) |value| {
                    result0 = @truncate(value);
                    result1 = @truncate(value >> 32);
                } else {
                    result0 = 0xFFFF_FFFF;
                    result1 = 0xFFFF_FFFF;
                }
            },
            CMD_WRITE_MEM => {
                // Write a word into the guest's RAM.  ARG0 is the guest
                // physical address, and the value is 64 bits wide, so it
                // comes in two argument registers.
                const value = @as(u64, arg1) | (@as(u64, arg2) << 32);
                if (self.memory.writeWord(arg0, value)) {
                    result0 = 0;
                    result1 = 0;
                } else {
                    result0 = 0xFFFF_FFFF;
                    result1 = 1;
                }
            },
            else => {
                result0 = 0;
                status = STATUS_ERROR;
            },
        }

        self.putReg(REG_RESULT0, result0);
        self.putReg(REG_RESULT1, result1);
        self.putReg(REG_STATUS, status);
        self.putReg(REG_SERVICED, doorbell);
        self.commands_served += 1;
    }

    /// Write out a message the guest posted.
    ///
    /// Called from the deferred path, never from the tick handler: writing
    /// to a serial port can block on a full transmit FIFO, and a blocked tick
    /// handler stops the tick that would have released it.
    pub fn flushLog(self: *Zvp) void {
        if (!self.has_pending_log) return;
        self.has_pending_log = false;
        serial.serialWrite("[ZVP] Guest posted ");
        serial.serialWriteDec(self.last_message_len);
        serial.serialWrite(" bytes: ");
        serial.serialWrite(self.last_message[0..self.last_message_len]);
        serial.serialWrite("\n");
    }

    /// Post an event to the guest.
    pub fn postEvent(self: *Zvp, event: u32) void {
        self.putReg(REG_EVENT, self.getReg(REG_EVENT) | event);
    }
};

fn putLe16(buf: []u8, at: usize, value: u16) void {
    buf[at + 0] = @truncate(value);
    buf[at + 1] = @truncate(value >> 8);
}

fn putLe32(buf: []u8, at: usize, value: u32) void {
    buf[at + 0] = @truncate(value);
    buf[at + 1] = @truncate(value >> 8);
    buf[at + 2] = @truncate(value >> 16);
    buf[at + 3] = @truncate(value >> 24);
}
