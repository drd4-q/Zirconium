const root = @import("root");
const serial = root.serial;
const vga = root.vga;
const port_io = @import("../arch/port.zig");
const isr_mod = @import("../arch/isr.zig");
const fb = @import("../system/framebuffer.zig");

const KB_DATA: u16 = 0x60;
const KB_STATUS: u16 = 0x64;

// Pixel position (used by GUI). Falls back to character-cell coords for the
// text console if the framebuffer is inactive.
pub var mx: i32 = 40;
pub var my: i32 = 12;
pub var left_button: bool = false;
pub var right_button: bool = false;
pub var middle_button: bool = false;
pub var dx: i32 = 0;
pub var dy: i32 = 0;

pub var debug_log: bool = false;
var packet_cnt: u32 = 0;
var last_dbg_buttons: u8 = 0;

// Cursor bound following any pixel movement: clamped to both char-cell grid
// and pixel framebuffer.
fn clampCoords() void {
    if (fb.active) {
        if (mx < 0) mx = 0;
        if (my < 0) my = 0;
        if (mx >= @as(i32, @intCast(fb.fb_width))) mx = @as(i32, @intCast(fb.fb_width)) - 1;
        if (my >= @as(i32, @intCast(fb.fb_height))) my = @as(i32, @intCast(fb.fb_height)) - 1;
    } else {
        if (mx < 0) mx = 0;
        if (mx >= 80) mx = 79;
        if (my < 0) my = 0;
        if (my >= 25) my = 24;
    }
}

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

        // Byte 0 of a 3-byte packet always has bit 3 set. Only resync at a
        // packet boundary: a mid-packet byte (e.g. small delta 0..7) also
        // lacks bit 3 and must never reset the parser, or every packet with
        // small movement (and every button press, where deltas are 0) is lost.
        if (packet_pos == 0) {
            if ((byte & 0x08) == 0) continue;
        }

        packet_buf[packet_pos] = byte;
        packet_pos += 1;

        if (packet_pos >= 3) {
            packet_pos = 0;

            const buttons = packet_buf[0];
            left_button = (buttons & 0x01) != 0;
            right_button = (buttons & 0x02) != 0;
            middle_button = (buttons & 0x04) != 0;

            // 9-bit signed deltas; overflow bits live in byte0 (bit4 = X, bit5 = Y).
            var raw_x: u9 = packet_buf[1];
            if ((buttons & 0x10) != 0) raw_x |= 0x100;
            var raw_y: u9 = packet_buf[2];
            if ((buttons & 0x20) != 0) raw_y |= 0x100;

            dx = @as(i32, @as(i9, @bitCast(raw_x)));
            dy = @as(i32, @as(i9, @bitCast(raw_y)));

            mx += dx;
            my -= dy; // PS/2 Y is inverted

            clampCoords();

            if (debug_log) {
                packet_cnt += 1;
                if (packet_cnt % 50 == 0) {
                    serial.serialWrite("M ");
                    serial.serialWriteDec(@intCast(mx));
                    serial.serialWrite(" ");
                    serial.serialWriteDec(@intCast(my));
                }
                const chg = (packet_buf[0] ^ last_dbg_buttons) & 0x07;
                if (chg != 0) {
                    serial.serialWrite("\nBTN ");
                    serial.serialWriteHexShort(chg);
                }
                last_dbg_buttons = packet_buf[0];
            }
        }
    }
}
