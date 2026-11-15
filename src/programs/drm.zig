//! The `drm` shell command: the display stack.
//!
//! The driver underneath is the Linux DRM model - the connector, the CRTC
//! and the fbdev emulation - around the framebuffer the bootloader set up;
//! see `src/drivers/drm/`.

const std = @import("std");
const root = @import("root");
const vga = root.vga;
const drm = @import("../drivers/drm/mod.zig");

fn write(s: []const u8) void {
    vga.write(s);
}

fn writeDec(v: u64) void {
    vga.writeDec(v);
}

pub fn run(args: []const u8) void {
    vga.setColor(.light_cyan, .black);

    const trimmed = std.mem.trim(u8, args, " \t");
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const sub = it.next() orelse "info";

    if (std.mem.eql(u8, sub, "modes")) {
        modes();
    } else if (std.mem.eql(u8, sub, "edid")) {
        edid();
    } else {
        drm.printStatus(write, writeDec);
    }

    vga.setColor(.white, .black);
}

/// The modes the connector offers.
fn modes() void {
    const count = drm.connector.modeCount();
    if (count == 0) {
        write("  No modes.\n");
        return;
    }

    write("  Modes:\n");
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const mode = drm.connector.mode(i) orelse continue;
        write("    ");
        writeDec(mode.h_active);
        write("x");
        writeDec(mode.v_active);
        write(" @ ");
        writeDec(mode.refreshRate());
        write(" Hz, ");
        writeDec(mode.clock_khz);
        write(" kHz\n");
    }
}

/// The EDID of the display, decoded.
fn edid() void {
    const e = drm.connector.edid orelse {
        write("  No EDID.\n");
        return;
    };

    write("  EDID\n");
    write("    manufacturer : ");
    write(e.manufacturer[0..3]);
    write("\n    product code : ");
    writeDec(e.product_code);
    write("\n    serial       : ");
    writeDec(e.serial_number);
    write("\n    made in      : ");
    writeDec(e.year);
    write("\n    name         : ");
    write(e.name());
    write("\n    size         : ");
    writeDec(e.h_size_cm);
    write(" x ");
    writeDec(e.v_size_cm);
    write(" cm\n");
    write("    gamma        : ");
    writeDec(e.gamma);
    write("\n");
}
