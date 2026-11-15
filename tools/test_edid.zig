//! Host-side test of the EDID parser.
//!
//! The parser itself lives in `src/drivers/drm/edid.zig` and is free of any
//! kernel dependency, so this test imports the real thing rather than
//! mirroring it.
//!
//! Run it with:
//!
//!     zig run --dep edid -Mroot=tools/test_edid.zig \
//!         -Medid=src/drivers/drm/edid.zig
//!
//! The blob is the one Linux's own DRM KUnit tests use
//! (`drivers/gpu/drm/tests/drm_kunit_edid.h`), and the expected values are
//! the ones `edid-decode` prints for it, so the test checks the parser
//! against reality rather than against a copy of its own mistakes.

const std = @import("std");

// The parser is a separate module so that the test can import the real
// thing instead of a copy of it:
//
//     zig run --dep edid -Mroot=tools/test_edid.zig \
//         -Medid=src/drivers/drm/edid.zig
const edid_mod = @import("edid");

const Edid = edid_mod.Edid;
const Mode = edid_mod.Mode;

var failures: u32 = 0;
var checks: u32 = 0;

fn check(ok: bool, what: []const u8) void {
    checks += 1;
    if (ok) return;
    failures += 1;
    std.debug.print("  FAIL: {s}\n", .{what});
}

fn checkEq(got: anytype, want: anytype, what: []const u8) void {
    checks += 1;
    if (got == want) return;
    failures += 1;
    std.debug.print("  FAIL: {s}: got {any}, want {any}\n", .{ what, got, want });
}

/// The EDID from Linux's `drivers/gpu/drm/tests/drm_kunit_edid.h`.
const TEST_EDID = [_]u8{
    0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x31, 0xd8, 0x2a, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x01, 0x03, 0x81, 0xa0, 0x5a, 0x78,
    0x0a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02, 0x3a, 0x80, 0x18, 0x71, 0x38,
    0x2d, 0x40, 0x58, 0x2c, 0x45, 0x00, 0x40, 0x84, 0x63, 0x00, 0x00, 0x1e,
    0x00, 0x00, 0x00, 0xfc, 0x00, 0x54, 0x65, 0x73, 0x74, 0x20, 0x45, 0x44,
    0x49, 0x44, 0x0a, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xfd, 0x00, 0x32,
    0x46, 0x1e, 0x46, 0x0f, 0x00, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
    0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xab,
};

fn testRealEdid() void {
    std.debug.print("test: a real EDID is parsed\n", .{});

    const parsed = Edid.parse(&TEST_EDID) orelse {
        check(false, "the EDID should have been accepted");
        return;
    };

    // The identity, as edid-decode prints it.
    checkEq(@as(u8, parsed.manufacturer[0]), 'L', "the manufacturer's first letter");
    checkEq(@as(u8, parsed.manufacturer[1]), 'N', "the manufacturer's second letter");
    checkEq(@as(u8, parsed.manufacturer[2]), 'X', "the manufacturer's third letter");
    checkEq(parsed.product_code, 42, "the product code");
    checkEq(parsed.year, 2023, "the year of manufacture");
    checkEq(parsed.version, 1, "the EDID version");
    checkEq(parsed.revision, 3, "the EDID revision");
    checkEq(parsed.h_size_cm, 160, "the width in centimetres");
    checkEq(parsed.v_size_cm, 90, "the height in centimetres");
    checkEq(parsed.gamma, 220, "the gamma");
    check(parsed.digital_input, "the input is digital");
    checkEq(parsed.extension_count, 0, "the number of extension blocks");

    // The monitor's name.
    check(std.mem.eql(u8, parsed.name(), "Test EDID"), "the monitor's name");

    // The detailed timing: 1920x1080 at 60 Hz.
    checkEq(parsed.mode_count, 1, "the number of detailed timings");
    if (parsed.mode_count > 0) {
        const mode = parsed.modes[0];
        checkEq(mode.clock_khz, 148500, "the pixel clock");
        checkEq(mode.h_active, 1920, "the horizontal active pixels");
        checkEq(mode.v_active, 1080, "the vertical active pixels");
        checkEq(mode.h_sync_start, 2008, "the horizontal sync start");
        checkEq(mode.h_sync_end, 2052, "the horizontal sync end");
        checkEq(mode.h_total, 2200, "the horizontal total");
        checkEq(mode.v_sync_start, 1084, "the vertical sync start");
        checkEq(mode.v_sync_end, 1089, "the vertical sync end");
        checkEq(mode.v_total, 1125, "the vertical total");
        checkEq(mode.h_size_mm, 1600, "the width in millimetres");
        checkEq(mode.v_size_mm, 900, "the height in millimetres");
        check(!mode.interlaced, "the display is not interlaced");
        checkEq(mode.refreshRate(), 60, "the refresh rate");
    }

    // This EDID announces no established timings.
    var modes: [32]Mode = @splat(.{});
    checkEq(parsed.establishedModes(&modes), 0, "the number of established timings");
}

/// The HDMI EDID from Linux's tests: the same display, but with the
/// established timings switched on and a CTA-861 extension block.
const TEST_EDID_HDMI = [_]u8{
    0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x31, 0xd8, 0x2a, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x01, 0x03, 0x81, 0xa0, 0x5a, 0x78,
    0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20,
    0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02, 0x3a, 0x80, 0x18, 0x71, 0x38,
    0x2d, 0x40, 0x58, 0x2c, 0x45, 0x00, 0x40, 0x84, 0x63, 0x00, 0x00, 0x1e,
    0x00, 0x00, 0x00, 0xfc, 0x00, 0x54, 0x65, 0x73, 0x74, 0x20, 0x45, 0x44,
    0x49, 0x44, 0x0a, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xfd, 0x00, 0x32,
    0x46, 0x00, 0x00, 0xc4, 0x00, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
    0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x41, 0x02, 0x03, 0x1b, 0x81,
};

fn testHdmiEdid() void {
    std.debug.print("test: the HDMI EDID\n", .{});

    const parsed = Edid.parse(&TEST_EDID_HDMI) orelse {
        check(false, "the EDID should have been accepted");
        return;
    };

    checkEq(parsed.extension_count, 1, "the number of extension blocks");
    check(std.mem.eql(u8, parsed.name(), "Test EDID"), "the monitor's name");

    // The established timings: DMT 0x04, 640x480 at 59.94 Hz.
    var modes: [32]Mode = @splat(.{});
    const count = parsed.establishedModes(&modes);
    checkEq(count, 1, "the number of established timings");
    if (count > 0) {
        checkEq(modes[0].h_active, 640, "the horizontal active pixels");
        checkEq(modes[0].v_active, 480, "the vertical active pixels");
        checkEq(modes[0].clock_khz, 25175, "the pixel clock");
    }
}

fn testBadEdid() void {
    std.debug.print("test: a broken EDID is refused\n", .{});

    // A wrong header.
    var broken = TEST_EDID;
    broken[3] = 0x00;
    check(Edid.parse(&broken) == null, "an EDID with a broken header is refused");

    // A wrong checksum.
    broken = TEST_EDID;
    broken[127] +%= 1;
    check(Edid.parse(&broken) == null, "an EDID with a broken checksum is refused");

    // Too short.
    check(Edid.parse(TEST_EDID[0..64]) == null, "a short EDID is refused");

    // The good one is still accepted.
    check(Edid.parse(&TEST_EDID) != null, "the untouched EDID is accepted");
}

fn testPreferredMode() void {
    std.debug.print("test: the preferred mode is the largest one\n", .{});

    const parsed = Edid.parse(&TEST_EDID) orelse {
        check(false, "the EDID should have been accepted");
        return;
    };

    const preferred = parsed.preferredMode() orelse {
        check(false, "there should be a preferred mode");
        return;
    };
    checkEq(preferred.h_active, 1920, "the preferred mode");
    checkEq(preferred.v_active, 1080, "the preferred mode");
}

fn testManufacturerId() void {
    std.debug.print("test: the manufacturer ID\n", .{});

    const decoded = edid_mod.decodeManufacturerId(&[_]u8{ 0x31, 0xd8 });
    checkEq(@as(u8, decoded[0]), 'L', "the first letter");
    checkEq(@as(u8, decoded[1]), 'N', "the second letter");
    checkEq(@as(u8, decoded[2]), 'X', "the third letter");

    // "DEL" is the manufacturer used in the classic EDID examples.
    const del = edid_mod.decodeManufacturerId(&[_]u8{ 0x10, 0xac });
    checkEq(@as(u8, del[0]), 'D', "the first letter");
    checkEq(@as(u8, del[1]), 'E', "the second letter");
    checkEq(@as(u8, del[2]), 'L', "the third letter");
}

pub fn main() !void {
    std.debug.print("EDID parser test\n", .{});
    testRealEdid();
    testHdmiEdid();
    testBadEdid();
    testPreferredMode();
    testManufacturerId();

    std.debug.print("\n{d} checks, {d} failures\n", .{ checks, failures });
    if (failures != 0) std.process.exit(1);
}
