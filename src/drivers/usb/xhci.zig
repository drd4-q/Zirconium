const std = @import("std");
const root = @import("root");
const serial = root.serial;
const timer = @import("../timer.zig");
const types = @import("types.zig");
const dma = @import("dma.zig");
const pci_detect = @import("pci_detect.zig");

pub const UsbSetupPacket = types.UsbSetupPacket;
pub const UsbPortStatus = types.UsbPortStatus;

pub const XhciTrb = extern struct {
    parameter: u64 = 0,
    status: u32 = 0,
    control: u32 = 0, // Bit 0: Cycle bit, bits 15:10: Type
};

pub const ErstEntry = extern struct {
    ring_segment_base_address: u64 = 0,
    ring_segment_size: u16 = 0,
    _reserved: u16 = 0,
    _pad: u32 = 0,
};

pub const TRB_TYPE_NORMAL: u32 = 1;
pub const TRB_TYPE_SETUP_STAGE: u32 = 2;
pub const TRB_TYPE_DATA_STAGE: u32 = 3;
pub const TRB_TYPE_STATUS_STAGE: u32 = 4;
pub const TRB_TYPE_LINK: u32 = 6;
pub const TRB_TYPE_ENABLE_SLOT: u32 = 9;
pub const TRB_TYPE_DISABLE_SLOT: u32 = 10;
pub const TRB_TYPE_ADDRESS_DEVICE: u32 = 11;
pub const TRB_TYPE_CONFIG_ENDPOINT: u32 = 12;
pub const TRB_TYPE_EVAL_CONTEXT: u32 = 13;
pub const TRB_TYPE_RESET_ENDPOINT: u32 = 14;
pub const TRB_TYPE_TRANSFER_EVENT: u32 = 32;
pub const TRB_TYPE_COMMAND_COMPLETION: u32 = 33;
pub const TRB_TYPE_PORT_STATUS_CHANGE: u32 = 34;

inline fn readMmio32(addr: usize) u32 {
    const p: *const volatile u32 = @ptrFromInt(addr);
    return p.*;
}

inline fn writeMmio32(addr: usize, val: u32) void {
    const p: *volatile u32 = @ptrFromInt(addr);
    p.* = val;
}

inline fn readMmio64(addr: usize) u64 {
    const p: *const volatile u64 = @ptrFromInt(addr);
    return p.*;
}

inline fn writeMmio64(addr: usize, val: u64) void {
    const p: *volatile u64 = @ptrFromInt(addr);
    p.* = val;
}

inline fn readMmio8(addr: usize) u8 {
    const p: *const volatile u8 = @ptrFromInt(addr);
    return p.*;
}

fn spinDelayMs(ms: u32) void {
    if (timer.ticks > 0) {
        const needed: u64 = if (ms == 0) 0 else ((@as(u64, ms) + 9) / 10);
        const target = timer.ticks + needed;
        while (timer.ticks < target) {
            asm volatile ("pause");
        }
    } else {
        var i: u32 = 0;
        while (i < ms * 10000) : (i += 1) {
            asm volatile ("pause");
        }
    }
}

pub const XhciSlot = struct {
    active: bool = false,
    slot_id: u8 = 0,
    port_idx: u8 = 0,
    speed_code: u8 = 0,

    dev_ctx_phys: usize = 0,
    input_ctx_phys: usize = 0,

    ep0_ring_phys: usize = 0,
    ep0_ring: *[16]XhciTrb = undefined,
    ep0_enqueue: usize = 0,
    ep0_cycle: u1 = 1,

    intr_ring_phys: usize = 0,
    intr_ring: *[16]XhciTrb = undefined,
    intr_enqueue: usize = 0,
    intr_cycle: u1 = 1,
    intr_dci: u8 = 0,

    intr2_ring_phys: usize = 0,
    intr2_ring: *[16]XhciTrb = undefined,
    intr2_enqueue: usize = 0,
    intr2_cycle: u1 = 1,
    intr2_dci: u8 = 0,

    ctrl_buf_phys: usize = 0,
    ctrl_buf: *[512]u8 = undefined,
};

pub const XhciController = struct {
    id: u8,
    bus: u8,
    dev: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    irq: u8,
    mmio_base: usize,
    op_regs: usize = 0,
    rt_regs: usize = 0,
    db_regs: usize = 0,
    num_ports: u8 = 0,
    max_slots: u8 = 0,
    csz_64: bool = false,
    ports: [32]UsbPortStatus = undefined,
    slots: [8]XhciSlot = [_]XhciSlot{.{}} ** 8,

    // PMM DMA Memory
    dcbaa_phys: usize = 0,
    dcbaa: *[32]u64 = undefined,

    cmd_ring_phys: usize = 0,
    cmd_ring: *[256]XhciTrb = undefined,
    cmd_enqueue: usize = 0,
    cmd_cycle: u1 = 1,

    event_ring_phys: usize = 0,
    event_ring: *[256]XhciTrb = undefined,
    erst_phys: usize = 0,
    erst: *ErstEntry = undefined,
    event_dequeue: usize = 0,
    event_cycle: u1 = 1,

    scratchpad_array_phys: usize = 0,
    scratchpad_pages: [128]usize = [_]usize{0} ** 128,
    scratchpad_count: usize = 0,

    dma_pool: dma.UsbDmaPool = dma.UsbDmaPool.init(),

    pub fn init(self: *XhciController, pci_ctrl: *const pci_detect.PciUsbController, id: u8) bool {
        self.id = id;
        self.bus = pci_ctrl.bus;
        self.dev = pci_ctrl.dev;
        self.func = pci_ctrl.func;
        self.vendor_id = pci_ctrl.vendor_id;
        self.device_id = pci_ctrl.device_id;
        self.irq = pci_ctrl.irq;
        self.mmio_base = pci_ctrl.mmio_base;

        serial.serialWrite("[XHCI] Init: PCI ");
        serial.serialWriteDec(pci_ctrl.bus);
        serial.serialWrite(":");
        serial.serialWriteDec(pci_ctrl.dev);
        serial.serialWrite(".");
        serial.serialWriteDec(pci_ctrl.func);
        serial.serialWrite(" MMIO=0x");
        serial.serialWriteHex(self.mmio_base);
        serial.serialWrite("\n");

        if (self.mmio_base == 0) {
            serial.serialWrite("[XHCI] FAIL: MMIO base is 0\n");
            return false;
        }

        // ─── Read capability registers with sanity checks ───────────
        const cap_len = readMmio8(self.mmio_base + 0x00);
        if (cap_len == 0 or cap_len == 0xFF) {
            serial.serialWrite("[XHCI] FAIL: CAPLENGTH=0x");
            serial.serialWriteHex(cap_len);
            serial.serialWrite(" — MMIO may not be mapped or controller absent\n");
            return false;
        }
        self.op_regs = self.mmio_base + cap_len;

        const hcs1 = readMmio32(self.mmio_base + 0x04);
        if (hcs1 == 0 or hcs1 == 0xFFFFFFFF) {
            serial.serialWrite("[XHCI] FAIL: HCSPARAMS1=0x");
            serial.serialWriteHex(hcs1);
            serial.serialWrite(" — controller not responding\n");
            return false;
        }
        self.max_slots = @intCast(hcs1 & 0xFF);
        self.num_ports = @intCast(@min((hcs1 >> 24) & 0xFF, 32));

        serial.serialWrite("[XHCI] CAPLENGTH=");
        serial.serialWriteDec(cap_len);
        serial.serialWrite(" OP_REGS=0x");
        serial.serialWriteHex(self.op_regs);
        serial.serialWrite(" MAX_SLOTS=");
        serial.serialWriteDec(self.max_slots);
        serial.serialWrite(" NUM_PORTS=");
        serial.serialWriteDec(self.num_ports);
        serial.serialWrite("\n");

        const hcs2 = readMmio32(self.mmio_base + 0x08);
        const max_scratchpads: usize = (((hcs2 >> 27) & 0x1F) << 5) | ((hcs2 >> 21) & 0x1F);

        const hcc1 = readMmio32(self.mmio_base + 0x10);
        self.csz_64 = (hcc1 & (1 << 2)) != 0;
        const xecp = (hcc1 >> 16) & 0xFFFF;

        serial.serialWrite("[XHCI] HCC1=0x");
        serial.serialWriteHex(hcc1);
        serial.serialWrite(" CSZ64=");
        serial.serialWrite(if (self.csz_64) "yes" else "no");
        serial.serialWrite(" XECP=0x");
        serial.serialWriteHex(xecp);
        serial.serialWrite("\n");

        const db_raw = readMmio32(self.mmio_base + 0x14);
        const rt_raw = readMmio32(self.mmio_base + 0x18);
        self.db_regs = self.mmio_base + (db_raw & ~@as(u32, 0x03));
        self.rt_regs = self.mmio_base + (rt_raw & ~@as(u32, 0x1F));

        // ─── BIOS Handoff (USBLEGSUP) ──────────────────────────────
        if (xecp != 0) {
            serial.serialWrite("[XHCI] BIOS handoff: searching extended capabilities...\n");
            var cap_offset = self.mmio_base + (@as(usize, xecp) << 2);
            // Safety: limit traversal to 256 iterations to prevent runaway
            var cap_iter: u32 = 0;
            var bios_handled = false;
            while (cap_iter < 256) : (cap_iter += 1) {
                // Bounds check: cap_offset must be within the mapped MMIO BAR range (256 KB)
                if (cap_offset < self.mmio_base or cap_offset >= self.mmio_base + 0x40000) {
                    serial.serialWrite("[XHCI] BIOS handoff: cap_offset out of MMIO range, aborting\n");
                    break;
                }
                const cap_val = readMmio32(cap_offset);
                if (cap_val == 0xFFFFFFFF) {
                    serial.serialWrite("[XHCI] BIOS handoff: MMIO read returned 0xFFFFFFFF at offset 0x");
                    serial.serialWriteHex(cap_offset - self.mmio_base);
                    serial.serialWrite(" — aborting\n");
                    break;
                }
                const cap_id = cap_val & 0xFF;
                if (cap_id == 1) { // USB Legacy Support
                    serial.serialWrite("[XHCI] Found USBLEGSUP at offset 0x");
                    serial.serialWriteHex(cap_offset - self.mmio_base);
                    serial.serialWrite("\n");
                    // Bit 24 = OS Owned Semaphore, Bit 16 = BIOS Owned Semaphore
                    writeMmio32(cap_offset, cap_val | (1 << 24));
                    var spins: u32 = 0;
                    while (spins < 1000) : (spins += 1) {
                        if ((readMmio32(cap_offset) & (1 << 16)) == 0) break;
                        spinDelayMs(1);
                    }
                    if (spins >= 1000) {
                        serial.serialWrite("[XHCI] WARN: BIOS did not release ownership, forcing claim\n");
                        writeMmio32(cap_offset, (readMmio32(cap_offset) & ~@as(u32, 1 << 16)) | (1 << 24));
                    } else {
                        serial.serialWrite("[XHCI] BIOS handoff OK\n");
                    }
                    // Disable all BIOS SMIs (clear SMI enable bits 31..29, clear status bits 21..16)
                    writeMmio32(cap_offset + 4, 0xE01F0000);
                    bios_handled = true;
                    break;
                }
                const next = (cap_val >> 8) & 0xFF;
                if (next == 0) break;
                cap_offset += (@as(usize, next) << 2);
            }
            if (!bios_handled and cap_iter < 256) {
                serial.serialWrite("[XHCI] BIOS handoff: no USBLEGSUP found, continuing\n");
            }
        }

        // ─── Halt controller ────────────────────────────────────────
        serial.serialWrite("[XHCI] Halting controller...\n");
        var usbcmd = readMmio32(self.op_regs + 0x00);
        writeMmio32(self.op_regs + 0x00, usbcmd & ~@as(u32, 1)); // Clear RS
        var wait_halt: u32 = 0;
        while (wait_halt < 1000) : (wait_halt += 1) {
            if ((readMmio32(self.op_regs + 0x04) & 1) != 0) break; // HCHalted
            spinDelayMs(1);
        }
        if (wait_halt >= 1000) {
            serial.serialWrite("[XHCI] WARN: Controller did not halt after 1s\n");
        }

        // ─── Reset controller ───────────────────────────────────────
        serial.serialWrite("[XHCI] Resetting controller (HCRST)...\n");
        writeMmio32(self.op_regs + 0x00, readMmio32(self.op_regs + 0x00) | 2); // HCRST
        var wait_reset: u32 = 0;
        while (wait_reset < 1000) : (wait_reset += 1) {
            if ((readMmio32(self.op_regs + 0x00) & 2) == 0) break;
            spinDelayMs(1);
        }
        if (wait_reset >= 1000) {
            serial.serialWrite("[XHCI] WARN: HCRST did not clear after 1s\n");
        }

        // Wait for Controller Not Ready (CNR bit 11) to clear
        serial.serialWrite("[XHCI] Waiting for CNR to clear...\n");
        var wait_cnr: u32 = 0;
        while (wait_cnr < 1000) : (wait_cnr += 1) {
            if ((readMmio32(self.op_regs + 0x04) & (1 << 11)) == 0) break;
            spinDelayMs(1);
        }
        if (wait_cnr >= 1000) {
            serial.serialWrite("[XHCI] WARN: CNR did not clear after 1s\n");
        }

        // ─── Configure Max Device Slots Enabled ─────────────────────
        const slots_en = @min(self.max_slots, 16);
        writeMmio32(self.op_regs + 0x38, @as(u32, slots_en)); // CONFIG
        serial.serialWrite("[XHCI] Configured ");
        serial.serialWriteDec(slots_en);
        serial.serialWrite(" device slots\n");

        // ─── Allocate DCBAA ─────────────────────────────────────────
        const dcbaa_page = dma.allocPage() orelse {
            serial.serialWrite("[XHCI] FAIL: Could not allocate DCBAA page\n");
            return false;
        };
        self.dcbaa_phys = dcbaa_page;
        self.dcbaa = @ptrCast(@alignCast(@as([*]u64, @ptrFromInt(dcbaa_page))));

        // Setup scratchpad buffers if required
        if (max_scratchpads > 0) {
            self.scratchpad_count = @min(max_scratchpads, 128);
            serial.serialWrite("[XHCI] Scratchpads requested: ");
            serial.serialWriteDec(max_scratchpads);
            serial.serialWrite(", allocating: ");
            serial.serialWriteDec(self.scratchpad_count);
            serial.serialWrite(" page(s)\n");

            const sp_array_page = dma.allocPage() orelse return false;
            self.scratchpad_array_phys = sp_array_page;
            const sp_array: [*]u64 = @ptrFromInt(sp_array_page);

            var s: usize = 0;
            while (s < self.scratchpad_count) : (s += 1) {
                const sp_buf = dma.allocPage() orelse break;
                self.scratchpad_pages[s] = sp_buf;
                sp_array[s] = @as(u64, sp_buf);
            }
            self.dcbaa[0] = @as(u64, self.scratchpad_array_phys);
        }

        writeMmio64(self.op_regs + 0x30, @as(u64, self.dcbaa_phys)); // DCBAAP

        // ─── Allocate Command Ring ──────────────────────────────────
        const cmd_page = dma.allocPage() orelse {
            serial.serialWrite("[XHCI] FAIL: Could not allocate command ring page\n");
            return false;
        };
        self.cmd_ring_phys = cmd_page;
        self.cmd_ring = @ptrCast(@alignCast(@as([*]XhciTrb, @ptrFromInt(cmd_page))));
        self.cmd_enqueue = 0;
        self.cmd_cycle = 1;

        // Last TRB is Link TRB pointing back to start with Toggle Cycle bit set
        self.cmd_ring[255] = XhciTrb{
            .parameter = @as(u64, self.cmd_ring_phys),
            .status = 0,
            .control = (TRB_TYPE_LINK << 10) | (1 << 1), // Type=Link, TC=1
        };

        writeMmio64(self.op_regs + 0x18, @as(u64, self.cmd_ring_phys) | 1); // CRCR (RCS = 1)

        // ─── Allocate Event Ring ────────────────────────────────────
        const event_page = dma.allocPage() orelse {
            serial.serialWrite("[XHCI] FAIL: Could not allocate event ring page\n");
            return false;
        };
        self.event_ring_phys = event_page;
        self.event_ring = @ptrCast(@alignCast(@as([*]XhciTrb, @ptrFromInt(event_page))));
        self.event_dequeue = 0;
        self.event_cycle = 1;

        const erst_page = dma.allocPage() orelse return false;
        self.erst_phys = erst_page;
        self.erst = @ptrCast(@alignCast(@as([*]ErstEntry, @ptrFromInt(erst_page))));
        self.erst.* = ErstEntry{
            .ring_segment_base_address = @as(u64, self.event_ring_phys),
            .ring_segment_size = 256,
        };

        // Initialize Primary Interrupter (Interrupter 0 at rt_regs + 0x20)
        const intr0 = self.rt_regs + 0x20;
        writeMmio32(intr0 + 0x08, 1); // ERSTSZ = 1
        writeMmio64(intr0 + 0x10, @as(u64, self.erst_phys)); // ERSTBA
        writeMmio64(intr0 + 0x18, @as(u64, self.event_ring_phys) | (1 << 3)); // ERDP (EHB bit 3)
        writeMmio32(intr0 + 0x00, 2); // IMAN: Interrupt Enable = 1

        // ─── Power on root hub ports ────────────────────────────────
        serial.serialWrite("[XHCI] Powering on ");
        serial.serialWriteDec(self.num_ports);
        serial.serialWrite(" root hub ports...\n");
        var p: u8 = 0;
        while (p < self.num_ports) : (p += 1) {
            const portsc_addr = self.op_regs + 0x400 + (@as(usize, p) * 0x10);
            const val = readMmio32(portsc_addr);
            // Neutralize bits so we don't clear RW1C change bits, don't write 1 to PED (RW1CS),
            // and assert Port Power (PP bit 9)
            writeMmio32(portsc_addr, xhciPortStateToNeutral(val) | (1 << 9));
        }
        spinDelayMs(100);

        // ─── Start controller ───────────────────────────────────────
        serial.serialWrite("[XHCI] Starting controller (USBCMD Run/IE)...\n");
        usbcmd = readMmio32(self.op_regs + 0x00);
        writeMmio32(self.op_regs + 0x00, usbcmd | (1 << 0) | (1 << 2));

        var wait_run: u32 = 0;
        while (wait_run < 1000) : (wait_run += 1) {
            if ((readMmio32(self.op_regs + 0x04) & 1) == 0) break; // HCH == 0
            spinDelayMs(1);
        }
        if (wait_run >= 1000) {
            serial.serialWrite("[XHCI] WARN: Controller did not start (HCH still set) after 1s\n");
        } else {
            serial.serialWrite("[XHCI] Controller running\n");
        }

        // Scan ports and detect connections
        self.checkPorts();

        serial.serialWrite("[XHCI] Init complete\n");
        return true;
    }

    pub fn deinit(self: *XhciController) void {
        if (self.op_regs != 0) {
            writeMmio32(self.op_regs + 0x00, 0); // Stop controller
        }
        if (self.dcbaa_phys != 0) {
            dma.freePage(self.dcbaa_phys);
            self.dcbaa_phys = 0;
        }
        if (self.cmd_ring_phys != 0) {
            dma.freePage(self.cmd_ring_phys);
            self.cmd_ring_phys = 0;
        }
        if (self.event_ring_phys != 0) {
            dma.freePage(self.event_ring_phys);
            self.event_ring_phys = 0;
        }
        if (self.erst_phys != 0) {
            dma.freePage(self.erst_phys);
            self.erst_phys = 0;
        }
        var s: usize = 0;
        while (s < self.scratchpad_count) : (s += 1) {
            if (self.scratchpad_pages[s] != 0) {
                dma.freePage(self.scratchpad_pages[s]);
            }
        }
        if (self.scratchpad_array_phys != 0) {
            dma.freePage(self.scratchpad_array_phys);
            self.scratchpad_array_phys = 0;
        }
        var sl: usize = 0;
        while (sl < self.slots.len) : (sl += 1) {
            if (self.slots[sl].active) {
                if (self.slots[sl].input_ctx_phys != 0) dma.freePage(self.slots[sl].input_ctx_phys);
                if (self.slots[sl].dev_ctx_phys != 0) dma.freePage(self.slots[sl].dev_ctx_phys);
                self.slots[sl] = .{};
            }
        }
        self.dma_pool.deinit();
    }

    pub inline fn xhciPortStateToNeutral(portsc: u32) u32 {
        const XHCI_PORT_RO: u32 = (1 << 0) | (1 << 3) | (0xF << 10) | (1 << 30);
        const XHCI_PORT_RWS: u32 = (0xF << 5) | (1 << 9) | (0x3 << 14) | (0x7 << 25);
        return (portsc & XHCI_PORT_RO) | (portsc & XHCI_PORT_RWS);
    }

    pub fn checkPorts(self: *XhciController) void {
        var p: u8 = 0;
        while (p < self.num_ports and p < 32) : (p += 1) {
            const portsc_addr = self.op_regs + 0x400 + (@as(usize, p) * 0x10);
            var status = readMmio32(portsc_addr);

            serial.serialWrite("[XHCI] Port ");
            serial.serialWriteDec(p + 1);
            serial.serialWrite(" PORTSC=0x");
            serial.serialWriteHex(status);
            serial.serialWrite("\n");

            // Sanity: if MMIO read fails, skip this port
            if (status == 0xFFFFFFFF) {
                serial.serialWrite("[XHCI] Port ");
                serial.serialWriteDec(p + 1);
                serial.serialWrite(": MMIO read failed, skipping\n");
                self.ports[p] = .{
                    .port = p + 1,
                    .connected = false,
                    .enabled = false,
                    .speed = "Unknown",
                    .device_desc = "MMIO error",
                };
                continue;
            }

            const connected = (status & 0x01) != 0;

            if (connected) {
                // If port is not enabled, perform reset (assert PR bit 4)
                if ((status & 0x02) == 0) {
                    serial.serialWrite("[XHCI] Port ");
                    serial.serialWriteDec(p + 1);
                    serial.serialWrite(": Connected but not enabled, resetting...\n");

                    // Assert Port Reset (PR bit 4) while preserving neutral state + Port Power (bit 9)
                    const neutral = xhciPortStateToNeutral(status);
                    writeMmio32(portsc_addr, neutral | (1 << 4) | (1 << 9));

                    // Wait for Port Reset (PR bit 4) to deassert
                    var reset_wait: u32 = 0;
                    while (reset_wait < 100) : (reset_wait += 1) {
                        spinDelayMs(1);
                        status = readMmio32(portsc_addr);
                        if ((status & (1 << 4)) == 0) break;
                    }

                    // Clear Port Reset Change (PRC bit 21) safely WITHOUT setting bit 1 (PED is RW1CS)
                    status = readMmio32(portsc_addr);
                    if ((status & (1 << 21)) != 0) {
                        writeMmio32(portsc_addr, xhciPortStateToNeutral(status) | (1 << 21));
                    }

                    // Recovery delay after reset (USB TRSTRCY = 20ms)
                    spinDelayMs(20);

                    // Wait up to 100ms for Port Enabled (PED bit 1) to settle (critical for AMD xHCI!)
                    var pe_wait: u32 = 0;
                    while (pe_wait < 100) : (pe_wait += 1) {
                        status = readMmio32(portsc_addr);
                        if ((status & 0x02) != 0) break;
                        spinDelayMs(1);
                    }

                    // Clear any lingering change bits (CSC, PEC, PRC) safely
                    const chg = status & 0x00FE0000;
                    if (chg != 0) {
                        writeMmio32(portsc_addr, xhciPortStateToNeutral(status) | chg);
                    }
                    status = readMmio32(portsc_addr);
                }

                const enabled = (status & 0x02) != 0;
                const speed_code = (status >> 10) & 0x0F;
                const speed_str: []const u8 = switch (speed_code) {
                    1 => "Full-Speed (12 Mbps)",
                    2 => "Low-Speed (1.5 Mbps)",
                    3 => "High-Speed (480 Mbps)",
                    4 => "SuperSpeed (5 Gbps)",
                    5 => "SuperSpeed+ (10 Gbps)",
                    else => "SuperSpeed (5 Gbps)",
                };
                const desc_str: []const u8 = switch (speed_code) {
                    4, 5 => "USB 3.0 SuperSpeed Device",
                    3 => "USB 2.0 High-Speed Device",
                    2 => "USB Low-Speed HID",
                    else => "USB Generic Device",
                };

                serial.serialWrite("[XHCI] Port ");
                serial.serialWriteDec(p + 1);
                serial.serialWrite(": ");
                serial.serialWrite(if (enabled) "ENABLED, Speed=" else "DISABLED, Speed=");
                serial.serialWrite(speed_str);
                serial.serialWrite("\n");

                self.ports[p] = .{
                    .port = p + 1,
                    .connected = true,
                    .enabled = enabled,
                    .speed = speed_str,
                    .device_desc = desc_str,
                };
            } else {
                self.ports[p] = .{
                    .port = p + 1,
                    .connected = false,
                    .enabled = false,
                    .speed = "SuperSpeed (5 Gbps)",
                    .device_desc = "No device",
                };
            }
        }
    }

    pub fn resetPort(self: *XhciController, port_idx: u8) bool {
        if (port_idx >= self.num_ports or port_idx >= 32) return false;
        const portsc_addr = self.op_regs + 0x400 + (@as(usize, port_idx) * 0x10);
        var status = readMmio32(portsc_addr);

        const neutral = xhciPortStateToNeutral(status);
        writeMmio32(portsc_addr, neutral | (1 << 4) | (1 << 9));

        var reset_wait: u32 = 0;
        while (reset_wait < 100) : (reset_wait += 1) {
            spinDelayMs(1);
            status = readMmio32(portsc_addr);
            if ((status & (1 << 4)) == 0) break;
        }

        status = readMmio32(portsc_addr);
        if ((status & (1 << 21)) != 0) {
            writeMmio32(portsc_addr, xhciPortStateToNeutral(status) | (1 << 21));
        }
        spinDelayMs(20);

        var pe_wait: u32 = 0;
        while (pe_wait < 100) : (pe_wait += 1) {
            status = readMmio32(portsc_addr);
            if ((status & 0x02) != 0) break;
            spinDelayMs(1);
        }

        const chg = status & 0x00FE0000;
        if (chg != 0) {
            writeMmio32(portsc_addr, xhciPortStateToNeutral(status) | chg);
        }
        status = readMmio32(portsc_addr);
        return (status & 0x02) != 0;
    }

    pub fn ringDoorbell(self: *XhciController, target_slot: u8, target_endpoint: u8) void {
        const db_addr = self.db_regs + (@as(usize, target_slot) * 4);
        writeMmio32(db_addr, @as(u32, target_endpoint));
    }

    pub fn sendCommandRaw(self: *XhciController, param: u64, status: u32, ctrl: u32, out_slot_id: ?*u8) bool {
        const idx = self.cmd_enqueue;
        self.cmd_ring[idx] = XhciTrb{
            .parameter = param,
            .status = status,
            .control = ctrl,
        };

        self.cmd_enqueue += 1;
        if (self.cmd_enqueue == 255) {
            self.cmd_ring[255].control = (TRB_TYPE_LINK << 10) | (1 << 1) | @as(u32, self.cmd_cycle);
            self.cmd_enqueue = 0;
            self.cmd_cycle ^= 1;
        }

        self.ringDoorbell(0, 0);

        const start_tick = timer.ticks;
        var loop_spins: usize = 0;
        while ((timer.ticks > 0 and timer.ticks - start_tick < 50) or (timer.ticks == 0 and loop_spins < 2_000_000)) : (loop_spins += 1) {
            const ev_trb = &self.event_ring[self.event_dequeue];
            const ev_ctrl = ev_trb.control;
            const ev_cycle: u1 = @intCast(ev_ctrl & 1);

            if (ev_cycle == self.event_cycle) {
                const ev_type = (ev_ctrl >> 10) & 0x3F;
                const comp_code = (ev_trb.status >> 24) & 0xFF;
                const slot_id: u8 = @intCast((ev_ctrl >> 24) & 0xFF);

                self.event_dequeue += 1;
                if (self.event_dequeue == 256) {
                    self.event_dequeue = 0;
                    self.event_cycle ^= 1;
                }
                const erdp_val = @as(u64, self.event_ring_phys + self.event_dequeue * @sizeOf(XhciTrb)) | (1 << 3);
                writeMmio64(self.rt_regs + 0x38, erdp_val);

                if (ev_type == TRB_TYPE_COMMAND_COMPLETION) {
                    if (out_slot_id) |s| {
                        s.* = slot_id;
                    }
                    if (comp_code != 1) {
                        serial.serialWrite("[XHCI] Command completed with code: ");
                        serial.serialWriteDec(comp_code);
                        serial.serialWrite("\n");
                    }
                    return comp_code == 1; // 1 = Success
                }
            }
            asm volatile ("pause");
        }

        serial.serialWrite("[XHCI] Command timed out after 500ms\n");
        return false;
    }

    pub fn sendCommand(self: *XhciController, param: u64, status: u32, trb_type: u32) bool {
        const ctrl = (trb_type << 10) | @as(u32, self.cmd_cycle);
        return self.sendCommandRaw(param, status, ctrl, null);
    }

    pub fn enableSlot(self: *XhciController) ?u8 {
        var slot_id: u8 = 0;
        const ctrl = (TRB_TYPE_ENABLE_SLOT << 10) | @as(u32, self.cmd_cycle);
        if (!self.sendCommandRaw(0, 0, ctrl, &slot_id)) {
            return null;
        }
        if (slot_id == 0 or slot_id > self.max_slots) return null;
        return slot_id;
    }

    pub fn disableSlot(self: *XhciController, slot_id: u8) void {
        const ctrl = (TRB_TYPE_DISABLE_SLOT << 10) | (@as(u32, slot_id) << 24) | @as(u32, self.cmd_cycle);
        _ = self.sendCommandRaw(0, 0, ctrl, null);
    }

    pub fn allocSlot(self: *XhciController, slot_id: u8, port_idx: u8, speed_code: u8) ?usize {
        var s_idx: usize = 0;
        while (s_idx < self.slots.len) : (s_idx += 1) {
            if (!self.slots[s_idx].active) {
                var slot = &self.slots[s_idx];
                const page1 = dma.allocPage() orelse return null;
                const page2 = dma.allocPage() orelse {
                    dma.freePage(page1);
                    return null;
                };

                const p1_bytes: [*]u8 = @ptrFromInt(page1);
                const p2_bytes: [*]u8 = @ptrFromInt(page2);
                @memset(p1_bytes[0..dma.PAGE_SIZE], 0);
                @memset(p2_bytes[0..dma.PAGE_SIZE], 0);

                slot.active = true;
                slot.slot_id = slot_id;
                slot.port_idx = port_idx;
                slot.speed_code = speed_code;
                slot.input_ctx_phys = page1;
                slot.dev_ctx_phys = page2;

                slot.ep0_ring_phys = page1 + 2176;
                slot.ep0_ring = @ptrCast(@alignCast(p1_bytes + 2176));
                slot.ep0_ring[15] = XhciTrb{
                    .parameter = @as(u64, slot.ep0_ring_phys),
                    .status = 0,
                    .control = (TRB_TYPE_LINK << 10) | (1 << 1),
                };
                slot.ep0_enqueue = 0;
                slot.ep0_cycle = 1;

                slot.intr_ring_phys = page1 + 2432;
                slot.intr_ring = @ptrCast(@alignCast(p1_bytes + 2432));
                slot.intr_ring[15] = XhciTrb{
                    .parameter = @as(u64, slot.intr_ring_phys),
                    .status = 0,
                    .control = (TRB_TYPE_LINK << 10) | (1 << 1),
                };
                slot.intr_enqueue = 0;
                slot.intr_cycle = 1;
                slot.intr_dci = 0;

                slot.ctrl_buf_phys = page1 + 2688;
                slot.ctrl_buf = @ptrCast(@alignCast(p1_bytes + 2688));

                slot.intr2_ring_phys = page1 + 3200;
                slot.intr2_ring = @ptrCast(@alignCast(p1_bytes + 3200));
                slot.intr2_ring[15] = XhciTrb{
                    .parameter = @as(u64, slot.intr2_ring_phys),
                    .status = 0,
                    .control = (TRB_TYPE_LINK << 10) | (1 << 1),
                };
                slot.intr2_enqueue = 0;
                slot.intr2_cycle = 1;
                slot.intr2_dci = 0;

                return s_idx;
            }
        }
        return null;
    }

    pub fn addressDevice(self: *XhciController, slot_idx: usize, port_idx: u8, speed_code: u8) bool {
        if (slot_idx >= self.slots.len) return false;
        const slot = &self.slots[slot_idx];
        const ctx_size: usize = if (self.csz_64) 64 else 32;
        const input_ctx = @as([*]u32, @ptrFromInt(slot.input_ctx_phys));

        if (self.csz_64) {
            input_ctx[0] = 0; // Drop Context Flags Low
            input_ctx[1] = 0; // Drop Context Flags High
            input_ctx[2] = (1 << 0) | (1 << 1); // Add Context Flags Low: Slot (A0) + EP0 (A1)
            input_ctx[3] = 0; // Add Context Flags High
        } else {
            input_ctx[0] = 0; // Drop Context Flags
            input_ctx[1] = (1 << 0) | (1 << 1); // Add Context Flags: Slot (A0) + EP0 (A1)
        }

        const slot_ctx = @as([*]u32, @ptrFromInt(slot.input_ctx_phys + ctx_size));
        slot_ctx[0] = (@as(u32, speed_code) << 20) | (1 << 27);
        slot_ctx[1] = @as(u32, port_idx + 1) << 16;
        slot_ctx[2] = 0;
        slot_ctx[3] = 0;

        const ep0_ctx = @as([*]u32, @ptrFromInt(slot.input_ctx_phys + 2 * ctx_size));
        const max_p0: u32 = switch (speed_code) {
            4, 5 => 512,
            3 => 64,
            1 => 64,
            2 => 8,
            else => 8,
        };
        ep0_ctx[0] = 0;
        ep0_ctx[1] = (3 << 1) | (4 << 3) | (max_p0 << 16);
        ep0_ctx[2] = @as(u32, @intCast(slot.ep0_ring_phys & 0xFFFFFFFF)) | 1;
        ep0_ctx[3] = @as(u32, @intCast(slot.ep0_ring_phys >> 32));
        ep0_ctx[4] = 8;

        self.dcbaa[slot.slot_id] = @as(u64, slot.dev_ctx_phys);

        const cmd_ctrl = (TRB_TYPE_ADDRESS_DEVICE << 10) | (@as(u32, slot.slot_id) << 24) | @as(u32, self.cmd_cycle);
        return self.sendCommandRaw(@as(u64, slot.input_ctx_phys), 0, cmd_ctrl, null);
    }

    pub fn controlTransfer(
        self: *XhciController,
        slot_idx: usize,
        max_p0: u16,
        setup: *const UsbSetupPacket,
        data_out: ?[]const u8,
        data_in: ?[]u8,
    ) bool {
        _ = max_p0;
        if (slot_idx >= self.slots.len) return false;
        const slot = &self.slots[slot_idx];
        if (!slot.active) return false;

        const is_in = (setup.bmRequestType & 0x80) != 0;
        const trt: u32 = if (setup.wLength == 0) 0 else if (is_in) 3 else 2;
        const setup_param: u64 = @as(u64, setup.bmRequestType) |
            (@as(u64, setup.bRequest) << 8) |
            (@as(u64, setup.wValue) << 16) |
            (@as(u64, setup.wIndex) << 32) |
            (@as(u64, setup.wLength) << 48);

        const setup_idx = slot.ep0_enqueue;
        slot.ep0_ring[setup_idx] = XhciTrb{
            .parameter = setup_param,
            .status = 8,
            .control = (TRB_TYPE_SETUP_STAGE << 10) | (1 << 6) | (trt << 16) | @as(u32, slot.ep0_cycle),
        };
        slot.ep0_enqueue += 1;
        if (slot.ep0_enqueue == 15) {
            slot.ep0_ring[15].control = (TRB_TYPE_LINK << 10) | (1 << 1) | @as(u32, slot.ep0_cycle);
            slot.ep0_enqueue = 0;
            slot.ep0_cycle ^= 1;
        }

        if (setup.wLength > 0) {
            const len = setup.wLength;
            if (!is_in and data_out != null) {
                const chunk = @min(len, @as(u16, @intCast(data_out.?.len)));
                @memcpy(slot.ctrl_buf[0..chunk], data_out.?[0..chunk]);
            }

            const data_idx = slot.ep0_enqueue;
            slot.ep0_ring[data_idx] = XhciTrb{
                .parameter = @as(u64, slot.ctrl_buf_phys),
                .status = @as(u32, len),
                .control = (TRB_TYPE_DATA_STAGE << 10) | (if (is_in) @as(u32, 1 << 16) else 0) | @as(u32, slot.ep0_cycle),
            };
            slot.ep0_enqueue += 1;
            if (slot.ep0_enqueue == 15) {
                slot.ep0_ring[15].control = (TRB_TYPE_LINK << 10) | (1 << 1) | @as(u32, slot.ep0_cycle);
                slot.ep0_enqueue = 0;
                slot.ep0_cycle ^= 1;
            }
        }

        const status_dir: u32 = if (setup.wLength == 0 or !is_in) 1 else 0;
        const status_idx = slot.ep0_enqueue;
        slot.ep0_ring[status_idx] = XhciTrb{
            .parameter = 0,
            .status = 0,
            .control = (TRB_TYPE_STATUS_STAGE << 10) | (status_dir << 16) | (1 << 5) | @as(u32, slot.ep0_cycle),
        };
        slot.ep0_enqueue += 1;
        if (slot.ep0_enqueue == 15) {
            slot.ep0_ring[15].control = (TRB_TYPE_LINK << 10) | (1 << 1) | @as(u32, slot.ep0_cycle);
            slot.ep0_enqueue = 0;
            slot.ep0_cycle ^= 1;
        }

        self.ringDoorbell(slot.slot_id, 1);

        const start_tick = timer.ticks;
        var loop_spins: usize = 0;
        while ((timer.ticks > 0 and timer.ticks - start_tick < 50) or (timer.ticks == 0 and loop_spins < 2_000_000)) : (loop_spins += 1) {
            const ev_trb = &self.event_ring[self.event_dequeue];
            const ev_ctrl = ev_trb.control;
            const ev_cycle: u1 = @intCast(ev_ctrl & 1);

            if (ev_cycle == self.event_cycle) {
                const ev_type = (ev_ctrl >> 10) & 0x3F;
                const ev_slot = (ev_ctrl >> 24) & 0xFF;

                self.event_dequeue += 1;
                if (self.event_dequeue == 256) {
                    self.event_dequeue = 0;
                    self.event_cycle ^= 1;
                }
                const erdp_val = @as(u64, self.event_ring_phys + self.event_dequeue * @sizeOf(XhciTrb)) | (1 << 3);
                writeMmio64(self.rt_regs + 0x38, erdp_val);

                if (ev_type == TRB_TYPE_TRANSFER_EVENT and ev_slot == slot.slot_id) {
                    const comp_code = (ev_trb.status >> 24) & 0xFF;
                    if (comp_code == 1 or comp_code == 13) {
                        if (is_in and data_in != null) {
                            const copy_len = @min(setup.wLength, @as(u16, @intCast(data_in.?.len)));
                            @memcpy(data_in.?[0..copy_len], slot.ctrl_buf[0..copy_len]);
                        }
                        return true;
                    }
                    serial.serialWrite("[XHCI] Transfer failed with completion code: ");
                    serial.serialWriteDec(comp_code);
                    serial.serialWrite("\n");
                    return false;
                }
            }
            asm volatile ("pause");
        }
        serial.serialWrite("[XHCI] Control transfer timed out after 500ms\n");
        return false;
    }

    pub fn configureInterruptEndpoint(
        self: *XhciController,
        slot_idx: usize,
        ep_num: u8,
        max_packet: u16,
        interval: u8,
    ) bool {
        if (slot_idx >= self.slots.len) return false;
        var slot = &self.slots[slot_idx];
        if (!slot.active) return false;

        const ctx_size: usize = if (self.csz_64) 64 else 32;
        const dci: u8 = ep_num * 2 + 1;

        const use_second = (slot.intr_dci != 0 and slot.intr_dci != dci);
        if (use_second) {
            slot.intr2_dci = dci;
        } else {
            slot.intr_dci = dci;
        }
        const ring_phys = if (use_second) slot.intr2_ring_phys else slot.intr_ring_phys;

        const input_ctx = @as([*]u32, @ptrFromInt(slot.input_ctx_phys));
        const add_mask: u32 = (1 << 0) | (@as(u32, 1) << @as(u5, @intCast(dci)));

        if (self.csz_64) {
            input_ctx[0] = 0; // Drop Context Flags Low
            input_ctx[1] = 0; // Drop Context Flags High
            input_ctx[2] = add_mask; // Add Context Flags Low: Slot (A0) + Endpoint (Adci)
            input_ctx[3] = 0; // Add Context Flags High
        } else {
            input_ctx[0] = 0; // Drop Context Flags
            input_ctx[1] = add_mask; // Add Context Flags
        }

        const slot_ctx = @as([*]u32, @ptrFromInt(slot.input_ctx_phys + ctx_size));
        const curr_entries = (slot_ctx[0] >> 27) & 0x1F;
        const max_entries = @max(curr_entries, dci);
        slot_ctx[0] = (slot_ctx[0] & ~@as(u32, 0x1F << 27)) | (@as(u32, max_entries) << 27);

        const ep_ctx = @as([*]u32, @ptrFromInt(slot.input_ctx_phys + (@as(usize, dci) + 1) * ctx_size));
        
        var p_exp: u32 = 0;
        const target_iv: u32 = if (interval > 0) interval else 10;
        while ((@as(u32, 1) << @as(u5, @intCast(p_exp))) < target_iv and p_exp < 8) : (p_exp += 1) {}
        const interval_val: u32 = @min(p_exp + 3, 15);

        const max_p: u32 = @min(@max(max_packet, 8), 64);
        ep_ctx[0] = interval_val << 16;
        ep_ctx[1] = (3 << 1) | (7 << 3) | (max_p << 16);
        ep_ctx[2] = @as(u32, @intCast(ring_phys & 0xFFFFFFFF)) | 1;
        ep_ctx[3] = @as(u32, @intCast(ring_phys >> 32));
        // Dword 4: Low 16 bits = Average TRB Length, High 16 bits = Max ESIT Payload (mandatory on bare-metal xHCI!)
        ep_ctx[4] = (max_p << 16) | max_p;

        const cmd_ctrl = (TRB_TYPE_CONFIG_ENDPOINT << 10) | (@as(u32, slot.slot_id) << 24) | @as(u32, self.cmd_cycle);
        const ok = self.sendCommandRaw(@as(u64, slot.input_ctx_phys), 0, cmd_ctrl, null);
        if (!ok) {
            serial.serialWrite("[XHCI] Configure Endpoint failed for DCI=");
            serial.serialWriteDec(dci);
            serial.serialWrite("\n");
        }
        return ok;
    }

    pub fn queueInterruptTransfer(
        self: *XhciController,
        slot_idx: usize,
        dci_arg: u8,
        report_buf_phys: usize,
        max_len: u16,
    ) void {
        if (slot_idx >= self.slots.len) return;
        var slot = &self.slots[slot_idx];
        if (!slot.active) return;

        const dci: u8 = if (dci_arg != 0) dci_arg else slot.intr_dci;
        if (dci == 0) return;

        if (dci == slot.intr2_dci and slot.intr2_dci != 0) {
            const idx = slot.intr2_enqueue;
            slot.intr2_ring[idx] = XhciTrb{
                .parameter = @as(u64, report_buf_phys),
                .status = @as(u32, max_len),
                .control = (TRB_TYPE_NORMAL << 10) | (1 << 5) | @as(u32, slot.intr2_cycle),
            };
            slot.intr2_enqueue += 1;
            if (slot.intr2_enqueue == 15) {
                slot.intr2_ring[15].control = (TRB_TYPE_LINK << 10) | (1 << 1) | @as(u32, slot.intr2_cycle);
                slot.intr2_enqueue = 0;
                slot.intr2_cycle ^= 1;
            }
            self.ringDoorbell(slot.slot_id, dci);
        } else {
            const idx = slot.intr_enqueue;
            slot.intr_ring[idx] = XhciTrb{
                .parameter = @as(u64, report_buf_phys),
                .status = @as(u32, max_len),
                .control = (TRB_TYPE_NORMAL << 10) | (1 << 5) | @as(u32, slot.intr_cycle),
            };
            slot.intr_enqueue += 1;
            if (slot.intr_enqueue == 15) {
                slot.intr_ring[15].control = (TRB_TYPE_LINK << 10) | (1 << 1) | @as(u32, slot.intr_cycle);
                slot.intr_enqueue = 0;
                slot.intr_cycle ^= 1;
            }
            self.ringDoorbell(slot.slot_id, dci);
        }
    }

    pub fn getPortSpeedCode(self: *XhciController, port_idx: u8) u8 {
        if (port_idx >= self.num_ports or port_idx >= 32) return 1;
        const portsc_addr = self.op_regs + 0x400 + (@as(usize, port_idx) * 0x10);
        const status = readMmio32(portsc_addr);
        return @intCast((status >> 10) & 0x0F);
    }

    pub fn pollEvents(self: *XhciController, on_transfer: *const fn (slot_id: u8, dci: u8, rem_bytes: u32, comp_code: u32) void) void {
        while (true) {
            const ev_trb = &self.event_ring[self.event_dequeue];
            const ev_ctrl = ev_trb.control;
            const ev_cycle: u1 = @intCast(ev_ctrl & 1);
            if (ev_cycle != self.event_cycle) break;

            const ev_type = (ev_ctrl >> 10) & 0x3F;
            const ev_slot: u8 = @intCast((ev_ctrl >> 24) & 0xFF);
            const comp_code: u32 = (ev_trb.status >> 24) & 0xFF;
            const rem_bytes: u32 = ev_trb.status & 0xFFFFFF;
            const dci: u8 = @intCast((ev_ctrl >> 16) & 0x1F);

            self.event_dequeue += 1;
            if (self.event_dequeue == 256) {
                self.event_dequeue = 0;
                self.event_cycle ^= 1;
            }
            const erdp_val = @as(u64, self.event_ring_phys + self.event_dequeue * @sizeOf(XhciTrb)) | (1 << 3);
            writeMmio64(self.rt_regs + 0x38, erdp_val);

            if (ev_type == TRB_TYPE_TRANSFER_EVENT) {
                on_transfer(ev_slot, dci, rem_bytes, comp_code);
            }
        }
    }
};
