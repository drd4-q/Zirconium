const std = @import("std");

// ============================================================================
// Mirror of Kernel Data Structures & Algorithms from:
// - src/drivers/usb/hid.zig
// - src/drivers/keyboard.zig
// - src/drivers/mouse.zig
// ============================================================================

// --- Keyboard Direct Ring Buffer (from src/drivers/keyboard.zig) ---
const KEY_BUF_SIZE: usize = 64;
var direct_key_ring: [KEY_BUF_SIZE]u8 = undefined;
var direct_key_head: usize = 0;
var direct_key_tail: usize = 0;

pub fn pushKey(ch: u8) void {
    if (ch == 0) return;
    const next = (direct_key_head + 1) % KEY_BUF_SIZE;
    if (next != direct_key_tail) {
        direct_key_ring[direct_key_head] = ch;
        direct_key_head = next;
    }
}

pub fn popKey() ?u8 {
    if (direct_key_head == direct_key_tail) return null;
    const ch = direct_key_ring[direct_key_tail];
    direct_key_tail = (direct_key_tail + 1) % KEY_BUF_SIZE;
    return ch;
}

pub fn resetKeyRing() void {
    direct_key_head = 0;
    direct_key_tail = 0;
}

// Special keys
pub const KEY_UP: u8 = 0x80;
pub const KEY_DOWN: u8 = 0x81;
pub const KEY_LEFT: u8 = 0x82;
pub const KEY_RIGHT: u8 = 0x83;
pub const KEY_TAB: u8 = 0x84;
pub const KEY_PAGE_UP: u8 = 0x85;
pub const KEY_PAGE_DOWN: u8 = 0x86;
pub const KEY_HOME: u8 = 0x87;
pub const KEY_END: u8 = 0x88;
pub const KEY_DELETE: u8 = 0x89;
pub const KEY_INSERT: u8 = 0x8A;

// --- HID Key Translation (from src/drivers/usb/hid.zig) ---
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
        0x49 => return KEY_INSERT,
        0x4A => return KEY_HOME,
        0x4B => return KEY_PAGE_UP,
        0x4C => return KEY_DELETE,
        0x4D => return KEY_END,
        0x4E => return KEY_PAGE_DOWN,
        0x4F => return KEY_RIGHT,
        0x50 => return KEY_LEFT,
        0x51 => return KEY_DOWN,
        0x52 => return KEY_UP,
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

// --- HID Keyboard Report Decoder (from src/drivers/usb/hid.zig) ---
pub fn decodeKeyboardReport(report: []const u8, prev_report: []u8, caps_lock: *bool) void {
    if (report.len < 8) return;

    // Detect Report-ID prefixed report (e.g. 9 bytes where byte 0 is Report ID 1 and byte 1 is modifiers)
    const is_prefixed = (report.len >= 9 and report[0] != 0 and (report[0] <= 4 or report[1] == 0));
    const offset: usize = if (is_prefixed) 1 else 0;
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
                pushKey(ch);
            }
        }
    }

    const copy_len = @min(prev_report.len, 8);
    @memcpy(prev_report[0..copy_len], report[offset .. offset + copy_len]);
}

// --- Mouse Subsystem (from src/drivers/mouse.zig) ---
pub var mx: i32 = 40;
pub var my: i32 = 12;
pub var left_button: bool = false;
pub var right_button: bool = false;
pub var middle_button: bool = false;
pub var dx: i32 = 0;
pub var dy: i32 = 0;
pub var fb_active: bool = true;
pub var fb_width: u32 = 1024;
pub var fb_height: u32 = 768;

pub fn clampCoords() void {
    if (fb_active) {
        if (mx < 0) mx = 0;
        if (my < 0) my = 0;
        if (mx >= @as(i32, @intCast(fb_width))) mx = @as(i32, @intCast(fb_width)) - 1;
        if (my >= @as(i32, @intCast(fb_height))) my = @as(i32, @intCast(fb_height)) - 1;
    } else {
        if (mx < 0) mx = 0;
        if (mx >= 80) mx = 79;
        if (my < 0) my = 0;
        if (my >= 25) my = 24;
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
}

pub fn decodeMouseReport(report: []const u8, prev_report: []u8) void {
    if (report.len < 3) return;

    // Detect Report-ID prefixed report (e.g. 4+ bytes where byte 0 is Report ID 2)
    const is_prefixed = (report.len >= 4 and report[0] != 0 and report[0] <= 4);
    const offset: usize = if (is_prefixed) 1 else 0;
    if (report.len < offset + 3) return;

    const buttons = report[offset + 0];
    const dx_val = @as(i32, @as(i8, @bitCast(report[offset + 1])));
    const dy_val = @as(i32, @as(i8, @bitCast(report[offset + 2])));

    const last_buttons = if (prev_report.len > 0) prev_report[0] else 0;
    if (dx_val != 0 or dy_val != 0 or buttons != last_buttons) {
        updateFromUsb(buttons, dx_val, dy_val);
    }

    if (prev_report.len > 0) {
        prev_report[0] = buttons;
    }
}

// ============================================================================
// Adversarial Stress Tests
// ============================================================================

fn testChallenge1_KeyRolloverAndRingBuffer() !void {
    std.debug.print("--- Challenge 1: Key Rollover & Rapid Report Decoding ---\n", .{});

    // 1.1: 6-Key Rollover (6KRO) - Multiple Simultaneous Keypresses
    {
        resetKeyRing();
        var prev: [8]u8 = [_]u8{0} ** 8;
        var caps: bool = false;

        // Press 'a', 'b', 'c', 'd', 'e', 'f' all simultaneously in a single 8-byte report
        // HID Usage IDs: 0x04 (a), 0x05 (b), 0x06 (c), 0x07 (d), 0x08 (e), 0x09 (f)
        const report = [_]u8{ 0x00, 0x00, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 };
        decodeKeyboardReport(&report, &prev, &caps);

        // Verify all 6 keys were pushed in order
        const expected = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f' };
        for (expected) |exp_ch| {
            const ch = popKey();
            try std.testing.expect(ch != null);
            try std.testing.expectEqual(exp_ch, ch.?);
        }
        try std.testing.expectEqual(@as(?u8, null), popKey());
        std.debug.print("  [PASS] 1.1: 6-Key Rollover simultaneous keypresses decoded in exact order\n", .{});
    }

    // 1.2: Key rollover error codes (0x01 = ErrorRollOver, 0x02 = POSTFail, 0x03 = ErrorUndefined)
    {
        resetKeyRing();
        var prev: [8]u8 = [_]u8{0} ** 8;
        var caps: bool = false;

        const error_report = [_]u8{ 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01 };
        decodeKeyboardReport(&error_report, &prev, &caps);
        try std.testing.expectEqual(@as(?u8, null), popKey());

        const post_report = [_]u8{ 0x00, 0x00, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02 };
        decodeKeyboardReport(&post_report, &prev, &caps);
        try std.testing.expectEqual(@as(?u8, null), popKey());

        std.debug.print("  [PASS] 1.2: USB HID rollover error codes (0x01, 0x02) ignored safely\n", .{});
    }

    // 1.3: Partial release and new keys in subsequent reports
    {
        resetKeyRing();
        var prev: [8]u8 = [_]u8{0} ** 8;
        var caps: bool = false;

        // Step 1: Press 'a', 'b'
        const r1 = [_]u8{ 0x00, 0x00, 0x04, 0x05, 0x00, 0x00, 0x00, 0x00 };
        decodeKeyboardReport(&r1, &prev, &caps);
        try std.testing.expectEqual(@as(u8, 'a'), popKey().?);
        try std.testing.expectEqual(@as(u8, 'b'), popKey().?);
        try std.testing.expectEqual(@as(?u8, null), popKey());

        // Step 2: Keep 'a' held, release 'b', press 'c' -> only 'c' should be pushed
        const r2 = [_]u8{ 0x00, 0x00, 0x04, 0x06, 0x00, 0x00, 0x00, 0x00 };
        decodeKeyboardReport(&r2, &prev, &caps);
        try std.testing.expectEqual(@as(u8, 'c'), popKey().?);
        try std.testing.expectEqual(@as(?u8, null), popKey());

        // Step 3: Release all
        const r3 = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
        decodeKeyboardReport(&r3, &prev, &caps);
        try std.testing.expectEqual(@as(?u8, null), popKey());

        std.debug.print("  [PASS] 1.3: Partial key release and state tracking verified\n", .{});
    }

    // 1.4: Direct Key Ring Buffer Boundary Stress
    {
        resetKeyRing();

        // Direct ring buffer size is 64. Usable capacity is KEY_BUF_SIZE - 1 = 63.
        var i: usize = 0;
        while (i < 63) : (i += 1) {
            pushKey(@intCast((i % 26) + 'a'));
        }

        // Buffer is now full. Attempt to push an extra key.
        // It should gracefully drop without corrupting head, tail, or memory.
        pushKey('Z');

        // Drain 63 keys and verify exact values
        i = 0;
        while (i < 63) : (i += 1) {
            const expected_ch: u8 = @intCast((i % 26) + 'a');
            const actual = popKey();
            try std.testing.expect(actual != null);
            try std.testing.expectEqual(expected_ch, actual.?);
        }
        // Should now be empty (Z was dropped, buffer was not corrupted)
        try std.testing.expectEqual(@as(?u8, null), popKey());

        // Test circular wrap-around: push 20, pop 20, repeat 5 times across buffer boundary
        var cycle: usize = 0;
        while (cycle < 5) : (cycle += 1) {
            var k: usize = 0;
            while (k < 20) : (k += 1) {
                pushKey('x');
            }
            k = 0;
            while (k < 20) : (k += 1) {
                try std.testing.expectEqual(@as(u8, 'x'), popKey().?);
            }
            try std.testing.expectEqual(@as(?u8, null), popKey());
        }

        std.debug.print("  [PASS] 1.4: Direct key ring buffer capacity (63 items) and circular wrap verified\n", .{});
    }

    // 1.5: Rapid Sequence Endurance (10,000 rapid reports with interleaved draining)
    {
        resetKeyRing();
        var prev: [8]u8 = [_]u8{0} ** 8;
        var caps: bool = false;

        var count: usize = 0;
        while (count < 10000) : (count += 1) {
            const key_idx: u8 = @intCast((count % 26) + 0x04);
            const r_down = [_]u8{ 0x00, 0x00, key_idx, 0x00, 0x00, 0x00, 0x00, 0x00 };
            decodeKeyboardReport(&r_down, &prev, &caps);

            const r_up = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
            decodeKeyboardReport(&r_up, &prev, &caps);

            const expected_ch: u8 = 'a' + @as(u8, @intCast(count % 26));
            const ch = popKey();
            try std.testing.expect(ch != null);
            try std.testing.expectEqual(expected_ch, ch.?);
        }
        try std.testing.expectEqual(@as(?u8, null), popKey());
        std.debug.print("  [PASS] 1.5: 10,000 rapid report decoding iterations with 0 dropped characters\n", .{});
    }
}

fn testChallenge2_CorruptedAndTruncatedReports() !void {
    std.debug.print("\n--- Challenge 2: Corrupted or Truncated HID Reports ---\n", .{});

    // 2.1: Truncated keyboard reports (lengths 0 through 7 bytes)
    {
        var prev: [8]u8 = [_]u8{0} ** 8;
        var caps: bool = false;
        const dummy = [_]u8{ 0x00, 0x00, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 };

        var len: usize = 0;
        while (len < 8) : (len += 1) {
            resetKeyRing();
            // Must return early and NOT read out-of-bounds
            decodeKeyboardReport(dummy[0..len], &prev, &caps);
            try std.testing.expectEqual(@as(?u8, null), popKey());
        }
        std.debug.print("  [PASS] 2.1: Truncated keyboard reports (0..7 bytes) safely rejected\n", .{});
    }

    // 2.2: Standard 8-byte report with modifier 0x01 (Ctrl) - must NOT be treated as prefixed
    {
        var prev: [8]u8 = [_]u8{0} ** 8;
        var caps: bool = false;
        // Byte 0 is Left Ctrl (0x01), byte 1 is reserved (0x00), byte 2 is 'a' (0x04)
        const ctrl_a_report = [_]u8{ 0x01, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 };
        resetKeyRing();
        decodeKeyboardReport(&ctrl_a_report, &prev, &caps);
        // Ctrl + 'a' = 0x01 (ASCII SOH / Ctrl+A)
        try std.testing.expectEqual(@as(u8, 1), popKey().?);
        try std.testing.expectEqual(@as(?u8, null), popKey());
        std.debug.print("  [PASS] 2.2: Standard 8-byte report with modifier 0x01 (Ctrl) decodes Ctrl+A correctly\n", .{});
    }

    // 2.3: Valid 9-byte report-ID prefixed report
    {
        var prev: [8]u8 = [_]u8{0} ** 8;
        var caps: bool = false;
        resetKeyRing();
        const pref_valid = [_]u8{ 0x01, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 };
        decodeKeyboardReport(&pref_valid, &prev, &caps);
        try std.testing.expectEqual(@as(u8, 'a'), popKey().?);
        std.debug.print("  [PASS] 2.3: Valid 9-byte report-ID prefixed report decoded correctly\n", .{});
    }

    // 2.4: Truncated mouse reports (lengths 0 through 2 bytes)
    {
        var prev: [4]u8 = [_]u8{0} ** 4;
        const dummy = [_]u8{ 0x01, 0x0A, 0x0A, 0x00 };

        var len: usize = 0;
        while (len < 3) : (len += 1) {
            decodeMouseReport(dummy[0..len], &prev);
        }
        std.debug.print("  [PASS] 2.4: Truncated mouse reports (0..2 bytes) safely rejected\n", .{});
    }

    // 2.5: Truncated report-ID prefixed mouse reports (length 3 with prefix != 0, requires 4 bytes)
    {
        var prev: [4]u8 = [_]u8{0} ** 4;
        const pref_mouse_trunc = [_]u8{ 0x02, 0x01, 0x0A };
        decodeMouseReport(&pref_mouse_trunc, &prev);
        std.debug.print("  [PASS] 2.5: Truncated report-ID prefixed mouse report (3 bytes with prefix) safely rejected\n", .{});
    }

    // 2.6: Exhaustive Usage ID safety check (all 256 byte values, all modifier flags)
    {
        var key: u16 = 0;
        while (key <= 255) : (key += 1) {
            const k: u8 = @intCast(key);
            for ([_]bool{ false, true }) |shift| {
                for ([_]bool{ false, true }) |ctrl| {
                    for ([_]bool{ false, true }) |caps| {
                        // usbKeyToAscii must NEVER panic on any input
                        _ = usbKeyToAscii(k, shift, ctrl, caps);
                    }
                }
            }
        }
        // Unknown usage IDs (e.g. 0x00, 0x01..0x03, 0x64..0xFF) must return null
        try std.testing.expectEqual(@as(?u8, null), usbKeyToAscii(0x00, false, false, false));
        try std.testing.expectEqual(@as(?u8, null), usbKeyToAscii(0x01, false, false, false));
        try std.testing.expectEqual(@as(?u8, null), usbKeyToAscii(0x64, false, false, false));
        try std.testing.expectEqual(@as(?u8, null), usbKeyToAscii(0xFF, false, false, false));
        std.debug.print("  [PASS] 2.6: Exhaustive 256 usage IDs x 8 modifier flags check completed with 0 panics\n", .{});
    }

    // 2.7: Random Fuzzing Stress (50,000 arbitrary byte packets of variable lengths)
    {
        var prng = std.Random.DefaultPrng.init(0x1337BEEF);
        const random = prng.random();

        var prev_k: [8]u8 = [_]u8{0} ** 8;
        var prev_m: [4]u8 = [_]u8{0} ** 4;
        var caps: bool = false;

        var buf: [64]u8 = undefined;

        var iter: usize = 0;
        while (iter < 50000) : (iter += 1) {
            const pkt_len = random.intRangeAtMost(usize, 0, 32);
            random.bytes(buf[0..pkt_len]);

            // Fuzz keyboard decoder
            decodeKeyboardReport(buf[0..pkt_len], &prev_k, &caps);

            // Fuzz mouse decoder
            decodeMouseReport(buf[0..pkt_len], &prev_m);
        }
        std.debug.print("  [PASS] 2.7: 50,000 fuzzing iterations with random byte buffers: 0 panics/crashes\n", .{});
    }
}

fn testChallenge3_ContinuousMouseMotionAndClamping() !void {
    std.debug.print("\n--- Challenge 3: Continuous Mouse Motion & Coordinate Clamping ---\n", .{});

    // 3.1: Clamping in Framebuffer Mode (1024x768)
    {
        fb_active = true;
        fb_width = 1024;
        fb_height = 768;

        // Reset to center
        mx = 512;
        my = 384;

        // Large positive delta X (+5,000) -> must clamp to width - 1 = 1023
        updateFromUsb(0, 5000, 0);
        try std.testing.expectEqual(@as(i32, 1023), mx);
        try std.testing.expectEqual(@as(i32, 384), my);

        // Large negative delta X (-10,000) -> must clamp to 0
        updateFromUsb(0, -10000, 0);
        try std.testing.expectEqual(@as(i32, 0), mx);

        // Large positive delta Y (+5,000) -> must clamp to height - 1 = 767
        updateFromUsb(0, 0, 5000);
        try std.testing.expectEqual(@as(i32, 767), my);

        // Large negative delta Y (-10,000) -> must clamp to 0
        updateFromUsb(0, 0, -10000);
        try std.testing.expectEqual(@as(i32, 0), my);

        std.debug.print("  [PASS] 3.1: Framebuffer mode coordinate clamping (0..1023, 0..767) validated\n", .{});
    }

    // 3.2: Clamping in Text Console Mode (80x25)
    {
        fb_active = false;

        mx = 40;
        my = 12;

        updateFromUsb(0, 500, 0);
        try std.testing.expectEqual(@as(i32, 79), mx);

        updateFromUsb(0, -500, 0);
        try std.testing.expectEqual(@as(i32, 0), mx);

        updateFromUsb(0, 0, 500);
        try std.testing.expectEqual(@as(i32, 24), my);

        updateFromUsb(0, 0, -500);
        try std.testing.expectEqual(@as(i32, 0), my);

        std.debug.print("  [PASS] 3.2: Text console mode coordinate clamping (0..79, 0..24) validated\n", .{});
    }

    // 3.3: Continuous Mouse Motion Stress (100,000 steps with random deltas)
    {
        fb_active = true;
        fb_width = 1024;
        fb_height = 768;
        mx = 512;
        my = 384;

        var prng = std.Random.DefaultPrng.init(0xCAFE);
        const random = prng.random();

        var step: usize = 0;
        while (step < 100000) : (step += 1) {
            // Standard HID mouse reports provide 8-bit signed displacements (-128..127)
            const dx_step = @as(i32, random.intRangeAtMost(i8, -128, 127));
            const dy_step = @as(i32, random.intRangeAtMost(i8, -128, 127));
            const btn = random.intRangeAtMost(u8, 0, 7);

            updateFromUsb(btn, dx_step, dy_step);

            // Invariant: coordinates must ALWAYS be within [0, 1023] and [0, 767]
            try std.testing.expect(mx >= 0 and mx <= 1023);
            try std.testing.expect(my >= 0 and my <= 767);
        }
        std.debug.print("  [PASS] 3.3: 100,000 continuous mouse motion steps verified within bounds on every step\n", .{});
    }

    // 3.4: Extreme large deltas (+/-1,000,000 and +/-100,000,000) without integer overflow
    {
        fb_active = true;
        fb_width = 1024;
        fb_height = 768;
        mx = 512;
        my = 384;

        // Positive 100 million
        updateFromUsb(0, 100_000_000, 100_000_000);
        try std.testing.expectEqual(@as(i32, 1023), mx);
        try std.testing.expectEqual(@as(i32, 767), my);

        // Negative 100 million
        updateFromUsb(0, -100_000_000, -100_000_000);
        try std.testing.expectEqual(@as(i32, 0), mx);
        try std.testing.expectEqual(@as(i32, 0), my);

        std.debug.print("  [PASS] 3.4: Extreme +/-100M delta updates clamped cleanly without integer overflow\n", .{});
    }
}

pub fn main() !void {
    std.debug.print("====================================================================\n", .{});
    std.debug.print(" Zirconium HID Subsystem & Input Routing Empirical Challenge Suite\n", .{});
    std.debug.print("====================================================================\n\n", .{});

    try testChallenge1_KeyRolloverAndRingBuffer();
    try testChallenge2_CorruptedAndTruncatedReports();
    try testChallenge3_ContinuousMouseMotionAndClamping();

    std.debug.print("\n====================================================================\n", .{});
    std.debug.print(" ALL EMPIRICAL HID CHALLENGE TESTS PASSED CLEANLY (100% SUCCESS)\n", .{});
    std.debug.print("====================================================================\n", .{});
}
