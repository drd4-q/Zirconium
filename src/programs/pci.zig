//! The `pci` shell command: what the kernel found on the bus.
//!
//! The same information `lspci` prints, and the place to look when a device
//! is not there: a display adapter that the bootloader could not drive, an
//! eGPU behind a bridge, a card whose BAR is above the identity map.

const std = @import("std");
const root = @import("root");
const vga = root.vga;
const pci = @import("../drivers/pci.zig");
const pcidisplay = @import("../drivers/video/pcidisplay.zig");

fn write(s: []const u8) void {
    vga.write(s);
}

fn writeDec(v: u64) void {
    vga.writeDec(v);
}

fn writeHex8(v: u8) void {
    const h = "0123456789ABCDEF";
    vga.putChar(h[v >> 4]);
    vga.putChar(h[v & 0xF]);
}

fn writeHex16(v: u16) void {
    writeHex8(@intCast(v >> 8));
    writeHex8(@truncate(v));
}

/// The class names of the devices the kernel is likely to meet.
fn className(cls: u8, sub: u8) []const u8 {
    if (cls == 0x03) {
        return switch (sub) {
            0x00 => "Display controller (VGA compatible)",
            0x01 => "Display controller (XGA compatible)",
            0x02 => "Display controller (3D)",
            else => "Display controller",
        };
    }
    if (cls == 0x02) return "Ethernet controller";
    if (cls == 0x01) return "SCSI controller";
    if (cls == 0x06) return "Bridge";
    if (cls == 0x0C) return "Serial bus controller";
    if (cls == 0x07) return "Communication controller";
    if (cls == 0x08) return "Generic system peripheral";
    if (cls == 0x09) return "Input device controller";
    if (cls == 0x0B) return "Processor";
    if (cls == 0x10) return "Unclassified device";
    return "Unknown";
}

pub fn run(args: []const u8) void {
    vga.setColor(.light_cyan, .black);

    const trimmed = std.mem.trim(u8, args, " \t");
    if (std.mem.eql(u8, trimmed, "display")) {
        display();
    } else {
        list();
    }

    vga.setColor(.white, .black);
}

/// Every device on the bus.
fn list() void {
    write("\n  PCI devices:\n\n");

    var i: usize = 0;
    while (i < pci.device_count) : (i += 1) {
        const d = &pci.devices[i];

        write("  ");
        writeDec(d.bus);
        write(":");
        writeDec(d.dev);
        write(".");
        writeDec(d.func);
        write("  ");
        writeHex16(d.vendor_id);
        write(":");
        writeHex16(d.device_id);
        write("  ");
        write(className(d.class, d.subclass));
        write("\n");

        // The base address registers, the way `lspci -v` prints them.
        var b: usize = 0;
        while (b < d.bars.len) : (b += 1) {
            if (d.bars[b] == 0) continue;
            write("      BAR");
            writeDec(b);
            write(": 0x");
            writeHex16(@truncate(d.bars[b] >> 16));
            writeHex16(@truncate(d.bars[b]));
            if (d.barAddress(b)) |addr| {
                write(" -> 0x");
                writeHex16(@truncate(addr >> 16));
                writeHex16(@truncate(addr));
                if (d.barPrefetchable(b)) write("  prefetchable");
            }
            write("\n");
        }
    }

    if (pci.device_count == 0) write("  (none)\n");
    write("\n");
}

/// The display adapters and what could be done with them.
fn display() void {
    write("\n  Display adapters:\n\n");
    if (pcidisplay.adapter_count == 0) {
        write("  (no PCI display adapter on the bus)\n");
        write("\n  A laptop with a discrete GPU usually has one, behind a\n");
        write("  bridge.  If the list is empty, the machine has no display\n");
        write("  adapter at all - the console is then on the chipset's\n");
        write("  legacy VGA, which an external monitor does not show.\n\n");
        return;
    }

    var i: usize = 0;
    while (i < pcidisplay.adapter_count) : (i += 1) {
        const a = &pcidisplay.adapters[i];
        write("  adapter ");
        writeDec(i);
        write(":  ");
        writeHex16(a.dev.vendor_id);
        write(":");
        writeHex16(a.dev.device_id);
        write("\n");

        if (a.bound) {
            write("    framebuffer : ");
            writeDec(a.fb_width);
            write("x");
            writeDec(a.fb_height);
            write("x");
            writeDec(a.fb_bpp);
            write(" at 0x");
            writeHex16(@truncate(a.fb_addr >> 16));
            writeHex16(@truncate(a.fb_addr));
            write("\n");
        } else {
            write("    ");
            write(a.note);
            write("\n");
        }
    }
    write("\n");
}
