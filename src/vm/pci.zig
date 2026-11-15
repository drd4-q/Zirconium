//! The PCI bus a guest sees.
//!
//! A guest finds a device the ordinary way: it writes a bus/function/
//! register triple to the configuration address port and reads or writes the
//! configuration space through the data port.  That is the whole protocol,
//! and it is what this module implements.
//!
//! The address register (port 0xCF8) is:
//!
//!     bit 31     the enable bit: without it the data port reads all ones
//!     bits 23-16 the bus number
//!     bits 15-11 the device (slot) number
//!     bits 10-8  the function number within the slot
//!     bits 7-2   the register number, in dwords
//!     bits 1-0   zero
//!
//! The data port (0xCFC) is the register's dword.  Ports 0xCFC..0xCFF are
//! the four byte lanes of it, so a guest that writes a byte to 0xCFF changes
//! the top byte of the register - which is how a driver that only knows how
//! to write bytes still works.
//!
//! **The device is where the guest says it is.**  A memory BAR is a place the
//! guest chooses, and the hypervisor moves the device there: a guest that
//! programs a base address register and then uses it gets the device it
//! programmed, exactly as on real hardware.

const std = @import("std");
const mmu = @import("mmu.zig");

/// The configuration address port.
pub const CONFIG_ADDRESS: u16 = 0xCF8;

/// The configuration data port.  Ports 0xCFC..0xCFF are its byte lanes.
pub const CONFIG_DATA: u16 = 0xCFC;

/// The most functions one bus can have.
pub const MAX_FUNCTIONS: usize = 8;

/// The configuration space of one function.
pub const Function = struct {
    bus: u8 = 0,
    device: u8 = 0,
    function: u8 = 0,
    /// The 256 bytes the guest reads.
    config: [256]u8 = @splat(0),
    /// Where each memory BAR's registers are in the host.
    bar_host: [6]u64 = @splat(0),
    /// How many bytes each memory BAR covers.
    bar_bytes: [6]u64 = @splat(0),
    /// The guest physical address the guest programmed into each BAR.
    bar_gpa: [6]u64 = @splat(0),
    /// What each BAR is: 0 = none, 1 = memory, 2 = I/O.
    bar_kind: [6]u8 = @splat(0),
    /// Which of the guest's device regions each BAR belongs to.
    bar_region: [6]usize = @splat(0),
};

/// The bus.
///
/// It owns the functions and the address register, and it is the only thing
/// that knows how a guest's port I/O reaches the configuration space.
pub const Bus = struct {
    functions: [MAX_FUNCTIONS]Function = @splat(.{ .bus = 0, .device = 0, .function = 0, .config = @splat(0), .bar_host = @splat(0), .bar_bytes = @splat(0), .bar_gpa = @splat(0), .bar_kind = @splat(0), .bar_region = @splat(0) }),
    count: usize = 0,
    /// The address the guest last wrote to the configuration address port.
    address: u32 = 0,
    /// The guest's page tables, so a device can be moved when the guest
    /// programs its base address register.
    tables: ?*mmu.Tables = null,
    /// The guest's memory map, so a device's region can move with it.
    memory: ?*mmu.Memory = null,

    /// Add a function to the bus.
    pub fn add(self: *Bus, bus_no: u8, device: u8, function: u8) ?*Function {
        if (self.count >= MAX_FUNCTIONS) return null;
        const f = &self.functions[self.count];
        f.* = .{ .bus = bus_no, .device = device, .function = function };
        self.count += 1;
        return f;
    }

    /// The function the address register points at, if any.
    fn addressed(self: *Bus) ?*Function {
        if ((self.address & 0x8000_0000) == 0) return null;
        const bus_no: u8 = @truncate((self.address >> 16) & 0xFF);
        const device: u8 = @truncate((self.address >> 11) & 0x1F);
        const function: u8 = @truncate((self.address >> 8) & 0x07);
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const f = &self.functions[i];
            if (f.bus == bus_no and f.device == device and f.function == function) return f;
        }
        return null;
    }

    /// The register number the address register points at.
    fn registerOffset(self: *const Bus) u32 {
        return (self.address & 0xFC) & 0xFF;
    }

    /// Read a dword of configuration space.
    pub fn readData(self: *Bus) u32 {
        const f = self.addressed() orelse return 0xFFFF_FFFF;
        const offset = self.registerOffset();
        return readLe32(&f.config, offset);
    }

    /// Write a dword of configuration space.
    ///
    /// A write to a base address register moves the device: the guest has
    /// said where it wants the device, and the hypervisor puts it there.
    pub fn writeData(self: *Bus, offset: u32, value: u32) void {
        const f = self.addressed() orelse return;
        const reg = offset & 0xFC;

        // Is this one of the base address registers?
        if (reg >= 0x10 and reg < 0x28) {
            const index: usize = @intCast((reg - 0x10) / 4);
            const kind = f.bar_kind[index];
            if (kind == 1) {
                // A memory BAR.  The low four bits say how wide it is; the
                // rest is the address the guest chose.
                const is_64 = (value & 0x06) == 0x06;
                const mask: u32 = if (is_64) 0xFFFF_FFF0 else 0xFFFF_FFF0;
                const address = value & mask;
                if (address != 0) {
                    f.bar_gpa[index] = address;
                    // The high half of a 64-bit BAR is the next register.
                    if (is_64) {
                        f.bar_gpa[index + 1] = 0;
                        f.bar_kind[index + 1] = 0;
                    }
                    // The device moves: the guest has said where it wants it,
                    // and the hypervisor puts it there.
                    self.moveDevice(f, index, address);
                }
                // The configuration space keeps showing the low bits, and the
                // address the guest programmed.
                writeLe32(&f.config, reg, @as(u32, @truncate(f.bar_gpa[index])) | (value & 0x0F));
                return;
            }
        }

        writeLe32(&f.config, reg, value);
    }

    /// Read a byte lane of the configuration data port.
    pub fn portIn(self: *Bus, port: u16) u8 {
        if (port >= CONFIG_ADDRESS and port < CONFIG_ADDRESS + 4) {
            const shift: u5 = @intCast((port - CONFIG_ADDRESS) * 8);
            return @truncate(self.address >> shift);
        }
        if (port < CONFIG_DATA or port > CONFIG_DATA + 3) return 0xFF;
        const lane = port - CONFIG_DATA;
        const value = self.readData();
        return @truncate(value >> @intCast(lane * 8));
    }

    /// Move a device to the address the guest programmed into its BAR.
    ///
    /// The region moves with it, and the guest's page tables gain the
    /// mapping.  The old mapping is left alone: it is a duplicate of the same
    /// registers, and a guest that has not reprogrammed anything never
    /// notices.
    fn moveDevice(self: *Bus, f: *Function, index: usize, gpa: u64) void {
        const region = f.bar_region[index];
        if (self.memory) |memory| {
            _ = memory.moveRegion(region, gpa);
        }
        if (self.tables) |tables| {
            _ = tables.mapDevice(gpa, f.bar_bytes[index]);
        }
    }

    /// Write a byte lane of the configuration data port.
    pub fn portOut(self: *Bus, port: u16, value: u8) void {
        if (port >= CONFIG_ADDRESS and port < CONFIG_ADDRESS + 4) {
            const shift: u5 = @intCast((port - CONFIG_ADDRESS) * 8);
            const mask: u32 = @as(u32, 0xFF) << shift;
            self.address = (self.address & ~mask) | (@as(u32, value) << shift);
            return;
        }
        if (port < CONFIG_DATA or port > CONFIG_DATA + 3) return;
        const lane = port - CONFIG_DATA;
        const shift: u5 = @intCast(lane * 8);
        const mask: u32 = @as(u32, 0xFF) << shift;
        const current = self.readData();
        const updated = (current & ~mask) | (@as(u32, value) << shift);
        self.writeData(self.registerOffset(), updated);
    }
};

fn readLe32(bytes: *const [256]u8, offset: u32) u32 {
    const at: usize = @intCast(offset & 0xFC);
    if (at + 4 > bytes.len) return 0xFFFF_FFFF;
    return @as(u32, bytes[at]) |
        (@as(u32, bytes[at + 1]) << 8) |
        (@as(u32, bytes[at + 2]) << 16) |
        (@as(u32, bytes[at + 3]) << 24);
}

fn writeLe32(bytes: *[256]u8, offset: u32, value: u32) void {
    const at: usize = @intCast(offset & 0xFC);
    if (at + 4 > bytes.len) return;
    bytes[at] = @truncate(value);
    bytes[at + 1] = @truncate(value >> 8);
    bytes[at + 2] = @truncate(value >> 16);
    bytes[at + 3] = @truncate(value >> 24);
}
