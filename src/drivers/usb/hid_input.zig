const std = @import("std");
const keyboard = @import("../keyboard.zig");
const mouse = @import("../mouse.zig");

// USB HID Input Mapping (corresponds to Linux drivers/hid/hid-input.c)
// Translates raw HID reports (Usage Page 0x07 Keyboard, Mouse REL_X/REL_Y)
// into system keyboard keycodes and mouse movement.

// Global dynamic lock states (as in Linux input core)
pub var num_lock_state: bool = true;
pub var caps_lock_state: bool = false;
pub var scroll_lock_state: bool = false;

// Convert USB HID Usage ID to ASCII or special navigation keycode
pub fn hidUsageToAscii(key: u8, shift: bool, ctrl: bool, caps: bool, num_lock: bool) ?u8 {
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
        // Cursor / navigation keys (dedicated navigation cluster)
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
        // Keypad operators (always active)
        0x54 => return '/',
        0x55 => return '*',
        0x56 => return '-',
        0x57 => return '+',
        0x58 => return '\n',
        // Keypad digits / navigation (depends on NumLock state)
        0x59 => return if (num_lock) '1' else keyboard.KEY_END,
        0x5A => return if (num_lock) '2' else keyboard.KEY_DOWN,
        0x5B => return if (num_lock) '3' else keyboard.KEY_PAGE_DOWN,
        0x5C => return if (num_lock) '4' else keyboard.KEY_LEFT,
        0x5D => return if (num_lock) '5' else null,
        0x5E => return if (num_lock) '6' else keyboard.KEY_RIGHT,
        0x5F => return if (num_lock) '7' else keyboard.KEY_HOME,
        0x60 => return if (num_lock) '8' else keyboard.KEY_UP,
        0x61 => return if (num_lock) '9' else keyboard.KEY_PAGE_UP,
        0x62 => return if (num_lock) '0' else keyboard.KEY_INSERT,
        0x63 => return if (num_lock) '.' else keyboard.KEY_DELETE,
        else => return null,
    }
}

pub const LedCallback = *const fn (num: bool, caps: bool, scroll: bool) void;

/// Decodes USB HID Keyboard reports (Linux hid-input mapping).
/// Supports 8-byte standard Boot Report, or 9-byte Report-ID prefixed report.
pub fn handleKeyboardReport(
    report: []const u8,
    prev_report: []u8,
    caps_out: *bool,
    on_led_change: ?LedCallback,
) void {
    if (report.len < 8) return;

    // Report-ID prefix check: if byte 0 == 1 (common for 2.4GHz wireless dongles & composite devices)
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
            if (key == 0x53) {
                // NumLock pressed: toggle state & notify hardware LED driver
                num_lock_state = !num_lock_state;
                if (on_led_change) |cb| {
                    cb(num_lock_state, caps_lock_state, scroll_lock_state);
                }
            } else if (key == 0x39) {
                // CapsLock pressed: toggle state & notify hardware LED driver
                caps_lock_state = !caps_lock_state;
                caps_out.* = caps_lock_state;
                if (on_led_change) |cb| {
                    cb(num_lock_state, caps_lock_state, scroll_lock_state);
                }
            } else if (key == 0x47) {
                // ScrollLock pressed: toggle state & notify hardware LED driver
                scroll_lock_state = !scroll_lock_state;
                if (on_led_change) |cb| {
                    cb(num_lock_state, caps_lock_state, scroll_lock_state);
                }
            } else if (hidUsageToAscii(key, shift, ctrl, caps_lock_state, num_lock_state)) |ch| {
                keyboard.pushKey(ch);
            }
        }
    }

    const copy_len = @min(prev_report.len, 8);
    @memcpy(prev_report[0..copy_len], report[offset .. offset + copy_len]);
}

/// Decodes USB HID Mouse reports (Linux hid-input mapping).
/// Supports 3-4 byte standard Boot Report, or 4-5 byte Report-ID prefixed report.
pub fn handleMouseReport(report: []const u8, prev_report: []u8) void {
    if (report.len < 3) return;

    // Report-ID prefix check: if byte 0 == 2
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
