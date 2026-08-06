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

var shift_pressed: bool = false;
var caps_lock: bool = false;

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
    port_io.outb(KB_DATA, 0x45);

    isr_mod.registerIrq(1, irqHandler);
}

fn irqHandler(_: *isr_mod.InterruptFrame) void {
    // Drain all pending keyboard bytes. Status bit 5 = 1 means mouse data.
    while (true) {
        const status = port_io.inb(KB_STATUS);
        if ((status & 0x01) == 0) break; // output buffer empty
        if ((status & 0x20) != 0) break; // mouse data (bit 5 = 1), skip

        const scancode = port_io.inb(KB_DATA);
        const next = (ring_head + 1) % RING_SIZE;
        if (next != ring_tail) {
            scancode_ring[ring_head] = scancode;
            ring_head = next;
        }
    }
}

fn readScancode() ?u8 {
    if (ring_head == ring_tail) return null;
    const sc = scancode_ring[ring_tail];
    ring_tail = (ring_tail + 1) % RING_SIZE;
    return sc;
}

pub fn flush() void {
    ring_head = 0;
    ring_tail = 0;
}

var e0_prefix: bool = false;

pub const KEY_UP: u8 = 0x80;
pub const KEY_DOWN: u8 = 0x81;
pub const KEY_LEFT: u8 = 0x82;
pub const KEY_RIGHT: u8 = 0x83;
pub const KEY_TAB: u8 = 0x84;
pub const KEY_PAGE_UP: u8 = 0x85;
pub const KEY_PAGE_DOWN: u8 = 0x86;

pub fn pollKey() ?u8 {
    while (true) {
        const sc = readScancode() orelse return null;

        if (sc == 0xE0) {
            e0_prefix = true;
            continue;
        }

        if (e0_prefix) {
            e0_prefix = false;
            if (sc & 0x80 != 0) {
                handleKeyRelease(sc & 0x7F);
                continue;
            }
            return switch (sc) {
                0x48 => KEY_UP,
                0x50 => KEY_DOWN,
                0x4B => KEY_LEFT,
                0x4D => KEY_RIGHT,
                0x09 => KEY_TAB,
                0x49 => KEY_PAGE_UP,
                0x51 => KEY_PAGE_DOWN,
                else => 0,
            };
        }

        if (sc & 0x80 != 0) {
            handleKeyRelease(sc & 0x7F);
            continue;
        }
        return scancodeToAscii(sc);
    }
}

fn handleKeyRelease(sc: u8) void {
    if (sc == 0x2A or sc == 0x36) {
        shift_pressed = false;
    }
}

fn scancodeToAscii(sc: u8) u8 {
    if (sc == 0x2A or sc == 0x36) {
        shift_pressed = true;
        return 0;
    }
    if (sc == 0x3A) {
        caps_lock = !caps_lock;
        return 0;
    }

    var base: u8 = 0;
    switch (sc) {
        0x02 => base = '1',
        0x03 => base = '2',
        0x04 => base = '3',
        0x05 => base = '4',
        0x06 => base = '5',
        0x07 => base = '6',
        0x08 => base = '7',
        0x09 => base = '8',
        0x0A => base = '9',
        0x0B => base = '0',
        0x0C => base = '-',
        0x0D => base = '=',
        0x0E => base = 0x08,
        0x0F => base = '\t',
        0x10 => base = 'q',
        0x11 => base = 'w',
        0x12 => base = 'e',
        0x13 => base = 'r',
        0x14 => base = 't',
        0x15 => base = 'y',
        0x16 => base = 'u',
        0x17 => base = 'i',
        0x18 => base = 'o',
        0x19 => base = 'p',
        0x1A => base = '[',
        0x1B => base = ']',
        0x1C => base = '\n',
        0x1E => base = 'a',
        0x1F => base = 's',
        0x20 => base = 'd',
        0x21 => base = 'f',
        0x22 => base = 'g',
        0x23 => base = 'h',
        0x24 => base = 'j',
        0x25 => base = 'k',
        0x26 => base = 'l',
        0x27 => base = ';',
        0x28 => base = '\'',
        0x29 => base = '`',
        0x2B => base = '\\',
        0x2C => base = 'z',
        0x2D => base = 'x',
        0x2E => base = 'c',
        0x2F => base = 'v',
        0x30 => base = 'b',
        0x31 => base = 'n',
        0x32 => base = 'm',
        0x33 => base = ',',
        0x34 => base = '.',
        0x35 => base = '/',
        0x39 => base = ' ',
        else => return 0,
    }

    const is_letter = (base >= 'a' and base <= 'z');
    if (is_letter) {
        if (shift_pressed != caps_lock) {
            return base - 32;
        }
        return base;
    }

    if (shift_pressed) {
        return shiftToAscii(base);
    }
    return base;
}

fn shiftToAscii(ch: u8) u8 {
    return switch (ch) {
        '1' => '!', '2' => '@', '3' => '#', '4' => '$',
        '5' => '%', '6' => '^', '7' => '&', '8' => '*',
        '9' => '(', '0' => ')',
        '-' => '_', '=' => '+',
        '[' => '{', ']' => '}',
        '\\' => '|',
        ';' => ':', '\'' => '"',
        '`' => '~',
        ',' => '<', '.' => '>', '/' => '?',
        else => ch,
    };
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
