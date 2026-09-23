const std = @import("std");
const root = @import("root");
const serial = root.serial;
const timer = @import("../timer.zig");
const types = @import("types.zig");
const uhci = @import("uhci.zig");
const ehci = @import("ehci.zig");
const hid = @import("hid.zig");

pub const UsbSpeed = types.UsbSpeed;
pub const UsbDeviceClass = types.UsbDeviceClass;
pub const UsbDeviceType = types.UsbDeviceType;
pub const UsbSetupPacket = types.UsbSetupPacket;
pub const UsbEndpoint = types.UsbEndpoint;
pub const UsbInterface = types.UsbInterface;
pub const UhciQh = uhci.UhciQh;
pub const UhciTd = uhci.UhciTd;
pub const EhciQh = ehci.EhciQh;
pub const EhciQtd = ehci.EhciQtd;

pub const MAX_DEVICE_INTERFACES: usize = types.MAX_DEVICE_INTERFACES;

pub const UsbDevice = struct {
    active: bool = false,
    ctrl_idx: u8 = 0,
    port: u8 = 0,
    addr: u8 = 0,
    ep0_max_packet: u8 = 8,
    low_speed: bool = false,
    speed: UsbSpeed = .full,
    dev_type: UsbDeviceType = .unknown,
    vendor_id: u16 = 0,
    product_id: u16 = 0,
    is_wireless: bool = false,

    // Multi-interface composite device support
    interfaces: [MAX_DEVICE_INTERFACES]UsbInterface = [_]UsbInterface{.{}} ** MAX_DEVICE_INTERFACES,
    interface_count: usize = 0,

    // Legacy fields maintained for backward compatibility with existing keyboard/mouse/shell code
    interface_num: u8 = 0,
    ep_in: u8 = 1,
    ep_max_packet: u16 = 8,
    ep_interval: u8 = 10,
    toggle: u1 = 0,
    qh: UhciQh align(16) = .{},
    td: UhciTd align(16) = .{},
    ehci_qh: EhciQh align(32) = .{},
    ehci_qtd: EhciQtd align(32) = .{},
    report_buf: [64]u8 align(16) = [_]u8{0} ** 64,
    prev_report: [64]u8 = [_]u8{0} ** 64,
    packet_count: u32 = 0,
    caps_lock: bool = false,
    xhci_slot_id: u8 = 0,
    xhci_slot_idx: u8 = 0,
    xhci_intr_configured: bool = false,
    xhci_bulk_in_configured: bool = false,
    xhci_bulk_out_configured: bool = false,

    // Bulk endpoints (for Mass Storage, USB Wi-Fi, etc.)
    ep_bulk_in: u8 = 0,
    ep_bulk_in_max_pkt: u16 = 64,
    ep_bulk_in_toggle: u1 = 0,
    ep_bulk_out: u8 = 0,
    ep_bulk_out_max_pkt: u16 = 64,
    ep_bulk_out_toggle: u1 = 0,
};

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

pub fn enumerateDevice(
    ctrl_idx: u8,
    port_idx: u8,
    low_speed: bool,
    speed: UsbSpeed,
    dev_out: *UsbDevice,
    new_addr: u8,
    ctrl_transfer_fn: *const fn (addr: u8, maxp0: u8, setup: *const UsbSetupPacket, dout: ?[]const u8, din: ?[]u8) bool,
    already_addressed: bool,
) bool {
    // Step 1: Read first 8 bytes of Device Descriptor at address 0 (or assigned address if hardware addressed)
    var dev_desc_8: [8]u8 = [_]u8{0} ** 8;
    const get_desc_pkt = UsbSetupPacket{
        .bmRequestType = 0x80,
        .bRequest = types.REQ_GET_DESCRIPTOR,
        .wValue = 0x0100, // DEVICE descriptor
        .wIndex = 0,
        .wLength = 8,
    };

    const target_addr: u8 = if (already_addressed) new_addr else 0;

    if (!ctrl_transfer_fn(target_addr, 8, &get_desc_pkt, null, &dev_desc_8)) {
        serial.serialWrite("[USB] Failed to read Device Descriptor (8 bytes)\n");
        return false;
    }

    const max_packet0: u8 = switch (dev_desc_8[7]) {
        16 => 16,
        32 => 32,
        64 => 64,
        else => 8,
    };
    dev_out.ep0_max_packet = max_packet0;

    // Step 2: Set Address (only if NOT already addressed by hardware, e.g. UHCI/EHCI)
    if (!already_addressed) {
        const set_addr_pkt = UsbSetupPacket{
            .bmRequestType = 0x00,
            .bRequest = types.REQ_SET_ADDRESS,
            .wValue = new_addr,
            .wIndex = 0,
            .wLength = 0,
        };

        if (!ctrl_transfer_fn(0, max_packet0, &set_addr_pkt, null, null)) {
            serial.serialWrite("[USB] Failed to SET_ADDRESS\n");
            return false;
        }
        spinDelayMs(20); // Device recovery time after address assignment
    }

    // Step 3: Read full 18-byte Device Descriptor at assigned address
    var dev_desc: [18]u8 = [_]u8{0} ** 18;
    const get_full_desc_pkt = UsbSetupPacket{
        .bmRequestType = 0x80,
        .bRequest = types.REQ_GET_DESCRIPTOR,
        .wValue = 0x0100,
        .wIndex = 0,
        .wLength = 18,
    };

    if (!ctrl_transfer_fn(new_addr, max_packet0, &get_full_desc_pkt, null, &dev_desc)) {
        serial.serialWrite("[USB] Failed to read full Device Descriptor\n");
        return false;
    }

    const vendor_id = @as(u16, dev_desc[8]) | (@as(u16, dev_desc[9]) << 8);
    const product_id = @as(u16, dev_desc[10]) | (@as(u16, dev_desc[11]) << 8);
    const dev_class = dev_desc[4];

    // Step 4: Read 9-byte Configuration Descriptor Header to get total length
    var cfg_hdr: [9]u8 = [_]u8{0} ** 9;
    const get_cfg_hdr_pkt = UsbSetupPacket{
        .bmRequestType = 0x80,
        .bRequest = types.REQ_GET_DESCRIPTOR,
        .wValue = 0x0200, // CONFIGURATION descriptor
        .wIndex = 0,
        .wLength = 9,
    };

    if (!ctrl_transfer_fn(new_addr, max_packet0, &get_cfg_hdr_pkt, null, &cfg_hdr)) {
        serial.serialWrite("[USB] Failed to read Config Descriptor Header\n");
        return false;
    }

    if (cfg_hdr[0] < 9 or cfg_hdr[1] != types.DESC_CONFIGURATION) {
        serial.serialWrite("[USB] Invalid configuration descriptor header\n");
        return false;
    }
    var total_cfg_len = @as(u16, cfg_hdr[2]) | (@as(u16, cfg_hdr[3]) << 8);
    if (total_cfg_len < 9) {
        serial.serialWrite("[USB] Invalid configuration descriptor length\n");
        return false;
    }
    total_cfg_len = @min(total_cfg_len, 512);

    // Step 5: Read full Configuration Descriptor tree
    var cfg_buf: [512]u8 = [_]u8{0} ** 512;
    const get_full_cfg_pkt = UsbSetupPacket{
        .bmRequestType = 0x80,
        .bRequest = types.REQ_GET_DESCRIPTOR,
        .wValue = 0x0200,
        .wIndex = 0,
        .wLength = total_cfg_len,
    };

    if (!ctrl_transfer_fn(new_addr, max_packet0, &get_full_cfg_pkt, null, cfg_buf[0..total_cfg_len])) {
        serial.serialWrite("[USB] Failed to read full Config Descriptor\n");
        return false;
    }

    // Step 6: Multi-interface parsing
    var iface_count: usize = 0;
    var current_iface: ?*UsbInterface = null;

    var off: usize = 0;
    while (off + 2 <= total_cfg_len) {
        const desc_len = cfg_buf[off];
        if (desc_len < 2 or off + desc_len > total_cfg_len) break;
        const desc_type = cfg_buf[off + 1];

        if (desc_type == types.DESC_INTERFACE and desc_len >= 9) {
            if (iface_count < MAX_DEVICE_INTERFACES) {
                current_iface = &dev_out.interfaces[iface_count];
                current_iface.?.* = UsbInterface{
                    .interface_num = cfg_buf[off + 2],
                    .class_code = cfg_buf[off + 5],
                    .subclass_code = cfg_buf[off + 6],
                    .protocol_code = cfg_buf[off + 7],
                };

                if (current_iface.?.class_code == 0x03) {
                    if (current_iface.?.protocol_code == 1) {
                        current_iface.?.driver_type = .keyboard;
                    } else if (current_iface.?.protocol_code == 2) {
                        current_iface.?.driver_type = .mouse;
                    } else {
                        current_iface.?.driver_type = if (iface_count == 0) .keyboard else .mouse;
                    }
                } else if (current_iface.?.class_code == 0x08) {
                    current_iface.?.driver_type = .storage;
                } else if (current_iface.?.class_code == 0xFF) {
                    current_iface.?.driver_type = .wifi;
                }

                iface_count += 1;
            }
        } else if (desc_type == types.DESC_ENDPOINT and desc_len >= 7) {
            if (current_iface) |iface| {
                if (iface.endpoint_count < types.MAX_DEVICE_ENDPOINTS) {
                    const ep_addr = cfg_buf[off + 2];
                    const ep_attr = cfg_buf[off + 3];
                    const max_pkt = @as(u16, cfg_buf[off + 4]) | (@as(u16, cfg_buf[off + 5]) << 8);
                    const interval = cfg_buf[off + 6];

                    const t_type: types.UsbTransferType = switch (ep_attr & 3) {
                        0 => .control,
                        1 => .isochronous,
                        2 => .bulk,
                        3 => .interrupt,
                        else => .interrupt,
                    };

                    iface.endpoints[iface.endpoint_count] = UsbEndpoint{
                        .ep_addr = ep_addr,
                        .transfer_type = t_type,
                        .max_packet_size = if (max_pkt > 0) max_pkt else 8,
                        .interval_ms = interval,
                        .active = true,
                    };
                    iface.endpoint_count += 1;
                }
            }
        }
        off += desc_len;
    }

    dev_out.interface_count = iface_count;

    // Step 7: Set Configuration (wValue = bConfigurationValue from header)
    const cfg_val: u16 = if (cfg_hdr[5] != 0) cfg_hdr[5] else 1;
    const set_cfg_pkt = UsbSetupPacket{
        .bmRequestType = 0x00,
        .bRequest = types.REQ_SET_CONFIGURATION,
        .wValue = cfg_val,
        .wIndex = 0,
        .wLength = 0,
    };
    if (!ctrl_transfer_fn(new_addr, max_packet0, &set_cfg_pkt, null, null)) {
        serial.serialWrite("[USB] Failed to SET_CONFIGURATION\n");
        return false;
    }
    serial.serialWrite("[USB] SET_CONFIGURATION OK\n");
    spinDelayMs(20);

    // Step 8: Configure HID interfaces (Boot Protocol + Report on change)
    if (hid.isWirelessDongle(vendor_id, product_id)) {
        serial.serialWrite("[USB] Detected 2.4GHz Wireless Receiver: ");
        if (hid.getDongleName(vendor_id, product_id)) |dname| {
            serial.serialWrite(dname);
        } else {
            serial.serialWrite("Generic 2.4GHz Wireless Receiver");
        }
        serial.serialWrite("\n");
    }

    var primary_dtype: UsbDeviceType = .unknown;
    var if_idx: usize = 0;
    while (if_idx < iface_count) : (if_idx += 1) {
        const iface = &dev_out.interfaces[if_idx];
        if (iface.class_code == 0x03) {
            // SET_PROTOCOL: 0 = Boot Protocol (only valid for boot interface subclass)
            if (iface.subclass_code == 0x01) {
                const set_proto_pkt = hid.makeSetProtocolPacket(iface.interface_num, hid.PROTOCOL_BOOT);
                _ = ctrl_transfer_fn(new_addr, max_packet0, &set_proto_pkt, null, null);
            }

            // SET_IDLE: 0 = Report on change
            const set_idle_pkt = hid.makeSetIdlePacket(iface.interface_num, 0, 0);
            _ = ctrl_transfer_fn(new_addr, max_packet0, &set_idle_pkt, null, null);

            if (iface.driver_type == .keyboard) {
                // Turn on NumLock LED on keyboard by default
                hid.setKeyboardLeds(new_addr, max_packet0, iface.interface_num, true, false, false, ctrl_transfer_fn);
            }

            if (primary_dtype == .unknown) {
                primary_dtype = iface.driver_type;
            }
        } else if (iface.class_code == 0x08 and primary_dtype == .unknown) {
            primary_dtype = .storage;
        } else if (iface.class_code == 0xFF and primary_dtype == .unknown) {
            primary_dtype = .wifi;
        }
    }

    if (primary_dtype == .unknown) {
        if (dev_class == 0x03) {
            primary_dtype = if (port_idx == 0) .keyboard else .mouse;
        } else if (dev_class == 0x09) {
            primary_dtype = .hub;
        } else if (dev_class == 0x08) {
            primary_dtype = .storage;
        }
    }

    // Step 9: Populate primary device fields
    dev_out.active = true;
    dev_out.ctrl_idx = ctrl_idx;
    dev_out.port = port_idx + 1;
    dev_out.addr = new_addr;
    dev_out.low_speed = low_speed;
    dev_out.speed = speed;
    dev_out.dev_type = primary_dtype;
    dev_out.vendor_id = vendor_id;
    dev_out.product_id = product_id;
    dev_out.is_wireless = hid.isWirelessDongle(vendor_id, product_id);

    // Populate legacy single-interface fields from first interface if available
    if (iface_count > 0) {
        const first_if = &dev_out.interfaces[0];
        dev_out.interface_num = first_if.interface_num;
        var found_in = false;
        var ep_k: usize = 0;
        while (ep_k < first_if.endpoint_count) : (ep_k += 1) {
            const ep = &first_if.endpoints[ep_k];
            if (ep.active and ep.isInput() and ep.transfer_type == .interrupt) {
                dev_out.ep_in = ep.epNumber();
                dev_out.ep_max_packet = ep.max_packet_size;
                dev_out.ep_interval = ep.interval_ms;
                found_in = true;
                break;
            }
        }
        if (!found_in and first_if.endpoint_count > 0) {
            const first_ep = &first_if.endpoints[0];
            dev_out.ep_in = first_ep.epNumber();
            dev_out.ep_max_packet = first_ep.max_packet_size;
            dev_out.ep_interval = first_ep.interval_ms;
        }

        // Scan for bulk endpoints across all interfaces
        var scan_if: usize = 0;
        while (scan_if < iface_count) : (scan_if += 1) {
            const cur_if = &dev_out.interfaces[scan_if];
            var ep_i: usize = 0;
            while (ep_i < cur_if.endpoint_count) : (ep_i += 1) {
                const ep = &cur_if.endpoints[ep_i];
                if (ep.active and ep.transfer_type == .bulk) {
                    if (ep.isInput()) {
                        if (dev_out.ep_bulk_in == 0) {
                            dev_out.ep_bulk_in = ep.epNumber();
                            dev_out.ep_bulk_in_max_pkt = ep.max_packet_size;
                        }
                    } else {
                        if (dev_out.ep_bulk_out == 0) {
                            dev_out.ep_bulk_out = ep.epNumber();
                            dev_out.ep_bulk_out_max_pkt = ep.max_packet_size;
                        }
                    }
                }
            }
        }

        // For storage devices, ensure ep_in defaults to bulk-in
        if (primary_dtype == .storage and dev_out.ep_bulk_in != 0) {
            dev_out.ep_in = dev_out.ep_bulk_in;
            dev_out.ep_max_packet = dev_out.ep_bulk_in_max_pkt;
        }
    } else {
        dev_out.interface_num = 0;
        dev_out.ep_in = 1;
        dev_out.ep_max_packet = 8;
        dev_out.ep_interval = 10;
    }

    dev_out.toggle = 0;
    dev_out.packet_count = 0;
    dev_out.caps_lock = false;
    @memset(&dev_out.report_buf, 0);
    @memset(&dev_out.prev_report, 0);

    // Write log markers
    serial.serialWrite("[USB] Registered ");
    serial.serialWrite(primary_dtype.name());
    serial.serialWrite(" at Addr ");
    serial.serialWriteDec(new_addr);
    serial.serialWrite(" (Vendor=0x");
    serial.serialWriteHex(vendor_id);
    serial.serialWrite(" Product=0x");
    serial.serialWriteHex(product_id);
    serial.serialWrite(" EP_IN=");
    serial.serialWriteDec(dev_out.ep_in);
    if (dev_out.ep_bulk_out != 0) {
        serial.serialWrite(" EP_OUT=");
        serial.serialWriteDec(dev_out.ep_bulk_out);
    }
    serial.serialWrite(")\n");

    return true;
}
