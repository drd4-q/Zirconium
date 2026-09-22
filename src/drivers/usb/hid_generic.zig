const std = @import("std");
const types = @import("types.zig");
const hid_input = @import("hid_input.zig");

// USB HID Generic Driver (corresponds to Linux drivers/hid/hid-generic.c)
// Generic driver that binds standard USB HID devices (Class 0x03) to the
// input subsystem mapping layer.

pub fn match(class_code: u8) bool {
    return class_code == 0x03;
}

pub fn processReport(
    dev_type: types.UsbDeviceType,
    is_wireless: bool,
    report: []const u8,
    prev_report: []u8,
    caps_lock: *bool,
    on_led_change: ?hid_input.LedCallback,
) void {
    if (report.len == 0) return;

    // Composite / 2.4GHz dongles prefixing reports with Report IDs:
    // Report ID 1 = Keyboard
    if ((report.len >= 9 or (is_wireless and report.len >= 8)) and report[0] == 1) {
        hid_input.handleKeyboardReport(report, prev_report, caps_lock, on_led_change);
        return;
    }

    // Report ID 2 = Mouse
    if (report[0] == 2 and (report.len >= 5 or (is_wireless and report.len >= 4))) {
        hid_input.handleMouseReport(report, prev_report);
        return;
    }

    // Direct dispatch based on device type
    if (dev_type == .keyboard and report.len >= 8) {
        hid_input.handleKeyboardReport(report, prev_report, caps_lock, on_led_change);
    } else if (dev_type == .mouse and report.len >= 3) {
        hid_input.handleMouseReport(report, prev_report);
    }
}
