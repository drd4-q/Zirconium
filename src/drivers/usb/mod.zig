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

fn enumerateCompositeInterfaces(dev: *device.UsbDevice, c_idx: u8, p: u8, is_low_speed: bool, new_addr: u8) void {
    var if_idx: usize = 1;
    while (if_idx < dev.interface_count and usb_device_count < MAX_USB_DEVICES) : (if_idx += 1) {
        const iface = &dev.interfaces[if_idx];
        if (iface.class_code == 0x03) {
            var dev_extra = &usb_devices[usb_device_count];
            dev_extra.active = true;
            dev_extra.ctrl_idx = c_idx;
            dev_extra.port = p + 1;
            dev_extra.addr = new_addr;
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
                dev_extra.ep_in = @intCast(if_idx + 1);
                dev_extra.ep_max_packet = 8;
                dev_extra.ep_interval = 10;
            }

            dev_extra.toggle = 0;
            dev_extra.packet_count = 0;
            dev_extra.caps_lock = false;
            @memset(&dev_extra.report_buf, 0);
            @memset(&dev_extra.prev_report, 0);

            serial.serialWrite("[USB] Registered ");
            serial.serialWrite(dev_extra.dev_type.name());
            serial.serialWrite(" at Addr ");
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

fn relinkUhciControllerSchedule(u_ctrl: *uhci.UhciController, ctrl_index: u8) void {
    var prev_qh: ?*UhciQh = null;

    var i: usize = 0;
    while (i < usb_device_count) : (i += 1) {
        const dev = &usb_devices[i];
        if (!dev.active or dev.ctrl_idx != ctrl_index) continue;
        if (dev.dev_type != .keyboard and dev.dev_type != .mouse and dev.dev_type != .unknown) continue;

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
        pq.head_link = @intCast(@intFromPtr(u_ctrl.ctrl_qh) | 0x02);
    } else {
        const qh_ptr: u32 = @intCast(@intFromPtr(u_ctrl.ctrl_qh) | 0x02);
        var f: usize = 0;
        while (f < 1024) : (f += 1) {
            u_ctrl.frame_list[f] = qh_ptr;
        }
    }
    u_ctrl.ctrl_qh.head_link = @intCast(@intFromPtr(u_ctrl.bulk_qh) | 0x02);
    u_ctrl.bulk_qh.head_link = 1;
    u_ctrl.bulk_qh.element_link = 1;
}

fn relinkEhciControllerSchedule(e_ctrl: *ehci.EhciController, ctrl_index: u8) void {
    var prev_qh: ?*ehci.EhciQh = null;

    var i: usize = 0;
    while (i < usb_device_count) : (i += 1) {
        const dev = &usb_devices[i];
        if (!dev.active or dev.ctrl_idx != ctrl_index) continue;
        if (dev.dev_type != .keyboard and dev.dev_type != .mouse and dev.dev_type != .unknown) continue;

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

        if (prev_qh) |pq| {
            pq.horizontal_link = @intCast(@intFromPtr(&dev.ehci_qh) | 0x02);
        } else {
            e_ctrl.linkInterruptQh(&dev.ehci_qh);
        }
        prev_qh = &dev.ehci_qh;
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

pub fn init() void {
    if (initialized) return;

    controller_count = 0;
    usb_device_count = 0;
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
                                                dev.xhci_slot_id = slot_id;
                                                dev.xhci_slot_idx = @intCast(slot_idx);

                                                const is_low_speed = (speed_code == 2);
                                                const dev_speed: UsbSpeed = if (is_low_speed)
                                                    .low
                                                else if (speed_code == 3)
                                                    .high
                                                else if (speed_code >= 4)
                                                    .super_speed
                                                else
                                                    .full;
                                                const new_addr: u8 = @intCast(usb_device_count + 1);

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

                                                    // Configure interrupt endpoint on xHCI for primary device
                                                    _ = x.configureInterruptEndpoint(slot_idx, dev.ep_in, dev.ep_max_packet, dev.ep_interval);
                                                    // Queue initial interrupt transfer
                                                    x.queueInterruptTransfer(slot_idx, dev.ep_in * 2 + 1, @intFromPtr(&dev.report_buf), @min(@max(dev.ep_max_packet, 8), 64));

                                                    // Also configure interrupt endpoints for any secondary composite interfaces
                                                    var sec_i = extra_start;
                                                    while (sec_i < usb_device_count) : (sec_i += 1) {
                                                        const sec_dev = &usb_devices[sec_i];
                                                        if (sec_dev.active and sec_dev.ep_in != dev.ep_in) {
                                                            _ = x.configureInterruptEndpoint(slot_idx, sec_dev.ep_in, sec_dev.ep_max_packet, sec_dev.ep_interval);
                                                            x.queueInterruptTransfer(slot_idx, sec_dev.ep_in * 2 + 1, @intFromPtr(&sec_dev.report_buf), @min(@max(sec_dev.ep_max_packet, 8), 64));
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
            var hub_ports: [8]hub.HubPortInfo = undefined;
            const num_conn = hub.configureHubPorts(hub_dev.addr, 8, cfn, hub_ports[0..]);
            var p_i: usize = 0;
            while (p_i < num_conn and usb_device_count < MAX_USB_DEVICES) : (p_i += 1) {
                const hp = &hub_ports[p_i];
                if (hp.connected and hp.enabled) {
                    const dev = &usb_devices[usb_device_count];
                    const new_addr: u8 = @intCast(usb_device_count + 1);
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
                        if (dev.dev_type == .keyboard or dev.dev_type == .mouse) {
                            _ = hid_core.registerHidDevice(usb_device_count - 1, dev, dev.interface_num, dev.dev_type);
                        }
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

fn processHidReport(dev: *device.UsbDevice, len: usize) void {
    if (len == 0) return;
    hid_core.processRawDeviceReport(dev, len);
}

var current_poll_xhci: ?*xhci.XhciController = null;
var current_poll_ctrl_idx: u8 = 0;

fn onXhciTransfer(slot_id: u8, dci: u8, rem_bytes: u32, comp_code: u32) void {
    if (current_poll_xhci) |x| {
        var d_k: usize = 0;
        while (d_k < usb_device_count) : (d_k += 1) {
            var d = &usb_devices[d_k];
            if (d.active and d.ctrl_idx == current_poll_ctrl_idx and d.xhci_slot_id == slot_id and (d.ep_in * 2 + 1) == dci) {
                if (comp_code == 1 or comp_code == 13) {
                    const max_p = @min(@max(d.ep_max_packet, 8), 64);
                    const actual_len: usize = if (max_p >= rem_bytes) @as(usize, @intCast(max_p - rem_bytes)) else max_p;
                    if (actual_len > 0) {
                        processHidReport(d, actual_len);
                    }
                }
                x.queueInterruptTransfer(d.xhci_slot_idx, dci, @intFromPtr(&d.report_buf), @min(@max(d.ep_max_packet, 8), 64));
                break;
            }
        }
    }
}

var in_usb_poll = false;

// Asynchronous, non-blocking polling hook
pub fn poll() void {
    if (!initialized or usb_device_count == 0) return;
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
                    // Check for error bits (bits 22..17)
                    if ((st & 0x007E0000) == 0) {
                        const act_len_field = st & 0x7FF;
                        const actual_len: usize = if (act_len_field == 0x7FF) 0 else @as(usize, @intCast(act_len_field + 1));
                        if (actual_len > 0) {
                            dev.packet_count +%= 1;
                            processHidReport(dev, actual_len);
                        }
                    }

                    // Re-arm TD for next interrupt transfer non-blockingly
                    dev.toggle ^= 1;
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
                    // Check error bits: bits 6:3 (Halted, Data Buffer Error, Babble, XactErr)
                    if ((tok & 0x78) == 0) {
                        const max_p: u32 = @min(@max(dev.ep_max_packet, 8), 64);
                        const rem_bytes = (tok >> 16) & 0x7FFF;
                        const actual_len: usize = if (max_p >= rem_bytes) @as(usize, @intCast(max_p - rem_bytes)) else 0;
                        if (actual_len > 0) {
                            dev.packet_count +%= 1;
                            processHidReport(dev, actual_len);
                        }
                    }

                    // Re-arm qTD for next interrupt transfer non-blockingly
                    dev.toggle ^= 1;
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

    writeFn("=== Connected USB Devices (HID & Peripherals) ===\n\n");
    if (usb_device_count == 0) {
        writeFn("  No active USB devices registered.\n");
    } else {
        var d_idx: usize = 0;
        while (d_idx < usb_device_count) : (d_idx += 1) {
            const d = &usb_devices[d_idx];
            writeFn("  Device #");
            writeDecFn(d_idx + 1);
            writeFn(": ");
            writeFn(d.dev_type.name());
            writeFn("\n");

            writeFn("    Address:      ");
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

/// Perform a USB control transfer. Routes through the target device's controller
/// or falls back to the first active controller.
pub fn usbControlTransfer(addr: u8, maxp0: u8, setup: *const types.UsbSetupPacket, dout: ?[]const u8, din: ?[]u8) bool {
    if (!initialized) return false;

    // Check if target device is known
    var d_idx: usize = 0;
    while (d_idx < usb_device_count) : (d_idx += 1) {
        const dev = &usb_devices[d_idx];
        if (dev.active and dev.addr == addr) {
            const ctrl = &controllers[dev.ctrl_idx];
            switch (ctrl.ctrl_type) {
                .uhci => {
                    if (ctrl.inst_idx < uhci_count) {
                        return uhci_instances[ctrl.inst_idx].controlTransfer(addr, dev.low_speed, maxp0, setup, dout, din);
                    }
                },
                .ehci => {
                    if (ctrl.inst_idx < ehci_count) {
                        return ehci_instances[ctrl.inst_idx].controlTransfer(addr, maxp0, setup, dout, din);
                    }
                },
                .xhci => {
                    if (ctrl.inst_idx < xhci_count) {
                        return xhci_instances[ctrl.inst_idx].controlTransfer(dev.xhci_slot_idx, maxp0, setup, dout, din);
                    }
                },
                else => {},
            }
        }
    }

    // Fallback to UHCI
    if (uhci_count > 0) {
        current_uhci_ctrl = &uhci_instances[0];
        current_uhci_low_speed = false;
        return uhci_instances[0].controlTransfer(addr, false, maxp0, setup, dout, din);
    }

    // Fallback to EHCI
    if (ehci_count > 0) {
        return ehci_instances[0].controlTransfer(addr, maxp0, setup, dout, din);
    }

    return false;
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
        else => return null,
    }
    return null;
}

/// Clear a stalled endpoint using standard USB CLEAR_FEATURE(ENDPOINT_HALT).
pub fn usbClearHalt(dev: *device.UsbDevice, ep_num: u8, is_in: bool) bool {
    const ep_addr = ep_num | (if (is_in) @as(u8, 0x80) else 0);
    const clear_pkt = types.UsbSetupPacket{
        .bmRequestType = 0x02, // Standard, Endpoint
        .bRequest = types.REQ_CLEAR_FEATURE,
        .wValue = types.FEATURE_ENDPOINT_HALT,
        .wIndex = ep_addr,
        .wLength = 0,
    };
    const maxp0: u8 = @intCast(@min(dev.ep_max_packet, 64));
    return usbControlTransfer(dev.addr, maxp0, &clear_pkt, null, null);
}

/// Perform a USB bulk OUT transfer.
pub fn usbBulkOutTransfer(addr: u8, ep: u8, data: []const u8) bool {
    if (!initialized) return false;
    var d_idx: usize = 0;
    while (d_idx < usb_device_count) : (d_idx += 1) {
        const dev = &usb_devices[d_idx];
        if (dev.active and dev.addr == addr) {
            const mut_data = @constCast(data);
            const res = usbBulkTransfer(dev, ep, false, mut_data);
            return res != null and res.? == data.len;
        }
    }

    // Fallback if device address not registered
    if (uhci_count > 0) {
        var dummy_toggle: u1 = 0;
        const mut_data = @constCast(data);
        const res = uhci_instances[0].bulkTransfer(addr, ep, false, &dummy_toggle, 64, mut_data);
        return res != null and res.? == data.len;
    }
    if (ehci_count > 0) {
        var dummy_toggle: u1 = 0;
        const mut_data = @constCast(data);
        const res = ehci_instances[0].bulkTransfer(addr, ep, false, &dummy_toggle, 512, mut_data);
        return res != null and res.? == data.len;
    }
    return false;
}

/// Perform a USB bulk IN transfer.
pub fn usbBulkInTransfer(addr: u8, ep: u8, buf: []u8) ?usize {
    if (!initialized) return null;
    var d_idx: usize = 0;
    while (d_idx < usb_device_count) : (d_idx += 1) {
        const dev = &usb_devices[d_idx];
        if (dev.active and dev.addr == addr) {
            return usbBulkTransfer(dev, ep, true, buf);
        }
    }

    // Fallback if device address not registered
    if (uhci_count > 0) {
        var dummy_toggle: u1 = 0;
        return uhci_instances[0].bulkTransfer(addr, ep, true, &dummy_toggle, 64, buf);
    }
    if (ehci_count > 0) {
        var dummy_toggle: u1 = 0;
        return ehci_instances[0].bulkTransfer(addr, ep, true, &dummy_toggle, 512, buf);
    }
    return null;
}
