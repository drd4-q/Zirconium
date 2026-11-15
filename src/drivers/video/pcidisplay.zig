//! The PCI display devices: a linear framebuffer on a display adapter.
//!
//! Ported from the Linux kernel's `drivers/video/simpledfb.c` (and the
//! `fbdev` "simple" mode it implements) and from the X.Org `FB_SIMPLE`
//! interface it follows.
//!
//! A display adapter that has been programmed by a firmware - or that has a
//! linear framebuffer of its own - can leave that framebuffer in one of its
//! memory BARs and describe it in the first sixteen bytes of that BAR:
//!
//!     0x10  the magic "JALR" (0x3241554A)
//!     0x14  the width in pixels
//!     0x18  the height in pixels
//!     0x1c  the stride in bytes
//!     0x20  the virtual address (unused)
//!     0x24  the bit depth
//!
//! When a device has such a framebuffer, the kernel can draw on it directly.
//!
//! **What this cannot do:** a discrete GPU whose driver is proprietary has
//! no framebuffer to hand out until its driver has programmed the display
//! engine, and the programming sequences for that engine are not published.
//! An NVIDIA card shows up here, it is listed, and it cannot be driven -
//! the driver that can drive it is closed source and needs an operating
//! system it was written for.

const serial = @import("../../system/serial.zig");
const pci = @import("../pci.zig");
const framebuffer = @import("../../system/framebuffer.zig");

/// The magic in the framebuffer's registers: "JALR" (the X.Org interface
/// spells it that way round).
const SIMPLE_FB_MAGIC: u32 = 0x3241554A;

/// The display class of the PCI specification.
const PCI_CLASS_DISPLAY: u8 = 0x03;

/// One display adapter and what the kernel could do with it.
pub const Adapter = struct {
    /// The PCI device.
    dev: *pci.PciDevice = undefined,
    /// The framebuffer the adapter offers, if it offers one.
    fb_addr: u64 = 0,
    fb_width: u32 = 0,
    fb_height: u32 = 0,
    fb_pitch: u32 = 0,
    fb_bpp: u32 = 0,
    /// True when the framebuffer was found and bound.
    bound: bool = false,
    /// Why the adapter could not be driven, when it could not.
    note: []const u8 = "",
};

pub const MAX_ADAPTERS: usize = 4;

pub var adapters: [MAX_ADAPTERS]Adapter = undefined;
pub var adapter_count: usize = 0;

/// True when a display adapter was found.
pub var initialized: bool = false;

/// Look for a display adapter and bind its framebuffer, if it has one.
///
/// The framebuffer is only bound when the bootloader did not give us one:
/// the firmware's mode is the one the operator is used to, and a display
/// adapter that is merely *present* is not a reason to switch.
pub fn init() void {
    if (initialized) return;
    initialized = true;

    var i: usize = 0;
    while (i < pci.device_count) : (i += 1) {
        const dev = &pci.devices[i];
        if (dev.class != PCI_CLASS_DISPLAY) continue;
        if (adapter_count >= MAX_ADAPTERS) break;

        var adapter = Adapter{};
        adapter.dev = dev;

        serial.serialWrite("[DISP] PCI display device ");
        serial.serialWriteHex(dev.vendor_id);
        serial.serialWrite(":");
        serial.serialWriteHex(dev.device_id);
        serial.serialWrite(" class ");
        serial.serialWriteHex(dev.class);
        serial.serialWrite(".");
        serial.serialWriteHex(dev.subclass);
        serial.serialWrite("\n");

        findSimpleFramebuffer(&adapter);

        if (adapter.bound) {
            serial.serialWrite("[DISP]   linear framebuffer at 0x");
            serial.serialWriteHex(adapter.fb_addr);
            serial.serialWrite(" ");
            serial.serialWriteDec(adapter.fb_width);
            serial.serialWrite("x");
            serial.serialWriteDec(adapter.fb_height);
            serial.serialWrite("x");
            serial.serialWriteDec(adapter.fb_bpp);
            serial.serialWrite("\n");
        } else {
            serial.serialWrite("[DISP]   ");
            serial.serialWrite(adapter.note);
            serial.serialWrite("\n");
        }

        adapters[adapter_count] = adapter;
        adapter_count += 1;
    }
}

/// Look for the "simple" framebuffer in the adapter's BARs.
fn findSimpleFramebuffer(adapter: *Adapter) void {
    const dev = adapter.dev;

    var index: usize = 0;
    while (index < dev.bars.len) : (index += 1) {
        const addr = dev.barAddress(index) orelse continue;
        if (addr + 0x28 >= MAX_IDENTITY_MAP) continue;

        // Only a prefetchable memory BAR can be a framebuffer.  A device's
        // register file is not prefetchable, and reading a register of a
        // discrete GPU can have side effects (it can clear a status bit, or
        // wake the card up), so the other BARs are left alone.
        if (!dev.barPrefetchable(index)) continue;

        // The registers live at the start of the BAR's memory.
        const regs: [*]const volatile u32 = @ptrFromInt(addr);
        if (regs[4] != SIMPLE_FB_MAGIC) continue;

        const width = regs[5];
        const height = regs[6];
        const stride = regs[7];
        const bpp = regs[9];
        if (width == 0 or height == 0 or stride == 0) continue;

        adapter.fb_addr = addr;
        adapter.fb_width = width;
        adapter.fb_height = height;
        adapter.fb_pitch = stride;
        adapter.fb_bpp = bpp;
        adapter.bound = true;
        return;
    }

    adapter.note = "no linear framebuffer: the display engine has to be programmed first";
}

/// Use the framebuffer of a display adapter as the console's.
///
/// Returns false when there is no adapter with a framebuffer.
pub fn bindFramebuffer() bool {
    var i: usize = 0;
    while (i < adapter_count) : (i += 1) {
        const adapter = &adapters[i];
        if (!adapter.bound) continue;
        if (!framebuffer.initLinear(adapter.fb_addr, adapter.fb_width, adapter.fb_height, adapter.fb_pitch, adapter.fb_bpp)) continue;
        @import("../../system/gfx/mod.zig").useFramebuffer();
        return true;
    }
    return false;
}

/// Write the state of the display adapters to the serial log.
pub fn printStatus(
    write: *const fn (s: []const u8) void,
    writeDec: *const fn (v: u64) void,
) void {
    if (adapter_count == 0) {
        write("  No PCI display adapters.\n");
        return;
    }

    var i: usize = 0;
    while (i < adapter_count) : (i += 1) {
        const adapter = &adapters[i];
        write("  adapter ");
        writeDec(i);
        write("  vendor ");
        writeDec(adapter.dev.vendor_id);
        write("  ");
        if (adapter.bound) {
            write("framebuffer ");
            writeDec(adapter.fb_width);
            write("x");
            writeDec(adapter.fb_height);
            write("x");
            writeDec(adapter.fb_bpp);
            write("\n");
        } else {
            write(adapter.note);
            write("\n");
        }
    }
}

/// The identity map covers the low 64 GB.
const MAX_IDENTITY_MAP: u64 = 64 * 1024 * 1024 * 1024;
