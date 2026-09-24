const std = @import("std");
const root = @import("root");
const serial = root.serial;
const timer = @import("../timer.zig");
const pci = @import("../pci.zig");
const types = @import("types.zig");
const dma = @import("dma.zig");
const pci_detect = @import("pci_detect.zig");

pub const UsbSetupPacket = types.UsbSetupPacket;
pub const UsbPortStatus = types.UsbPortStatus;

pub const EhciQtd = extern struct {
    next_qtd: u32 = 1, // Terminate = 1
    alt_next_qtd: u32 = 1,
    token: u32 = 0, // Bit 7: Active, 9:8: PID, 11:10: CERR, 15: IOC, 30:16: bytes, 31: toggle
    buf: [5]u32 = [_]u32{0} ** 5,
};

pub const EhciQh = extern struct {
    horizontal_link: u32 = 1, // Next QH (bit 1=1 for QH)
    ep_characteristics: u32 = 0, // DevAddr (6:0), EP (11:8), Speed (13:12: 10b=High), DTC (14), H (15), MaxPacket (26:16)
    ep_capabilities: u32 = 0, // s-mask (7:0), c-mask (15:8), Mult (31:30)
    current_qtd: u32 = 1,
    overlay_next_qtd: u32 = 1,
    overlay_alt_next_qtd: u32 = 1,
    overlay_token: u32 = 0,
    overlay_buf: [5]u32 = [_]u32{0} ** 5,
};

// qTD token bits
pub const QTD_ACTIVE: u32 = 1 << 7;
pub const QTD_PID_OUT: u32 = 0 << 8;
pub const QTD_PID_IN: u32 = 1 << 8;
pub const QTD_PID_SETUP: u32 = 2 << 8;
pub const QTD_3ERRORS: u32 = 3 << 10;
pub const QTD_IOC: u32 = 1 << 15;
pub const QTD_TOGGLE_1: u32 = 1 << 31;

inline fn readMmio32(addr: usize) u32 {
    const p: *const volatile u32 = @ptrFromInt(addr);
    return p.*;
}

inline fn writeMmio32(addr: usize, val: u32) void {
    const p: *volatile u32 = @ptrFromInt(addr);
    p.* = val;
}

inline fn readMmio8(addr: usize) u8 {
    const p: *const volatile u8 = @ptrFromInt(addr);
    return p.*;
}

inline fn writeMmio8(addr: usize, val: u8) void {
    const p: *volatile u8 = @ptrFromInt(addr);
    p.* = val;
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

pub const EhciController = struct {
    id: u8,
    bus: u8,
    dev: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    irq: u8,
    mmio_base: usize,
    op_regs: usize = 0,
    num_ports: u8 = 0,
    num_companions: u8 = 0,
    ports: [16]UsbPortStatus = undefined,

    // PMM DMA Memory
    periodic_list_phys: usize = 0,
    periodic_list: *[1024]u32 = undefined,

    async_page_phys: usize = 0,
    async_qh: *EhciQh = undefined,
    ctrl_qh: *EhciQh = undefined,
    ctrl_qtds: *[8]EhciQtd = undefined,
    ctrl_setup_pkt: *UsbSetupPacket = undefined,
    ctrl_buf: *[512]u8 = undefined,

    bulk_qh: *EhciQh = undefined,
    bulk_qtds: *[16]EhciQtd = undefined,
    bulk_buf: *[2048]u8 = undefined,

    dma_pool: dma.UsbDmaPool = dma.UsbDmaPool.init(),

    pub fn init(self: *EhciController, pci_ctrl: *const pci_detect.PciUsbController, id: u8) bool {
        self.id = id;
        self.bus = pci_ctrl.bus;
        self.dev = pci_ctrl.dev;
        self.func = pci_ctrl.func;
        self.vendor_id = pci_ctrl.vendor_id;
        self.device_id = pci_ctrl.device_id;
        self.irq = pci_ctrl.irq;
        self.mmio_base = pci_ctrl.mmio_base;

        if (self.mmio_base == 0) return false;

        // Never touch MMIO outside the 0..64GB boot identity map.
        if (self.mmio_base >= 0x1000000000) return false;

        // Sanity: unmapped MMIO reads back as 0xFF/0xFFFFFFFF. Touching a
        // truncated 64-bit BAR (low half aliasing RAM) would corrupt memory,
        // so bail out early instead of programming garbage addresses.
        const cap_len = readMmio8(self.mmio_base + 0x00);
        if (cap_len == 0 or cap_len == 0xFF or cap_len > 0x40) return false;
        self.op_regs = self.mmio_base + cap_len;

        const hcs_params = readMmio32(self.mmio_base + 0x04);
        if (hcs_params == 0 or hcs_params == 0xFFFFFFFF) return false;
        self.num_ports = @intCast(@min(hcs_params & 0x0F, 16));
        self.num_companions = @intCast((hcs_params >> 12) & 0x0F);

        const hcc_params = readMmio32(self.mmio_base + 0x08);
        const eecp = @as(u8, @intCast((hcc_params >> 8) & 0xFF));

        // BIOS Handoff if EECP present
        if (eecp >= 0x40) {
            const legsup = pci.readConfig(self.bus, self.dev, self.func, eecp);
            if ((legsup & 0xFF) == 1) { // USBLEGSUP
                // Request OS Ownership (bit 24)
                pci.writeConfig(self.bus, self.dev, self.func, eecp, legsup | (1 << 24));
                var spins: u32 = 0;
                while (spins < 1000) : (spins += 1) {
                    const check = pci.readConfig(self.bus, self.dev, self.func, eecp);
                    if ((check & (1 << 16)) == 0) break; // BIOS released
                    spinDelayMs(1);
                }
                // Disable all BIOS SMIs (clear USBLEGCTLSTS at offset eecp + 4)
                pci.writeConfig(self.bus, self.dev, self.func, eecp + 4, 0);
            }
        }

        // Halt controller
        var usbcmd = readMmio32(self.op_regs + 0x00);
        writeMmio32(self.op_regs + 0x00, usbcmd & ~@as(u32, 1)); // Clear RS
        var wait_halt: u32 = 0;
        while (wait_halt < 1000) : (wait_halt += 1) {
            if ((readMmio32(self.op_regs + 0x04) & (1 << 12)) != 0) break; // HCHalted
            spinDelayMs(1);
        }

        // Reset controller
        writeMmio32(self.op_regs + 0x00, readMmio32(self.op_regs + 0x00) | 2); // HCRESET
        var wait_reset: u32 = 0;
        while (wait_reset < 1000) : (wait_reset += 1) {
            if ((readMmio32(self.op_regs + 0x00) & 2) == 0) break;
            spinDelayMs(1);
        }

        // Allocate Periodic Frame List (4KB aligned)
        // EHCI uses 32-bit DMA pointers: fail if PMM hands out pages >= 4GB
        // (real hardware with lots of RAM) instead of truncating the address.
        const p_page = dma.allocPage() orelse return false;
        if (p_page >= 0x100000000) {
            dma.freePage(p_page);
            return false;
        }
        self.periodic_list_phys = p_page;
        self.periodic_list = @ptrCast(@alignCast(@as([*]u32, @ptrFromInt(p_page))));
        var f: usize = 0;
        while (f < 1024) : (f += 1) {
            self.periodic_list[f] = 1; // Terminate
        }
        writeMmio32(self.op_regs + 0x14, @intCast(self.periodic_list_phys));

        // Allocate Async Schedule memory
        const a_page = dma.allocPage() orelse {
            dma.freePage(p_page);
            return false;
        };
        if (a_page >= 0x100000000) {
            dma.freePage(a_page);
            dma.freePage(p_page);
            return false;
        }
        self.async_page_phys = a_page;
        const page_bytes: [*]u8 = @ptrFromInt(a_page);
        @memset(page_bytes[0..dma.PAGE_SIZE], 0);

        self.async_qh = @ptrCast(@alignCast(page_bytes + 0));
        self.ctrl_qh = @ptrCast(@alignCast(page_bytes + 128));
        self.ctrl_qtds = @ptrCast(@alignCast(page_bytes + 256));
        self.ctrl_setup_pkt = @ptrCast(@alignCast(page_bytes + 512));
        self.bulk_qh = @ptrCast(@alignCast(page_bytes + 576));
        self.bulk_qtds = @ptrCast(@alignCast(page_bytes + 704));
        self.ctrl_buf = @ptrCast(@alignCast(page_bytes + 1280));
        self.bulk_buf = @ptrCast(@alignCast(page_bytes + 1800));

        // Setup Async Schedule Ring: async_qh -> ctrl_qh -> bulk_qh -> async_qh
        const async_qh_phys: u32 = @intCast(@intFromPtr(self.async_qh));
        const ctrl_qh_phys: u32 = @intCast(@intFromPtr(self.ctrl_qh));
        const bulk_qh_phys: u32 = @intCast(@intFromPtr(self.bulk_qh));

        self.async_qh.horizontal_link = ctrl_qh_phys | 0x02; // Points to ctrl_qh
        self.async_qh.ep_characteristics = (1 << 15); // H = Head of Reclamation
        self.async_qh.current_qtd = 1;
        self.async_qh.overlay_next_qtd = 1;
        self.async_qh.overlay_alt_next_qtd = 1;

        self.ctrl_qh.horizontal_link = bulk_qh_phys | 0x02; // Points to bulk_qh
        self.ctrl_qh.ep_characteristics = (2 << 12) | (64 << 16) | (1 << 14); // High-Speed (10b), 64 max packet, DTC=1
        self.ctrl_qh.current_qtd = 1;
        self.ctrl_qh.overlay_next_qtd = 1;
        self.ctrl_qh.overlay_alt_next_qtd = 1;

        self.bulk_qh.horizontal_link = async_qh_phys | 0x02; // Circular link back to async_qh
        self.bulk_qh.ep_characteristics = (2 << 12) | (512 << 16); // High-Speed (10b), 512 max packet
        self.bulk_qh.current_qtd = 1;
        self.bulk_qh.overlay_next_qtd = 1;
        self.bulk_qh.overlay_alt_next_qtd = 1;

        writeMmio32(self.op_regs + 0x18, async_qh_phys);

        // Linux starts the controller before driving PORTSC.PP.  Some
        // controllers ignore power writes while the host is still stopped,
        // which leaves the keyboard completely unpowered.
        usbcmd = readMmio32(self.op_regs + 0x00);
        writeMmio32(self.op_regs + 0x00, usbcmd | (1 << 0)); // Run first
        spinDelayMs(5);
        var run_wait: u32 = 0;
        while (run_wait < 1000 and (readMmio32(self.op_regs + 0x04) & (1 << 12)) != 0) : (run_wait += 1) {
            spinDelayMs(0);
        }
        if (run_wait >= 1000) {
            serial.serialWrite("[EHCI] WARN: controller did not leave HALT state\n");
        }

        // Claim the ports only after Run is visible.  Linux also delays the
        // handoff briefly before enabling the async/periodic schedules.
        writeMmio32(self.op_regs + 0x40, 1);
        spinDelayMs(5);
        usbcmd = readMmio32(self.op_regs + 0x00);
        writeMmio32(self.op_regs + 0x00, usbcmd | (1 << 0) | (1 << 4) | (1 << 5));
        // QEMU and a few older controllers do not report ASS/PSS in the
        // operational status register until the first schedule entry is
        // consumed, so do not treat those bits as a power-ready barrier.
        spinDelayMs(1);

        // Power each port and read the register back.  Keep the diagnostic
        // explicit: a missing PP bit is a hardware/BIOS handoff problem, not
        // a HID parsing problem.
        var p: u8 = 0;
        while (p < self.num_ports) : (p += 1) {
            const port_reg = self.op_regs + 0x44 + (@as(usize, p) * 4);
            const val = readMmio32(port_reg);
            writeMmio32(port_reg, val | (1 << 12)); // Port Power
            const powered = readMmio32(port_reg);
            if ((powered & (1 << 12)) == 0) {
                serial.serialWrite("[EHCI] Port ");
                serial.serialWriteDec(p + 1);
                serial.serialWrite(": VBUS power did not latch\n");
            }
        }
        spinDelayMs(20);

        // Scan and initialize ports after VBUS is actually enabled.
        self.checkPorts();

        return true;
    }

    pub fn deinit(self: *EhciController) void {
        if (self.op_regs != 0) {
            writeMmio32(self.op_regs + 0x00, 0); // Stop controller
        }
        if (self.periodic_list_phys != 0) {
            dma.freePage(self.periodic_list_phys);
            self.periodic_list_phys = 0;
        }
        if (self.async_page_phys != 0) {
            dma.freePage(self.async_page_phys);
            self.async_page_phys = 0;
        }
        self.dma_pool.deinit();
    }

    pub fn checkPorts(self: *EhciController) void {
        var p: u8 = 0;
        while (p < self.num_ports) : (p += 1) {
            const port_reg = self.op_regs + 0x44 + (@as(usize, p) * 4);
            var status = readMmio32(port_reg);
            if ((status & (1 << 12)) == 0) {
                writeMmio32(port_reg, (status & ~@as(u32, 1 << 2)) | (1 << 12));
                spinDelayMs(2);
                status = readMmio32(port_reg);
            }

            const connected = (status & 0x01) != 0;

            if (connected) {
                // Clear connect status change (RW1C bit 1)
                if ((status & 0x02) != 0) {
                    writeMmio32(port_reg, status);
                }

                // Check LineStatus (bits 11:10)
                const line_status = (status >> 10) & 0x03;
                if (line_status == 0x01 and self.num_companions > 0) {
                    // Low-Speed device on EHCI -> release port to companion (Port Owner bit 13)
                    writeMmio32(port_reg, (status & ~@as(u32, 1 << 2)) | (1 << 13));
                    self.ports[p] = .{
                        .port = p + 1,
                        .connected = false,
                        .enabled = false,
                        .powered = (readMmio32(port_reg) & (1 << 12)) != 0,
                        .speed = "Low-Speed (1.5 Mbps)",
                        .device_desc = "Routed to Companion Controller",
                    };
                    continue;
                }

                // High-Speed / Full-Speed Reset: assert PR (bit 8) for 50ms, then deassert
                writeMmio32(port_reg, (status & ~@as(u32, 1 << 2)) | (1 << 8));
                spinDelayMs(50);
                writeMmio32(port_reg, readMmio32(port_reg) & ~@as(u32, 1 << 8));
                spinDelayMs(20);

                status = readMmio32(port_reg);
                const enabled = (status & 0x04) != 0;

                if (!enabled and self.num_companions > 0) {
                    // Full-Speed device on EHCI -> release port to companion
                    writeMmio32(port_reg, (status & ~@as(u32, 1 << 2)) | (1 << 13));
                    self.ports[p] = .{
                        .port = p + 1,
                        .connected = false,
                        .enabled = false,
                        .powered = (readMmio32(port_reg) & (1 << 12)) != 0,
                        .speed = "Full-Speed (12 Mbps)",
                        .device_desc = "Routed to Companion Controller",
                    };
                    continue;
                }

                self.ports[p] = .{
                    .port = p + 1,
                    .connected = true,
                    .enabled = enabled,
                    .powered = (status & (1 << 12)) != 0,
                    .speed = "High-Speed (480 Mbps)",
                    .device_desc = "USB 2.0 High-Speed Device",
                };
            } else {
                self.ports[p] = .{
                    .port = p + 1,
                    .connected = false,
                    .enabled = false,
                    .powered = (status & (1 << 12)) != 0,
                    .speed = "High-Speed (480 Mbps)",
                    .device_desc = "No device",
                };
            }
        }
    }

    pub fn resetPort(self: *EhciController, port_idx: u8) bool {
        if (port_idx >= self.num_ports) return false;
        const port_reg = self.op_regs + 0x44 + (@as(usize, port_idx) * 4);
        var status = readMmio32(port_reg);

        writeMmio32(port_reg, (status & ~@as(u32, 1 << 2)) | (1 << 8));
        spinDelayMs(50);
        writeMmio32(port_reg, readMmio32(port_reg) & ~@as(u32, 1 << 8));
        spinDelayMs(20);

        status = readMmio32(port_reg);
        return (status & 0x04) != 0;
    }

    pub fn controlTransfer(
        self: *EhciController,
        dev_addr: u8,
        max_packet0: u16,
        setup: *const UsbSetupPacket,
        data_out: ?[]const u8,
        data_in: ?[]u8,
    ) bool {
        const requested_len: usize = @intCast(setup.wLength);
        const supplied_len: usize = if (data_in) |d| d.len else if (data_out) |d| d.len else 0;
        if (requested_len > 0 and supplied_len == 0) return false;
        const data_len = @min(@min(requested_len, self.ctrl_buf.len), supplied_len);
        var wire_setup = setup.*;
        wire_setup.wLength = @intCast(data_len);
        self.ctrl_setup_pkt.* = wire_setup;
        @memset(self.ctrl_buf[0..], 0);
        var reset_idx: usize = 0;
        while (reset_idx < self.ctrl_qtds.len) : (reset_idx += 1) {
            self.ctrl_qtds[reset_idx] = .{};
        }

        // Update target address and max packet size in ctrl_qh
        const mp: u32 = @min(if (max_packet0 > 0) max_packet0 else 64, 64);
        self.ctrl_qh.ep_characteristics = (@as(u32, dev_addr) & 0x7F) |
            (2 << 12) | // High Speed (10b)
            (1 << 14) | // DTC
            (mp << 16);

        // Build Setup qTD
        self.ctrl_qtds[0].token = QTD_ACTIVE | QTD_PID_SETUP | QTD_3ERRORS | (@as(u32, 8) << 16);
        self.ctrl_qtds[0].buf[0] = @intCast(@intFromPtr(self.ctrl_setup_pkt));
        self.ctrl_qtds[0].buf[1] = 0;
        self.ctrl_qtds[0].next_qtd = 1;
        self.ctrl_qtds[0].alt_next_qtd = 1;

        var qtd_idx: usize = 1;
        var toggle: u32 = 1;

        if (data_in) |_| {
            var transferred: usize = 0;
            const total = data_len;
            if (total > self.ctrl_buf.len) return false;
            while (transferred < total) {
                if (qtd_idx + 1 >= self.ctrl_qtds.len) {
                    self.ctrl_qh.overlay_next_qtd = 1;
                    return false;
                }
                const chunk = @min(total - transferred, mp);
                self.ctrl_qtds[qtd_idx - 1].next_qtd = @intCast(@intFromPtr(&self.ctrl_qtds[qtd_idx]));
                self.ctrl_qtds[qtd_idx].token = QTD_ACTIVE | QTD_PID_IN | QTD_3ERRORS | (@as(u32, @intCast(chunk)) << 16) | (toggle << 31);
                self.ctrl_qtds[qtd_idx].buf[0] = @intCast(@intFromPtr(&self.ctrl_buf[transferred]));
                self.ctrl_qtds[qtd_idx].alt_next_qtd = 1;
                toggle ^= 1;
                transferred += chunk;
                qtd_idx += 1;
            }
        } else if (data_out) |dout| {
            var transferred: usize = 0;
            const total = data_len;
            if (total > self.ctrl_buf.len) return false;
            while (transferred < total) {
                if (qtd_idx + 1 >= self.ctrl_qtds.len) {
                    self.ctrl_qh.overlay_next_qtd = 1;
                    return false;
                }
                const chunk = @min(total - transferred, mp);
                @memcpy(self.ctrl_buf[transferred .. transferred + chunk], dout[transferred .. transferred + chunk]);
                self.ctrl_qtds[qtd_idx - 1].next_qtd = @intCast(@intFromPtr(&self.ctrl_qtds[qtd_idx]));
                self.ctrl_qtds[qtd_idx].token = QTD_ACTIVE | QTD_PID_OUT | QTD_3ERRORS | (@as(u32, @intCast(chunk)) << 16) | (toggle << 31);
                self.ctrl_qtds[qtd_idx].buf[0] = @intCast(@intFromPtr(&self.ctrl_buf[transferred]));
                self.ctrl_qtds[qtd_idx].alt_next_qtd = 1;
                toggle ^= 1;
                transferred += chunk;
                qtd_idx += 1;
            }
        }

        // Status qTD
        if (qtd_idx == 0 or qtd_idx >= self.ctrl_qtds.len) {
            self.ctrl_qh.overlay_next_qtd = 1;
            return false;
        }
        self.ctrl_qtds[qtd_idx - 1].next_qtd = @intCast(@intFromPtr(&self.ctrl_qtds[qtd_idx]));
        const is_read = (wire_setup.bmRequestType & 0x80) != 0;
        const status_pid = if (is_read) QTD_PID_OUT else QTD_PID_IN;
        self.ctrl_qtds[qtd_idx].token = QTD_ACTIVE | status_pid | QTD_3ERRORS | QTD_IOC | QTD_TOGGLE_1;
        self.ctrl_qtds[qtd_idx].buf[0] = 0;
        self.ctrl_qtds[qtd_idx].next_qtd = 1; // Terminate
        self.ctrl_qtds[qtd_idx].alt_next_qtd = 1;

        const last_qtd = qtd_idx;

        // Attach first qTD to ctrl_qh
        self.ctrl_qh.current_qtd = 1;
        self.ctrl_qh.overlay_next_qtd = @intCast(@intFromPtr(&self.ctrl_qtds[0]));
        self.ctrl_qh.overlay_token = 0;

        // Poll for completion with millisecond timeout (up to 500ms for bare metal hardware)
        var wait_ms: u32 = 0;
        while (wait_ms < 500) : (wait_ms += 1) {
            var inner: u32 = 0;
            while (inner < 50) : (inner += 1) {
                const last_tok = @as(*const volatile u32, @ptrCast(&self.ctrl_qtds[last_qtd].token)).*;
                if ((last_tok & QTD_ACTIVE) == 0) {
                    // Check errors
                    var err = false;
                    var k: usize = 0;
                    while (k <= last_qtd) : (k += 1) {
                        const tok = @as(*const volatile u32, @ptrCast(&self.ctrl_qtds[k].token)).*;
                        if ((tok & 0x7E) != 0) { // Error bits: Halted, Buffer Error, Babble, XactErr, Missed uFrame
                            err = true;
                            break;
                        }
                    }
                    self.ctrl_qh.overlay_next_qtd = 1;
                    if (err) return false;

                    if (data_in) |din| {
                        var actual_len: usize = 0;
                        var data_qtd: usize = 1;
                        var offset: usize = 0;
                        while (data_qtd < qtd_idx) : (data_qtd += 1) {
                            const tok = @as(*const volatile u32, @ptrCast(&self.ctrl_qtds[data_qtd].token)).*;
                            const chunk = @min(data_len - offset, @as(usize, @intCast(mp)));
                            const residual: usize = @intCast((tok >> 16) & 0x7FFF);
                            actual_len += if (residual >= chunk) 0 else chunk - residual;
                            offset += chunk;
                        }
                        if (actual_len > din.len) actual_len = din.len;
                        @memcpy(din[0..actual_len], self.ctrl_buf[0..actual_len]);
                    }
                    return true;
                }
                asm volatile ("pause");
            }
            spinDelayMs(1);
        }

        self.ctrl_qh.overlay_next_qtd = 1;
        return false;
    }

    pub fn bulkTransfer(
        self: *EhciController,
        dev_addr: u8,
        ep_num: u8,
        is_in: bool,
        toggle: *u1,
        max_packet: u16,
        data: []u8,
    ) ?usize {
        if (data.len == 0) return 0;
        const mp: u32 = if (max_packet > 0) max_packet else 512;
        var total_transferred: usize = 0;

        while (total_transferred < data.len) {
            const chunk_total = @min(data.len - total_transferred, self.bulk_buf.len);

            self.bulk_qh.ep_characteristics = (@as(u32, dev_addr) & 0x7F) |
                (@as(u32, ep_num) << 8) |
                (2 << 12) | // High Speed (10b)
                (mp << 16);

            if (is_in) {
                @memset(self.bulk_buf[0..chunk_total], 0);
            } else {
                @memcpy(self.bulk_buf[0..chunk_total], data[total_transferred .. total_transferred + chunk_total]);
            }

            const pid = if (is_in) QTD_PID_IN else QTD_PID_OUT;
            self.bulk_qtds[0].token = QTD_ACTIVE | pid | QTD_3ERRORS | QTD_IOC |
                (@as(u32, @intCast(chunk_total)) << 16) | (@as(u32, toggle.*) << 31);
            self.bulk_qtds[0].buf[0] = @intCast(@intFromPtr(&self.bulk_buf[0]));
            self.bulk_qtds[0].buf[1] = 0;
            self.bulk_qtds[0].buf[2] = 0;
            self.bulk_qtds[0].buf[3] = 0;
            self.bulk_qtds[0].buf[4] = 0;
            self.bulk_qtds[0].next_qtd = 1; // Terminate
            self.bulk_qtds[0].alt_next_qtd = 1;

            const packets = (chunk_total + mp - 1) / mp;
            if ((packets & 1) != 0) {
                toggle.* ^= 1;
            }

            // Attach to bulk_qh
            self.bulk_qh.current_qtd = 1;
            self.bulk_qh.overlay_next_qtd = @intCast(@intFromPtr(&self.bulk_qtds[0]));
            self.bulk_qh.overlay_token = 0;

            // Poll for completion non-blockingly
            var spin: u32 = 0;
            const max_spins: u32 = 100000;
            var completed = false;
            while (spin < max_spins) : (spin += 1) {
                const tok = @as(*const volatile u32, @ptrCast(&self.bulk_qtds[0].token)).*;
                if ((tok & QTD_ACTIVE) == 0) {
                    completed = true;
                    break;
                }
                asm volatile ("pause");
            }

            self.bulk_qh.overlay_next_qtd = 1;

            if (!completed) {
                return null;
            }

            const final_tok = @as(*const volatile u32, @ptrCast(&self.bulk_qtds[0].token)).*;
            if ((final_tok & 0x7E) != 0) {
                return null;
            }

            var actual_chunk: usize = chunk_total;
            if (is_in) {
                const residual: usize = @intCast((final_tok >> 16) & 0x7FFF);
                actual_chunk = if (residual >= chunk_total) 0 else chunk_total - residual;
                if (actual_chunk > 0) {
                    @memcpy(data[total_transferred .. total_transferred + actual_chunk], self.bulk_buf[0..actual_chunk]);
                }
            }

            total_transferred += actual_chunk;
            if (actual_chunk < chunk_total) break;
        }

        return total_transferred;
    }

    pub fn linkInterruptQh(self: *EhciController, qh: *EhciQh) void {
        self.linkInterruptQhScheduled(qh, 0, 1);
    }

    pub fn linkInterruptQhScheduled(self: *EhciController, qh: *EhciQh, start: usize, interval: usize) void {
        const qh_phys: u32 = @intCast(@intFromPtr(qh) | 0x02); // 0x02 = QH
        const step = @max(interval, 1);
        var f = start % 1024;
        while (f < 1024) : (f += step) {
            self.periodic_list[f] = qh_phys;
        }
    }
};
