const root = @import("root");
const vga = root.vga;
const fb = @import("../system/framebuffer.zig");
const serial = root.serial;

/// Shell entry point: `screen [info|redraw|refresh|clear]`.
pub fn run(args: []const u8) void {
    if (!vga.isFbActive()) {
        vga.setColor(.light_red, .black);
        vga.write("\n  No framebuffer: VGA text mode only.\n");
        vga.write("  Pick a graphics entry in the boot menu for a real mode.\n\n");
        vga.setColor(.white, .black);
        return;
    }

    var cmd = trim(args);
    if (cmd.len == 0) cmd = "info";

    if (eq(cmd, "info") or eq(cmd, "status")) {
        printInfo();
    } else if (eq(cmd, "redraw") or eq(cmd, "repaint")) {
        redrawConsole();
    } else if (eq(cmd, "refresh") or eq(cmd, "flush")) {
        refreshScreen();
    } else if (eq(cmd, "clear") or eq(cmd, "cls")) {
        vga.clear();
        vga.setColor(.light_green, .black);
        vga.write("  Screen cleared and flushed.\n\n");
        vga.setColor(.white, .black);
    } else if (eq(cmd, "test") or eq(cmd, "bars") or eq(cmd, "pattern")) {
        // Raw-LFB colour bars, bypassing the shadow buffer.  If the screen stays
        // black but the serial log says every probe read back OK, the buffer is
        // writable and the hardware simply is not scanning it out.
        // The message goes out first: any later vga.write triggers a full-shadow
        // flush that would paint over the bars.
        vga.setColor(.light_green, .black);
        vga.write("  Colour bars written to the LFB; see the log for readback.\n\n");
        vga.setColor(.white, .black);
        fb.testPattern();
    } else {
        vga.setColor(.light_red, .black);
        vga.write("\n  Unknown subcommand '");
        vga.write(cmd);
        vga.write("'\n");
        vga.setColor(.white, .black);
        printUsage();
    }
}

fn printUsage() void {
    vga.write("  Usage: screen [info|redraw|refresh|clear|test]\n");
    vga.write("    info     Framebuffer geometry, pitch, grid, shadow state\n");
    vga.write("    redraw   Repaint the text console from its mirror\n");
    vga.write("    refresh  Force a full-shadow -> LFB flush\n");
    vga.write("    clear    Clear the screen\n");
    vga.write("    test     Raw-LFB colour bars + readback (diagnoses a black screen)\n\n");
}

fn printInfo() void {
    vga.setColor(.cyan, .black);
    vga.write("\n  === Screen ===\n\n");
    vga.setColor(.white, .black);

    vga.write("  Mode:      ");
    vga.writeDec(fb.boot_width);
    vga.write("x");
    vga.writeDec(fb.boot_height);
    vga.write("x");
    vga.writeDec(fb.fb_bpp);
    vga.write("  (set by the boot menu)\n");

    vga.write("  LFB:       0x");
    vga.writeHex(fb.fb_addr);
    vga.write("  pitch=");
    vga.writeDec(fb.boot_pitch);
    vga.write("  stride=");
    vga.writeDec(fb.bytesPerPixel());
    vga.write("B  type=");
    vga.writeDec(fb.fb_type);
    vga.write("\n");

    vga.write("  Viewport:  ");
    vga.writeDec(fb.fb_width);
    vga.write("x");
    vga.writeDec(fb.fb_height);
    if (fb.viewport_scaled) {
        vga.setColor(.yellow, .black);
        vga.write("  (scaled inside the boot mode)");
    }
    vga.setColor(.white, .black);
    vga.write("\n");

    vga.write("  Text grid: ");
    vga.writeDec(fb.cols);
    vga.write("x");
    vga.writeDec(fb.rows);
    vga.write(" cells (");
    vga.writeDec(fb.char_w);
    vga.write("x");
    vga.writeDec(fb.char_h);
    vga.write(" px)\n");

    vga.setColor(.light_green, .black);
    vga.write("  Text area: ");
    vga.setColor(.white, .black);
    vga.writeDec(@as(u32, @intCast(fb.cols * fb.char_w)));
    vga.write("x");
    vga.writeDec(@as(u32, @intCast(fb.rows * fb.char_h)));
    vga.write(" px");
    if (fb.fb_width > fb.cols * fb.char_w or fb.fb_height > fb.rows * fb.char_h) {
        vga.setColor(.yellow, .black);
        vga.write("  (rest of the screen is background)");
    }
    vga.setColor(.white, .black);
    vga.write("\n\n");

    vga.setColor(.white, .black);
    vga.write("  Real hardware modes are chosen in the boot menu:\n");
    vga.write("    \"keep current mode\" - reuse whatever is already set\n");
    vga.write("    \"1024x768x32\"       - deterministic\n");
    vga.write("    \"native / high\"     - longest 32bpp chain first\n");
    vga.write("    \"VGA text\"          - Legacy fallback (invisible under UEFI)\n");
    vga.write("  The kernel has no runtime VBE mode setter yet, so\n");
    vga.write("  `resolution` only rescales the viewport inside this mode.\n\n");
    vga.write("  Usage: screen [info|redraw|refresh|clear]\n\n");
}

fn redrawConsole() void {
    fb.redrawAllText();
    vga.setColor(.light_green, .black);
    vga.write("  Console repainted from the screen mirror.\n\n");
    vga.setColor(.white, .black);
    logEvent("redraw");
}

fn refreshScreen() void {
    // Force the whole viewport out of the shadow buffer, even when nothing
    // marked itself dirty (e.g. a program scribbled on the LFB directly).
    fb.markDirtyRect(0, 0, fb.fb_width, fb.fb_height);
    fb.flush();
    vga.setColor(.light_green, .black);
    vga.write("  Full framebuffer refresh done.\n\n");
    vga.setColor(.white, .black);
    logEvent("refresh");
}

fn logEvent(what: []const u8) void {
    serial.serialWrite("[SCREEN] ");
    serial.serialWrite(what);
    serial.serialWrite(" ");
    serial.serialWriteDec(fb.fb_width);
    serial.serialWrite("x");
    serial.serialWriteDec(fb.fb_height);
    serial.serialWrite(" (boot ");
    serial.serialWriteDec(fb.boot_width);
    serial.serialWrite("x");
    serial.serialWriteDec(fb.boot_height);
    serial.serialWrite(")\n");
}

// ---- small string helpers (kernel has no std) ----

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    return s[start..end];
}

fn eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lx = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const ly = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (lx != ly) return false;
    }
    return true;
}
