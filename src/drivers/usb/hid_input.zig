const std = @import("std");
const root = @import("root");
const serial = root.serial;
const keyboard = @import("../keyboard.zig");
const mouse = @import("../mouse.zig");
const hid_report = @import("../hid/hid_report.zig");

/// Emit raw HID reports and decoded USB keys on the serial console when the
/// user runs `usb debug on`.  It is intentionally opt-in because a keyboard
/// can produce a report for every held/released key.
pub var debug: bool = false;

/// One line, ever: the first key the descriptor decoder turned into a
/// character.  It separates "the interrupt transfer never completed" from
/// "the key was decoded and the shell did not see it".
var first_key_logged: bool = false;

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
        // 0x01/0x02 are the HID rollover-error usages, not key presses.
        if (key == 0x01 or key == 0x02) continue;

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
                if (!first_key_logged) {
                    first_key_logged = true;
                    serial.serialWrite("[HID] first boot-protocol key usage=0x");
                    serial.serialWriteHex(key);
                    serial.serialWrite(" char=0x");
                    serial.serialWriteHex(ch);
                    serial.serialWrite("\n");
                }
                if (debug) {
                    serial.serialWrite("[USB-HID] key=");
                    serial.serialWriteHex(ch);
                    serial.serialWrite("\n");
                }
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
    const wheel = if (report.len >= offset + 4)
        @as(i32, @as(i8, @bitCast(report[offset + 3])))
    else
        0;
    if (dx != 0 or dy != 0 or wheel != 0 or buttons != last_buttons) {
        mouse.updateFromUsbWithWheel(buttons, dx, dy, wheel);
    }

    if (prev_report.len > 0) {
        prev_report[0] = buttons;
    }
}

// ─── Report descriptor driven decoding (Linux hid-input.c) ───────────────
//
// The boot protocol decoder above guesses the layout of a report: eight
// bytes, modifiers first, six key slots.  A modern keyboard is rarely that
// layout, and a dongle behind an interface can prefix every report with a
// report ID.  This decoder takes the layout from the parsed report
// descriptor instead, the way `hid-input.c` walks `hid_field`s: a variable
// field names one usage per bit range, an array field's value names the
// usage that is currently down, and the usages decide what the value means.

pub const MAX_REPORT_KEYS: usize = 24;

/// The keyboard and mouse state that a descriptor driven report needs in
/// order to tell a press from a repeat: an array report lists every key
/// that is down, not the key that changed.
pub const State = struct {
    keys: [MAX_REPORT_KEYS]u16 = @splat(0),
    key_count: u8 = 0,
    buttons: u8 = 0,

    fn contains(self: *const State, usage: u16) bool {
        var i: usize = 0;
        while (i < @as(usize, self.key_count)) : (i += 1) {
            if (self.keys[i] == usage) return true;
        }
        return false;
    }

    fn add(self: *State, usage: u16) void {
        if (self.key_count >= MAX_REPORT_KEYS or self.contains(usage)) return;
        self.keys[@as(usize, self.key_count)] = usage;
        self.key_count += 1;
    }
};

fn addReportKey(keys: *[MAX_REPORT_KEYS]u16, count: *usize, usage: u16) void {
    if (count.* >= MAX_REPORT_KEYS) return;
    var i: usize = 0;
    while (i < count.*) : (i += 1) {
        if (keys[i] == usage) return;
    }
    keys[count.*] = usage;
    count.* += 1;
}

/// Decode one input report using the layout in `table`.
///
/// Returns false when the report is not an input report of this interface
/// (an unknown report ID, or a report the descriptor does not describe), so
/// the caller can leave it for the interface it belongs to.
pub fn handleDescriptorReport(
    table: *const hid_report.Table,
    report: []const u8,
    state: *State,
    on_led_change: ?LedCallback,
) bool {
    if (report.len == 0) return false;

    // A numbered report starts with its report ID; an unnumbered one does
    // not (`hid_report_len` and `hid_report_enum` in hid-core.c).
    var report_id: u8 = 0;
    var payload: []const u8 = report;
    if (table.numbered(.input)) {
        report_id = report[0];
        payload = report[1..];
    }
    if (table.findReport(.input, report_id) == null) return false;
    if (payload.len == 0) return false;

    var modifiers: u8 = 0;
    var keys: [MAX_REPORT_KEYS]u16 = @splat(0);
    var key_count: usize = 0;

    var buttons: u8 = 0;
    var dx: i32 = 0;
    var dy: i32 = 0;
    var wheel: i32 = 0;
    var abs_x: i32 = 0;
    var abs_y: i32 = 0;
    var abs_max_x: i32 = 0;
    var abs_max_y: i32 = 0;
    var have_axes = false;
    var have_wheel = false;
    var absolute = false;

    var field_idx: usize = 0;
    while (field_idx < @as(usize, table.field_count)) : (field_idx += 1) {
        const field = &table.fields[field_idx];
        if (field.report_type != .input or field.report_id != report_id) continue;
        if (field.isConstant() or field.report_size == 0) continue;

        var index: u16 = 0;
        while (index < field.report_count) : (index += 1) {
            const value = field.valueAt(payload, index) orelse continue;
            const usage = if (field.isVariable())
                field.usageAt(index)
            else
                (field.usageForValue(value) orelse continue);

            switch (usage.page) {
                hid_report.USAGE_PAGE_KEYBOARD => {
                    if (value == 0 or usage.id == 0) continue;
                    if (usage.id >= 0xE0 and usage.id <= 0xE7) {
                        // The modifier usages are one bit each: 0xE0 left
                        // ctrl ... 0xE7 right GUI (`hidinput_configure_usage`).
                        modifiers |= @as(u8, 1) << @intCast(usage.id - 0xE0);
                    } else {
                        addReportKey(&keys, &key_count, usage.id);
                    }
                },
                hid_report.USAGE_PAGE_BUTTON => {
                    if (value == 0) continue;
                    if (usage.id >= 1 and usage.id <= 8) {
                        buttons |= @as(u8, 1) << @intCast(usage.id - 1);
                    }
                },
                hid_report.USAGE_PAGE_GENERIC_DESKTOP => switch (usage.id) {
                    hid_report.USAGE_GD_X => {
                        have_axes = true;
                        if (field.isRelative()) {
                            dx += value;
                        } else {
                            abs_x = value;
                            abs_max_x = @max(abs_max_x, field.logical_max);
                            absolute = true;
                        }
                    },
                    hid_report.USAGE_GD_Y => {
                        have_axes = true;
                        if (field.isRelative()) {
                            dy += value;
                        } else {
                            abs_y = value;
                            abs_max_y = @max(abs_max_y, field.logical_max);
                            absolute = true;
                        }
                    },
                    hid_report.USAGE_GD_WHEEL => {
                        have_wheel = true;
                        wheel += value;
                    },
                    else => {},
                },
                else => {},
            }
        }
    }

    // The keyboard half: an array report lists the keys that are down, so
    // the press is the usage that was not down before.
    const shift = (modifiers & 0x22) != 0; // left/right shift
    const ctrl = (modifiers & 0x11) != 0; // left/right ctrl
    var next_state = State{ .buttons = buttons };
    var led_changed = false;

    var key_idx: usize = 0;
    while (key_idx < key_count) : (key_idx += 1) {
        const key = keys[key_idx];
        if (!state.contains(key)) {
            switch (key) {
                0x39 => {
                    caps_lock_state = !caps_lock_state;
                    led_changed = true;
                },
                0x53 => {
                    num_lock_state = !num_lock_state;
                    led_changed = true;
                },
                0x47 => {
                    scroll_lock_state = !scroll_lock_state;
                    led_changed = true;
                },
                else => {
                    if (hidUsageToAscii(@intCast(key), shift, ctrl, caps_lock_state, num_lock_state)) |ch| {
                        keyboard.pushKey(ch);
                        if (!first_key_logged) {
                            first_key_logged = true;
                            serial.serialWrite("[HID] first decoded key usage=0x");
                            serial.serialWriteHex(key);
                            serial.serialWrite(" char=0x");
                            serial.serialWriteHex(ch);
                            serial.serialWrite("\n");
                        }
                        if (debug) {
                            serial.serialWrite("[USB-HID] key=");
                            serial.serialWriteHex(ch);
                            serial.serialWrite("\n");
                        }
                    }
                },
            }
        }
        next_state.add(key);
    }
    state.keys = next_state.keys;
    state.key_count = next_state.key_count;

    if (led_changed) {
        if (on_led_change) |cb| cb(num_lock_state, caps_lock_state, scroll_lock_state);
    }

    // The pointer half.  A tablet reports absolute coordinates in its own
    // logical range; a mouse reports a displacement.
    const left = (buttons & 0x01) != 0;
    const right = (buttons & 0x02) != 0;
    const middle = (buttons & 0x04) != 0;
    const axes_changed = dx != 0 or dy != 0 or wheel != 0 or buttons != state.buttons;
    if (absolute) {
        mouse.usbUpdateRange(
            @intCast(@max(abs_x, 0)),
            @intCast(@max(abs_y, 0)),
            @intCast(@max(abs_max_x, 0)),
            @intCast(@max(abs_max_y, 0)),
            left,
            right,
            middle,
        );
    } else if (have_axes and axes_changed) {
        mouse.updateFromUsbWithWheel(buttons, dx, dy, wheel);
    } else if (have_wheel and axes_changed) {
        mouse.updateFromUsbWithWheel(buttons, 0, 0, wheel);
    }
    state.buttons = buttons;

    if (debug and (have_axes or have_wheel)) {
        serial.serialWrite("[USB-HID] pointer ");
        if (absolute) {
            serial.serialWrite("abs ");
            serial.serialWriteDec(@intCast(@max(abs_x, 0)));
            serial.serialWrite(",");
            serial.serialWriteDec(@intCast(@max(abs_y, 0)));
            serial.serialWrite("/");
            serial.serialWriteDec(@intCast(@max(abs_max_x, 0)));
            serial.serialWrite(",");
            serial.serialWriteDec(@intCast(@max(abs_max_y, 0)));
        } else {
            serial.serialWrite("rel ");
            if (dx < 0) serial.serialWrite("-");
            serial.serialWriteDec(@intCast(if (dx < 0) -dx else dx));
            serial.serialWrite(",");
            if (dy < 0) serial.serialWrite("-");
            serial.serialWriteDec(@intCast(if (dy < 0) -dy else dy));
            serial.serialWrite(" wheel=");
            if (wheel < 0) serial.serialWrite("-");
            serial.serialWriteDec(@intCast(if (wheel < 0) -wheel else wheel));
        }
        serial.serialWrite(" buttons=");
        serial.serialWriteDec(buttons);
        serial.serialWrite("\n");
    }

    return true;
}
