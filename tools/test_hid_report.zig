//! Host-side test of the HID report descriptor parser.
//!
//! The parser lives in `src/drivers/hid/hid_report.zig` and has no kernel
//! dependencies, so this test imports the real module — the descriptors
//! below are the ones QEMU's usb-kbd and usb-tablet hand to the driver, plus
//! a numbered composite in the shape a 2.4GHz receiver uses.
//!
//! Run it with:
//!
//!     zig run --dep hidreport -Mroot=tools/test_hid_report.zig \
//!         -Mhidreport=src/drivers/hid/hid_report.zig

const std = @import("std");

const hid = @import("hidreport");

var failures: u32 = 0;
var checks: u32 = 0;

fn checkEq(got: anytype, want: anytype, what: []const u8) void {
    checks += 1;
    if (got == want) return;
    failures += 1;
    std.debug.print("  FAIL: {s}: got 0x{x}, want 0x{x}\n", .{ what, got, want });
}

fn check(ok: bool, what: []const u8) void {
    checks += 1;
    if (ok) return;
    failures += 1;
    std.debug.print("  FAIL: {s}\n", .{what});
}

// QEMU hw/usb/dev-hid.c, the usb-kbd report descriptor: boot keyboard with
// an eight bit modifier field, a five bit LED output field and a six slot
// key array.
const qemu_keyboard = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x06, // Usage (Keyboard)
    0xA1, 0x01, // Collection (Application)
    0x05, 0x07, //   Usage Page (Keyboard)
    0x19, 0xE0, //   Usage Minimum (224)
    0x29, 0xE7, //   Usage Maximum (231)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x01, //   Logical Maximum (1)
    0x75, 0x01, //   Report Size (1)
    0x95, 0x08, //   Report Count (8)
    0x81, 0x02, //   Input (Data, Variable, Absolute)
    0x95, 0x01, //   Report Count (1)
    0x75, 0x08, //   Report Size (8)
    0x81, 0x01, //   Input (Constant)
    0x95, 0x05, //   Report Count (5)
    0x75, 0x01, //   Report Size (1)
    0x05, 0x08, //   Usage Page (LEDs)
    0x19, 0x01, //   Usage Minimum (1)
    0x29, 0x05, //   Usage Maximum (5)
    0x91, 0x02, //   Output (Data, Variable, Absolute)
    0x95, 0x01, //   Report Count (1)
    0x75, 0x03, //   Report Size (3)
    0x91, 0x01, //   Output (Constant)
    0x95, 0x06, //   Report Count (6)
    0x75, 0x08, //   Report Size (8)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x65, //   Logical Maximum (101)
    0x05, 0x07, //   Usage Page (Keyboard)
    0x19, 0x00, //   Usage Minimum (0)
    0x29, 0x65, //   Usage Maximum (101)
    0x81, 0x00, //   Input (Data, Array)
    0xC0, // End Collection
};

// QEMU hw/usb/dev-hid.c, the usb-tablet report descriptor: buttons, then
// absolute X/Y over the full 0..32767 logical range.
const qemu_tablet = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x02, // Usage (Mouse)
    0xA1, 0x01, // Collection (Application)
    0x09, 0x01, //   Usage (Pointer)
    0xA1, 0x00, //   Collection (Physical)
    0x05, 0x09, //     Usage Page (Button)
    0x19, 0x01, //     Usage Minimum (1)
    0x29, 0x03, //     Usage Maximum (3)
    0x15, 0x00, //     Logical Minimum (0)
    0x25, 0x01, //     Logical Maximum (1)
    0x95, 0x03, //     Report Count (3)
    0x75, 0x01, //     Report Size (1)
    0x81, 0x02, //     Input (Data, Variable, Absolute)
    0x95, 0x01, //     Report Count (1)
    0x75, 0x05, //     Report Size (5)
    0x81, 0x01, //     Input (Constant)
    0x05, 0x01, //     Usage Page (Generic Desktop)
    0x09, 0x30, //     Usage (X)
    0x09, 0x31, //     Usage (Y)
    0x15, 0x00, //     Logical Minimum (0)
    0x26, 0xFF, 0x7F, // Logical Maximum (32767)
    0x75, 0x10, //     Report Size (16)
    0x95, 0x02, //     Report Count (2)
    0x81, 0x02, //     Input (Data, Variable, Absolute)
    0xC0, //   End Collection
    0xC0, // End Collection
};

// A receiver shaped like the 2.4GHz dongles: one interface, two top-level
// collections, report ID 1 for the keyboard and report ID 2 for the mouse.
const numbered_composite = [_]u8{
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, // Keyboard
    0x85, 0x01, // Report ID (1)
    0x05, 0x07,
    0x19, 0xE0,
    0x29, 0xE7,
    0x15, 0x00,
    0x25, 0x01,
    0x75, 0x01,
    0x95, 0x08,
    0x81, 0x02,
    0x95, 0x01,
    0x75, 0x08,
    0x81, 0x01,
    0x95, 0x06,
    0x75, 0x08,
    0x15, 0x00,
    0x25, 0x65,
    0x19, 0x00,
    0x29, 0x65,
    0x81, 0x00,
    0xC0,
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, // Mouse
    0x85, 0x02, // Report ID (2)
    0x05, 0x09,
    0x19, 0x01,
    0x29, 0x03,
    0x15, 0x00,
    0x25, 0x01,
    0x95, 0x03,
    0x75, 0x01,
    0x81, 0x02,
    0x95, 0x01,
    0x75, 0x05,
    0x81, 0x01,
    0x05, 0x01,
    0x09, 0x30,
    0x09, 0x31,
    0x09, 0x38,
    0x15, 0x81,
    0x25, 0x7F,
    0x75, 0x08,
    0x95, 0x03,
    0x81, 0x06,
    0xC0,
};

fn testQemuKeyboard() void {
    std.debug.print("test: the QEMU boot keyboard\n", .{});

    const table = hid.parse(&qemu_keyboard) catch |err| {
        failures += 1;
        std.debug.print("  FAIL: parse: {s}\n", .{@errorName(err)});
        return;
    };
    check(table.valid, "the descriptor is valid");
    check(table.kind() == .keyboard, "the application is a keyboard");
    check(!table.numbered(.input), "the reports are not numbered");
    checkEq(table.field_count, 3, "three fields (modifiers, LEDs, keys)");
    checkEq(table.report_count, 2, "one input and one output report");
    checkEq(table.findReport(.input, 0).?.len(), 8, "the input report is 8 bytes");
    checkEq(table.findReport(.output, 0).?.len(), 1, "the output report is 1 byte");
    checkEq(table.maxReportLen(.input), 8, "an unnumbered input report is 8 bytes on the wire");
    checkEq(table.maxReportLen(.output), 1, "an unnumbered output report is 1 byte on the wire");

    // The modifier field: eight one-bit variable usages at bit zero.
    const modifiers = &table.fields[0];
    checkEq(modifiers.report_size, 1, "modifier bits are one bit wide");
    checkEq(modifiers.report_count, 8, "one bit per modifier");
    checkEq(modifiers.usageAt(1).id, 0xE1, "the second modifier is left shift");
    checkEq(modifiers.bit_offset, 0, "the modifiers start at bit zero");

    // A report with left shift and 'a' down.
    var report = [_]u8{ 0x02, 0x00, 0x04, 0, 0, 0, 0, 0 };
    checkEq(modifiers.valueAt(&report, 1).?, 1, "left shift is down");
    const keys = &table.fields[2];
    checkEq(keys.valueAt(&report, 0).?, 0x04, "the first key slot is 'a'");
    checkEq(keys.usageForValue(0x04).?.id, 0x04, "usage 4 is 'a'");
    checkEq(keys.valueAt(&report, 5).?, 0, "the unused slots are zero");

    // The LED output field: five one-bit usages, Num Lock, Caps Lock,
    // Scroll Lock, Compose and Kana.
    const leds = &table.fields[1];
    checkEq(leds.report_count, 5, "five LED bits");
    checkEq(leds.usageAt(0).page, hid.USAGE_PAGE_LED, "the LED usage page");
    checkEq(leds.usageAt(0).id, 1, "usage 1 is Num Lock");
    checkEq(leds.usageAt(1).id, 2, "usage 2 is Caps Lock");
    checkEq(leds.usageAt(2).id, 3, "usage 3 is Scroll Lock");

    var leds_out = [_]u8{0};
    leds.setValue(&leds_out, 0, 1);
    leds.setValue(&leds_out, 1, 0);
    leds.setValue(&leds_out, 2, 1);
    checkEq(leds_out[0], 0x05, "Num Lock and Scroll Lock set");
    checkEq(leds.valueAt(&leds_out, 0).?, 1, "reading the output field back");
}

fn testQemuTablet() void {
    std.debug.print("test: the QEMU tablet\n", .{});

    const table = hid.parse(&qemu_tablet) catch |err| {
        failures += 1;
        std.debug.print("  FAIL: parse: {s}\n", .{@errorName(err)});
        return;
    };
    check(table.kind() == .mouse, "the application is a pointer");
    check(!table.numbered(.input), "the reports are not numbered");
    checkEq(table.field_count, 2, "one button field and one axis field");
    checkEq(table.findReport(.input, 0).?.len(), 5, "the input report is 5 bytes");

    const buttons = &table.fields[0];
    checkEq(buttons.report_count, 3, "three buttons");
    checkEq(buttons.usageAt(2).id, 3, "the third button");

    const axes = &table.fields[1];
    checkEq(axes.bit_offset, 8, "the axes start after the buttons");
    check(!axes.isRelative(), "tablet coordinates are absolute");
    checkEq(axes.logical_max, 32767, "the logical maximum is 32767");
    checkEq(axes.usageAt(0).id, hid.USAGE_GD_X, "the first axis is X");
    checkEq(axes.usageAt(1).id, hid.USAGE_GD_Y, "the second axis is Y");

    // Buttons 1, X = 16384, Y = 8192 (little endian 16-bit fields).
    var report = [_]u8{ 0x01, 0x00, 0x40, 0x00, 0x20 };
    checkEq(buttons.valueAt(&report, 0).?, 1, "the left button is down");
    checkEq(axes.valueAt(&report, 0).?, 0x4000, "the X coordinate");
    checkEq(axes.valueAt(&report, 1).?, 0x2000, "the Y coordinate");
}

fn testNumberedComposite() void {
    std.debug.print("test: a numbered keyboard/mouse receiver\n", .{});

    const table = hid.parse(&numbered_composite) catch |err| {
        failures += 1;
        std.debug.print("  FAIL: parse: {s}\n", .{@errorName(err)});
        return;
    };
    check(table.kind() == .keyboard, "the keyboard half names the interface");
    check(table.numbered(.input), "the input reports carry a report ID");
    check(table.hasInputReport(1), "report ID 1 is an input report");
    check(table.hasInputReport(2), "report ID 2 is an input report");
    check(!table.hasInputReport(3), "report ID 3 is not an input report");
    checkEq(table.findReport(.input, 1).?.len(), 8, "keyboard report length");
    checkEq(table.findReport(.input, 2).?.len(), 4, "mouse report length");
    checkEq(table.maxReportLen(.input), 9, "the numbered keyboard report is 9 bytes on the wire");

    // The mouse report declares three relative axes with logical -127..127.
    const wheel_field = &table.fields[3];
    checkEq(wheel_field.usageAt(2).id, hid.USAGE_GD_WHEEL, "the third axis is the wheel");
    check(wheel_field.isRelative(), "mouse axes are relative");
    checkEq(wheel_field.logical_min, -127, "the negative logical minimum");

    var mouse_report = [_]u8{ 0x02, 0x01, 0xFF, 0xF0, 0x01 };
    const buttons = &table.fields[2];
    checkEq(buttons.valueAt(mouse_report[1..], 0).?, 1, "the left button is down");
    checkEq(wheel_field.valueAt(mouse_report[1..], 2).?, 1, "the wheel ticks up");
    checkEq(wheel_field.valueAt(mouse_report[1..], 0).?, -1, "a negative displacement");
}

fn testBitHelpers() void {
    std.debug.print("test: the bit helpers\n", .{});

    // snto32 sign-extends an n-bit value (hid-core.c:snto32).
    checkEq(hid.snto32(0xFF, 8), -1, "0xff sign-extends to -1");
    checkEq(hid.snto32(0x7F, 8), 127, "0x7f stays 127");
    checkEq(hid.snto32(0x80, 8), -128, "0x80 sign-extends to -128");
    checkEq(hid.snto32(0x3FFF, 15), 16383, "the largest positive 15-bit value");
    checkEq(hid.snto32(0x7FFF, 15), -1, "the 15-bit all-ones value");
    checkEq(hid.snto32(0, 8), 0, "zero stays zero");

    // __extract crosses a byte boundary.
    const bytes = [_]u8{ 0xAA, 0x03 };
    checkEq(hid.extractBits(&bytes, 6, 6), 0x0E, "six bits across two bytes");
    checkEq(hid.extractBits(&bytes, 0, 8), 0xAA, "one whole byte");
    checkEq(hid.extractBits(&bytes, 8, 2), 0x03, "two bits into the second byte");

    var out = [_]u8{ 0, 0 };
    hid.implementBits(&out, 6, 6, 0x0E);
    checkEq(out[0], 0x80, "the low bits land in the first byte");
    checkEq(out[1], 0x03, "the rest lands in the second byte");
    checkEq(hid.extractBits(&out, 6, 6), 0x0E, "the round trip");
}

fn testMalformed() void {
    std.debug.print("test: malformed descriptors\n", .{});

    check(hid.parse(&[_]u8{}) == error.Empty, "an empty descriptor is rejected");
    check(hid.parse(&[_]u8{ 0x05, 0x01, 0x09 }) == error.Truncated, "a truncated item is rejected");
    check(hid.parse(&[_]u8{ 0xA1, 0x01 }) == error.UnbalancedCollection, "an unclosed collection is rejected");
    check(hid.parse(&[_]u8{0xC0}) == error.UnbalancedCollection, "an extra end collection is rejected");

    // Padding at the end is not an item: a controller that returns more
    // bytes than the descriptor holds reports the rest as zeroes.
    var padded: [qemu_keyboard.len + 24]u8 = @splat(0);
    @memcpy(padded[0..qemu_keyboard.len], &qemu_keyboard);
    const table = hid.parse(&padded) catch |err| {
        failures += 1;
        std.debug.print("  FAIL: zero padded descriptor: {s}\n", .{@errorName(err)});
        return;
    };
    check(table.valid, "a zero padded descriptor parses");
    checkEq(table.field_count, 3, "the padded descriptor keeps its fields");
}

pub fn main() !void {
    std.debug.print("HID report descriptor test\n", .{});
    testQemuKeyboard();
    testQemuTablet();
    testNumberedComposite();
    testBitHelpers();
    testMalformed();

    std.debug.print("\n{d} checks, {d} failures\n", .{ checks, failures });
    if (failures != 0) std.process.exit(1);
}
