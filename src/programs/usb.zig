const std = @import("std");
const root = @import("root");
const vga = root.vga;
const usb = @import("../drivers/usb.zig");

fn vgaWrite(s: []const u8) void {
    vga.write(s);
}

fn vgaWriteDec(v: u64) void {
    vga.writeDec(v);
}

fn vgaWriteHex(v: u64) void {
    vga.writeHex(v);
}

pub fn run() void {
    vga.setColor(.light_cyan, .black);
    usb.printUsbStatus(vgaWrite, vgaWriteDec, vgaWriteHex);
    vga.setColor(.white, .black);
}
