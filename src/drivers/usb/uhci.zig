const std = @import("std");
const root = @import("root");
const serial = root.serial;
const timer = @import("../timer.zig");
const types = @import("types.zig");
const dma = @import("dma.zig");
const pci_detect = @import("pci_detect.zig");

pub const UsbSetupPacket = types.UsbSetupPacket;
pub const UsbPortStatus = types.UsbPortStatus;

pub const UhciQh = extern struct {
    head_link: u32 = 1, // Next QH (bit 1=1) or terminate (bit 0=1)
    element_link: u32 = 1, // First TD (bit 1=0) or QH (bit 1=1) or terminate (bit 0=1)
    _pad0: u32 = 0,
    _pad1: u32 = 0,
};

pub const UhciTd = extern struct {
    link: u32 = 1, // Next TD (bit 1=0) or QH (bit 1=1) or terminate (bit 0=1)
    ctrl_status: u32 = 0, // Control and status bits
    token: u32 = 0, // Packet token: PID, dev addr, EP, toggle, max len
    buffer: u32 = 0, // 32-bit physical buffer pointer
};

pub const TD_CTRL_ACTIVE: u32 = 1 << 23;
pub const TD_CTRL_IOC: u32 = 1 << 24;
pub const TD_CTRL_LOWSPEED: u32 = 1 << 26;
pub const TD_CTRL_3ERRORS: u32 = 3 << 27;
pub const TD_CTRL_SPD: u32 = 1 << 29;
pub const TD_CTRL_STALL: u32 = 1 << 22;
pub const TD_CTRL_BABBLE: u32 = 1 << 20;
pub const TD_CTRL_NAK: u32 = 1 << 19;
pub const TD_CTRL_TIMEOUT: u32 = 1 << 18;
pub const TD_CTRL_DATA_ERR: u32 = 1 << 17;

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %%dx, %%al"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %%al, %%dx"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
    );
}

inline fn inw(port: u16) u16 {
    return asm volatile ("inw %%dx, %%ax"
        : [result] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

inline fn outw(port: u16, val: u16) void {
    asm volatile ("outw %%ax, %%dx"
        :
        : [val] "{ax}" (val),
          [port] "{dx}" (port),
    );
}

inline fn inl(port: u16) u32 {
    return asm volatile ("inl %%dx, %%eax"
        : [result] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

inline fn outl(port: u16, val: u32) void {
    asm volatile ("outl %%eax, %%dx"
        :
        : [val] "{eax}" (val),
          [port] "{dx}" (port),
    );
}

inline fn readVolatileU32(ptr: *const u32) u32 {
    return @as(*const volatile u32, @ptrCast(ptr)).*;
}

inline fn writeVolatileU32(ptr: *u32, val: u32) void {
    @as(*volatile u32, @ptrCast(ptr)).* = val;
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

pub const UhciController = struct {
    id: u8,
    bus: u8,
    dev: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    irq: u8,
    io_base: u16,
    num_ports: u8 = 2,
    ports: [2]UsbPortStatus = undefined,

    // PMM DMA Memory
    frame_list_phys: usize = 0,
    frame_list: *[1024]u32 = undefined,

    ctrl_page_phys: usize = 0,
    ctrl_qh: *UhciQh = undefined,
    ctrl_tds: *[16]UhciTd = undefined,
    ctrl_setup_pkt: *UsbSetupPacket = undefined,
    ctrl_buf: *[512]u8 = undefined,

    bulk_qh: *UhciQh = undefined,
    bulk_tds: *[32]UhciTd = undefined,
    bulk_buf: *[2048]u8 = undefined,

    dma_pool: dma.UsbDmaPool = dma.UsbDmaPool.init(),

    pub fn init(self: *UhciController, pci_ctrl: *const pci_detect.PciUsbController, id: u8) bool {
        self.id = id;
        self.bus = pci_ctrl.bus;
        self.dev = pci_ctrl.dev;
        self.func = pci_ctrl.func;
        self.vendor_id = pci_ctrl.vendor_id;
        self.device_id = pci_ctrl.device_id;
        self.irq = pci_ctrl.irq;
        self.io_base = pci_ctrl.io_base;
        self.num_ports = 2;

        if (self.io_base == 0) return false;

        // Allocate 1024-entry Frame List (4KB aligned)
        // UHCI uses 32-bit physical pointers: refuse pages >= 4GB instead of
        // truncating (real hardware with high RAM would DMA into the wrong page).
        const fl_page = dma.allocPage() orelse return false;
        if (fl_page >= 0x100000000) {
            dma.freePage(fl_page);
            return false;
        }
        self.frame_list_phys = fl_page;
        self.frame_list = @ptrCast(@alignCast(@as([*]u32, @ptrFromInt(fl_page))));
        var f: usize = 0;
        while (f < 1024) : (f += 1) {
            self.frame_list[f] = 1; // Terminate bit = 1
        }

        // Allocate control structures in a dedicated 4KB DMA page
        const ctrl_page = dma.allocPage() orelse {
            dma.freePage(fl_page);
            return false;
        };
        if (ctrl_page >= 0x100000000) {
            dma.freePage(ctrl_page);
            dma.freePage(fl_page);
            return false;
        }
        self.ctrl_page_phys = ctrl_page;
        const page_bytes: [*]u8 = @ptrFromInt(ctrl_page);
        @memset(page_bytes[0..dma.PAGE_SIZE], 0);

        self.ctrl_qh = @ptrCast(@alignCast(page_bytes + 0));
        self.ctrl_tds = @ptrCast(@alignCast(page_bytes + 64));
        self.ctrl_setup_pkt = @ptrCast(@alignCast(page_bytes + 64 + 16 * @sizeOf(UhciTd)));
        self.ctrl_buf = @ptrCast(@alignCast(page_bytes + 512));

        self.bulk_qh = @ptrCast(@alignCast(page_bytes + 1024));
        self.bulk_tds = @ptrCast(@alignCast(page_bytes + 1088));
        self.bulk_buf = @ptrCast(@alignCast(page_bytes + 1600));

        // Keep the control QH as the tail of the schedule.  The bulk QH is
        // the root and points to the control QH, so both queues remain
        // reachable while the control QH itself terminates the chain.
        self.bulk_qh.head_link = @intCast(@intFromPtr(self.ctrl_qh) | 0x02);
        self.bulk_qh.element_link = 1;

        self.ctrl_qh.head_link = 1;
        self.ctrl_qh.element_link = 1;

        // Reset UHCI controller
        outw(self.io_base + 0x00, 0x0002); // USBCMD: HCRESET
        spinDelayMs(10);
        outw(self.io_base + 0x04, 0x0000); // USBINTR: disable IRQs (polling mode)
        outw(self.io_base + 0x02, 0x00FF); // USBSTS: clear status
        outw(self.io_base + 0x06, 0x0000); // FRNUM: reset frame num
        outb(self.io_base + 0x0C, 0x40); // SOFMOD: 1ms SOF

        // Point all frame list entries to the schedule root (bulk QH).
        const qh_phys: u32 = @intCast(@intFromPtr(self.bulk_qh) | 0x02);
        f = 0;
        while (f < 1024) : (f += 1) {
            self.frame_list[f] = qh_phys;
        }
        outl(self.io_base + 0x08, @intCast(self.frame_list_phys));

        // Start UHCI Schedule (Run = 1, Configured = 1, Max Packet 64 = 1)
        outw(self.io_base + 0x00, 0x00C1);

        // Scan ports and detect connections
        self.checkPorts();

        return true;
    }

    pub fn deinit(self: *UhciController) void {
        if (self.io_base != 0) {
            outw(self.io_base + 0x00, 0x0000); // Stop controller
        }
        if (self.frame_list_phys != 0) {
            dma.freePage(self.frame_list_phys);
            self.frame_list_phys = 0;
        }
        if (self.ctrl_page_phys != 0) {
            dma.freePage(self.ctrl_page_phys);
            self.ctrl_page_phys = 0;
        }
        self.dma_pool.deinit();
    }

    pub fn checkPorts(self: *UhciController) void {
        var p: u8 = 0;
        while (p < self.num_ports) : (p += 1) {
            const port_reg = self.io_base + 0x10 + (@as(u16, p) * 2);
            var status = inw(port_reg);
            const connected = (status & 0x01) != 0;

            if (connected) {
                // Clear connect status change
                if ((status & 0x02) != 0) {
                    outw(port_reg, status | 0x02);
                }

                // Port Reset: assert reset (bit 9), wait 50ms, deassert, re-enable port
                outw(port_reg, 0x0204);
                spinDelayMs(50);
                outw(port_reg, 0x0004);
                spinDelayMs(20);

                // Ensure port is enabled
                status = inw(port_reg);
                if ((status & 0x04) == 0) {
                    outw(port_reg, status | 0x04);
                    spinDelayMs(10);
                    status = inw(port_reg);
                }

                const enabled = (status & 0x04) != 0;
                const low_speed = (status & 0x0100) != 0;

                self.ports[p] = .{
                    .port = p + 1,
                    .connected = true,
                    .enabled = enabled,
                    .speed = if (low_speed) "Low-Speed (1.5 Mbps)" else "Full-Speed (12 Mbps)",
                    .device_desc = if (low_speed) "USB HID (Keyboard/Mouse)" else "USB Full-Speed Device",
                };
            } else {
                self.ports[p] = .{
                    .port = p + 1,
                    .connected = false,
                    .enabled = false,
                    .speed = "Full-Speed (12 Mbps)",
                    .device_desc = "No device",
                };
            }
        }
    }

    pub fn resetPort(self: *UhciController, port_idx: u8) bool {
        if (port_idx >= self.num_ports) return false;
        const port_reg = self.io_base + 0x10 + (@as(u16, port_idx) * 2);
        outw(port_reg, 0x0204);
        spinDelayMs(50);
        outw(port_reg, 0x0004);
        spinDelayMs(20);

        var status = inw(port_reg);
        if ((status & 0x04) == 0) {
            outw(port_reg, status | 0x04);
            spinDelayMs(10);
            status = inw(port_reg);
        }
        return (status & 0x04) != 0;
    }

    pub fn controlTransfer(
        self: *UhciController,
        dev_addr: u8,
        low_speed: bool,
        max_packet0: u8,
        setup: *const UsbSetupPacket,
        data_out: ?[]const u8,
        data_in: ?[]u8,
    ) bool {
        // Control transfers use a shared DMA buffer.  Bound the request to
        // both the hardware buffer and the caller's slice before programming
        // any TDs; otherwise a malformed/large wLength can overrun ctrl_buf.
        const requested_len: usize = @intCast(setup.wLength);
        const supplied_len: usize = if (data_in) |d| d.len else if (data_out) |d| d.len else 0;
        const data_len = @min(@min(requested_len, self.ctrl_buf.len), supplied_len);
        if (requested_len > 0 and supplied_len == 0) return false;

        var wire_setup = setup.*;
        wire_setup.wLength = @intCast(data_len);
        self.ctrl_setup_pkt.* = wire_setup;
        @memset(self.ctrl_buf[0..], 0);

        // Reset all fields that may have been left by a previous transfer.
        var reset_idx: usize = 0;
        while (reset_idx < self.ctrl_tds.len) : (reset_idx += 1) {
            self.ctrl_tds[reset_idx] = .{};
        }

        // Setup stage TD
        self.ctrl_tds[0].ctrl_status = TD_CTRL_ACTIVE | TD_CTRL_3ERRORS | (if (low_speed) TD_CTRL_LOWSPEED else 0);
        self.ctrl_tds[0].token = 0x2D | (@as(u32, dev_addr) << 8) | (0 << 15) | (0 << 19) | ((8 - 1) << 21); // PID_SETUP, DATA0, len 8
        self.ctrl_tds[0].buffer = @intCast(@intFromPtr(self.ctrl_setup_pkt));

        var td_idx: usize = 1;
        var toggle: u32 = 1; // Data stage starts with DATA1
        const mp: usize = if (max_packet0 > 0) max_packet0 else 8;

        if (data_in) |_| {
            var transferred: usize = 0;
            const total = data_len;
            while (transferred < total) {
                if (td_idx + 1 >= self.ctrl_tds.len) {
                    writeVolatileU32(&self.ctrl_qh.element_link, 1);
                    return false;
                }
                const chunk = @min(total - transferred, mp);
                self.ctrl_tds[td_idx - 1].link = @intCast(@intFromPtr(&self.ctrl_tds[td_idx]) | 0x04);
                self.ctrl_tds[td_idx].token = 0x69 | (@as(u32, dev_addr) << 8) | (0 << 15) | (toggle << 19) | ((@as(u32, @intCast(chunk - 1)) & 0x7FF) << 21);
                self.ctrl_tds[td_idx].ctrl_status = TD_CTRL_ACTIVE | TD_CTRL_3ERRORS | (if (low_speed) TD_CTRL_LOWSPEED else 0) | TD_CTRL_SPD;
                self.ctrl_tds[td_idx].buffer = @intCast(@intFromPtr(&self.ctrl_buf[transferred]));
                toggle ^= 1;
                transferred += chunk;
                td_idx += 1;
            }
        } else if (data_out) |dout| {
            var transferred: usize = 0;
            const total = data_len;
            while (transferred < total) {
                if (td_idx + 1 >= self.ctrl_tds.len) {
                    writeVolatileU32(&self.ctrl_qh.element_link, 1);
                    return false;
                }
                const chunk = @min(total - transferred, mp);
                @memcpy(self.ctrl_buf[transferred .. transferred + chunk], dout[transferred .. transferred + chunk]);
                self.ctrl_tds[td_idx - 1].link = @intCast(@intFromPtr(&self.ctrl_tds[td_idx]) | 0x04);
                self.ctrl_tds[td_idx].token = 0xE1 | (@as(u32, dev_addr) << 8) | (0 << 15) | (toggle << 19) | ((@as(u32, @intCast(chunk - 1)) & 0x7FF) << 21);
                self.ctrl_tds[td_idx].ctrl_status = TD_CTRL_ACTIVE | TD_CTRL_3ERRORS | (if (low_speed) TD_CTRL_LOWSPEED else 0);
                self.ctrl_tds[td_idx].buffer = @intCast(@intFromPtr(&self.ctrl_buf[transferred]));
                toggle ^= 1;
                transferred += chunk;
                td_idx += 1;
            }
        }

        // Status stage TD
        if (td_idx == 0 or td_idx >= self.ctrl_tds.len) {
            writeVolatileU32(&self.ctrl_qh.element_link, 1);
            return false;
        }
        self.ctrl_tds[td_idx - 1].link = @intCast(@intFromPtr(&self.ctrl_tds[td_idx]) | 0x04);
        const is_read = (setup.bmRequestType & 0x80) != 0;
        if (is_read) {
            // Device-to-Host (Read) -> Status is OUT, DATA1, 0 bytes
            self.ctrl_tds[td_idx].token = 0xE1 | (@as(u32, dev_addr) << 8) | (0 << 15) | (1 << 19) | (0x7FF << 21);
        } else {
            // Host-to-Device (Write) -> Status is IN, DATA1, 0 bytes
            self.ctrl_tds[td_idx].token = 0x69 | (@as(u32, dev_addr) << 8) | (0 << 15) | (1 << 19) | (0x7FF << 21);
        }
        self.ctrl_tds[td_idx].ctrl_status = TD_CTRL_ACTIVE | TD_CTRL_3ERRORS | (if (low_speed) TD_CTRL_LOWSPEED else 0);
        self.ctrl_tds[td_idx].buffer = 0;
        self.ctrl_tds[td_idx].link = 1; // Terminate

        const last_td = td_idx;

        // Attach to Control QH (volatile write)
        writeVolatileU32(&self.ctrl_qh.element_link, @intCast(@intFromPtr(&self.ctrl_tds[0])));

        // Wait: check status with millisecond timeout (up to 500ms for bare metal hardware)
        var wait_ms: u32 = 0;
        while (wait_ms < 500) : (wait_ms += 1) {
            var inner: u32 = 0;
            while (inner < 50) : (inner += 1) {
                const st_last = readVolatileU32(&self.ctrl_tds[last_td].ctrl_status);
                if ((st_last & TD_CTRL_ACTIVE) == 0) {
                    // Check error bits across TDs
                    var err = false;
                    var k: usize = 0;
                    while (k <= last_td) : (k += 1) {
                        const st_k = readVolatileU32(&self.ctrl_tds[k].ctrl_status);
                        if ((st_k & 0x007E0000) != 0) {
                            err = true;
                            break;
                        }
                    }
                    writeVolatileU32(&self.ctrl_qh.element_link, 1);
                    if (err) {
                        serial.serialWrite("[UHCI] control TD error, last status=0x");
                        serial.serialWriteHex(readVolatileU32(&self.ctrl_tds[last_td].ctrl_status));
                        serial.serialWrite(" requested=");
                        serial.serialWriteDec(requested_len);
                        serial.serialWrite(" supplied=");
                        serial.serialWriteDec(supplied_len);
                        serial.serialWrite(" data=");
                        serial.serialWriteDec(data_len);
                        serial.serialWrite("\n");
                        return false;
                    }

                    if (data_in) |din| {
                        // UHCI stores (actual_length - 1) in status bits
                        // 0..10; 0x7fff denotes a zero-length packet.  Sum
                        // the data TDs so short descriptor replies do not
                        // copy stale bytes from the previous transfer.
                        var actual_len: usize = 0;
                        var data_td: usize = 1;
                        var offset: usize = 0;
                        while (data_td < td_idx) : (data_td += 1) {
                            const st = readVolatileU32(&self.ctrl_tds[data_td].ctrl_status);
                            const chunk = @min(data_len - offset, mp);
                            const length_field: usize = @intCast(st & 0x7FF);
                            const transferred: usize = if (length_field == 0x7FF) 0 else length_field + 1;
                            actual_len += @min(transferred, chunk);
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

        writeVolatileU32(&self.ctrl_qh.element_link, 1);
        return false;
    }

    pub fn bulkTransfer(
        self: *UhciController,
        dev_addr: u8,
        ep_num: u8,
        is_in: bool,
        toggle: *u1,
        max_packet: u16,
        data: []u8,
    ) ?usize {
        if (data.len == 0) return 0;
        const mp: usize = if (max_packet > 0) max_packet else 64;
        var total_transferred: usize = 0;

        while (total_transferred < data.len) {
            const chunk_total = @min(data.len - total_transferred, self.bulk_buf.len);
            const num_tds = (chunk_total + mp - 1) / mp;
            if (num_tds == 0 or num_tds > self.bulk_tds.len) break;

            if (is_in) {
                @memset(self.bulk_buf[0..chunk_total], 0);
            } else {
                @memcpy(self.bulk_buf[0..chunk_total], data[total_transferred .. total_transferred + chunk_total]);
            }

            var curr_chunk: usize = 0;
            var t_idx: usize = 0;
            while (t_idx < num_tds) : (t_idx += 1) {
                const packet_len = @min(chunk_total - curr_chunk, mp);
                const pid: u32 = if (is_in) 0x69 else 0xE1;
                const len_field: u32 = if (packet_len == 0) 0x7FF else @as(u32, @intCast(packet_len - 1)) & 0x7FF;

                const spd: u32 = if (is_in) TD_CTRL_SPD else 0;
                self.bulk_tds[t_idx].ctrl_status = TD_CTRL_ACTIVE | TD_CTRL_3ERRORS | spd;
                self.bulk_tds[t_idx].token = pid |
                    (@as(u32, dev_addr) << 8) |
                    (@as(u32, ep_num) << 15) |
                    (@as(u32, toggle.*) << 19) |
                    (len_field << 21);
                self.bulk_tds[t_idx].buffer = @intCast(@intFromPtr(&self.bulk_buf[curr_chunk]));

                if (t_idx + 1 < num_tds) {
                    self.bulk_tds[t_idx].link = @intCast(@intFromPtr(&self.bulk_tds[t_idx + 1]) | 0x04);
                } else {
                    self.bulk_tds[t_idx].link = 1; // Terminate
                }

                toggle.* ^= 1;
                curr_chunk += packet_len;
            }

            const last_td = num_tds - 1;
            writeVolatileU32(&self.bulk_qh.element_link, @intCast(@intFromPtr(&self.bulk_tds[0])));

            // Poll for completion non-blockingly
            var spin: u32 = 0;
            const max_spins: u32 = 100000;
            var completed = false;
            while (spin < max_spins) : (spin += 1) {
                const st_last = readVolatileU32(&self.bulk_tds[last_td].ctrl_status);
                if ((st_last & TD_CTRL_ACTIVE) == 0) {
                    completed = true;
                    break;
                }
                asm volatile ("pause");
            }

            writeVolatileU32(&self.bulk_qh.element_link, 1);

            if (!completed) {
                const st_last = readVolatileU32(&self.bulk_tds[last_td].ctrl_status);
                serial.serialWrite("[UHCI-BULK] Timeout! last_td st=0x");
                serial.serialWriteHex(st_last);
                serial.serialWrite(" tok=0x");
                serial.serialWriteHex(self.bulk_tds[last_td].token);
                serial.serialWrite("\n");
                return null;
            }

            // Check errors across all TDs
            var k: usize = 0;
            while (k <= last_td) : (k += 1) {
                const st_k = readVolatileU32(&self.bulk_tds[k].ctrl_status);
                if ((st_k & 0x007E0000) != 0) {
                    serial.serialWrite("[UHCI-BULK] TD error! k=");
                    serial.serialWriteDec(k);
                    serial.serialWrite(" st=0x");
                    serial.serialWriteHex(st_k);
                    serial.serialWrite("\n");
                    return null;
                }
            }

            var actual_chunk: usize = chunk_total;
            if (is_in) {
                actual_chunk = 0;
                var t: usize = 0;
                var offset: usize = 0;
                while (t < num_tds) : (t += 1) {
                    const st = readVolatileU32(&self.bulk_tds[t].ctrl_status);
                    const chunk = @min(chunk_total - offset, mp);
                    const length_field: usize = @intCast(st & 0x7FF);
                    const transferred: usize = if (length_field == 0x7FF) 0 else length_field + 1;
                    const received: usize = @min(transferred, chunk);
                    actual_chunk += received;
                    offset += chunk;
                }
                if (actual_chunk > data.len - total_transferred) {
                    actual_chunk = data.len - total_transferred;
                }
                @memcpy(data[total_transferred .. total_transferred + actual_chunk], self.bulk_buf[0..actual_chunk]);
            }

            total_transferred += actual_chunk;
            if (actual_chunk < chunk_total) break;
        }

        return total_transferred;
    }

    pub fn linkEndpointQh(self: *UhciController, qh: *UhciQh) void {
        // Insert QH before the bulk/control tail of the schedule.
        qh.head_link = @intCast(@intFromPtr(self.bulk_qh) | 0x02);
        const qh_phys: u32 = @intCast(@intFromPtr(qh) | 0x02);
        var f: usize = 0;
        while (f < 1024) : (f += 1) {
            self.frame_list[f] = qh_phys;
        }
    }
};
