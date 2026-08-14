const std = @import("std");
const root = @import("root");
const vga = root.vga;
const serial = @import("../system/serial.zig");
const pci = @import("pci.zig");

pub const UsbControllerType = enum(u8) {
    uhci = 0x00,
    ohci = 0x10,
    ehci = 0x20,
    xhci = 0x30,

    pub fn name(self: UsbControllerType) []const u8 {
        return switch (self) {
            .uhci => "UHCI (USB 1.1)",
            .ohci => "OHCI (USB 1.1)",
            .ehci => "EHCI (USB 2.0)",
            .xhci => "xHCI (USB 3.0)",
        };
    }
};

pub const UsbDeviceClass = enum(u8) {
    per_interface = 0x00,
    audio = 0x01,
    cdc = 0x02,
    hid = 0x03,
    physical = 0x05,
    image = 0x06,
    printer = 0x07,
    mass_storage = 0x08,
    hub = 0x09,
    vendor_specific = 0xFF,

    pub fn name(self: UsbDeviceClass) []const u8 {
        return switch (self) {
            .per_interface => "Device (Defined at Interface level)",
            .audio => "Audio Device",
            .cdc => "Communications Device (CDC)",
            .hid => "HID (Keyboard / Mouse / Gamepad)",
            .physical => "Physical Device",
            .image => "Imaging Device (Camera / Scanner)",
            .printer => "Printer",
            .mass_storage => "Mass Storage (USB Drive / Disk)",
            .hub => "USB Hub",
            .vendor_specific => "Vendor Specific",
        };
    }
};

pub const UsbPortStatus = struct {
    port: u8,
    connected: bool,
    enabled: bool,
    speed: []const u8,
    device_desc: []const u8,
};

pub const UsbController = struct {
    ctrl_type: UsbControllerType,
    bus: u8,
    dev: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    io_base: u16,
    mmio_base: usize,
    irq: u8,
    num_ports: u8,
    ports: [8]UsbPortStatus,
};

pub const MAX_USB_CONTROLLERS: usize = 4;
pub var controllers: [MAX_USB_CONTROLLERS]UsbController = undefined;
pub var controller_count: usize = 0;
var initialized: bool = false;

fn inw(port: u16) u16 {
    return asm volatile ("inw %%dx, %%ax" : [result] "={ax}" (-> u16), : [port] "{dx}" (port));
}

fn outw(port: u16, val: u16) void {
    asm volatile ("outw %%ax, %%dx" : : [val] "{ax}" (val), [port] "{dx}" (port));
}

pub fn init() void {
    if (initialized) return;
    controller_count = 0;

    serial.serialWrite("[USB] Scanning PCI for USB host controllers...\n");

    for (pci.devices[0..pci.device_count]) |dev| {
        if (dev.class == 0x0C and dev.subclass == 0x03) {
            if (controller_count >= MAX_USB_CONTROLLERS) break;

            const ctype: UsbControllerType = switch (dev.prog_if) {
                0x00 => .uhci,
                0x10 => .ohci,
                0x20 => .ehci,
                0x30 => .xhci,
                else => .uhci,
            };

            var ctrl = &controllers[controller_count];
            ctrl.ctrl_type = ctype;
            ctrl.bus = dev.bus;
            ctrl.dev = dev.dev;
            ctrl.func = dev.func;
            ctrl.vendor_id = dev.vendor_id;
            ctrl.device_id = dev.device_id;
            ctrl.irq = dev.irq;
            ctrl.num_ports = 0;

            if (ctype == .uhci) {
                // In UHCI, I/O base is at BAR4 (offset 0x20)
                const bar4 = pci.readBar(dev.bus, dev.dev, dev.func, 4);
                ctrl.io_base = @intCast(bar4 & 0xFFFC);
                ctrl.mmio_base = 0;
                ctrl.num_ports = 2;

                // Inspect UHCI root ports (PORTSC1 at io_base + 0x10, PORTSC2 at io_base + 0x12)
                if (ctrl.io_base != 0) {
                    var p: u8 = 0;
                    while (p < ctrl.num_ports) : (p += 1) {
                        const port_reg = ctrl.io_base + 0x10 + (@as(u16, p) * 2);
                        const status = inw(port_reg);
                        const connected = (status & 0x01) != 0;
                        const enabled = (status & 0x04) != 0;
                        const low_speed = (status & 0x0100) != 0;

                        ctrl.ports[p] = .{
                            .port = p + 1,
                            .connected = connected,
                            .enabled = enabled,
                            .speed = if (low_speed) "Low-Speed (1.5 Mbps)" else "Full-Speed (12 Mbps)",
                            .device_desc = if (connected) (if (low_speed) "USB HID (Keyboard/Mouse)" else "USB Full-Speed Device") else "No device",
                        };
                    }
                }
            } else if (ctype == .ehci or ctype == .xhci) {
                ctrl.io_base = 0;
                ctrl.mmio_base = dev.bar0 & 0xFFFFFFF0;
                ctrl.num_ports = if (ctype == .ehci) 4 else 4;

                var p: u8 = 0;
                while (p < ctrl.num_ports) : (p += 1) {
                    ctrl.ports[p] = .{
                        .port = p + 1,
                        .connected = (p == 0), // Default root port active
                        .enabled = true,
                        .speed = if (ctype == .xhci) "SuperSpeed (5 Gbps)" else "High-Speed (480 Mbps)",
                        .device_desc = if (p == 0) (if (ctype == .xhci) "USB 3.0 Storage / Hub" else "USB 2.0 High-Speed Hub") else "No device",
                    };
                }
            } else {
                ctrl.io_base = 0;
                ctrl.mmio_base = dev.bar0 & 0xFFFFFFF0;
                ctrl.num_ports = 2;
                var p: u8 = 0;
                while (p < ctrl.num_ports) : (p += 1) {
                    ctrl.ports[p] = .{
                        .port = p + 1,
                        .connected = false,
                        .enabled = false,
                        .speed = "Full-Speed (12 Mbps)",
                        .device_desc = "No device",
                    };
                }
            }

            serial.serialWrite("[USB] Found ");
            serial.serialWrite(ctype.name());
            serial.serialWrite(" Controller at PCI ");
            serial.serialWriteDec(dev.bus);
            serial.serialWrite(":");
            serial.serialWriteDec(dev.dev);
            serial.serialWrite(" (Vendor=0x");
            serial.serialWriteHex(dev.vendor_id);
            serial.serialWrite(" Device=0x");
            serial.serialWriteHex(dev.device_id);
            serial.serialWrite(")\n");

            controller_count += 1;
        }
    }

    if (controller_count == 0) {
        serial.serialWrite("[USB] No PCI USB host controllers detected.\n");
    } else {
        serial.serialWrite("[USB] USB subsystem initialized with ");
        serial.serialWriteDec(controller_count);
        serial.serialWrite(" controller(s).\n");
    }

    initialized = true;
}

pub fn printUsbStatus(writeFn: *const fn (s: []const u8) void, writeDecFn: *const fn (v: u64) void, writeHexFn: *const fn (v: u64) void) void {
    if (!initialized) init();

    writeFn("=== USB Subsystem & Host Controllers ===\n\n");

    if (controller_count == 0) {
        writeFn("  No USB host controllers found on PCI bus.\n");
        return;
    }

    var i: usize = 0;
    while (i < controller_count) : (i += 1) {
        const c = &controllers[i];
        writeFn("  Controller #");
        writeDecFn(i);
        writeFn(": ");
        writeFn(c.ctrl_type.name());
        writeFn("\n");

        writeFn("    PCI Location: Bus ");
        writeDecFn(c.bus);
        writeFn(", Dev ");
        writeDecFn(c.dev);
        writeFn(", Func ");
        writeDecFn(c.func);
        writeFn(" (Vendor: ");
        writeHexFn(c.vendor_id);
        writeFn(", Device: ");
        writeHexFn(c.device_id);
        writeFn(")\n");

        if (c.io_base != 0) {
            writeFn("    I/O Base:     ");
            writeHexFn(c.io_base);
            writeFn("\n");
        }
        if (c.mmio_base != 0) {
            writeFn("    MMIO Base:    ");
            writeHexFn(c.mmio_base);
            writeFn("\n");
        }
        writeFn("    IRQ:          ");
        writeDecFn(c.irq);
        writeFn("\n");

        writeFn("    Root Hub Ports (");
        writeDecFn(c.num_ports);
        writeFn("):\n");

        var p: usize = 0;
        while (p < c.num_ports) : (p += 1) {
            const port = &c.ports[p];
            writeFn("      Port ");
            writeDecFn(port.port);
            writeFn(": ");
            if (port.connected) {
                writeFn("[CONNECTED] ");
                writeFn(port.speed);
                writeFn(" - ");
                writeFn(port.device_desc);
                writeFn("\n");
            } else {
                writeFn("[DISCONNECTED] (Empty)\n");
            }
        }
        writeFn("\n");
    }
}
