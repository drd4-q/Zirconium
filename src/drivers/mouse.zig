const root = @import("root");
const vga = root.vga;
const port_io = @import("../arch/port.zig");
const isr_mod = @import("../arch/isr.zig");

const KB_DATA: u16 = 0x60;
const KB_STATUS: u16 = 0x64;

pub var mx: i32 = 40;
pub var my: i32 = 12;
pub var left_button: bool = false;
pub var right_button: bool = false;
pub var middle_button: bool = false;
pub var dx: i32 = 0;
pub var dy: i32 = 0;

var packet_buf: [3]u8 = undefined;
var packet_pos: u8 = 0;
pub var ready: bool = false;

fn waitInput() void {
    var timeout: u32 = 0;
    while (timeout < 100000) : (timeout += 1) {
        if ((port_io.inb(KB_STATUS) & 0x02) == 0) return;
    }
}

fn waitOutput() void {
    var timeout: u32 = 0;
    while (timeout < 100000) : (timeout += 1) {
        if ((port_io.inb(KB_STATUS) & 0x01) != 0) return;
    }
}

fn readData() u8 {
    waitOutput();
    return port_io.inb(KB_DATA);
}

pub fn init() void {
    asm volatile ("cli");

    // Flush any pending data from port 0x60
    while ((port_io.inb(KB_STATUS) & 0x01) != 0) {
        _ = port_io.inb(KB_DATA);
    }

    // Enable auxiliary device (mouse)
    waitInput();
    port_io.outb(KB_STATUS, 0xA8);

    // Enable auxiliary interrupts via config
    waitInput();
    port_io.outb(KB_STATUS, 0x20); // Read config
    waitOutput();
    const cfg = port_io.inb(KB_DATA);
    waitInput();
    port_io.outb(KB_STATUS, 0x60); // Write config
    waitInput();
    port_io.outb(KB_DATA, cfg | 0x02); // Enable IRQ12

    // Flush again after config change
    while ((port_io.inb(KB_STATUS) & 0x01) != 0) {
        _ = port_io.inb(KB_DATA);
    }

    // Set defaults
    waitInput();
    port_io.outb(KB_STATUS, 0xD4); // Send to mouse
    waitInput();
    port_io.outb(KB_DATA, 0xF6);
    waitOutput();
    _ = port_io.inb(KB_DATA);

    // Enable data reporting
    waitInput();
    port_io.outb(KB_STATUS, 0xD4); // Send to mouse
    waitInput();
    port_io.outb(KB_DATA, 0xF4);
    waitOutput();
    _ = port_io.inb(KB_DATA);

    // Final flush — discard any controller response bytes that keyboard IRQ might have missed
    while ((port_io.inb(KB_STATUS) & 0x01) != 0) {
        _ = port_io.inb(KB_DATA);
    }

    isr_mod.registerIrq(12, irqHandler);
    ready = true;

    // Flush keyboard ring buffer to remove any garbage read during init
    @import("../drivers/keyboard.zig").flush();

    asm volatile ("sti");
    vga.write("[MOUSE] PS/2 mouse initialized\n");
}

fn irqHandler(_: *isr_mod.InterruptFrame) void {
    // Process at most one complete mouse packet (3 bytes) per IRQ.
    // Checking status bit 5 ensures we only read mouse data, not keyboard.
    var count: u8 = 0;
    while (count < 3) : (count += 1) {
        const status = port_io.inb(KB_STATUS);
        if ((status & 0x01) == 0) break;
        if ((status & 0x20) == 0) break;

        const byte = port_io.inb(KB_DATA);

        if (byte & 0x08 == 0) {
            // Byte 0 always has bit 3 set; if not, resync
            packet_pos = 0;
            continue;
        }

        packet_buf[packet_pos] = byte;
        packet_pos += 1;

        if (packet_pos >= 3) {
            packet_pos = 0;

            left_button = (packet_buf[0] & 0x01) != 0;
            right_button = (packet_buf[0] & 0x02) != 0;
            middle_button = (packet_buf[0] & 0x04) != 0;

            dx = @as(i8, @bitCast(packet_buf[1]));
            dy = @as(i8, @bitCast(packet_buf[2]));

            mx += dx;
            my -= dy; // PS/2 Y is inverted

            // Clamp to screen
            if (mx < 0) mx = 0;
            if (mx >= 80) mx = 79;
            if (my < 0) my = 0;
            if (my >= 25) my = 24;
        }
    }
}
