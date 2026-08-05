const root = @import("root");
const vga = root.vga;
const port_io = @import("../arch/port.zig");
const isr_mod = @import("../arch/isr.zig");

const KB_DATA: u16 = 0x60;
const KB_STATUS: u16 = 0x64;

const RING_SIZE: usize = 64;
var scancode_ring: [RING_SIZE]u8 = undefined;
var ring_head: usize = 0;
var ring_tail: usize = 0;

pub fn init() void {
    while ((port_io.inb(KB_STATUS) & 2) != 0) {}
    port_io.outb(0x64, 0xAE);
    while ((port_io.inb(KB_STATUS) & 2) != 0) {}
    port_io.outb(0x64, 0xA8);

    while ((port_io.inb(KB_STATUS) & 2) != 0) {}
    port_io.outb(0x64, 0xAA);
    while ((port_io.inb(KB_STATUS) & 1) == 0) {}
    _ = port_io.inb(KB_DATA);

    port_io.outb(0x64, 0x60);
    while ((port_io.inb(KB_STATUS) & 2) != 0) {}
    port_io.outb(KB_DATA, 0x47);

    isr_mod.registerIrq(1, irqHandler);
}

fn irqHandler(_: *isr_mod.InterruptFrame) void {
    const scancode = port_io.inb(KB_DATA);
    const next = (ring_head + 1) % RING_SIZE;
    if (next != ring_tail) {
        scancode_ring[ring_head] = scancode;
        ring_head = next;
    }
}

fn readScancode() ?u8 {
    if (ring_head == ring_tail) return null;
    const sc = scancode_ring[ring_tail];
    ring_tail = (ring_tail + 1) % RING_SIZE;
    return sc;
}

pub fn pollKey() ?u8 {
    while (true) {
        const sc = readScancode() orelse return null;
        if (sc & 0x80 != 0) continue;
        return scancodeToAscii(sc);
    }
}

pub fn readLine(buf: []u8, max_len: usize) usize {
    var pos: usize = 0;
    while (pos < max_len) {
        if (pollKey()) |ch| {
            if (ch == '\n' or ch == '\r') {
                vga.putChar('\n');
                return pos;
            } else if (ch == 0x08) {
                if (pos > 0) {
                    pos -= 1;
                    vga.putChar(0x08);
                    vga.putChar(' ');
                    vga.putChar(0x08);
                }
            } else if (ch >= 0x20) {
                buf[pos] = ch;
                pos += 1;
                vga.putChar(ch);
            }
        } else {
            asm volatile ("hlt");
        }
    }
    return pos;
}

fn scancodeToAscii(sc: u8) u8 {
    return switch (sc) {
        0x02 => '1', 0x03 => '2', 0x04 => '3', 0x05 => '4',
        0x06 => '5', 0x07 => '6', 0x08 => '7', 0x09 => '8',
        0x0A => '9', 0x0B => '0',
        0x0C => '-', 0x0D => '=', 0x0E => 0x08,
        0x0F => '\t', 0x10 => 'q', 0x11 => 'w', 0x12 => 'e',
        0x13 => 'r', 0x14 => 't', 0x15 => 'y', 0x16 => 'u',
        0x17 => 'i', 0x18 => 'o', 0x19 => 'p',
        0x1A => '[', 0x1B => ']', 0x1C => '\n',
        0x1E => 'a', 0x1F => 's', 0x20 => 'd', 0x21 => 'f',
        0x22 => 'g', 0x23 => 'h', 0x24 => 'j', 0x25 => 'k',
        0x26 => 'l', 0x27 => ';', 0x28 => '\'', 0x29 => '`',
        0x2B => '\\', 0x2C => 'z', 0x2D => 'x', 0x2E => 'c',
        0x2F => 'v', 0x30 => 'b', 0x31 => 'n', 0x32 => 'm',
        0x33 => ',', 0x34 => '.', 0x35 => '/',
        0x39 => ' ',
        else => 0,
    };
}
