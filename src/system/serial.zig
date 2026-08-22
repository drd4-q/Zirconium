const COM1: u16 = 0x3F8;

fn outb(port_addr: u16, val: u8) void {
    asm volatile ("outb %%al, %%dx"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port_addr),
    );
}

fn inb(port_addr: u16) u8 {
    return asm volatile ("inb %%dx, %%al"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port_addr),
    );
}

pub fn init() void {
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x80);
    outb(COM1 + 0, 0x03);
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03);
    outb(COM1 + 2, 0xC7);
    outb(COM1 + 4, 0x0B);
}

fn isTransmitEmpty() bool {
    return (inb(COM1 + 5) & 0x20) != 0;
}

/// Poll the receive side of COM1: returns one byte when data is ready.
/// Used by the shell and console stdin so the kernel can be driven over a
/// headless serial link (QEMU -serial stdio).
pub fn pollRead() ?u8 {
    if ((inb(COM1 + 5) & 0x01) == 0) return null;
    return inb(COM1);
}

fn writeChar(ch: u8) void {
    while (!isTransmitEmpty()) {}
    outb(COM1, ch);
}

pub fn serialWrite(str: []const u8) void {
    for (str) |ch| {
        writeChar(ch);
    }
}

pub fn serialWriteHex(value: u64) void {
    const hex = "0123456789ABCDEF";
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        writeChar(hex[(value >> @intCast(i * 4)) & 0xF]);
    }
}

pub fn serialWriteHexShort(value: u64) void {
    const hex = "0123456789ABCDEF";
    var started = false;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        const nibble: u8 = @intCast((value >> @intCast(i * 4)) & 0xF);
        if (nibble != 0 or started or i == 0) {
            started = true;
            writeChar(hex[nibble]);
        }
    }
}

pub fn serialWriteDec(value: u64) void {
    if (value == 0) {
        writeChar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var v = value;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    while (i < 20) : (i += 1) {
        writeChar(buf[i]);
    }
}
