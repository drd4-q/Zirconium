const std = @import("std");
const root = @import("root");
const serial = root.serial;
const timer = @import("../timer.zig");
const keyboard = @import("../keyboard.zig");
const mouse = @import("../mouse.zig");

pub const types = @import("types.zig");
pub const dma = @import("dma.zig");
pub const pci_detect = @import("pci_detect.zig");
pub const uhci = @import("uhci.zig");
pub const ehci = @import("ehci.zig");
pub const xhci = @import("xhci.zig");
pub const device = @import("device.zig");
pub const hid = @import("hid.zig");
pub const usbhid = @import("usbhid.zig");
pub const hid_core = @import("hid_core.zig");
pub const hid_generic = @import("hid_generic.zig");
pub const hid_input = @import("hid_input.zig");
pub const hub = @import("hub.zig");
pub const storage = @import("storage.zig");

pub const UsbControllerType = types.UsbControllerType;
pub const UsbSpeed = types.UsbSpeed;
pub const UsbTransferType = types.UsbTransferType;
pub const UsbTransferStatus = types.UsbTransferStatus;
pub const UsbDeviceClass = types.UsbDeviceClass;
pub const UsbDeviceType = types.UsbDeviceType;
pub const UsbPortStatus = types.UsbPortStatus;
pub const UsbSetupPacket = types.UsbSetupPacket;
pub const UsbDevice = device.UsbDevice;
pub const UhciQh = uhci.UhciQh;
pub const UhciTd = uhci.UhciTd;

pub const MAX_USB_CONTROLLERS: usize = 12;
pub const MAX_USB_DEVICES: usize = 16;

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
    inst_idx: u8 = 0,
    num_ports: u8,
    ports: [32]UsbPortStatus,
};

pub var controllers: [MAX_USB_CONTROLLERS]UsbController = undefined;
pub var controller_count: usize = 0;

pub var usb_devices: [MAX_USB_DEVICES]UsbDevice = undefined;
pub var usb_device_count: usize = 0;

// Monotonic software ID shared by every host controller.  USB addresses are
// controller-local (and xHCI chooses them), so they cannot be used as a
// kernel-wide device identifier.
var next_usb_device_id: u32 = 1;

fn allocateUsbDeviceId() u32 {
    const id = next_usb_device_id;
    next_usb_device_id +%= 1;
    if (next_usb_device_id == 0) next_usb_device_id = 1;
    return id;
}

var initialized: bool = false;

// Driver instances
var uhci_instances: [4]uhci.UhciController = undefined;
var uhci_count: usize = 0;

var ehci_instances: [4]ehci.EhciController = undefined;
var ehci_count: usize = 0;

var xhci_instances: [4]xhci.XhciController = undefined;
var xhci_count: usize = 0;

// Re-export USB HID keycode translation from hid driver
pub const usbKeyToAscii = hid.usbKeyToAscii;

pub fn setHidDebug(enabled: bool) void {
    hid_input.debug = enabled;
}

fn enumerateCompositeInterfaces(dev: *device.UsbDevice, c_idx: u8, p: u8, is_low_speed: bool, new_addr: u8) void {
    var if_idx: usize = 1;
    while (if_idx < dev.interface_count and usb_device_count < MAX_USB_DEVICES) : (if_idx += 1) {
        const iface = &dev.interfaces[if_idx];
        if (iface.class_code == 0x03) {
            var dev_extra = &usb_devices[usb_device_count];
            dev_extra.* = .{};
            dev_extra.id = dev.id;
            dev_extra.active = true;
            dev_extra.ctrl_idx = c_idx;
            dev_extra.port = p + 1;
            dev_extra.addr = new_addr;
            dev_extra.ep0_max_packet = dev.ep0_max_packet;
            dev_extra.low_speed = is_low_speed;
            dev_extra.speed = dev.speed;
            dev_extra.dev_type = iface.driver_type;
            dev_extra.vendor_id = dev.vendor_id;
            dev_extra.product_id = dev.product_id;
            dev_extra.interface_num = iface.interface_num;
            dev_extra.interfaces = dev.interfaces;
            dev_extra.interface_count = dev.interface_count;
            dev_extra.is_wireless = dev.is_wireless;
            dev_extra.xhci_slot_id = dev.xhci_slot_id;
            dev_extra.xhci_slot_idx = dev.xhci_slot_idx;
            dev_extra.xhci_parent_slot_id = dev.xhci_parent_slot_id;
            dev_extra.xhci_parent_port = dev.xhci_parent_port;
            dev_extra.xhci_root_port = dev.xhci_root_port;
            dev_extra.xhci_route = dev.xhci_route;
            dev_extra.xhci_hub_depth = dev.xhci_hub_depth;
            dev_extra.xhci_hub_multi_tt = dev.xhci_hub_multi_tt;
            dev_extra.xhci_hub_interface = dev.xhci_hub_interface;

            var found_ep = false;
            var ep_k: usize = 0;
            while (ep_k < iface.endpoint_count) : (ep_k += 1) {
                const ep = &iface.endpoints[ep_k];
                if (ep.active and ep.isInput() and ep.transfer_type == .interrupt) {
                    dev_extra.ep_in = ep.epNumber();
                    dev_extra.ep_max_packet = ep.max_packet_size;
                    dev_extra.ep_interval = ep.interval_ms;
                    found_ep = true;
                    break;
                }
            }
            if (!found_ep) {
                // Do not invent an interrupt endpoint: a composite interface
                // without one must stay out of the HID transfer schedule.
                dev_extra.ep_in = 0;
                dev_extra.ep_max_packet = 0;
                dev_extra.ep_interval = 0;
            }

            dev_extra.toggle = 0;
            dev_extra.packet_count = 0;
            dev_extra.caps_lock = false;
            @memset(&dev_extra.report_buf, 0);
            @memset(&dev_extra.prev_report, 0);

            serial.serialWrite("[USB] Registered ");
            serial.serialWrite(dev_extra.dev_type.name());
            serial.serialWrite(" at ID ");
            serial.serialWriteDec(dev_extra.id);
            serial.serialWrite(" Addr ");
            serial.serialWriteDec(new_addr);
            serial.serialWrite(" (Vendor=0x");
            serial.serialWriteHex(dev.vendor_id);
            serial.serialWrite(" Product=0x");
            serial.serialWriteHex(dev.product_id);
            serial.serialWrite(" EP_IN=");
            serial.serialWriteDec(dev_extra.ep_in);
            serial.serialWrite(")\n");

            usb_device_count += 1;
        }
    }
}

fn duplicateHidEndpoint(dev: *device.UsbDevice, upto: usize) bool {
    var i: usize = 0;
    while (i < upto) : (i += 1) {
        const prior = &usb_devices[i];
        if (prior.active and prior.ctrl_idx == dev.ctrl_idx and prior.addr == dev.addr and
            prior.ep_in == dev.ep_in and (prior.dev_type == .keyboard or prior.dev_type == .mouse))
        {
            return true;
        }
    }
    return false;
}

fn relinkUhciControllerSchedule(u_ctrl: *uhci.UhciController, ctrl_index: u8) void {
    var prev_qh: ?*UhciQh = null;

    var i: usize = 0;
    while (i < usb_device_count) : (i += 1) {
        const dev = &usb_devices[i];
        if (!dev.active or dev.ctrl_idx != ctrl_index) continue;
        if (dev.dev_type != .keyboard and dev.dev_type != .mouse) continue;
        if (dev.ep_in == 0) continue;
        if (duplicateHidEndpoint(dev, i)) continue;

        const max_p: u32 = @min(@max(dev.ep_max_packet, 8), 64);

        dev.td.link = 1; // Terminate
        dev.td.ctrl_status = uhci.TD_CTRL_ACTIVE | uhci.TD_CTRL_3ERRORS | (if (dev.low_speed) uhci.TD_CTRL_LOWSPEED else 0) | uhci.TD_CTRL_SPD;
        dev.td.token = 0x69 | (@as(u32, dev.addr) << 8) | (@as(u32, dev.ep_in) << 15) | (@as(u32, dev.toggle) << 19) | ((max_p - 1) << 21);
        dev.td.buffer = @intCast(@intFromPtr(&dev.report_buf));

        dev.qh.element_link = @intCast(@intFromPtr(&dev.td));
        dev.qh.head_link = 1;

        if (prev_qh) |pq| {
            pq.head_link = @intCast(@intFromPtr(&dev.qh) | 0x02);
        } else {
            const qh_ptr: u32 = @intCast(@intFromPtr(&dev.qh) | 0x02);
            var f: usize = 0;
            while (f < 1024) : (f += 1) {
                u_ctrl.frame_list[f] = qh_ptr;
            }
        }
        prev_qh = &dev.qh;
    }

    if (prev_qh) |pq| {
        pq.head_link = @intCast(@intFromPtr(u_ctrl.bulk_qh) | 0x02);
    } else {
        const qh_ptr: u32 = @intCast(@intFromPtr(u_ctrl.bulk_qh) | 0x02);
        var f: usize = 0;
        while (f < 1024) : (f += 1) {
            u_ctrl.frame_list[f] = qh_ptr;
        }
    }
    // The control QH is the terminal QH.  Keeping it last also makes the
    // schedule termination explicit instead of relying on a stale link.
    u_ctrl.ctrl_qh.head_link = 1;
    u_ctrl.bulk_qh.head_link = @intCast(@intFromPtr(u_ctrl.ctrl_qh) | 0x02);
    u_ctrl.bulk_qh.element_link = 1;
}

fn relinkEhciControllerSchedule(e_ctrl: *ehci.EhciController, ctrl_index: u8) void {
    var frame: usize = 0;
    while (frame < 1024) : (frame += 1) {
        e_ctrl.periodic_list[frame] = 1;
    }
    var hid_index: usize = 0;

    var i: usize = 0;
    while (i < usb_device_count) : (i += 1) {
        const dev = &usb_devices[i];
        if (!dev.active or dev.ctrl_idx != ctrl_index) continue;
        if (dev.dev_type != .keyboard and dev.dev_type != .mouse) continue;
        if (dev.ep_in == 0) continue;
        if (duplicateHidEndpoint(dev, i)) continue;

        const max_p: u32 = @min(@max(dev.ep_max_packet, 8), 64);

        dev.ehci_qtd.next_qtd = 1; // Terminate
        dev.ehci_qtd.alt_next_qtd = 1;
        dev.ehci_qtd.token = ehci.QTD_ACTIVE | ehci.QTD_PID_IN | ehci.QTD_3ERRORS | (max_p << 16) | (@as(u32, dev.toggle) << 31);
        dev.ehci_qtd.buf[0] = @intCast(@intFromPtr(&dev.report_buf));

        const speed_val: u32 = if (dev.low_speed) 1 else if (dev.speed == .high) 2 else 0;

        dev.ehci_qh.horizontal_link = 1;
        dev.ehci_qh.ep_characteristics = (@as(u32, dev.addr)) |
            (@as(u32, dev.ep_in) << 8) |
            (speed_val << 12) |
            (1 << 14) | // DTC = 1
            (max_p << 16);
        dev.ehci_qh.ep_capabilities = 0x01 | (0x1C << 8) | (1 << 30); // s-mask=1, c-mask=0x1C, Mult=1
        dev.ehci_qh.current_qtd = 1;
        dev.ehci_qh.overlay_next_qtd = @intCast(@intFromPtr(&dev.ehci_qtd));
        dev.ehci_qh.overlay_alt_next_qtd = 1;
        dev.ehci_qh.overlay_token = 0;

        const interval: usize = @max(@as(usize, dev.ep_interval), 1);
        e_ctrl.linkInterruptQhScheduled(&dev.ehci_qh, hid_index, interval);
        hid_index += 1;
    }
}

// Global hook for UHCI control transfers during enumeration
var current_uhci_ctrl: ?*uhci.UhciController = null;
var current_uhci_low_speed: bool = false;

fn uhciCtrlTransferWrapper(addr: u8, maxp0: u8, setup: *const UsbSetupPacket, dout: ?[]const u8, din: ?[]u8) bool {
    if (current_uhci_ctrl) |c| {
        return c.controlTransfer(addr, current_uhci_low_speed, maxp0, setup, dout, din);
    }
    return false;
}

// Global hook for EHCI control transfers during enumeration
var current_ehci_ctrl: ?*ehci.EhciController = null;

fn ehciCtrlTransferWrapper(addr: u8, maxp0: u8, setup: *const UsbSetupPacket, dout: ?[]const u8, din: ?[]u8) bool {
    if (current_ehci_ctrl) |e| {
        return e.controlTransfer(addr, maxp0, setup, dout, din);
    }
    return false;
}

// Global hook for xHCI control transfers during enumeration
var current_xhci_ctrl: ?*xhci.XhciController = null;
var current_xhci_slot_idx: usize = 0;

fn xhciCtrlTransferWrapper(addr: u8, maxp0: u8, setup: *const UsbSetupPacket, dout: ?[]const u8, din: ?[]u8) bool {
    _ = addr;
    if (current_xhci_ctrl) |x| {
        return x.controlTransfer(current_xhci_slot_idx, maxp0, setup, dout, din);
    }
    return false;
}

fn setControlContext(dev: *device.UsbDevice) void {
    if (dev.ctrl_idx >= controller_count) return;
    const ctrl = &controllers[dev.ctrl_idx];
    switch (ctrl.ctrl_type) {
        .uhci => {
            current_uhci_ctrl = if (ctrl.inst_idx < uhci_count) &uhci_instances[ctrl.inst_idx] else null;
            current_uhci_low_speed = dev.low_speed;
        },
        .ehci => {
            current_ehci_ctrl = if (ctrl.inst_idx < ehci_count) &ehci_instances[ctrl.inst_idx] else null;
        },
        .xhci => {
            current_xhci_ctrl = if (ctrl.inst_idx < xhci_count) &xhci_instances[ctrl.inst_idx] else null;
            current_xhci_slot_idx = dev.xhci_slot_idx;
        },
        else => {},
    }
}

pub fn init() void {
    if (initialized) return;

    controller_count = 0;
    usb_device_count = 0;
    next_usb_device_id = 1;
    uhci_count = 0;
    ehci_count = 0;
    xhci_count = 0;

    const detected_pci_count = pci_detect.scanPciControllers();

    var pci_idx: usize = 0;
    while (pci_idx < detected_pci_count and controller_count < MAX_USB_CONTROLLERS) : (pci_idx += 1) {
        const pci_ctrl = &pci_detect.detected[pci_idx];
        const c_idx: u8 = @intCast(controller_count);

        var ctrl = &controllers[controller_count];
        ctrl.ctrl_type = pci_ctrl.ctrl_type;
        ctrl.bus = pci_ctrl.bus;
        ctrl.dev = pci_ctrl.dev;
        ctrl.func = pci_ctrl.func;
        ctrl.vendor_id = pci_ctrl.vendor_id;
        ctrl.device_id = pci_ctrl.device_id;
        ctrl.irq = pci_ctrl.irq;
        ctrl.io_base = pci_ctrl.io_base;
        ctrl.mmio_base = pci_ctrl.mmio_base;
        ctrl.num_ports = 0;

        switch (pci_ctrl.ctrl_type) {
            .uhci => {
                if (uhci_count < uhci_instances.len) {
                    ctrl.inst_idx = @intCast(uhci_count);
                    var u = &uhci_instances[uhci_count];
                    if (u.init(pci_ctrl, c_idx)) {
                        ctrl.num_ports = u.num_ports;
                        var p: u8 = 0;
                        while (p < u.num_ports) : (p += 1) {
                            ctrl.ports[p] = u.ports[p];
                            if (u.ports[p].connected and u.ports[p].enabled) {
                                if (usb_device_count < MAX_USB_DEVICES) {
                                    current_uhci_ctrl = u;
                                    const is_low_speed = (u.ports[p].speed.len > 0 and u.ports[p].speed[0] == 'L');
                                    current_uhci_low_speed = is_low_speed;

                                    var dev = &usb_devices[usb_device_count];
                                    dev.* = .{};
                                    dev.id = allocateUsbDeviceId();
                                    const new_addr: u8 = @intCast(usb_device_count + 1);
                                    if (device.enumerateDevice(
                                        c_idx,
                                        p,
                                        is_low_speed,
                                        if (is_low_speed) .low else .full,
                                        dev,
                                        new_addr,
                                        uhciCtrlTransferWrapper,
                                        false,
                                    )) {
                                        ctrl.ports[p].device_desc = dev.dev_type.name();
                                        usb_device_count += 1;
                                        enumerateCompositeInterfaces(dev, c_idx, p, is_low_speed, new_addr);
                                    }
                                }
                            }
                        }
                        relinkUhciControllerSchedule(u, c_idx);
                        uhci_count += 1;
                    }
                }
            },
            .ehci => {
                if (ehci_count < ehci_instances.len) {
                    ctrl.inst_idx = @intCast(ehci_count);
                    var e = &ehci_instances[ehci_count];
                    if (e.init(pci_ctrl, c_idx)) {
                        ctrl.num_ports = e.num_ports;
                        var p: u8 = 0;
                        while (p < e.num_ports) : (p += 1) {
                            ctrl.ports[p] = e.ports[p];
                            if (e.ports[p].connected and e.ports[p].enabled) {
                                if (usb_device_count < MAX_USB_DEVICES) {
                                    current_ehci_ctrl = e;
                                    var dev = &usb_devices[usb_device_count];
                                    dev.* = .{};
                                    dev.id = allocateUsbDeviceId();
                                    const new_addr: u8 = @intCast(usb_device_count + 1);
                                    if (device.enumerateDevice(
                                        c_idx,
                                        p,
                                        false,
                                        .high,
                                        dev,
                                        new_addr,
                                        ehciCtrlTransferWrapper,
                                        false,
                                    )) {
                                        ctrl.ports[p].device_desc = dev.dev_type.name();
                                        usb_device_count += 1;
                                        enumerateCompositeInterfaces(dev, c_idx, p, false, new_addr);
                                    }
                                }
                            }
                        }
                        relinkEhciControllerSchedule(e, c_idx);
                        ehci_count += 1;
                    }
                }
            },
            .xhci => {
                if (xhci_count < xhci_instances.len) {
                    ctrl.inst_idx = @intCast(xhci_count);
                    var x = &xhci_instances[xhci_count];
                    if (x.init(pci_ctrl, c_idx)) {
                        ctrl.num_ports = x.num_ports;
                        var p: u8 = 0;
                        while (p < x.num_ports) : (p += 1) {
                            ctrl.ports[p] = x.ports[p];
                            if (x.ports[p].connected and x.ports[p].enabled) {
                                if (usb_device_count < MAX_USB_DEVICES) {
                                    const speed_code = x.getPortSpeedCode(p);
                                    if (x.enableSlot()) |slot_id| {
                                        if (x.allocSlot(slot_id, p, speed_code)) |slot_idx| {
                                            if (x.addressDevice(slot_idx, p, speed_code)) {
                                                current_xhci_ctrl = x;
                                                current_xhci_slot_idx = slot_idx;

                                                var dev = &usb_devices[usb_device_count];
                                                dev.* = .{};
                                                dev.id = allocateUsbDeviceId();
                                                dev.xhci_slot_id = slot_id;
                                                dev.xhci_slot_idx = @intCast(slot_idx);
                                                dev.xhci_root_port = p + 1;
                                                dev.xhci_route = 0;
                                                dev.xhci_hub_depth = 0;

                                                const is_low_speed = (speed_code == 2);
                                                const dev_speed: UsbSpeed = if (is_low_speed)
                                                    .low
                                                else if (speed_code == 3)
                                                    .high
                                                else if (speed_code >= 4)
                                                    .super_speed
                                                else
                                                    .full;
                                                const new_addr: u8 = x.assignedAddress(slot_idx) orelse @intCast(usb_device_count + 1);

                                                if (device.enumerateDevice(
                                                    c_idx,
                                                    p,
                                                    is_low_speed,
                                                    dev_speed,
                                                    dev,
                                                    new_addr,
                                                    xhciCtrlTransferWrapper,
                                                    true,
                                                )) {
                                                    ctrl.ports[p].device_desc = dev.dev_type.name();
                                                    usb_device_count += 1;
                                                    const extra_start = usb_device_count;
                                                    enumerateCompositeInterfaces(dev, c_idx, p, is_low_speed, new_addr);

                                                    // Configure endpoints from the parsed interface class. HID gets interrupt-IN
                                                    // queues; storage and Wi-Fi get bulk endpoints.
                                                    if (!x.updateEp0MaxPacket(slot_idx, dev.ep0_max_packet)) {
                                                        serial.serialWrite("[XHCI] EP0 max-packet update failed\n");
                                                    }
                                                    configureXhciDeviceEndpoints(x, dev);

                                                    // Configure composite interface records as well.
                                                    var sec_i = extra_start;
                                                    while (sec_i < usb_device_count) : (sec_i += 1) {
                                                        const sec_dev = &usb_devices[sec_i];
                                                        if (sec_dev.active) {
                                                            configureXhciDeviceEndpoints(x, sec_dev);
                                                        }
                                                    }
                                                } else {
                                                    x.disableSlot(slot_id);
                                                }
                                            } else {
                                                x.disableSlot(slot_id);
                                            }
                                        } else {
                                            x.disableSlot(slot_id);
                                        }
                                    }
                                }
                            }
                        }
                        xhci_count += 1;
                    }
                }
            },
            else => {
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
            },
        }

        controller_count += 1;
    }

    // ─── Companion Controller Hand-Off Re-Scan Pass ───
    // When EHCI initializes, it detects Low/Full Speed devices (like keyboards,
    // mice, and 2.4GHz dongles) and releases their ports to the companion
    // UHCI controller by setting Port Owner (bit 13). Because UHCI was scanned
    // before EHCI in PCI order, UHCI missed the connection. We now re-scan all
    // UHCI ports to detect and enumerate handed-off devices.
    if (ehci_count > 0 and uhci_count > 0) {
        var u_idx: usize = 0;
        while (u_idx < uhci_count) : (u_idx += 1) {
            var u = &uhci_instances[u_idx];
            const c_idx = u.id;
            u.checkPorts();

            var p: u8 = 0;
            var newly_added = false;
            while (p < u.num_ports) : (p += 1) {
                if (u.ports[p].connected and u.ports[p].enabled) {
                    var already_enum = false;
                    var d: usize = 0;
                    while (d < usb_device_count) : (d += 1) {
                        if (usb_devices[d].ctrl_idx == c_idx and usb_devices[d].port == p + 1) {
                            already_enum = true;
                            break;
                        }
                    }

                    if (!already_enum and usb_device_count < MAX_USB_DEVICES) {
                        current_uhci_ctrl = u;
                        const is_low_speed = (u.ports[p].speed.len > 0 and u.ports[p].speed[0] == 'L');
                        current_uhci_low_speed = is_low_speed;

                        var dev = &usb_devices[usb_device_count];
                        dev.* = .{};
                        dev.id = allocateUsbDeviceId();
                        const new_addr: u8 = @intCast(usb_device_count + 1);
                        if (device.enumerateDevice(
                            c_idx,
                            p,
                            is_low_speed,
                            if (is_low_speed) .low else .full,
                            dev,
                            new_addr,
                            uhciCtrlTransferWrapper,
                            false,
                        )) {
                            controllers[c_idx].ports[p] = u.ports[p];
                            controllers[c_idx].ports[p].device_desc = dev.dev_type.name();
                            usb_device_count += 1;
                            enumerateCompositeInterfaces(dev, c_idx, p, is_low_speed, new_addr);
                            newly_added = true;
                        }
                    }
                }
            }
            if (newly_added) {
                relinkUhciControllerSchedule(u, c_idx);
            }
        }
    }

    if (controller_count == 0) {
        serial.serialWrite("[USB] No PCI USB host controllers detected.\n");
    } else {
        serial.serialWrite("[USB] Subsystem initialized with ");
        serial.serialWriteDec(controller_count);
        serial.serialWrite(" controller(s), ");
        serial.serialWriteDec(usb_device_count);
        serial.serialWrite(" active USB device(s).\n");
    }

    // ─── Detect and initialize RTL8188EU / RTL8192CU Wi-Fi adapters ───
    {
        const rtl = @import("rtl8188eu.zig");
        var d_idx: usize = 0;
        while (d_idx < usb_device_count) : (d_idx += 1) {
            const dev = &usb_devices[d_idx];
            if (!dev.active) continue;
            if (dev.vendor_id == rtl.RTL8188EU_VID and
                (dev.product_id == rtl.RTL8188EU_PID or dev.product_id == rtl.RTL8192CU_PID))
            {
                if (rtl.init(dev)) {
                    serial.serialWrite("[USB] RTL8188EU Wi-Fi adapter initialized\n");
                } else {
                    serial.serialWrite("[USB] RTL8188EU init failed\n");
                }
            }
        }
    }

    initialized = true;

    // ─── Initialize Linux-style USB HID Subsystem (hid-core.c) ───
    hid_core.init();
    var d_k: usize = 0;
    while (d_k < usb_device_count) : (d_k += 1) {
        const dev = &usb_devices[d_k];
        if (!dev.active) continue;
        if (dev.dev_type == .keyboard or dev.dev_type == .mouse) {
            _ = hid_core.registerHidDevice(d_k, dev, dev.interface_num, dev.dev_type);
        }
    }

    // ─── Downstream USB Hub Port Power & Enumeration (Class 0x09) ───
    const CtrlFnPtr = *const fn (addr: u8, maxp0: u8, setup: *const types.UsbSetupPacket, dout: ?[]const u8, din: ?[]u8) bool;
    var d_h: usize = 0;
    while (d_h < usb_device_count) : (d_h += 1) {
        const hub_dev = &usb_devices[d_h];
        if (!hub_dev.active or hub_dev.dev_type != .hub) continue;
        const ctrl = &controllers[hub_dev.ctrl_idx];
        const ctrl_fn: ?CtrlFnPtr = switch (ctrl.ctrl_type) {
            .uhci => uhciCtrlTransferWrapper,
            .ehci => ehciCtrlTransferWrapper,
            .xhci => xhciCtrlTransferWrapper,
            else => null,
        };
        if (ctrl_fn) |cfn| {
            setControlContext(hub_dev);
            var hub_ports: [8]hub.HubPortInfo = undefined;
            var hub_num_ports: u8 = 0;
            const num_conn = hub.configureHubPorts(hub_dev.addr, hub_dev.ep0_max_packet, cfn, hub_ports[0..], &hub_num_ports);
            if (ctrl.ctrl_type == .xhci and hub_dev.xhci_slot_id != 0 and ctrl.inst_idx < xhci_count) {
                const x = &xhci_instances[ctrl.inst_idx];
                if (!x.markHub(hub_dev.xhci_slot_idx, hub_num_ports, hub_dev.speed == .high and hub_dev.xhci_hub_multi_tt)) {
                    serial.serialWrite("[XHCI] Hub context update failed\n");
                }
            }
            var p_i: usize = 0;
            while (p_i < num_conn and usb_device_count < MAX_USB_DEVICES) : (p_i += 1) {
                const hp = &hub_ports[p_i];
                if (!hp.connected or !hp.enabled) continue;

                const dev = &usb_devices[usb_device_count];
                if (ctrl.ctrl_type == .xhci and hub_dev.xhci_slot_id != 0 and ctrl.inst_idx < xhci_count) {
                    const x = &xhci_instances[ctrl.inst_idx];
                    const shift: u5 = @intCast(@min(@as(usize, hub_dev.xhci_hub_depth) * 4, 19));
                    const port_route: u32 = @as(u32, @min(hp.port, 15)) << shift;
                    const route = hub_dev.xhci_route | port_route;
                    if (enumerateXhciHubChild(x, hub_dev, hp, dev, route, hub_dev.xhci_hub_depth + 1)) {
                        usb_device_count += 1;
                        const extra_start = usb_device_count;
                        enumerateCompositeInterfaces(dev, hub_dev.ctrl_idx, hp.port - 1, hp.speed == .low, dev.addr);
                        if (!x.updateEp0MaxPacket(dev.xhci_slot_idx, dev.ep0_max_packet)) {
                            serial.serialWrite("[XHCI] child EP0 max-packet update failed\n");
                        }
                        configureXhciDeviceEndpoints(x, dev);
                        var extra_i = extra_start;
                        while (extra_i < usb_device_count) : (extra_i += 1) {
                            configureXhciDeviceEndpoints(x, &usb_devices[extra_i]);
                        }
                    }
                } else {
                    const new_addr: u8 = @intCast(usb_device_count + 1);
                    dev.* = .{};
                    dev.id = allocateUsbDeviceId();
                    setControlContext(hub_dev);
                    if (device.enumerateDevice(
                        hub_dev.ctrl_idx,
                        hp.port - 1,
                        hp.speed == .low,
                        hp.speed,
                        dev,
                        new_addr,
                        cfn,
                        false,
                    )) {
                        usb_device_count += 1;
                    }
                }
            }
        }
    }
    const storage_count = storage.init();
    if (storage_count > 0) {
        serial.serialWrite("[USB] USB Mass Storage initialized: ");
        serial.serialWriteDec(storage_count);
        serial.serialWrite(" drive(s) online\n");
    }
}

fn enumerateXhciHubChild(
    x: *xhci.XhciController,
    hub_dev: *device.UsbDevice,
    hp: *hub.HubPortInfo,
    dev: *device.UsbDevice,
    route_string: u32,
    hub_depth: u8,
) bool {
    const speed_code: u8 = switch (hp.speed) {
        .low => 2,
        .full => 1,
        .high => 3,
        .super_speed => 4,
        .super_speed_plus => 5,
    };
    const root_port: u8 = if (hub_dev.xhci_root_port != 0) hub_dev.xhci_root_port else hub_dev.port;
    if (root_port == 0) return false;

    const slot_id = x.enableSlot() orelse return false;
    const slot_idx = x.allocSlot(slot_id, root_port - 1, speed_code) orelse {
        x.disableSlot(slot_id);
        return false;
    };

    const parent_is_hs_hub = hub_dev.speed == .high;
    serial.serialWrite("[XHCI] Hub child address: root=");
    serial.serialWriteDec(root_port);
    serial.serialWrite(" route=0x");
    serial.serialWriteHex(route_string);
    serial.serialWrite(" parent_slot=");
    serial.serialWriteDec(hub_dev.xhci_slot_id);
    serial.serialWrite(" parent_port=");
    serial.serialWriteDec(hp.port);
    serial.serialWrite("\n");
    if (!x.addressDeviceWithRoute(
        slot_idx,
        root_port - 1,
        speed_code,
        root_port,
        route_string,
        hub_dev.xhci_slot_id,
        hp.port,
        parent_is_hs_hub,
        hub_dev.xhci_hub_multi_tt,
    )) {
        serial.serialWrite("[XHCI] Hub child Address Device failed\n");
        x.disableSlot(slot_id);
        return false;
    }

    const assigned_addr = x.assignedAddress(slot_idx) orelse {
        serial.serialWrite("[XHCI] Hub child has no assigned USB address\n");
        x.disableSlot(slot_id);
        return false;
    };

    dev.* = .{};
    dev.id = allocateUsbDeviceId();
    dev.xhci_slot_id = slot_id;
    dev.xhci_slot_idx = @intCast(slot_idx);
    dev.xhci_parent_slot_id = hub_dev.xhci_slot_id;
    dev.xhci_parent_port = hp.port;
    dev.xhci_root_port = root_port;
    dev.xhci_route = route_string;
    dev.xhci_hub_depth = hub_depth;
    current_xhci_ctrl = x;
    current_xhci_slot_idx = slot_idx;

    if (!device.enumerateDevice(
        hub_dev.ctrl_idx,
        root_port - 1,
        hp.speed == .low,
        hp.speed,
        dev,
        assigned_addr,
        xhciCtrlTransferWrapper,
        true,
    )) {
        x.disableSlot(slot_id);
        return false;
    }
    return true;
}

fn configureXhciDeviceEndpoints(x: *xhci.XhciController, dev: *device.UsbDevice) void {
    if (dev.xhci_slot_idx == 0 and dev.xhci_slot_id == 0) return;
    const slot_idx: usize = dev.xhci_slot_idx;

    // Configure the endpoint belonging to this logical interface.  A
    // composite device has one UsbDevice record per HID interface, each with
    // its own report buffer; scanning every interface here would make all
    // records race on the same buffer.
    var target_iface: ?*types.UsbInterface = null;
    var if_idx: usize = 0;
    while (if_idx < dev.interface_count) : (if_idx += 1) {
        const candidate = &dev.interfaces[if_idx];
        if (candidate.interface_num == dev.interface_num) {
            target_iface = candidate;
            break;
        }
    }

    var shared_hid_endpoint = false;
    var prior_idx: usize = 0;
    while (prior_idx < usb_device_count) : (prior_idx += 1) {
        const prior = &usb_devices[prior_idx];
        if (prior != dev and prior.active and prior.xhci_intr_configured and
            prior.xhci_slot_idx == dev.xhci_slot_idx and prior.xhci_slot_id == dev.xhci_slot_id and
            prior.addr == dev.addr and prior.ep_in == dev.ep_in)
        {
            shared_hid_endpoint = true;
            break;
        }
    }
    if (shared_hid_endpoint) dev.xhci_intr_configured = true;

    if (target_iface) |iface| {
        if (iface.class_code == 0x03 and !shared_hid_endpoint) {
            var ep_idx: usize = 0;
            while (ep_idx < iface.endpoint_count) : (ep_idx += 1) {
                const ep = &iface.endpoints[ep_idx];
                if (!ep.active or !ep.isInput() or ep.transfer_type != .interrupt) continue;
                const ep_num = ep.epNumber();
                if (x.configureInterruptEndpoint(slot_idx, ep_num, ep.max_packet_size, ep.interval_ms)) {
                    dev.xhci_intr_configured = true;
                    const queue_dci: u8 = ep_num * 2 + 1;
                    x.queueInterruptTransfer(
                        slot_idx,
                        queue_dci,
                        @intFromPtr(&dev.report_buf),
                        @intCast(@min(@max(ep.max_packet_size, 8), 64)),
                    );
                    serial.serialWrite("[XHCI] HID endpoint queued id=");
                    serial.serialWriteDec(dev.id);
                    serial.serialWrite(" slot=");
                    serial.serialWriteDec(dev.xhci_slot_id);
                    serial.serialWrite(" dci=");
                    serial.serialWriteDec(queue_dci);
                    serial.serialWrite(" ep=");
                    serial.serialWriteDec(ep_num);
                    serial.serialWrite("\n");
                } else {
                    serial.serialWrite("[XHCI] HID endpoint configuration failed at EP");
                    serial.serialWriteDec(ep_num);
                    serial.serialWrite("\n");
                }
                break;
            }
        }
    }

    if (dev.ep_bulk_in != 0 and dev.ep_bulk_out != 0 and
        !dev.xhci_bulk_in_configured and !dev.xhci_bulk_out_configured)
    {
        if (x.configureBulkEndpoints(slot_idx, dev.ep_bulk_in, dev.ep_bulk_in_max_pkt, dev.ep_bulk_out, dev.ep_bulk_out_max_pkt)) {
            dev.xhci_bulk_in_configured = true;
            dev.xhci_bulk_out_configured = true;
        } else {
            serial.serialWrite("[XHCI] bulk endpoint configuration failed\n");
        }
    } else {
        if (dev.ep_bulk_in != 0 and !dev.xhci_bulk_in_configured) {
            if (x.configureBulkEndpoint(slot_idx, dev.ep_bulk_in, true, dev.ep_bulk_in_max_pkt)) {
                dev.xhci_bulk_in_configured = true;
            }
        }
        if (dev.ep_bulk_out != 0 and !dev.xhci_bulk_out_configured) {
            if (x.configureBulkEndpoint(slot_idx, dev.ep_bulk_out, false, dev.ep_bulk_out_max_pkt)) {
                dev.xhci_bulk_out_configured = true;
            }
        }
    }
}

fn processHidReport(dev: *device.UsbDevice, len: usize) void {
    if (len == 0 or len > dev.report_buf.len) return;

    // Opt-in trace: `usb debug on` makes it possible to distinguish a lost
    // HCD transfer from a HID decoding/input-ring problem on real hardware.
    if (hid_input.debug and dev.dev_type == .keyboard) {
        serial.serialWrite("[USB-HID] keyboard report id=");
        serial.serialWriteDec(dev.id);
        serial.serialWrite(" addr=");
        serial.serialWriteDec(dev.addr);
        serial.serialWrite(" len=");
        serial.serialWriteDec(len);
        serial.serialWrite(" data=");
        var trace_i: usize = 0;
        while (trace_i < len) : (trace_i += 1) {
            serial.serialWriteHex(dev.report_buf[trace_i]);
            serial.serialWrite(" ");
        }
        serial.serialWrite("\n");
    }

    hid_core.processRawDeviceReport(dev, len);

    // Composite receivers often expose keyboard and mouse interfaces on the
    // same interrupt endpoint.  Only one physical QH is scheduled, so fan the
    // report out to the other logical interface records instead of dropping
    // the mouse half of the device.
    if (dev.report_buf[0] == 1 or dev.report_buf[0] == 2) {
        var alias_idx: usize = 0;
        while (alias_idx < usb_device_count) : (alias_idx += 1) {
            const alias = &usb_devices[alias_idx];
            if (alias == dev or !alias.active or alias.ctrl_idx != dev.ctrl_idx or
                alias.addr != dev.addr or alias.ep_in != dev.ep_in) continue;
            if (alias.dev_type != .keyboard and alias.dev_type != .mouse) continue;
            @memcpy(alias.report_buf[0..len], dev.report_buf[0..len]);
            alias.packet_count +%= 1;
            hid_core.processRawDeviceReport(alias, len);
        }
    }
}

var current_poll_xhci: ?*xhci.XhciController = null;
var current_poll_ctrl_idx: u8 = 0;
var xhci_hid_event_logged: bool = false;

fn onXhciTransfer(slot_id: u8, dci: u8, rem_bytes: u32, comp_code: u32) void {
    if (current_poll_xhci) |x| {
        var d_k: usize = 0;
        while (d_k < usb_device_count) : (d_k += 1) {
            var d = &usb_devices[d_k];
            if (d.active and (d.dev_type == .keyboard or d.dev_type == .mouse) and
                d.xhci_intr_configured and d.ctrl_idx == current_poll_ctrl_idx and
                d.xhci_slot_id == slot_id and (d.ep_in * 2 + 1) == dci)
            {
                if (!xhci_hid_event_logged) {
                    serial.serialWrite("[XHCI] HID event id=");
                    serial.serialWriteDec(d.id);
                    serial.serialWrite(" slot=");
                    serial.serialWriteDec(slot_id);
                    serial.serialWrite(" dci=");
                    serial.serialWriteDec(dci);
                    serial.serialWrite(" code=");
                    serial.serialWriteDec(comp_code);
                    serial.serialWrite(" residual=");
                    serial.serialWriteDec(rem_bytes);
                    serial.serialWrite("\n");
                    xhci_hid_event_logged = true;
                }
                if (comp_code == 1 or comp_code == 13) {
                    const max_p = @min(@max(d.ep_max_packet, 8), 64);
                    const actual_len: usize = if (max_p >= rem_bytes) @as(usize, @intCast(max_p - rem_bytes)) else max_p;
                    if (actual_len > 0) {
                        d.packet_count +%= 1;
                        processHidReport(d, actual_len);
                    }
                    x.queueInterruptTransfer(d.xhci_slot_idx, dci, @intFromPtr(&d.report_buf), @min(@max(d.ep_max_packet, 8), 64));
                } else {
                    _ = usbClearHalt(d, d.ep_in, true);
                    x.queueInterruptTransfer(d.xhci_slot_idx, dci, @intFromPtr(&d.report_buf), @min(@max(d.ep_max_packet, 8), 64));
                }
                break;
            }
        }
    }
}

var in_usb_poll = false;

// Asynchronous, non-blocking polling hook
pub fn poll() void {
    if (!initialized) return;
    if (in_usb_poll) return;
    in_usb_poll = true;
    defer in_usb_poll = false;

    var i: usize = 0;
    while (i < usb_device_count) : (i += 1) {
        var dev = &usb_devices[i];
        if (!dev.active) continue;
        if (dev.ctrl_idx >= controller_count) continue;

        const ctrl = &controllers[dev.ctrl_idx];
        switch (ctrl.ctrl_type) {
            .uhci => {
                // Check if Active bit (bit 23) has cleared on the interrupt TD
                const st = @as(*const volatile u32, @ptrCast(&dev.td.ctrl_status)).*;
                if ((st & uhci.TD_CTRL_ACTIVE) == 0) {
                    // A NAK means "no report yet": the data toggle must stay
                    // unchanged.  Real errors likewise must not be mistaken
                    // for a successful packet, otherwise the next DATA0/1
                    // phase is desynchronised.
                    const had_nak = (st & uhci.TD_CTRL_NAK) != 0;
                    const had_error = (st & (uhci.TD_CTRL_STALL | uhci.TD_CTRL_BABBLE |
                        uhci.TD_CTRL_TIMEOUT | uhci.TD_CTRL_DATA_ERR)) != 0;
                    if (!had_nak and !had_error) {
                        const act_len_field = st & 0x7FF;
                        const actual_len: usize = if (act_len_field == 0x7FF) 0 else @as(usize, @intCast(act_len_field + 1));
                        if (actual_len > 0) {
                            dev.packet_count +%= 1;
                            processHidReport(dev, actual_len);
                        }
                        dev.toggle ^= 1;
                    } else if ((st & uhci.TD_CTRL_STALL) != 0) {
                        _ = usbClearHalt(dev, dev.ep_in, true);
                    }

                    // Re-arm TD for next interrupt transfer non-blockingly.
                    const max_p: u32 = @min(@max(dev.ep_max_packet, 8), 64);
                    dev.td.token = 0x69 | (@as(u32, dev.addr) << 8) | (@as(u32, dev.ep_in) << 15) | (@as(u32, dev.toggle) << 19) | ((max_p - 1) << 21);
                    dev.td.link = 1;
                    @as(*volatile u32, @ptrCast(&dev.td.ctrl_status)).* = uhci.TD_CTRL_ACTIVE | uhci.TD_CTRL_3ERRORS | (if (dev.low_speed) uhci.TD_CTRL_LOWSPEED else 0) | uhci.TD_CTRL_SPD;
                    @as(*volatile u32, @ptrCast(&dev.qh.element_link)).* = @intCast(@intFromPtr(&dev.td));
                }
            },
            .ehci => {
                // Check if Active bit (bit 7) has cleared on the interrupt qTD
                const tok = @as(*const volatile u32, @ptrCast(&dev.ehci_qtd.token)).*;
                if ((tok & ehci.QTD_ACTIVE) == 0) {
                    // qTD errors (halted/buffer/babble/transaction) are not
                    // successful reports and must not advance the data toggle.
                    const had_error = (tok & 0x7C) != 0;
                    if (!had_error) {
                        const max_p: u32 = @min(@max(dev.ep_max_packet, 8), 64);
                        const rem_bytes = (tok >> 16) & 0x7FFF;
                        const actual_len: usize = if (max_p >= rem_bytes) @as(usize, @intCast(max_p - rem_bytes)) else 0;
                        if (actual_len > 0) {
                            dev.packet_count +%= 1;
                            processHidReport(dev, actual_len);
                        }
                        dev.toggle ^= 1;
                    } else if ((tok & (1 << 6)) != 0) {
                        _ = usbClearHalt(dev, dev.ep_in, true);
                    }

                    // Re-arm qTD for next interrupt transfer non-blockingly.
                    const max_p: u32 = @min(@max(dev.ep_max_packet, 8), 64);
                    dev.ehci_qtd.next_qtd = 1;
                    dev.ehci_qtd.alt_next_qtd = 1;
                    dev.ehci_qtd.buf[0] = @intCast(@intFromPtr(&dev.report_buf));
                    @as(*volatile u32, @ptrCast(&dev.ehci_qtd.token)).* = ehci.QTD_ACTIVE | ehci.QTD_PID_IN | ehci.QTD_3ERRORS | (max_p << 16) | (@as(u32, dev.toggle) << 31);
                    @as(*volatile u32, @ptrCast(&dev.ehci_qh.overlay_next_qtd)).* = @intCast(@intFromPtr(&dev.ehci_qtd));
                    @as(*volatile u32, @ptrCast(&dev.ehci_qh.overlay_token)).* = 0;
                }
            },
            else => {},
        }
    }

    // Poll xHCI host controllers for interrupt events
    var x_idx: usize = 0;
    while (x_idx < xhci_count) : (x_idx += 1) {
        var x = &xhci_instances[x_idx];
        current_poll_xhci = x;
        current_poll_ctrl_idx = x.id;
        x.pollEvents(onXhciTransfer);
    }
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
            const power_known = c.ctrl_type == .ehci or c.ctrl_type == .xhci;
            writeFn("      Port ");
            writeDecFn(port.port);
            writeFn(": ");
            if (port.connected) {
                writeFn("[CONNECTED] ");
                if (power_known) {
                    writeFn(if (port.powered) "POWER=ON " else "POWER=OFF ");
                } else {
                    writeFn("POWER=N/A ");
                }
                writeFn(port.speed);
                writeFn(" - ");
                writeFn(port.device_desc);
                writeFn("\n");
            } else if (power_known) {
                writeFn(if (port.powered) "[DISCONNECTED] POWER=ON (Empty)\n" else "[DISCONNECTED] POWER=OFF (Empty)\n");
            } else {
                writeFn("[DISCONNECTED] POWER=N/A (Empty)\n");
            }
        }
        writeFn("\n");
    }

    writeFn("=== Connected USB Devices (HID & Peripherals) ===\n\n");
    if (usb_device_count == 0) {
        writeFn("  No active USB devices registered.\n");
    } else {
        var d_idx: usize = 0;
        while (d_idx < usb_device_count) : (d_idx += 1) {
            const d = &usb_devices[d_idx];
            writeFn("  Device ID: ");
            writeDecFn(d.id);
            writeFn(": ");
            writeFn(d.dev_type.name());
            writeFn("\n");

            writeFn("    USB Address:   ");
            writeDecFn(d.addr);
            writeFn(" (Controller #");
            writeDecFn(d.ctrl_idx);
            writeFn(", Port ");
            writeDecFn(d.port);
            writeFn(")\n");

            writeFn("    Speed:        ");
            writeFn(if (d.low_speed) "Low-Speed (1.5 Mbps)" else "Full-Speed (12 Mbps)");
            writeFn("\n");

            writeFn("    Vendor ID:    ");
            writeHexFn(d.vendor_id);
            writeFn(", Product ID: ");
            writeHexFn(d.product_id);
            writeFn("\n");

            writeFn("    Endpoint IN:  EP ");
            writeDecFn(d.ep_in);
            writeFn(" (MaxPacket: ");
            writeDecFn(d.ep_max_packet);
            writeFn(" bytes, Interval: ");
            writeDecFn(d.ep_interval);
            writeFn(" ms)\n");

            writeFn("    Packets Recv: ");
            writeDecFn(d.packet_count);
            writeFn("\n\n");
        }
    }

    // Print Mass Storage Drives
    storage.printStatus(writeFn, writeDecFn, writeHexFn);
}

// ─── Generic USB Transfer Helpers ──────────────────────────────────────────

fn findUsbDeviceById(id: u32) ?*device.UsbDevice {
    var d_idx: usize = 0;
    while (d_idx < usb_device_count) : (d_idx += 1) {
        const dev = &usb_devices[d_idx];
        if (dev.active and dev.id == id) return dev;
    }
    return null;
}

fn findUniqueUsbDeviceByAddress(addr: u8) ?*device.UsbDevice {
    var found: ?*device.UsbDevice = null;
    var d_idx: usize = 0;
    while (d_idx < usb_device_count) : (d_idx += 1) {
        const dev = &usb_devices[d_idx];
        if (!dev.active or dev.addr != addr) continue;
        if (found) |previous| {
            // Composite interfaces share an ID/address and are harmless.  A
            // match on different IDs means the legacy address-only API is
            // ambiguous and must not guess a controller.
            if (previous.id != dev.id or previous.ctrl_idx != dev.ctrl_idx) return null;
        } else {
            found = dev;
        }
    }
    return found;
}

fn usbControlTransferForDevice(
    dev: *device.UsbDevice,
    maxp0: u8,
    setup: *const types.UsbSetupPacket,
    dout: ?[]const u8,
    din: ?[]u8,
) bool {
    if (!initialized or !dev.active or dev.ctrl_idx >= controller_count) return false;
    const ctrl = &controllers[dev.ctrl_idx];
    switch (ctrl.ctrl_type) {
        .uhci => if (ctrl.inst_idx < uhci_count) {
            return uhci_instances[ctrl.inst_idx].controlTransfer(dev.addr, dev.low_speed, maxp0, setup, dout, din);
        },
        .ehci => if (ctrl.inst_idx < ehci_count) {
            return ehci_instances[ctrl.inst_idx].controlTransfer(dev.addr, maxp0, setup, dout, din);
        },
        .xhci => if (ctrl.inst_idx < xhci_count) {
            return xhci_instances[ctrl.inst_idx].controlTransfer(dev.xhci_slot_idx, maxp0, setup, dout, din);
        },
        else => {},
    }
    return false;
}

/// Perform a control transfer using the kernel-global device ID.  The ID
/// resolves the owning controller and, for xHCI, the device slot.
pub fn usbControlTransferById(id: u32, maxp0: u8, setup: *const types.UsbSetupPacket, dout: ?[]const u8, din: ?[]u8) bool {
    const dev = findUsbDeviceById(id) orelse return false;
    return usbControlTransferForDevice(dev, maxp0, setup, dout, din);
}

/// Legacy address-based entry point.  It is accepted only when the address
/// identifies one physical device; callers should prefer usbControlTransferById.
pub fn usbControlTransfer(addr: u8, maxp0: u8, setup: *const types.UsbSetupPacket, dout: ?[]const u8, din: ?[]u8) bool {
    const dev = findUniqueUsbDeviceByAddress(addr) orelse return false;
    return usbControlTransferForDevice(dev, maxp0, setup, dout, din);
}

/// Perform a USB bulk transfer (IN or OUT) to a specific device endpoint.
/// Automatically handles endpoint toggles, packet splitting, and host controller scheduling.
pub fn usbBulkTransfer(
    dev: *device.UsbDevice,
    ep_num: u8,
    is_in: bool,
    data: []u8,
) ?usize {
    if (!initialized or !dev.active) return null;
    if (dev.ctrl_idx >= controller_count) return null;

    const ctrl = &controllers[dev.ctrl_idx];
    switch (ctrl.ctrl_type) {
        .uhci => {
            if (ctrl.inst_idx < uhci_count) {
                const u = &uhci_instances[ctrl.inst_idx];
                const t = if (is_in) &dev.ep_bulk_in_toggle else &dev.ep_bulk_out_toggle;
                const mp = if (is_in) dev.ep_bulk_in_max_pkt else dev.ep_bulk_out_max_pkt;
                return u.bulkTransfer(dev.addr, ep_num, is_in, t, mp, data);
            }
        },
        .ehci => {
            if (ctrl.inst_idx < ehci_count) {
                const e = &ehci_instances[ctrl.inst_idx];
                const t = if (is_in) &dev.ep_bulk_in_toggle else &dev.ep_bulk_out_toggle;
                const mp = if (is_in) dev.ep_bulk_in_max_pkt else dev.ep_bulk_out_max_pkt;
                return e.bulkTransfer(dev.addr, ep_num, is_in, t, mp, data);
            }
        },
        .xhci => {
            if (ctrl.inst_idx < xhci_count) {
                return xhci_instances[ctrl.inst_idx].bulkTransfer(
                    dev.xhci_slot_idx,
                    ep_num,
                    is_in,
                    data,
                );
            }
        },
        else => return null,
    }
    return null;
}

/// Perform a bulk OUT transfer using the kernel-global device ID.
pub fn usbBulkOutTransferById(id: u32, ep: u8, data: []const u8) bool {
    const dev = findUsbDeviceById(id) orelse return false;
    const result = usbBulkTransfer(dev, ep, false, @constCast(data));
    return result != null and result.? == data.len;
}

/// Perform a bulk IN transfer using the kernel-global device ID.
pub fn usbBulkInTransferById(id: u32, ep: u8, buf: []u8) ?usize {
    const dev = findUsbDeviceById(id) orelse return null;
    return usbBulkTransfer(dev, ep, true, buf);
}

/// Reset and re-enable an xHCI bulk endpoint after a stall.
pub fn recoverXhciBulkEndpoint(dev: *device.UsbDevice, ep_num: u8, is_in: bool) bool {
    if (dev.xhci_slot_id == 0 or dev.ctrl_idx >= controller_count) return false;
    const ctrl = &controllers[dev.ctrl_idx];
    if (ctrl.ctrl_type != .xhci or ctrl.inst_idx >= xhci_count) return false;
    const max_packet = if (is_in) dev.ep_bulk_in_max_pkt else dev.ep_bulk_out_max_pkt;
    return xhci_instances[ctrl.inst_idx].recoverBulkEndpoint(
        dev.xhci_slot_idx,
        ep_num,
        is_in,
        max_packet,
    );
}

pub fn recoverXhciInterruptEndpoint(dev: *device.UsbDevice, ep_num: u8) bool {
    if (dev.xhci_slot_id == 0 or dev.ctrl_idx >= controller_count) return false;
    const ctrl = &controllers[dev.ctrl_idx];
    if (ctrl.ctrl_type != .xhci or ctrl.inst_idx >= xhci_count) return false;
    return xhci_instances[ctrl.inst_idx].recoverInterruptEndpoint(
        dev.xhci_slot_idx,
        ep_num,
        dev.ep_max_packet,
        dev.ep_interval,
    );
}

pub fn usbClearHalt(dev: *device.UsbDevice, ep_num: u8, is_in: bool) bool {
    const ep_addr = ep_num | (if (is_in) @as(u8, 0x80) else 0);
    const clear_pkt = types.UsbSetupPacket{
        .bmRequestType = 0x02, // Standard, Endpoint
        .bRequest = types.REQ_CLEAR_FEATURE,
        .wValue = types.FEATURE_ENDPOINT_HALT,
        .wIndex = ep_addr,
        .wLength = 0,
    };
    const maxp0: u8 = @min(dev.ep0_max_packet, 64);
    const ok = usbControlTransferById(dev.id, maxp0, &clear_pkt, null, null);
    if (ok and dev.xhci_slot_id != 0) {
        if (ep_num == dev.ep_in and (dev.dev_type == .keyboard or dev.dev_type == .mouse)) {
            _ = recoverXhciInterruptEndpoint(dev, ep_num);
        } else if (ep_num == dev.ep_bulk_in and is_in) {
            _ = recoverXhciBulkEndpoint(dev, ep_num, true);
        } else if (ep_num == dev.ep_bulk_out and !is_in) {
            _ = recoverXhciBulkEndpoint(dev, ep_num, false);
        }
    }
    return ok;
}

/// Legacy address-based bulk OUT entry point.  Prefer the ID-based variant.
pub fn usbBulkOutTransfer(addr: u8, ep: u8, data: []const u8) bool {
    const dev = findUniqueUsbDeviceByAddress(addr) orelse return false;
    const result = usbBulkTransfer(dev, ep, false, @constCast(data));
    return result != null and result.? == data.len;
}

/// Legacy address-based bulk IN entry point.  Prefer the ID-based variant.
pub fn usbBulkInTransfer(addr: u8, ep: u8, buf: []u8) ?usize {
    const dev = findUniqueUsbDeviceByAddress(addr) orelse return null;
    return usbBulkTransfer(dev, ep, true, buf);
}
