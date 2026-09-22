const std = @import("std");
const root = @import("root");
const serial = root.serial;
const keyboard = @import("../keyboard.zig");
const mouse = @import("../mouse.zig");
const types = @import("types.zig");

// HID Class Definition Constants (USB HID Spec 1.11)
pub const HID_CLASS: u8 = 0x03;
pub const HID_SUBCLASS_NONE: u8 = 0x00;
pub const HID_SUBCLASS_BOOT: u8 = 0x01;

pub const HID_PROTOCOL_NONE: u8 = 0x00;
pub const HID_PROTOCOL_KEYBOARD: u8 = 0x01;
pub const HID_PROTOCOL_MOUSE: u8 = 0x02;

// HID Class Specific Requests
pub const HID_REQ_GET_REPORT: u8 = 0x01;
pub const HID_REQ_GET_IDLE: u8 = 0x02;
pub const HID_REQ_GET_PROTOCOL: u8 = 0x03;
pub const HID_REQ_SET_REPORT: u8 = 0x09;
pub const HID_REQ_SET_IDLE: u8 = 0x0A;
pub const HID_REQ_SET_PROTOCOL: u8 = 0x0B;

// HID Protocol Codes for SET_PROTOCOL
pub const PROTOCOL_BOOT: u16 = 0x0000;
pub const PROTOCOL_REPORT: u16 = 0x0001;

// HID Report Types
pub const REPORT_TYPE_INPUT: u8 = 1;
pub const REPORT_TYPE_OUTPUT: u8 = 2;
pub const REPORT_TYPE_FEATURE: u8 = 3;

// Known 2.4GHz Wireless Dongle Profile
pub const DongleProfile = struct {
    vendor_id: u16,
    product_id: u16,
    name: []const u8,
    is_composite: bool,
};

// Database of popular 2.4GHz wireless dongles (Logitech Unifying, Nano, and Generic Combos)
pub const KNOWN_DONGLES = [_]DongleProfile{
    // Logitech Unifying & Wireless Receivers (VID 0x046D)
    .{ .vendor_id = 0x046D, .product_id = 0xC52B, .name = "Logitech Unifying Receiver", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC534, .name = "Logitech Nano Receiver (MK270)", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC52F, .name = "Logitech Wireless Receiver", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC539, .name = "Logitech Lightspeed Gaming Receiver", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC53A, .name = "Logitech PowerPlay Receiver", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC537, .name = "Logitech Spotlight Wireless Presenter", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC517, .name = "Logitech Cordless Receiver", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC518, .name = "Logitech Cordless Mouse/Keyboard", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC51A, .name = "Logitech Cordless Desktop", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC51B, .name = "Logitech Cordless 2.4GHz", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC521, .name = "Logitech Cordless Receiver", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC525, .name = "Logitech Cordless Mini Receiver", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC526, .name = "Logitech Cordless Nano Receiver", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC531, .name = "Logitech Wireless Combo Receiver", .is_composite = true },
    .{ .vendor_id = 0x046D, .product_id = 0xC532, .name = "Logitech Wireless Mouse Receiver", .is_composite = true },
    // Generic 2.4GHz Wireless Combo Receivers
    .{ .vendor_id = 0x0627, .product_id = 0x0001, .name = "MosArt 2.4GHz Wireless Keyboard/Mouse Combo", .is_composite = true },
    .{ .vendor_id = 0x24AE, .product_id = 0x1100, .name = "Rapoo 2.4GHz Wireless Combo Receiver", .is_composite = true },
    .{ .vendor_id = 0x24AE, .product_id = 0x2000, .name = "Rapoo 2.4GHz Wireless Receiver", .is_composite = true },
    .{ .vendor_id = 0x1A2C, .product_id = 0x0021, .name = "Semico 2.4GHz Wireless Combo Receiver", .is_composite = true },
    .{ .vendor_id = 0x1A2C, .product_id = 0x0027, .name = "Semico 2.4GHz Wireless Keyboard/Mouse", .is_composite = true },
    .{ .vendor_id = 0x04D9, .product_id = 0xA055, .name = "Holtek 2.4GHz Wireless Combo Receiver", .is_composite = true },
    .{ .vendor_id = 0x04F2, .product_id = 0x0833, .name = "Chicony 2.4GHz Wireless Combo Receiver", .is_composite = true },
    .{ .vendor_id = 0x093A, .product_id = 0x2510, .name = "PixArt 2.4GHz Wireless Receiver", .is_composite = true },
    .{ .vendor_id = 0x1BCF, .product_id = 0x0005, .name = "Sunplus 2.4GHz Wireless Receiver", .is_composite = true },
    .{ .vendor_id = 0x258A, .product_id = 0x0001, .name = "SinoWealth 2.4GHz Wireless Receiver", .is_composite = true },
    .{ .vendor_id = 0x1997, .product_id = 0x2433, .name = "Mosart Semi 2.4GHz Wireless Receiver", .is_composite = true },
    .{ .vendor_id = 0x0E8F, .product_id = 0x0003, .name = "GreenAsia 2.4GHz Wireless Receiver", .is_composite = true },
    .{ .vendor_id = 0x1241, .product_id = 0x1166, .name = "Belkin 2.4GHz Wireless Receiver", .is_composite = true },
    .{ .vendor_id = 0x1D57, .product_id = 0xAD03, .name = "Xenta 2.4GHz Wireless Receiver", .is_composite = true },
};

pub fn isWirelessDongle(vendor_id: u16, product_id: u16) bool {
    // Specific match from database
    for (KNOWN_DONGLES) |d| {
        if (d.vendor_id == vendor_id and (d.product_id == product_id or product_id == 0)) {
            return true;
        }
    }
    // Generic vendor match for known 2.4GHz dongle manufacturers
    return switch (vendor_id) {
        0x046D => (product_id >= 0xC500 and product_id <= 0xC5FF), // Logitech cordless/unifying range
        0x0627, 0x24AE, 0x1A2C, 0x04D9, 0x04F2, 0x093A, 0x1BCF, 0x258A, 0x1997, 0x0E8F, 0x1241, 0x1D57 => true,
        else => false,
    };
}

pub fn isLogitechUnifying(vendor_id: u16, product_id: u16) bool {
    return vendor_id == 0x046D and product_id == 0xC52B;
}

pub fn getDongleName(vendor_id: u16, product_id: u16) ?[]const u8 {
    for (KNOWN_DONGLES) |d| {
        if (d.vendor_id == vendor_id and d.product_id == product_id) {
            return d.name;
        }
    }
    if (vendor_id == 0x046D) {
        return "Logitech Wireless USB Receiver";
    }
    if (vendor_id == 0x0627) {
        return "MosArt 2.4GHz Wireless Receiver";
    }
    if (vendor_id == 0x24AE) {
        return "Rapoo 2.4GHz Wireless Receiver";
    }
    if (isWirelessDongle(vendor_id, product_id)) {
        return "Generic 2.4GHz Wireless Receiver";
    }
    return null;
}

// Convert USB HID Usage ID to ASCII or special navigation keycode
pub fn usbKeyToAscii(key: u8, shift: bool, ctrl: bool, caps: bool) ?u8 {
    // Letters A-Z: HID codes 0x04..0x1D
    if (key >= 0x04 and key <= 0x1D) {
        const base: u8 = 'a' + (key - 0x04);
        if (ctrl) {
            return base & 0x1F;
        }
        if (shift != caps) {
            return base - 32;
        }
        return base;
    }

    // Ctrl + '[' gives ESC (0x1B)
    if (ctrl and key == 0x2F) return 0x1B;

    // Digits 1-9, 0: HID codes 0x1E..0x27
    if (key >= 0x1E and key <= 0x27) {
        if (shift) {
            return switch (key) {
                0x1E => '!',
                0x1F => '@',
                0x20 => '#',
                0x21 => '$',
                0x22 => '%',
                0x23 => '^',
                0x24 => '&',
                0x25 => '*',
                0x26 => '(',
                0x27 => ')',
                else => 0,
            };
        } else {
            if (key == 0x27) return '0';
            return '1' + (key - 0x1E);
        }
    }

    // Enter, Esc, Backspace, Tab, Space & symbols
    switch (key) {
        0x28 => return '\n',
        0x29 => return 0x1B, // Esc
        0x2A => return 0x08, // Backspace
        0x2B => return '\t', // Tab
        0x2C => return ' ',
        0x2D => return if (shift) '_' else '-',
        0x2E => return if (shift) '+' else '=',
        0x2F => return if (shift) '{' else '[',
        0x30 => return if (shift) '}' else ']',
        0x31 => return if (shift) '|' else '\\',
        0x33 => return if (shift) ':' else ';',
        0x34 => return if (shift) '"' else '\'',
        0x35 => return if (shift) '~' else '`',
        0x36 => return if (shift) '<' else ',',
        0x37 => return if (shift) '>' else '.',
        0x38 => return if (shift) '?' else '/',
        // Cursor / navigation keys
        0x49 => return keyboard.KEY_INSERT,
        0x4A => return keyboard.KEY_HOME,
        0x4B => return keyboard.KEY_PAGE_UP,
        0x4C => return keyboard.KEY_DELETE,
        0x4D => return keyboard.KEY_END,
        0x4E => return keyboard.KEY_PAGE_DOWN,
        0x4F => return keyboard.KEY_RIGHT,
        0x50 => return keyboard.KEY_LEFT,
        0x51 => return keyboard.KEY_DOWN,
        0x52 => return keyboard.KEY_UP,
        // Keypad keys
        0x54 => return '/',
        0x55 => return '*',
        0x56 => return '-',
        0x57 => return '+',
        0x58 => return '\n',
        0x59 => return '1',
        0x5A => return '2',
        0x5B => return '3',
        0x5C => return '4',
        0x5D => return '5',
        0x5E => return '6',
        0x5F => return '7',
        0x60 => return '8',
        0x61 => return '9',
        0x62 => return '0',
        0x63 => return '.',
        else => return null,
    }
}

// Decode USB HID Keyboard Boot Report (8 bytes standard or 9 bytes report-ID prefixed)
pub fn decodeKeyboardReport(report: []const u8, prev_report: []u8, caps_lock: *bool) void {
    if (report.len < 8) return;

    // Detect Report-ID prefixed report:
    // If byte 0 is Report ID 1 (standard for composite 2.4GHz wireless dongles) and total length >= 9,
    // data payload starts at byte 1 (offset = 1).
    const offset: usize = if (report[0] == 1 and report.len >= 9) 1 else 0;
    if (report.len < offset + 8) return;

    const mod = report[offset + 0];
    const shift = (mod & 0x22) != 0; // Left Shift (0x02) or Right Shift (0x20)
    const ctrl = (mod & 0x11) != 0; // Left Ctrl (0x01) or Right Ctrl (0x10)

    // Check up to 6 pressed keys in report (bytes 2..7)
    var k: usize = 2;
    while (k < 8) : (k += 1) {
        const key = report[offset + k];
        if (key == 0) continue;

        var was_pressed = false;
        var prev_k: usize = 2;
        while (prev_k < 8 and prev_k < prev_report.len) : (prev_k += 1) {
            if (prev_report[prev_k] == key) {
                was_pressed = true;
                break;
            }
        }

        if (!was_pressed) {
            if (key == 0x39) { // CapsLock keycode
                caps_lock.* = !caps_lock.*;
            } else if (usbKeyToAscii(key, shift, ctrl, caps_lock.*)) |ch| {
                keyboard.pushKey(ch);
            }
        }
    }

    const copy_len = @min(prev_report.len, 8);
    @memcpy(prev_report[0..copy_len], report[offset .. offset + copy_len]);
}

// Decode USB HID Mouse Boot Report (3-4 bytes standard or 4-5 bytes report-ID prefixed)
pub fn decodeMouseReport(report: []const u8, prev_report: []u8) void {
    if (report.len < 3) return;

    // Detect Report-ID prefixed report:
    // If byte 0 is Report ID 2 and total length >= 4, data payload starts at byte 1.
    const offset: usize = if (report[0] == 2 and report.len >= 4) 1 else 0;
    if (report.len < offset + 3) return;

    const buttons = report[offset + 0];
    const dx = @as(i32, @as(i8, @bitCast(report[offset + 1])));
    const dy = @as(i32, @as(i8, @bitCast(report[offset + 2])));

    const last_buttons = if (prev_report.len > 0) prev_report[0] else 0;
    if (dx != 0 or dy != 0 or buttons != last_buttons) {
        mouse.updateFromUsb(buttons, dx, dy);
    }

    if (prev_report.len > 0) {
        prev_report[0] = buttons;
    }
}

// Build standard HID control request packets
pub fn makeSetProtocolPacket(iface_num: u8, protocol: u16) types.UsbSetupPacket {
    return types.UsbSetupPacket{
        .bmRequestType = 0x21, // Host-to-Device, Class, Interface
        .bRequest = HID_REQ_SET_PROTOCOL,
        .wValue = protocol, // 0 = Boot, 1 = Report
        .wIndex = iface_num,
        .wLength = 0,
    };
}

pub fn makeSetIdlePacket(iface_num: u8, duration: u8, report_id: u8) types.UsbSetupPacket {
    return types.UsbSetupPacket{
        .bmRequestType = 0x21,
        .bRequest = HID_REQ_SET_IDLE,
        .wValue = (@as(u16, duration) << 8) | @as(u16, report_id),
        .wIndex = iface_num,
        .wLength = 0,
    };
}

pub fn makeGetReportPacket(iface_num: u8, report_type: u8, report_id: u8, length: u16) types.UsbSetupPacket {
    return types.UsbSetupPacket{
        .bmRequestType = 0xA1, // Device-to-Host, Class, Interface
        .bRequest = HID_REQ_GET_REPORT,
        .wValue = (@as(u16, report_type) << 8) | @as(u16, report_id),
        .wIndex = iface_num,
        .wLength = length,
    };
}

pub fn makeSetReportPacket(iface_num: u8, report_type: u8, report_id: u8, length: u16) types.UsbSetupPacket {
    return types.UsbSetupPacket{
        .bmRequestType = 0x21,
        .bRequest = HID_REQ_SET_REPORT,
        .wValue = (@as(u16, report_type) << 8) | @as(u16, report_id),
        .wIndex = iface_num,
        .wLength = length,
    };
}

pub fn setKeyboardLeds(
    addr: u8,
    maxp0: u8,
    iface_num: u8,
    num_lock: bool,
    caps_lock: bool,
    scroll_lock: bool,
    ctrl_transfer_fn: *const fn (addr: u8, maxp0: u8, setup: *const types.UsbSetupPacket, dout: ?[]const u8, din: ?[]u8) bool,
) void {
    var led_val: u8 = 0;
    if (num_lock) led_val |= 0x01;
    if (caps_lock) led_val |= 0x02;
    if (scroll_lock) led_val |= 0x04;
    const led_data = [_]u8{led_val};
    const pkt = makeSetReportPacket(iface_num, 2, 0, 1);
    _ = ctrl_transfer_fn(addr, maxp0, &pkt, &led_data, null);
}
