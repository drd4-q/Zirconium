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
pub fn clampCoords() void {
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

fn waitInput() bool {
    var timeout: u32 = 0;
    while (timeout < 100000) : (timeout += 1) {
        if ((port_io.inb(KB_STATUS) & 0x02) == 0) return true;
    }
    return false;
}

fn waitOutput() bool {
    var timeout: u32 = 0;
    while (timeout < 100000) : (timeout += 1) {
        if ((port_io.inb(KB_STATUS) & 0x01) != 0) return true;
    }
    return false;
}

fn readData() u8 {
    _ = waitOutput();
    return port_io.inb(KB_DATA);
}

pub fn init() void {
    const init_st = port_io.inb(KB_STATUS);
    if (init_st == 0xFF) {
        // No physical 8042 controller present
        return;
    }

    asm volatile ("cli");
    defer asm volatile ("sti");

    // Flush any pending data from port 0x60
    var flush_timeout: u32 = 0;
    while ((port_io.inb(KB_STATUS) & 0x01) != 0 and flush_timeout < 1000) : (flush_timeout += 1) {
        _ = port_io.inb(KB_DATA);
    }

    // Test second PS/2 port (command 0xA9)
    if (!waitInput()) return;
    port_io.outb(KB_STATUS, 0xA9);
    if (!waitOutput()) return;
    const test_res = port_io.inb(KB_DATA);
    if (test_res != 0x00) {
        serial.serialWrite("[MOUSE] PS/2 port 2 test failed, no mouse present\n");
        return;
    }

    // Enable auxiliary device (mouse port)
    if (!waitInput()) return;
    port_io.outb(KB_STATUS, 0xA8);

    // Read controller configuration byte
    if (!waitInput()) return;
    port_io.outb(KB_STATUS, 0x20);
    if (!waitOutput()) return;
    const cfg = port_io.inb(KB_DATA);

    // Disable clock disable for mouse (bit 5 = 0)
    if (!waitInput()) return;
    port_io.outb(KB_STATUS, 0x60);
    if (!waitInput()) return;
    port_io.outb(KB_DATA, cfg & ~@as(u8, 0x20));

    // Reset mouse to check if a device is actually attached
    if (!waitInput()) return;
    port_io.outb(KB_STATUS, 0xD4);
    if (!waitInput()) return;
    port_io.outb(KB_DATA, 0xFF); // Reset command

    // Wait for ACK (0xFA)
    if (!waitOutput()) {
        serial.serialWrite("[MOUSE] No PS/2 mouse ACK on reset\n");
        return;
    }
    const ack = port_io.inb(KB_DATA);
    if (ack != 0xFA) {
        serial.serialWrite("[MOUSE] No PS/2 mouse detected\n");
        return;
    }

    // Read self-test pass (0xAA) and device ID (0x00)
    if (waitOutput()) _ = port_io.inb(KB_DATA);
    if (waitOutput()) _ = port_io.inb(KB_DATA);

    // Enable auxiliary interrupts (IRQ12) now that mouse presence is confirmed
    if (!waitInput()) return;
    port_io.outb(KB_STATUS, 0x20);
    if (!waitOutput()) return;
    const cfg2 = port_io.inb(KB_DATA);

    if (!waitInput()) return;
    port_io.outb(KB_STATUS, 0x60);
    if (!waitInput()) return;
    port_io.outb(KB_DATA, cfg2 | 0x02); // Enable IRQ12

    // Set defaults (0xF6)
    if (!waitInput()) return;
    port_io.outb(KB_STATUS, 0xD4);
    if (!waitInput()) return;
    port_io.outb(KB_DATA, 0xF6);
    if (waitOutput()) _ = port_io.inb(KB_DATA);

    // Enable data reporting (0xF4)
    if (!waitInput()) return;
    port_io.outb(KB_STATUS, 0xD4);
    if (!waitInput()) return;
    port_io.outb(KB_DATA, 0xF4);
    if (waitOutput()) _ = port_io.inb(KB_DATA);

    // Final flush
    flush_timeout = 0;
    while ((port_io.inb(KB_STATUS) & 0x01) != 0 and flush_timeout < 1000) : (flush_timeout += 1) {
        _ = port_io.inb(KB_DATA);
    }

    isr_mod.registerIrq(12, irqHandler);
    ready = true;

    // Flush keyboard ring buffer to remove any garbage read during init
    @import("../drivers/keyboard.zig").flush();

    vga.write("[MOUSE] PS/2 mouse initialized\n");
}

fn irqHandler(_: *isr_mod.InterruptFrame) void {
    // Process at most one complete mouse packet (3 bytes) per IRQ.
    var count: u8 = 0;
    while (count < 3) : (count += 1) {
        const status = port_io.inb(KB_STATUS);
        if ((status & 0x01) == 0) break;
        if ((status & 0x20) == 0) {
            // Unhandled keyboard data in buffer - forward to keyboard driver to avoid hanging 8042
            const kb_byte = port_io.inb(KB_DATA);
            @import("../drivers/keyboard.zig").pushScancode(kb_byte);
            break;
        }

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

pub fn updateFromUsb(buttons: u8, delta_x: i32, delta_y: i32) void {
    left_button = (buttons & 0x01) != 0;
    right_button = (buttons & 0x02) != 0;
    middle_button = (buttons & 0x04) != 0;
    dx = delta_x;
    dy = delta_y;

    mx += dx;
    my += dy; // USB HID mouse Y axis: positive delta is downwards

    clampCoords();
    ready = true;

    if (debug_log) {
        packet_cnt += 1;
        if (packet_cnt % 50 == 0) {
            serial.serialWrite("USB-M ");
            serial.serialWriteDec(@intCast(mx));
            serial.serialWrite(" ");
            serial.serialWriteDec(@intCast(my));
        }
        const chg = (buttons ^ last_dbg_buttons) & 0x07;
        if (chg != 0) {
            serial.serialWrite("\nUSB-BTN ");
            serial.serialWriteHexShort(chg);
        }
        last_dbg_buttons = buttons;
    }
}

pub var wheel: i32 = 0;
pub var dwheel: i32 = 0;

pub fn updateFromUsbWithWheel(buttons: u8, delta_x: i32, delta_y: i32, delta_wheel: i32) void {
    dwheel = delta_wheel;
    wheel += delta_wheel;
    updateFromUsb(buttons, delta_x, delta_y);
}

pub fn poll() void {
    @import("usb.zig").poll();
}

/// Absolute-position update from a USB tablet (HID digitizer, 0..4095 range
/// used by QEMU's usb-tablet). Coordinates land in the same pixel space the
/// PS/2 relative path uses.
pub fn usbUpdate(x: u32, y: u32, left: bool, right: bool, middle: bool) void {
    const max_c: u64 = 4095;
    if (fb.active and fb.fb_width > 0) {
        mx = @intCast(@min((@as(u64, x) * fb.fb_width) / max_c, fb.fb_width - 1));
        my = @intCast(@min((@as(u64, y) * fb.fb_height) / max_c, fb.fb_height - 1));
    } else {
        mx = @intCast(@min((@as(u64, x) * 80) / max_c, 79));
        my = @intCast(@min((@as(u64, y) * 25) / max_c, 24));
    }
    left_button = left;
    right_button = right;
    middle_button = middle;
    ready = true;
}
