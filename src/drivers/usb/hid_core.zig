const root = @import("root");
const serial = root.serial;
const types = @import("types.zig");
const usbhid = @import("usbhid.zig");
const hid_generic = @import("hid_generic.zig");
const hid_input = @import("hid_input.zig");
const hid_report = @import("../hid/hid_report.zig");
const device = @import("device.zig");
const mod = @import("mod.zig");

// USB HID Core Subsystem (corresponds to Linux drivers/hid/usbhid/hid-core.c)
// Manages HID device lifecycle, cyclic URB polling, LED power states, and
// report dispatch.  The report layout comes from the device's report
// descriptor (`hid_report.zig`), not from the boot protocol guess: a modern
// keyboard or a receiver behind an interface does not have to look like an
// eight byte boot report, and the descriptor says exactly what it looks
// like.

pub const MAX_HID_INSTANCES: usize = 16;

/// How much of a report descriptor to request when the HID class descriptor
/// did not carry its length.  Every boot keyboard and mouse descriptor fits;
/// a longer one fails to parse and falls back to the boot protocol.
const FALLBACK_DESCRIPTOR_LEN: usize = 128;

pub const HidDevice = struct {
    active: bool = false,
    id: u32 = 0,
    dev_idx: usize = 0,
    ctrl_idx: u8 = 0,
    addr: u8 = 0,
    interface_num: u8 = 0,
    dev_type: types.UsbDeviceType = .unknown,
    is_wireless: bool = false,
    ep0_max_packet: u8 = 8,
    /// The interface declared the boot subclass, so SET_PROTOCOL is legal.
    subclass_boot: bool = false,
    num_lock: bool = true,
    caps_lock: bool = false,
    scroll_lock: bool = false,
    in_urb: usbhid.Urb = .{},
    report_buf: [64]u8 align(16) = @splat(0),
    prev_report: [64]u8 = @splat(0),
    packet_count: u32 = 0,
    /// Parsed report descriptor (`struct hid_device.report_enum`).
    table: hid_report.Table = .{},
    has_table: bool = false,
    /// Keys/buttons that the previous descriptor driven report had down.
    state: hid_input.State = .{},
};

pub var hid_instances: [MAX_HID_INSTANCES]HidDevice = @splat(.{});
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

/// Send the LED state through the output field the report descriptor
/// declares (`hid-input.c:hidinput_led_worker`, which writes
/// `hid->leds[i]` into its `hid_field` and then calls
/// `hid_hw_output_report`).  Returns false when the descriptor has no LED
/// output field.
fn setDescriptorLeds(hid_dev: *HidDevice, num_lock: bool, caps_lock: bool, scroll_lock: bool) bool {
    const table = &hid_dev.table;

    var led_field: ?*const hid_report.Field = null;
    var field_idx: usize = 0;
    while (field_idx < @as(usize, table.field_count) and led_field == null) : (field_idx += 1) {
        const field = &table.fields[field_idx];
        if (field.report_type != .output or field.isConstant()) continue;
        var usage_idx: u16 = 0;
        while (usage_idx < field.report_count) : (usage_idx += 1) {
            const usage = field.usageAt(usage_idx);
            if (usage.page == hid_report.USAGE_PAGE_LED and usage.id >= 1 and usage.id <= 3) {
                led_field = field;
                break;
            }
        }
    }

    const field = led_field orelse return false;
    const report = table.findReport(.output, field.report_id) orelse return false;
    const len = report.len();
    if (len == 0) return false;

    var payload: [8]u8 = @splat(0);
    if (len > payload.len) return false;

    var usage_idx: u16 = 0;
    while (usage_idx < field.report_count) : (usage_idx += 1) {
        const usage = field.usageAt(usage_idx);
        if (usage.page != hid_report.USAGE_PAGE_LED) continue;
        const on = switch (usage.id) {
            1 => num_lock,
            2 => caps_lock,
            3 => scroll_lock,
            else => false,
        };
        field.setValue(payload[0..len], usage_idx, @intFromBool(on));
    }

    const pkt = usbhid.makeSetReportPacket(
        hid_dev.interface_num,
        usbhid.REPORT_TYPE_OUTPUT,
        field.report_id,
        @intCast(len),
    );
    const max_p0: u8 = @min(hid_dev.ep0_max_packet, 64);
    return mod.usbControlTransferById(hid_dev.id, max_p0, &pkt, payload[0..len], null);
}

/// Set keyboard LEDs on a specific HID device via SET_REPORT (Output Report).
pub fn setDeviceLeds(hid_dev: *HidDevice, num_lock: bool, caps_lock: bool, scroll_lock: bool) bool {
    if (!hid_dev.active) return false;
    const max_p0: u8 = @min(hid_dev.ep0_max_packet, 64);

    if (hid_dev.has_table and setDescriptorLeds(hid_dev, num_lock, caps_lock, scroll_lock)) {
        hid_dev.num_lock = num_lock;
        hid_dev.caps_lock = caps_lock;
        hid_dev.scroll_lock = scroll_lock;
        return true;
    }

    // The boot protocol report: one byte, report ID 0.  Only a keyboard has
    // one, and only a boot device is guaranteed to understand it.
    if (hid_dev.dev_type != .keyboard) return false;

    var led_val: u8 = 0;
    if (num_lock) led_val |= 0x01;
    if (caps_lock) led_val |= 0x02;
    if (scroll_lock) led_val |= 0x04;
    const led_data = [_]u8{led_val};

    const pkt = usbhid.makeSetReportPacket(hid_dev.interface_num, usbhid.REPORT_TYPE_OUTPUT, 0, 1);
    var ok = mod.usbControlTransferById(hid_dev.id, max_p0, &pkt, &led_data, null);
    if (!ok and hid_dev.is_wireless) {
        const pkt_id1 = usbhid.makeSetReportPacket(hid_dev.interface_num, usbhid.REPORT_TYPE_OUTPUT, 1, 1);
        ok = mod.usbControlTransferById(hid_dev.id, max_p0, &pkt_id1, &led_data, null);
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

fn findInterface(dev: *device.UsbDevice, iface_num: u8) ?*types.UsbInterface {
    var i: usize = 0;
    while (i < dev.interface_count) : (i += 1) {
        const iface = &dev.interfaces[i];
        if (iface.interface_num == iface_num) return iface;
    }
    return null;
}

/// The HID instance that decodes the reports of one logical interface.
/// Composite interfaces share the device ID, so the interface number is
/// part of the identity.
pub fn findForDevice(dev: *device.UsbDevice) ?*HidDevice {
    var i: usize = 0;
    while (i < hid_instance_count) : (i += 1) {
        const inst = &hid_instances[i];
        if (inst.active and inst.id == dev.id and inst.ctrl_idx == dev.ctrl_idx and
            inst.interface_num == dev.interface_num)
        {
            return inst;
        }
    }
    return null;
}

pub fn hasDescriptor(dev: *device.UsbDevice) bool {
    const inst = findForDevice(dev) orelse return false;
    return inst.has_table;
}

/// True when the interface's input reports carry a report ID byte.
pub fn hasNumberedInput(dev: *device.UsbDevice) bool {
    const inst = findForDevice(dev) orelse return false;
    return inst.has_table and inst.table.numbered(.input);
}

/// True when report ID `report_id` is an input report of this interface.
pub fn acceptsReportId(dev: *device.UsbDevice, report_id: u8) bool {
    const inst = findForDevice(dev) orelse return false;
    if (!inst.has_table) return report_id == 1 or report_id == 2;
    if (!inst.table.numbered(.input)) return true;
    return inst.table.hasInputReport(report_id);
}

/// Length of one input report for this interface, including the report ID
/// byte when the descriptor numbers its reports.  `usbhid_start()` submits
/// its interrupt URB with `hid->rsize`, and so must an xHCI transfer: a
/// transfer sized to the endpoint's max packet truncates a report that is
/// one byte longer (a numbered 8-byte keyboard report is 9 bytes on the
/// wire), and the tail of the report is then read as the start of the next.
pub fn inputReportLen(dev: *device.UsbDevice) ?usize {
    const inst = findForDevice(dev) orelse return null;
    if (!inst.has_table) return null;
    const len = inst.table.maxReportLen(.input);
    return if (len == 0) null else len;
}

/// Read and parse the report descriptor, then select the protocol the
/// descriptor needs.  This is `usbhid_parse()` followed by the SET_PROTOCOL
/// half of `usbhid_start()`: report protocol when the descriptor is
/// understood, boot protocol when it is not (a boot interface only).
fn loadReportDescriptor(inst: *HidDevice, dev: *device.UsbDevice) void {
    const iface = findInterface(dev, inst.interface_num);
    var wanted: usize = FALLBACK_DESCRIPTOR_LEN;
    if (iface) |desc| {
        if (desc.hid_report_len > 0) {
            wanted = @min(@as(usize, desc.hid_report_len), hid_report.MAX_DESCRIPTOR_SIZE);
        }
    }
    if (wanted == 0) wanted = FALLBACK_DESCRIPTOR_LEN;

    var descriptor: [hid_report.MAX_DESCRIPTOR_SIZE]u8 = @splat(0);
    const pkt = usbhid.makeGetDescriptorPacket(
        inst.interface_num,
        0x22, // HID_DT_REPORT
        0,
        @intCast(wanted),
    );
    const max_p0: u8 = @min(inst.ep0_max_packet, 64);
    if (!mod.usbControlTransferById(inst.id, max_p0, &pkt, null, descriptor[0..wanted])) {
        serial.serialWrite("[HID] report descriptor read failed id=");
        serial.serialWriteDec(inst.id);
        serial.serialWrite(" iface=");
        serial.serialWriteDec(inst.interface_num);
        serial.serialWrite("\n");
        return;
    }

    const table = hid_report.parse(descriptor[0..wanted]) catch |err| {
        serial.serialWrite("[HID] report descriptor parse failed id=");
        serial.serialWriteDec(inst.id);
        serial.serialWrite(" iface=");
        serial.serialWriteDec(inst.interface_num);
        serial.serialWrite(" error=");
        serial.serialWrite(@errorName(err));
        serial.serialWrite("\n");
        return;
    };
    if (!table.valid) return;

    inst.table = table;
    inst.has_table = true;

    // The top-level application collection identifies a HID interface
    // whose USB protocol code is zero (many keyboards and all tablets).
    if (table.kind()) |kind| {
        const corrected: types.UsbDeviceType = switch (kind) {
            .keyboard => .keyboard,
            .mouse => .mouse,
        };
        if (inst.dev_type != corrected) {
            serial.serialWrite("[HID] interface type corrected id=");
            serial.serialWriteDec(inst.id);
            serial.serialWrite(" ");
            serial.serialWrite(inst.dev_type.name());
            serial.serialWrite(" -> ");
            serial.serialWrite(corrected.name());
            serial.serialWrite("\n");
        }
        inst.dev_type = corrected;
        dev.dev_type = corrected;
    }

    serial.serialWrite("[HID] report descriptor id=");
    serial.serialWriteDec(inst.id);
    serial.serialWrite(" iface=");
    serial.serialWriteDec(inst.interface_num);
    serial.serialWrite(" type=");
    serial.serialWrite(inst.dev_type.name());
    serial.serialWrite(" fields=");
    serial.serialWriteDec(table.field_count);
    serial.serialWrite(" reports=");
    serial.serialWriteDec(table.report_count);
    serial.serialWrite(" in_len=");
    serial.serialWriteDec(table.maxReportLen(.input));
    serial.serialWrite(" out_len=");
    serial.serialWriteDec(table.maxReportLen(.output));
    serial.serialWrite(" mps=");
    serial.serialWriteDec(dev.ep_max_packet);
    serial.serialWrite("\n");
}

/// Register a new HID interface with the core driver (Linux hid_add_device).
pub fn registerHidDevice(dev_idx: usize, dev: *device.UsbDevice, iface_num: u8, dev_type: types.UsbDeviceType) ?*HidDevice {
    // Composite interfaces share the device ID: a second call for the same
    // interface must hand back the existing instance, not decode the same
    // reports twice (`hid_add_device` is called once per interface).
    var existing_idx: usize = 0;
    while (existing_idx < hid_instance_count) : (existing_idx += 1) {
        const existing = &hid_instances[existing_idx];
        if (existing.active and existing.id == dev.id and
            existing.ctrl_idx == dev.ctrl_idx and existing.interface_num == iface_num)
        {
            return existing;
        }
    }

    if (hid_instance_count >= MAX_HID_INSTANCES) return null;

    var inst = &hid_instances[hid_instance_count];
    inst.* = .{
        .active = true,
        .id = dev.id,
        .dev_idx = dev_idx,
        .ctrl_idx = dev.ctrl_idx,
        .addr = dev.addr,
        .interface_num = iface_num,
        .dev_type = dev_type,
        .is_wireless = dev.is_wireless,
        .ep0_max_packet = dev.ep0_max_packet,
        .num_lock = hid_input.num_lock_state,
        .caps_lock = hid_input.caps_lock_state,
        .scroll_lock = hid_input.scroll_lock_state,
        .packet_count = 0,
    };

    const iface = findInterface(dev, iface_num);
    inst.subclass_boot = if (iface) |desc| desc.subclass_code == 0x01 else false;

    // 1. The descriptor is the layout.  When it parses, the device is put
    //    into report protocol; otherwise a boot keyboard stays in boot
    //    protocol, which is what the decoder below falls back to.
    loadReportDescriptor(inst, dev);

    const max_p0: u8 = @min(dev.ep0_max_packet, 64);
    if (inst.subclass_boot) {
        const protocol: u16 = if (inst.has_table) usbhid.PROTOCOL_REPORT else usbhid.PROTOCOL_BOOT;
        const set_proto_pkt = usbhid.makeSetProtocolPacket(iface_num, protocol);
        const switched = mod.usbControlTransferById(dev.id, max_p0, &set_proto_pkt, null, null);
        if (!switched and inst.has_table) {
            // The interface refused the report protocol, so it will keep
            // sending the fixed boot report whatever its report descriptor
            // says.  Decode that layout instead: a boot-only keyboard is
            // exactly the device HID_QUIRK_NO_SET_PROTOCOL exists for.
            inst.has_table = false;
            const boot_pkt = usbhid.makeSetProtocolPacket(iface_num, usbhid.PROTOCOL_BOOT);
            _ = mod.usbControlTransferById(dev.id, max_p0, &boot_pkt, null, null);
            serial.serialWrite("[HID] report protocol refused, boot protocol id=");
            serial.serialWriteDec(inst.id);
            serial.serialWrite(" iface=");
            serial.serialWriteDec(inst.interface_num);
            serial.serialWrite("\n");
        }
    }

    // 2. SET_IDLE: Report on change (0).
    const set_idle_pkt = usbhid.makeSetIdlePacket(iface_num, 0, 0);
    _ = mod.usbControlTransferById(dev.id, max_p0, &set_idle_pkt, null, null);

    // 3. Set default LEDs on keyboard (turn on NumPad LED by default).
    if (inst.dev_type == .keyboard) {
        _ = setDeviceLeds(inst, inst.num_lock, inst.caps_lock, inst.scroll_lock);
    }

    // 4. Initialize Interrupt IN URB.
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
    if (!inst.active or actual_len == 0 or actual_len > inst.report_buf.len) return;

    inst.packet_count +%= 1;
    const report = inst.report_buf[0..actual_len];

    if (inst.has_table) {
        _ = hid_input.handleDescriptorReport(&inst.table, report, &inst.state, onLedStateChanged);
        return;
    }

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
    if (actual_len == 0 or actual_len > dev.report_buf.len) return;
    const report = dev.report_buf[0..actual_len];

    if (findForDevice(dev)) |inst| {
        inst.packet_count +%= 1;
        if (inst.has_table) {
            // The descriptor decides what the report means.  An unknown
            // report ID is not an error: on a composite device the report
            // belongs to the interface whose descriptor names it, and the
            // fan-out in mod.zig delivers it there.
            _ = hid_input.handleDescriptorReport(&inst.table, report, &inst.state, onLedStateChanged);
            return;
        }
    }

    // No descriptor (or registration happened before the interface was
    // known): the boot protocol layout is the only thing left.
    hid_generic.processReport(
        dev.dev_type,
        dev.is_wireless,
        report,
        dev.prev_report[0..],
        &dev.caps_lock,
        onLedStateChanged,
    );
}
