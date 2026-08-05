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
};

pub var devices: [32]PciDevice = undefined;
pub var device_count: usize = 0;

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

fn readConfig(bus: u8, dev: u8, func: u8, reg: u8) u32 {
    const addr: u32 = 0x80000000 |
        (@as(u32, bus) << 16) |
        (@as(u32, dev) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, reg & 0xFC));
    outl(CONFIG_ADDR, addr);
    return inl(CONFIG_DATA);
}

fn writeConfig(bus: u8, dev: u8, func: u8, reg: u8, val: u32) void {
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
    writeConfig(bus, dev, func, reg, 0xFFFFFFFF);
    const val = readConfig(bus, dev, func, reg);
    writeConfig(bus, dev, func, reg, 0);
    return val;
}

pub fn scan() void {
    device_count = 0;
    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        var dev: u8 = 0;
        while (dev < 32) : (dev += 1) {
            const v0 = readConfig(@intCast(bus), dev, 0, 0);
            const vid = @as(u16, @intCast(v0 & 0xFFFF));
            if (vid == 0xFFFF) continue;

            const v2 = readConfig(@intCast(bus), dev, 0, 0x08);
            const cls = @as(u8, @intCast((v2 >> 24) & 0xFF));
            const sub = @as(u8, @intCast((v2 >> 16) & 0xFF));
            const pi = @as(u8, @intCast((v2 >> 8) & 0xFF));

            const v10 = readConfig(@intCast(bus), dev, 0, 0x10);
            const v14 = readConfig(@intCast(bus), dev, 0, 0x14);
            const v3C = readConfig(@intCast(bus), dev, 0, 0x3C);

            if (device_count < devices.len) {
                devices[device_count] = PciDevice{
                    .bus = @intCast(bus),
                    .dev = dev,
                    .func = 0,
                    .vendor_id = vid,
                    .device_id = @intCast((v0 >> 16) & 0xFFFF),
                    .class = cls,
                    .subclass = sub,
                    .prog_if = pi,
                    .bar0 = v10,
                    .bar1 = v14,
                    .irq = @intCast(v3C & 0xFF),
                };
                device_count += 1;
            }
        }
    }
}

pub fn enableBusMaster(bus: u8, dev: u8, func: u8) void {
    const v08 = readConfig(bus, dev, func, 0x04);
    writeConfig(bus, dev, func, 0x04, v08 | (1 << 2) | 1);
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
