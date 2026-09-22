const std = @import("std");
const root = @import("root");
const vga = root.vga;
const usb = @import("../drivers/usb.zig");
const net = @import("../net/mod.zig");

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

pub fn runStorage() void {
    vga.setColor(.light_cyan, .black);
    usb.storage.printStatus(vgaWrite, vgaWriteDec, vgaWriteHex);
    vga.setColor(.white, .black);
}

pub fn runWifi() void {
    vga.setColor(.light_cyan, .black);

    if (usb.rtl8188eu.initialized) {
        usb.rtl8188eu.printStatus(vgaWrite, vgaWriteDec, vgaWriteHex);
    } else {
        vga.write("  No Realtek USB Wi-Fi adapter detected.\n");
        vga.write("  Supported: RTL8188EU (VID=0x0BDA PID=0x8179)\n");
        vga.write("              RTL8192CU (VID=0x0BDA PID=0x8178)\n\n");
    }

    // Show current network interface info
    vga.write("  Active NIC: ");
    switch (net.active_nic) {
        .e1000 => vga.write("e1000"),
        .rtl8169 => vga.write("RTL8168/8169"),
        .usb_wifi => vga.write("USB Wi-Fi"),
        .none => vga.write("none"),
    }
    vga.write("\n");

    if (net.hasNic()) {
        vga.write("  IP: ");
        vga.writeDec(net.our_ip[0]);
        vga.putChar('.');
        vga.writeDec(net.our_ip[1]);
        vga.putChar('.');
        vga.writeDec(net.our_ip[2]);
        vga.putChar('.');
        vga.writeDec(net.our_ip[3]);
        vga.write("\n  GW: ");
        vga.writeDec(net.gateway_ip[0]);
        vga.putChar('.');
        vga.writeDec(net.gateway_ip[1]);
        vga.putChar('.');
        vga.writeDec(net.gateway_ip[2]);
        vga.putChar('.');
        vga.writeDec(net.gateway_ip[3]);
        vga.write("\n  MAC: ");
        for (0..6) |i| {
            if (i > 0) vga.putChar(':');
            vga.writeHex(net.our_mac[i]);
        }
        vga.write("\n\n");
    } else {
        vga.write("  No active NIC.\n\n");
    }

    vga.setColor(.white, .black);
}
