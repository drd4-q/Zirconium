//! Host-side test of the HID++ protocol.
//!
//! The protocol lives in `src/drivers/hid/hidpp_proto.zig` and is free of
//! kernel dependencies, so this test imports the real thing.
//!
//! Run it with:
//!
//!     zig run --dep hidpp -Mroot=tools/test_hidpp.zig \
//!         -Mhidpp=src/drivers/hid/hidpp_proto.zig

const std = @import("std");

const hidpp = @import("hidpp");

var failures: u32 = 0;
var checks: u32 = 0;

fn checkEq(got: anytype, want: anytype, what: []const u8) void {
    checks += 1;
    if (got == want) return;
    failures += 1;
    std.debug.print("  FAIL: {s}: got {any}, want {any}\n", .{ what, got, want });
}

fn check(ok: bool, what: []const u8) void {
    checks += 1;
    if (ok) return;
    failures += 1;
    std.debug.print("  FAIL: {s}\n", .{what});
}

fn testShortReport() void {
    std.debug.print("test: the short report\n", .{});

    // A short report: the report ID, the device index, the feature index,
    // the function and the parameter index, the software ID and two
    // parameter bytes.
    const bytes = [_]u8{ 0x10, 0x01, 0x05, 0x00, 0x00, 0xAB, 0xCD };
    const report = hidpp.Report.parse(&bytes) orelse {
        check(false, "the report should have been parsed");
        return;
    };

    checkEq(report.report_id, hidpp.REPORT_ID_SHORT, "the report ID");
    checkEq(report.device_index, 1, "the device index");
    checkEq(report.feature_index, 5, "the feature index");
    checkEq(report.function, 0, "the function");
    checkEq(report.parameter_index, 0, "the parameter index");
    checkEq(report.param_len, 2, "the number of parameters");
    checkEq(report.params[0], 0xAB, "the first parameter");
    checkEq(report.params[1], 0xCD, "the second parameter");
}

fn testLongReport() void {
    std.debug.print("test: the long report\n", .{});

    var bytes: [hidpp.LONG_LENGTH]u8 = @splat(0);
    bytes[0] = hidpp.REPORT_ID_LONG;
    bytes[1] = 0x02; // the device index
    bytes[2] = 0x07; // the feature index
    bytes[3] = 0x31; // the function 3, the parameter index 1
    bytes[10] = 0x42;
    bytes[11] = 0x43;

    const report = hidpp.Report.parse(&bytes) orelse {
        check(false, "the report should have been parsed");
        return;
    };

    checkEq(report.report_id, hidpp.REPORT_ID_LONG, "the report ID");
    checkEq(report.device_index, 2, "the device index");
    checkEq(report.feature_index, 7, "the feature index");
    checkEq(report.function, 3, "the function");
    checkEq(report.parameter_index, 1, "the parameter index");
    checkEq(report.param_len, 10, "the number of parameters");
    checkEq(report.params[0], 0x42, "the first parameter");
}

fn testRejectsOtherReports() void {
    std.debug.print("test: other reports are refused\n", .{});

    // A boot protocol report is not a HID++ report.
    const boot = [_]u8{ 0x05, 0x01, 0x02, 0x03 };
    check(hidpp.Report.parse(&boot) == null, "a boot report is refused");

    // A short report that is too short.
    const short = [_]u8{ 0x10, 0x01 };
    check(hidpp.Report.parse(&short) == null, "a truncated report is refused");
}

fn testRequests() void {
    std.debug.print("test: the requests\n", .{});

    // The request for the index of a feature: the root feature, the
    // "get the feature index" function and the feature ID as a parameter.
    var buf: [hidpp.SHORT_LENGTH]u8 = @splat(0);
    const len = hidpp.featureIndexRequest(&buf, 1, 0x1000) orelse {
        check(false, "the request should have been built");
        return;
    };
    checkEq(len, hidpp.SHORT_LENGTH, "the length of the request");
    checkEq(buf[0], hidpp.REPORT_ID_SHORT, "the report ID");
    checkEq(buf[1], 1, "the device index");
    checkEq(buf[2], 0x00, "the root feature");
    checkEq(buf[3] >> 4, hidpp.RootFunction.get_feature_index, "the function");
    checkEq(buf[5], 0x00, "the low byte of the feature ID");
    checkEq(buf[6], 0x10, "the high byte of the feature ID");

    // The request for the battery level.
    const blen = hidpp.batteryRequest(&buf, 0, 0x04) orelse {
        check(false, "the request should have been built");
        return;
    };
    checkEq(blen, hidpp.SHORT_LENGTH, "the length of the request");
    checkEq(buf[2], 0x04, "the feature index");
    checkEq(buf[3] >> 4, hidpp.BatteryFunction.get_battery_level, "the function");

    // The request that sets the LED state.
    const llen = hidpp.ledRequest(&buf, 0, 0x06, hidpp.Led.caps_lock) orelse {
        check(false, "the request should have been built");
        return;
    };
    checkEq(llen, hidpp.SHORT_LENGTH, "the length of the request");
    checkEq(buf[3] >> 4, hidpp.LedFunction.set_led_state, "the function");
    checkEq(buf[5], hidpp.Led.caps_lock, "the LED state");
}

fn testFeatureTable() void {
    std.debug.print("test: the feature table\n", .{});

    var table = hidpp.FeatureTable{};
    check(table.indexOf(hidpp.Feature.battery) == null, "an empty table knows nothing");

    table.set(hidpp.Feature.battery, 4);
    table.set(hidpp.Feature.led_state, 6);
    checkEq(table.indexOf(hidpp.Feature.battery).?, 4, "the index of the battery feature");
    checkEq(table.indexOf(hidpp.Feature.led_state).?, 6, "the index of the LED feature");
    checkEq(table.featureOfIndex(6).?, hidpp.Feature.led_state, "the feature of an index");

    // The answer to "what is the index of this feature" carries the index
    // in its first parameter byte.
    var bytes: [hidpp.LONG_LENGTH]u8 = @splat(0);
    bytes[0] = hidpp.REPORT_ID_LONG;
    bytes[1] = 0; // the device index
    bytes[2] = 0; // the root feature
    bytes[3] = 0x00; // the function "get the feature index"
    bytes[10] = 0x04; // the index of the feature
    bytes[11] = 0x00; // the low byte of the feature ID
    bytes[12] = 0x10; // the high byte of the feature ID

    const report = hidpp.Report.parse(&bytes).?;
    checkEq(report.function, hidpp.RootFunction.get_feature_index, "the function");
    const feature_id = @as(u16, report.params[1]) | (@as(u16, report.params[2]) << 8);
    checkEq(feature_id, hidpp.Feature.battery, "the feature ID of the answer");
}

fn testNameAndBattery() void {
    std.debug.print("test: the name and the battery\n", .{});

    // The battery level: the first parameter of the answer.
    var bytes: [hidpp.LONG_LENGTH]u8 = @splat(0);
    bytes[0] = hidpp.REPORT_ID_LONG;
    bytes[2] = 0x04;
    bytes[3] = hidpp.BatteryFunction.get_battery_level << 4;
    bytes[10] = 87; // the battery level
    const report = hidpp.Report.parse(&bytes).?;
    checkEq(hidpp.batteryLevel(report).?, 87, "the battery level");

    // The name comes in parts of four bytes.
    var name: [32]u8 = @splat(0);
    var used: usize = 0;

    var part: [hidpp.LONG_LENGTH]u8 = @splat(0);
    part[0] = hidpp.REPORT_ID_LONG;
    part[2] = 0x05;
    part[3] = (hidpp.NameFunction.get_name << 4) | 0;
    @memcpy(part[10..14], "Zirc");

    var r = hidpp.Report.parse(&part).?;
    hidpp.appendName(&name, &used, r);
    checkEq(used, 4, "the length of the name so far");
    check(std.mem.eql(u8, name[0..4], "Zirc"), "the first part of the name");

    // The second part.
    part[3] = (hidpp.NameFunction.get_name << 4) | 1;
    @memcpy(part[10..14], "oniu");
    r = hidpp.Report.parse(&part).?;
    hidpp.appendName(&name, &used, r);
    checkEq(used, 8, "the length of the name so far");
    check(std.mem.eql(u8, name[0..8], "Zirconiu"), "the name so far");
}

pub fn main() !void {
    std.debug.print("HID++ protocol test\n", .{});
    testShortReport();
    testLongReport();
    testRejectsOtherReports();
    testRequests();
    testFeatureTable();
    testNameAndBattery();

    std.debug.print("\n{d} checks, {d} failures\n", .{ checks, failures });
    if (failures != 0) std.process.exit(1);
}
