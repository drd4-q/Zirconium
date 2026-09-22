const std = @import("std");
const root = @import("root");
const serial = root.serial;
const types = @import("types.zig");
const usbhid = @import("usbhid.zig");
const hid_generic = @import("hid_generic.zig");
const hid_input = @import("hid_input.zig");
const device = @import("device.zig");
const mod = @import("mod.zig");

// USB HID Core Subsystem (corresponds to Linux drivers/hid/usbhid/hid-core.c)
// Manages HID device lifecycle, cyclic URB polling, LED power states, and report dispatch.

pub const MAX_HID_INSTANCES: usize = 16;

pub const HidDevice = struct {
    active: bool = false,
    dev_idx: usize = 0,
    ctrl_idx: u8 = 0,
    addr: u8 = 0,
    interface_num: u8 = 0,
    dev_type: types.UsbDeviceType = .unknown,
    is_wireless: bool = false,
    num_lock: bool = true,
    caps_lock: bool = false,
    scroll_lock: bool = false,
    in_urb: usbhid.Urb = .{},
    report_buf: [64]u8 align(16) = [_]u8{0} ** 64,
    prev_report: [64]u8 = [_]u8{0} ** 64,
    packet_count: u32 = 0,
};

pub var hid_instances: [MAX_HID_INSTANCES]HidDevice = [_]HidDevice{.{}} ** MAX_HID_INSTANCES;
pub var hid_instance_count: usize = 0;

pub fn init() void {
    hid_instance_count = 0;
    for (&hid_instances) |*inst| {
        inst.* = .{};
    }
}

/// Callback triggered by hid_input when NumLock, CapsLock, or ScrollLock toggles.
fn onLedStateChanged(num: bool, caps: bool, scroll: bool) void {
    setLedsGlobal(num, caps, scroll);
}

/// Set keyboard LEDs on a specific HID device via SET_REPORT (Output Report).
pub fn setDeviceLeds(hid_dev: *HidDevice, num_lock: bool, caps_lock: bool, scroll_lock: bool) bool {
    if (!hid_dev.active or hid_dev.dev_type != .keyboard) return false;

    var led_val: u8 = 0;
    if (num_lock) led_val |= 0x01;
    if (caps_lock) led_val |= 0x02;
    if (scroll_lock) led_val |= 0x04;
    const led_data = [_]u8{led_val};

    const pkt = usbhid.makeSetReportPacket(hid_dev.interface_num, usbhid.REPORT_TYPE_OUTPUT, 0, 1);
    var ok = mod.usbControlTransfer(hid_dev.addr, 8, &pkt, &led_data, null);
    if (!ok and hid_dev.is_wireless) {
        const pkt_id1 = usbhid.makeSetReportPacket(hid_dev.interface_num, usbhid.REPORT_TYPE_OUTPUT, 1, 1);
        ok = mod.usbControlTransfer(hid_dev.addr, 8, &pkt_id1, &led_data, null);
    }
    if (ok) {
        hid_dev.num_lock = num_lock;
        hid_dev.caps_lock = caps_lock;
        hid_dev.scroll_lock = scroll_lock;
    }
    return ok;
}

/// Broadcast LED updates to all registered HID keyboards.
pub fn setLedsGlobal(num_lock: bool, caps_lock: bool, scroll_lock: bool) void {
    var i: usize = 0;
    while (i < hid_instance_count) : (i += 1) {
        const inst = &hid_instances[i];
        if (inst.active and inst.dev_type == .keyboard) {
            _ = setDeviceLeds(inst, num_lock, caps_lock, scroll_lock);
        }
    }
}

/// Register a new HID interface with the core driver (Linux hid_add_device).
pub fn registerHidDevice(dev_idx: usize, dev: *device.UsbDevice, iface_num: u8, dev_type: types.UsbDeviceType) ?*HidDevice {
    if (hid_instance_count >= MAX_HID_INSTANCES) return null;

    var inst = &hid_instances[hid_instance_count];
    inst.* = .{
        .active = true,
        .dev_idx = dev_idx,
        .ctrl_idx = dev.ctrl_idx,
        .addr = dev.addr,
        .interface_num = iface_num,
        .dev_type = dev_type,
        .is_wireless = dev.is_wireless,
        .num_lock = hid_input.num_lock_state,
        .caps_lock = hid_input.caps_lock_state,
        .scroll_lock = hid_input.scroll_lock_state,
        .packet_count = 0,
    };

    // 1. SET_PROTOCOL: Boot Protocol (0)
    const max_p0: u8 = @intCast(@min(dev.ep_max_packet, 64));
    const set_proto_pkt = usbhid.makeSetProtocolPacket(iface_num, usbhid.PROTOCOL_BOOT);
    _ = mod.usbControlTransfer(dev.addr, max_p0, &set_proto_pkt, null, null);

    // 2. SET_IDLE: Report on change (0)
    const set_idle_pkt = usbhid.makeSetIdlePacket(iface_num, 0, 0);
    _ = mod.usbControlTransfer(dev.addr, max_p0, &set_idle_pkt, null, null);

    // 3. Set default LEDs on keyboard (turn on NumPad LED by default)
    if (dev_type == .keyboard) {
        _ = setDeviceLeds(inst, inst.num_lock, inst.caps_lock, inst.scroll_lock);
    }

    // 4. Initialize Interrupt IN URB
    const max_p = @min(@max(dev.ep_max_packet, 8), 64);
    inst.in_urb = usbhid.Urb.init(
        dev.addr,
        dev.ep_in,
        true,
        .interrupt,
        inst.report_buf[0..max_p],
        null,
        @ptrCast(inst),
    );

    hid_instance_count += 1;
    return inst;
}

/// Interrupt completion handler (corresponds to Linux hid_irq_in).
/// Extracts report data, dispatches to generic driver, and handles LED updates.
pub fn usbhidIrqIn(inst: *HidDevice, actual_len: usize) void {
    if (!inst.active or actual_len == 0) return;

    inst.packet_count +%= 1;
    const report = inst.report_buf[0..actual_len];

    hid_generic.processReport(
        inst.dev_type,
        inst.is_wireless,
        report,
        inst.prev_report[0..],
        &inst.caps_lock,
        onLedStateChanged,
    );
}

/// Process an incoming HID packet from an underlying UsbDevice buffer.
pub fn processRawDeviceReport(dev: *device.UsbDevice, actual_len: usize) void {
    if (actual_len == 0) return;
    dev.packet_count +%= 1;

    // Route report through generic HID driver with dynamic LED state callback
    hid_generic.processReport(
        dev.dev_type,
        dev.is_wireless,
        dev.report_buf[0..actual_len],
        dev.prev_report[0..],
        &dev.caps_lock,
        onLedStateChanged,
    );
}
