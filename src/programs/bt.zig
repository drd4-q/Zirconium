//! The `bt` shell command: the Bluetooth controllers and the devices they see.
//!
//! The driver underneath is the Linux Bluetooth stack's HCI core and its USB
//! transport; see `src/drivers/bluetooth/`.

const std = @import("std");
const root = @import("root");
const vga = root.vga;
const bt = @import("../drivers/bluetooth/mod.zig");

fn write(s: []const u8) void {
    vga.write(s);
}

fn writeDec(v: u64) void {
    vga.writeDec(v);
}

fn printAddress(addr: bt.BdAddr) void {
    var buf: [32]u8 = undefined;
    vga.write(bt.Hci.formatBdAddr(addr, &buf));
}

pub fn run(args: []const u8) void {
    vga.setColor(.light_cyan, .black);

    const trimmed = std.mem.trim(u8, args, " \t");
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const sub = it.next() orelse "list";

    if (std.mem.eql(u8, sub, "scan")) {
        scan(&it);
    } else if (std.mem.eql(u8, sub, "info")) {
        info();
    } else {
        list();
    }

    vga.setColor(.white, .black);
}

/// List the controllers.
fn list() void {
    const count = bt.controllerCount();
    if (count == 0) {
        write("  No Bluetooth controllers.\n");
        return;
    }

    write("  Bluetooth controllers:\n");
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const c = bt.controller(i) orelse continue;
        write("    ");
        writeDec(i);
        write("  ");
        write(bt.controllerName(i));
        write("  state=");
        write(@tagName(c.state));
        write("  address=");
        printAddress(c.addr);
        write("\n");
    }
}

/// The details of every controller.
fn info() void {
    const count = bt.controllerCount();
    if (count == 0) {
        write("  No Bluetooth controllers.\n");
        return;
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const c = bt.controller(i) orelse continue;
        write("  Controller ");
        writeDec(i);
        write(" (");
        write(bt.controllerName(i));
        write(")\n");
        write("    state        : ");
        write(@tagName(c.state));
        write("\n");
        write("    address      : ");
        printAddress(c.addr);
        write("\n");
        write("    HCI version  : ");
        writeDec(c.version.hci_version);
        write("\n");
        write("    manufacturer : ");
        vga.writeHex(c.version.manufacturer);
        write("\n");
        write("    peers        : ");
        writeDec(c.peer_count);
        write("\n");
    }
}

/// Run an inquiry and print the devices that answer.
fn scan(it: *std.mem.TokenIterator(u8, .any)) void {
    var index: usize = 0;
    if (it.next()) |arg| {
        index = std.fmt.parseInt(usize, arg, 10) catch 0;
    }

    const c = bt.controller(index) orelse {
        write("  No such controller.\n");
        return;
    };

    if (c.state != .up) {
        write("  The controller is not up.\n");
        return;
    }

    write("  Scanning for nearby devices...\n");
    if (!bt.scan(index)) {
        write("  The inquiry could not be started.\n");
        return;
    }

    // The events arrive on the interrupt endpoint, so the stack has to be
    // polled while the inquiry runs.
    var guard: usize = 0;
    while (guard < 200 and !c.inquiry_done) : (guard += 1) {
        bt.poll();
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            asm volatile ("pause" ::: .{ .memory = true });
        }
    }

    write("  Found ");
    writeDec(c.peer_count);
    write(" device(s):\n");

    var i: usize = 0;
    while (i < c.peer_count) : (i += 1) {
        const peer = &c.peers[i];
        write("    ");
        printAddress(peer.addr);
        write("\n");
    }
}
