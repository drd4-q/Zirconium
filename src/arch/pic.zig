const port_io = @import("port.zig");

const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

const PIC_EOI: u8 = 0x20;

const ICW1_ICW4: u8 = 0x01;
const ICW1_SINGLE: u8 = 0x02;
const ICW1_INTERVAL4: u8 = 0x04;
const ICW1_LEVEL: u8 = 0x08;
const ICW1_INIT: u8 = 0x10;

const ICW4_8086: u8 = 0x01;
const ICW4_AUTO: u8 = 0x02;
const ICW4_BUF_SLAVE: u8 = 0x08;
const ICW4_BUF_MASTER: u8 = 0x0C;
const ICW4_SFNM: u8 = 0x10;

pub fn init() void {
    port_io.outb(PIC1_DATA, 0xFF);
    port_io.outb(PIC2_DATA, 0xFF);

    port_io.outb(PIC1_CMD, ICW1_INIT | ICW1_ICW4);
    port_io.ioWait();
    port_io.outb(PIC2_CMD, ICW1_INIT | ICW1_ICW4);
    port_io.ioWait();

    port_io.outb(PIC1_DATA, 0x20);
    port_io.ioWait();
    port_io.outb(PIC2_DATA, 0x28);
    port_io.ioWait();

    port_io.outb(PIC1_DATA, 1 << 2);
    port_io.ioWait();
    port_io.outb(PIC2_DATA, 2);
    port_io.ioWait();

    port_io.outb(PIC1_DATA, ICW4_8086);
    port_io.ioWait();
    port_io.outb(PIC2_DATA, ICW4_8086);
    port_io.ioWait();

    port_io.outb(PIC1_DATA, 0xFF);
    port_io.outb(PIC2_DATA, 0xFF);
}

pub fn maskAll() void {
    port_io.outb(PIC1_DATA, 0xFF);
    port_io.outb(PIC2_DATA, 0xFF);
}

pub fn unmaskAll() void {
    port_io.outb(PIC1_DATA, 0x00);
    port_io.outb(PIC2_DATA, 0x00);
}

pub fn unmask(irq: u8) void {
    if (irq < 8) {
        port_io.outb(PIC1_DATA, port_io.inb(PIC1_DATA) & ~(@as(u8, 1) << @as(u3, @intCast(irq))));
    } else if (irq < 16) {
        port_io.outb(PIC2_DATA, port_io.inb(PIC2_DATA) & ~(@as(u8, 1) << @as(u3, @intCast(irq - 8))));
    }
}

pub fn mask(irq: u8) void {
    if (irq < 8) {
        port_io.outb(PIC1_DATA, port_io.inb(PIC1_DATA) | (@as(u8, 1) << @as(u3, @intCast(irq))));
    } else if (irq < 16) {
        port_io.outb(PIC2_DATA, port_io.inb(PIC2_DATA) | (@as(u8, 1) << @as(u3, @intCast(irq - 8))));
    }
}

pub fn sendEoi(irq: u8) void {
    if (irq >= 8) {
        port_io.outb(PIC2_CMD, PIC_EOI);
    }
    port_io.outb(PIC1_CMD, PIC_EOI);
}
