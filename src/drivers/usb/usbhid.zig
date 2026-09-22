const std = @import("std");
const types = @import("types.zig");

// USB HID Transport Layer (corresponds to Linux drivers/hid/usbhid/usbhid.h)

// HID Class Definition Constants (USB HID Spec 1.11)
pub const HID_CLASS: u8 = 0x03;
pub const HID_SUBCLASS_NONE: u8 = 0x00;
pub const HID_SUBCLASS_BOOT: u8 = 0x01;

pub const HID_PROTOCOL_NONE: u8 = 0x00;
pub const HID_PROTOCOL_KEYBOARD: u8 = 0x01;
pub const HID_PROTOCOL_MOUSE: u8 = 0x02;

// HID Class Specific Requests
pub const HID_REQ_GET_REPORT: u8 = 0x01;
pub const HID_REQ_GET_IDLE: u8 = 0x02;
pub const HID_REQ_GET_PROTOCOL: u8 = 0x03;
pub const HID_REQ_SET_REPORT: u8 = 0x09;
pub const HID_REQ_SET_IDLE: u8 = 0x0A;
pub const HID_REQ_SET_PROTOCOL: u8 = 0x0B;

// HID Protocol Codes for SET_PROTOCOL
pub const PROTOCOL_BOOT: u16 = 0x0000;
pub const PROTOCOL_REPORT: u16 = 0x0001;

// HID Report Types
pub const REPORT_TYPE_INPUT: u8 = 1;
pub const REPORT_TYPE_OUTPUT: u8 = 2;
pub const REPORT_TYPE_FEATURE: u8 = 3;

// URB Status
pub const UrbStatus = enum {
    idle,
    pending,
    completed,
    err,
};

/// USB Request Block (URB) — transport level structure for cyclic polling and async I/O
pub const Urb = struct {
    dev_addr: u8 = 0,
    endpoint: u8 = 0,
    is_in: bool = true,
    transfer_type: types.UsbTransferType = .interrupt,
    status: UrbStatus = .idle,
    buffer: []u8 = &[_]u8{},
    actual_length: usize = 0,
    complete_fn: ?*const fn (urb: *Urb) void = null,
    context: ?*anyopaque = null,

    pub fn init(
        dev_addr: u8,
        endpoint: u8,
        is_in: bool,
        transfer_type: types.UsbTransferType,
        buf: []u8,
        complete_fn: ?*const fn (urb: *Urb) void,
        context: ?*anyopaque,
    ) Urb {
        return Urb{
            .dev_addr = dev_addr,
            .endpoint = endpoint,
            .is_in = is_in,
            .transfer_type = transfer_type,
            .status = .idle,
            .buffer = buf,
            .actual_length = 0,
            .complete_fn = complete_fn,
            .context = context,
        };
    }
};

// Build standard HID control request packets
pub fn makeSetProtocolPacket(iface_num: u8, protocol: u16) types.UsbSetupPacket {
    return types.UsbSetupPacket{
        .bmRequestType = 0x21, // Host-to-Device, Class, Interface
        .bRequest = HID_REQ_SET_PROTOCOL,
        .wValue = protocol, // 0 = Boot, 1 = Report
        .wIndex = iface_num,
        .wLength = 0,
    };
}

pub fn makeSetIdlePacket(iface_num: u8, duration: u8, report_id: u8) types.UsbSetupPacket {
    return types.UsbSetupPacket{
        .bmRequestType = 0x21,
        .bRequest = HID_REQ_SET_IDLE,
        .wValue = (@as(u16, duration) << 8) | @as(u16, report_id),
        .wIndex = iface_num,
        .wLength = 0,
    };
}

pub fn makeGetReportPacket(iface_num: u8, report_type: u8, report_id: u8, length: u16) types.UsbSetupPacket {
    return types.UsbSetupPacket{
        .bmRequestType = 0xA1, // Device-to-Host, Class, Interface
        .bRequest = HID_REQ_GET_REPORT,
        .wValue = (@as(u16, report_type) << 8) | @as(u16, report_id),
        .wIndex = iface_num,
        .wLength = length,
    };
}

pub fn makeSetReportPacket(iface_num: u8, report_type: u8, report_id: u8, length: u16) types.UsbSetupPacket {
    return types.UsbSetupPacket{
        .bmRequestType = 0x21, // Host-to-Device, Class, Interface
        .bRequest = HID_REQ_SET_REPORT,
        .wValue = (@as(u16, report_type) << 8) | @as(u16, report_id),
        .wIndex = iface_num,
        .wLength = length,
    };
}
