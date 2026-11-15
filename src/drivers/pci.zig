const root = @import("root");
const vga = root.vga;
const port = root.serial;

const CONFIG_ADDR: u16 = 0xCF8;
const CONFIG_DATA: u16 = 0xCFC;

pub const PciDevice = struct {
    bus: u8,
    dev: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    class: u8,
    subclass: u8,
    prog_if: u8,
    bar0: u32,
    bar1: u32,
    irq: u8,

    /// The base address registers, all six of them, with their raw value.
    ///
    /// The first two are also in `bar0`/`bar1` because the older code used
    /// those names; a display device needs more than two (the MMIO BAR, the
    /// framebuffer BAR and sometimes a third one).
    bars: [6]u32 = @splat(0),
    /// True when the device has a memory space master bit that is set.
    memory_space: bool = false,
    /// True when the device can do bus mastering.
    bus_master: bool = false,

    /// The base address of a BAR, with the 64 bit halves joined.
    ///
    /// Returns null when the BAR is not a memory BAR or when its address is
    /// above the identity map the kernel built (64 GB).
    pub fn barAddress(self: *const PciDevice, index: usize) ?u64 {
        if (index >= self.bars.len) return null;
        const raw = self.bars[index];
        if (raw == 0) return null;
        // Bit 0 clear means memory; bit 1 clear means 32 bit.
        if (raw & 1 != 0) return null;
        const low = raw & 0xFFFF_FFF0;

        // A 64 bit BAR keeps its high half in the next register.
        if (raw & 0x6 == 0x4) {
            if (index + 1 >= self.bars.len) return null;
            const high = self.bars[index + 1];
            const addr = @as(u64, high) << 32 | @as(u64, low);
            if (addr == 0 or addr >= MAX_IDENTITY_MAP) return null;
            return addr;
        }

        if (low == 0) return null;
        return low;
    }

    /// True when the BAR is a prefetchable memory BAR.
    pub fn barPrefetchable(self: *const PciDevice, index: usize) bool {
        if (index >= self.bars.len) return false;
        const raw = self.bars[index];
        if (raw == 0 or raw & 1 != 0) return false;
        // Bits 3:2 of a 32 bit memory BAR: 01 means prefetchable.
        if (raw & 0x6 == 0x4) return true;
        return (raw & 0xC) == 0x4;
    }
};

/// The identity map covers the low 64 GB, so a BAR above it is not
/// reachable without a mapping the kernel does not build.
const MAX_IDENTITY_MAP: u64 = 64 * 1024 * 1024 * 1024;

pub var devices: [512]PciDevice = undefined;
pub var device_count: usize = 0;
pub var scan_complete: bool = false;

fn outb(p: u16, v: u8) void {
    asm volatile ("outb %%al, %%dx" : : [val] "{al}" (v), [port] "{dx}" (p));
}

fn outl(p: u16, v: u32) void {
    asm volatile ("outl %%eax, %%dx" : : [val] "{eax}" (v), [port] "{dx}" (p));
}

fn inb(p: u16) u8 {
    return asm volatile ("inb %%dx, %%al" : [result] "={al}" (-> u8), : [port] "{dx}" (p));
}

fn inl(p: u16) u32 {
    return asm volatile ("inl %%dx, %%eax" : [result] "={eax}" (-> u32), : [port] "{dx}" (p));
}

pub fn readConfig(bus: u8, dev: u8, func: u8, reg: u8) u32 {
    const addr: u32 = 0x80000000 |
        (@as(u32, bus) << 16) |
        (@as(u32, dev) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, reg & 0xFC));
    outl(CONFIG_ADDR, addr);
    return inl(CONFIG_DATA);
}

pub fn writeConfig(bus: u8, dev: u8, func: u8, reg: u8, val: u32) void {
    const addr: u32 = 0x80000000 |
        (@as(u32, bus) << 16) |
        (@as(u32, dev) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, reg & 0xFC));
    outl(CONFIG_ADDR, addr);
    outl(CONFIG_DATA, val);
}

pub fn readBar(bus: u8, dev: u8, func: u8, bar_num: u8) u32 {
    const reg: u8 = 0x10 + bar_num * 4;
    return readConfig(bus, dev, func, reg);
}

pub fn getBarSize(bus: u8, dev: u8, func: u8, bar_num: u8) u32 {
    const reg: u8 = 0x10 + bar_num * 4;
    const orig = readConfig(bus, dev, func, reg);
    writeConfig(bus, dev, func, reg, 0xFFFFFFFF);
    const mask = readConfig(bus, dev, func, reg);
    writeConfig(bus, dev, func, reg, orig);
    if (mask == 0 or mask == 0xFFFFFFFF) return 0;
    // Low nibble holds the type/attribute bits, not size: masking it off before
    // inverting is what makes the 64-bit (type 10b) case return a size at all.
    // The old per-type masks left bits 3:1 in place for type 10b, so ~mask
    // produced 0x10 for every 64-bit BAR.
    const size_mask = mask & ~@as(u32, 0xF);
    if (size_mask == 0) return 0;
    return ~size_mask +% 1;
}

pub fn scan() void {
    // The current kernel has no PCI hotplug path.  Re-walking all 256 buses
    // from main, shell, and AHCI only adds hundreds of unnecessary config
    // transactions on real hardware.
    if (scan_complete) return;
    device_count = 0;
    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        var dev: u8 = 0;
        while (dev < 32) : (dev += 1) {
            var func: u8 = 0;
            while (func < 8) : (func += 1) {
                const v0 = readConfig(@intCast(bus), dev, func, 0);
                const vid = @as(u16, @intCast(v0 & 0xFFFF));
                if (vid == 0xFFFF) {
                    if (func == 0) break;
                    continue;
                }

                const v2 = readConfig(@intCast(bus), dev, func, 0x08);
                const cls = @as(u8, @intCast((v2 >> 24) & 0xFF));
                const sub = @as(u8, @intCast((v2 >> 16) & 0xFF));
                const pi = @as(u8, @intCast((v2 >> 8) & 0xFF));

                const v3 = readConfig(@intCast(bus), dev, func, 0x0C);
                const header_type = @as(u8, @intCast((v3 >> 16) & 0xFF));

                const v10 = readConfig(@intCast(bus), dev, func, 0x10);
                const v14 = readConfig(@intCast(bus), dev, func, 0x14);
                const v3C = readConfig(@intCast(bus), dev, func, 0x3C);
                const v04 = readConfig(@intCast(bus), dev, func, 0x04);

                // All six base address registers: a display device needs
                // more than the two the old code kept.
                var bars: [6]u32 = @splat(0);
                var bar_index: usize = 0;
                while (bar_index < bars.len) : (bar_index += 1) {
                    bars[bar_index] = readConfig(@intCast(bus), dev, func, @intCast(0x10 + bar_index * 4));
                }

                if (device_count < devices.len) {
                    devices[device_count] = PciDevice{
                        .bus = @intCast(bus),
                        .dev = dev,
                        .func = func,
                        .vendor_id = vid,
                        .device_id = @as(u16, @truncate(v0 >> 16)),
                        .class = cls,
                        .subclass = sub,
                        .prog_if = pi,
                        .bar0 = v10,
                        .bar1 = v14,
                        .irq = @as(u8, @truncate(v3C & 0xFF)),
                        .bars = bars,
                        .memory_space = (v04 & 0x2) != 0,
                        .bus_master = (v04 & 0x4) != 0,
                    };
                    device_count += 1;
                }

                // If func 0 is not a multi-function device, don't probe functions 1-7
                if (func == 0 and (header_type & 0x80) == 0) {
                    break;
                }
            }
        }
    }
    scan_complete = true;
}

pub fn enableBusMaster(bus: u8, dev: u8, func: u8) void {
    const v08 = readConfig(bus, dev, func, 0x04);
    writeConfig(bus, dev, func, 0x04, v08 | (1 << 2) | (1 << 1) | 1);
}

pub fn findDevice(vendor: u16, dev_id: u16) ?*PciDevice {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        if (devices[i].vendor_id == vendor and devices[i].device_id == dev_id) {
            return &devices[i];
        }
    }
    return null;
}

pub fn findByClass(cls: u8, sub: u8) ?*PciDevice {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        if (devices[i].class == cls and devices[i].subclass == sub) {
            return &devices[i];
        }
    }
    return null;
}

pub fn printDevices() void {
    vga.setColor(.cyan, .black);
    vga.write("\n  PCI Devices:\n\n");
    vga.setColor(.white, .black);

    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        const d = &devices[i];
        vga.write("  [");
        writeHex8(d.bus);
        vga.putChar(':');
        writeHex8(d.dev);
        vga.write("] ");
        writeHex16(d.vendor_id);
        vga.putChar(':');
        writeHex16(d.device_id);
        vga.write(" class=");
        writeHex8(d.class);
        vga.putChar('.');
        writeHex8(d.subclass);
        vga.write(" IRQ=");
        vga.writeDec(d.irq);
        vga.write("\n");
    }
}

fn writeHex8(v: u8) void {
    const h = "0123456789ABCDEF";
    vga.putChar(h[v >> 4]);
    vga.putChar(h[v & 0xF]);
}

fn writeHex16(v: u16) void {
    writeHex8(@intCast(v >> 8));
    writeHex8(@intCast(v & 0xFF));
}
