const std = @import("std");
const root = @import("root");
const serial = root.serial;
const pci = @import("../pci.zig");
const types = @import("types.zig");
const UsbControllerType = types.UsbControllerType;

pub const MAX_DETECTED_CONTROLLERS: usize = 8;

pub const PciUsbController = struct {
    ctrl_type: UsbControllerType,
    bus: u8,
    dev: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    irq: u8,
    io_base: u16 = 0,
    mmio_base: usize = 0,
};

pub var detected: [MAX_DETECTED_CONTROLLERS]PciUsbController = undefined;
pub var detected_count: usize = 0;

/// Read a (possibly 64-bit) MMIO BAR and return the full base address.
/// Returns 0 for I/O BARs, unassigned BARs, or BARs outside the boot
/// identity map (0..64GB). Touching those would page-fault, so callers skip
/// such controllers instead. Real hardware often places
/// xHCI/EHCI ABARs above 4GB; using only the low 32 bits would alias RAM.
fn mapMmioPages(phys: u64, size: usize) void {
    const vmm = @import("../../kernel/vmm.zig");
    const page_start = phys & ~@as(u64, 0xFFF);
    const page_end = (phys + size + 0xFFF) & ~@as(u64, 0xFFF);
    var p = page_start;
    while (p < page_end) : (p += 4096) {
        vmm.mapPage(p, p, vmm.PAGE_PRESENT | vmm.PAGE_WRITE);
    }
}

fn readMmioBar(d: *pci.PciDevice, bar_num: u8) usize {
    const reg: u8 = @intCast(0x10 + @as(u16, bar_num) * 4);
    const lo = pci.readConfig(d.bus, d.dev, d.func, reg);
    if (lo == 0 or lo == 0xFFFFFFFF) return 0;
    if ((lo & 1) != 0) return 0; // I/O BAR, not MMIO
    const IDENTITY_LIMIT: u64 = 0x1000000000; // 64GB boot map
    if ((lo & 0x06) == 0x04) {
        // 64-bit BAR: high dword lives in the next BAR slot.
        const hi = pci.readConfig(d.bus, d.dev, d.func, reg + 4);
        const full = (@as(u64, hi) << 32) | (@as(u64, lo) & 0xFFFFFFF0);
        if (full == 0 or full == 0xFFFFFFFFFFFFFFFF) return 0;
        if (full >= IDENTITY_LIMIT) {
            mapMmioPages(full, 0x40000);
        }
        return @intCast(full);
    }
    const base = lo & 0xFFFFFFF0;
    if (base == 0) return 0;
    if (@as(u64, base) >= IDENTITY_LIMIT) {
        mapMmioPages(base, 0x40000);
    }
    return @intCast(base);
}

pub fn scanPciControllers() usize {
    detected_count = 0;
    serial.serialWrite("[USB] Scanning PCI for USB host controllers...\n");

    // Ensure PCI scan has been run
    if (pci.device_count == 0) {
        pci.scan();
    }

    var i: usize = 0;
    while (i < pci.device_count) : (i += 1) {
        const d = &pci.devices[i];
        if (d.class == 0x0C and d.subclass == 0x03) {
            if (detected_count >= MAX_DETECTED_CONTROLLERS) break;

            const ctype: UsbControllerType = switch (d.prog_if) {
                0x00 => .uhci,
                0x10 => .ohci,
                0x20 => .ehci,
                0x30 => .xhci,
                else => .uhci,
            };

            var io_base: u16 = 0;
            var mmio_base: usize = 0;

            // Enable bus master, memory, and I/O access
            pci.enableBusMaster(d.bus, d.dev, d.func);

            if (ctype == .uhci) {
                // Linux quirk_usb_early_handoff: clear BIOS USB legacy SMI on UHCI
                pci.writeConfig(d.bus, d.dev, d.func, 0xC0, 0x8F00);
                const bar4 = pci.readBar(d.bus, d.dev, d.func, 4);
                // UHCI BAR4 must be I/O (bit 0 = 1); ignore MMIO values.
                if ((bar4 & 1) == 0) {
                    io_base = 0;
                } else {
                    io_base = @intCast(bar4 & 0xFFFC);
                }
                mmio_base = 0;
            } else if (ctype == .ehci) {
                io_base = 0;
                mmio_base = readMmioBar(d, 0);
            } else if (ctype == .xhci) {
                if (d.vendor_id == 0x8086) {
                    // Linux usb_enable_intel_xhci_ports(): route only the
                    // ports advertised by the hardware masks.  Writing
                    // 0xffffffff to the routing registers is not equivalent
                    // and can leave physical USB2 ports without VBUS/data.
                    const usb3_mask = pci.readConfig(d.bus, d.dev, d.func, 0xDC);
                    pci.writeConfig(d.bus, d.dev, d.func, 0xD8, usb3_mask);
                    const usb2_mask = pci.readConfig(d.bus, d.dev, d.func, 0xD4);
                    pci.writeConfig(d.bus, d.dev, d.func, 0xD0, usb2_mask);
                    serial.serialWrite("[USB] Intel xHCI port masks: USB2=0x");
                    serial.serialWriteHex(usb2_mask);
                    serial.serialWrite(" USB3=0x");
                    serial.serialWriteHex(usb3_mask);
                    serial.serialWrite("\n");
                }
                io_base = 0;
                mmio_base = readMmioBar(d, 0);
            } else {
                io_base = 0;
                mmio_base = readMmioBar(d, 0);
            }

            detected[detected_count] = PciUsbController{
                .ctrl_type = ctype,
                .bus = d.bus,
                .dev = d.dev,
                .func = d.func,
                .vendor_id = d.vendor_id,
                .device_id = d.device_id,
                .irq = d.irq,
                .io_base = io_base,
                .mmio_base = mmio_base,
            };

            serial.serialWrite("[USB] Found ");
            serial.serialWrite(ctype.name());
            serial.serialWrite(" Controller at PCI ");
            serial.serialWriteDec(d.bus);
            serial.serialWrite(":");
            serial.serialWriteDec(d.dev);
            serial.serialWrite(" (Vendor=0x");
            serial.serialWriteHex(d.vendor_id);
            serial.serialWrite(" Device=0x");
            serial.serialWriteHex(d.device_id);
            serial.serialWrite(")\n");

            detected_count += 1;
        }
    }

    return detected_count;
}
