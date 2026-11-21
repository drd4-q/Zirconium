const root = @import("root");
const serial = root.serial;
const types = @import("types.zig");
const usbhid = @import("usbhid.zig");
const hid_generic = @import("hid_generic.zig");
const hid_input = @import("hid_input.zig");
const hid_report = @import("../hid/hid_report.zig");
const device = @import("device.zig");
const mod = @import("mod.zig");
const timer = @import("../timer.zig");

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
    /// The descriptor driven decoder produced nothing usable for this
    /// interface, so the device was put back into the boot protocol and is
    /// decoded the way commit 7247d67 decoded every HID interface:
    /// SET_PROTOCOL(BOOT), SET_IDLE, the boot LED report and
    /// `hid_generic.processReport`.  The parsed table is kept for
    /// diagnostics; it is no longer used to decode.
    boot_fallback: bool = false,
    /// Consecutive descriptor reports that named no input report of this
    /// interface (an unknown report ID or an empty payload).
    descriptor_failures: u8 = 0,
    /// Consecutive changed reports that carried keyboard usages but produced
    /// no key, which means the descriptor's layout is not the device's.
    silent_reports: u8 = 0,
    /// At least one key was decoded through the descriptor.  Once the layout
    /// has produced a character it is not a wrong layout, so the silent
    /// report counter never switches the interface after that.
    ever_decoded: bool = false,
    /// The previous report, so an unchanged (held key) report is not counted
    /// as a decoder failure.
    last_report: [64]u8 = @splat(0),
    last_report_len: u8 = 0,
    /// Tick at registration, for the "no report at all" fallback.
    registered_tick: u64 = 0,
    /// Whether the no-report timeout has already been logged.
    no_report_logged: bool = false,
};

/// A descriptor report that names no report of the interface is not a
/// one-off: a device that ignores SET_PROTOCOL(REPORT) keeps sending its
/// boot report, whose modifier byte is a report ID the descriptor does not
/// know.  Three of them are enough evidence.
const DESCRIPTOR_FAILURE_LIMIT: u8 = 3;

/// A changed keyboard report that the descriptor turns into no key at all.
/// Four changed reports (press, release is all zeroes and not counted) with
/// no character in between is a layout that does not fit.
const SILENT_REPORT_LIMIT: u8 = 4;

/// A boot keyboard that never delivers a report has not exercised the
/// descriptor path at all.  Give it 30 s of shell time before putting it back
/// into the boot protocol.  SET_PROTOCOL(BOOT) is only sent to a boot
/// subclass interface, where it is defined, so this cannot break a report
/// protocol only device.
const NO_REPORT_FALLBACK_TICKS: u64 = 3000;

/// Why the descriptor path was abandoned.  The reason goes into the log, so
/// a capture says which of the three it was.
pub const FallbackReason = enum {
    descriptor_failures,
    silent_reports,
    no_reports,

    fn text(self: FallbackReason) []const u8 {
        return switch (self) {
            .descriptor_failures => "the descriptor decoder rejected the report",
            .silent_reports => "the descriptor decoded no key",
            .no_reports => "no report arrived",
        };
    }
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

    if (hid_dev.has_table and !hid_dev.boot_fallback and
        setDescriptorLeds(hid_dev, num_lock, caps_lock, scroll_lock))
    {
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

/// True when the interface's input reports carry a report ID byte.  A device
/// that was put back into the boot protocol sends unnumbered reports even if
/// its descriptor numbered them, so the composite fan-out must not read its
/// first byte (the modifier mask) as a report ID.
pub fn hasNumberedInput(dev: *device.UsbDevice) bool {
    const inst = findForDevice(dev) orelse return false;
    if (inst.boot_fallback) return false;
    return inst.has_table and inst.table.numbered(.input);
}

/// True when report ID `report_id` is an input report of this interface.
pub fn acceptsReportId(dev: *device.UsbDevice, report_id: u8) bool {
    const inst = findForDevice(dev) orelse return false;
    if (inst.boot_fallback) return true;
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
    // The boot protocol report is fixed: eight bytes for a keyboard, three
    // for a mouse.  The endpoint's max packet is the right request for it.
    if (!inst.has_table or inst.boot_fallback) return null;
    const len = inst.table.maxReportLen(.input);
    return if (len == 0) null else len;
}

/// Log which decode path an interface is on.  The first method is the report
/// descriptor; the fallback is the boot protocol from 7247d67.  A capture
/// has to say which one actually decoded the keys.
fn logDecodePath(inst: *HidDevice) void {
    serial.serialWrite("[HID] decode path id=");
    serial.serialWriteDec(inst.id);
    serial.serialWrite(" iface=");
    serial.serialWriteDec(inst.interface_num);
    // `has_table` false means the interface never got a descriptor table
    // (read/parse failure, or a boot protocol that contradicts it), and the
    // boot decoder below is what runs.
    const boot = inst.boot_fallback or !inst.has_table;
    serial.serialWrite(if (boot) " method=boot-protocol" else " method=report-descriptor");
    serial.serialWrite(" type=");
    serial.serialWrite(inst.dev_type.name());
    serial.serialWrite("\n");
}

/// Put one interface back into the boot protocol, exactly as commit 7247d67
/// did for every HID interface: SET_PROTOCOL(BOOT), SET_IDLE(0,0), the boot
/// LED report, and `hid_generic.processReport` for every report.  The
/// descriptor table is kept for diagnostics but no longer decodes anything.
fn activateBootFallback(inst: *HidDevice, reason: FallbackReason) bool {
    if (inst.boot_fallback) return true;

    const max_p0: u8 = @min(inst.ep0_max_packet, 64);

    const set_proto_pkt = usbhid.makeSetProtocolPacket(inst.interface_num, usbhid.PROTOCOL_BOOT);
    const switched = mod.usbControlTransferById(inst.id, max_p0, &set_proto_pkt, null, null);

    // The old path sent SET_IDLE(0,0) (report on change) whether or not
    // SET_PROTOCOL was acknowledged, and so does this one.
    const set_idle_pkt = usbhid.makeSetIdlePacket(inst.interface_num, 0, 0);
    _ = mod.usbControlTransferById(inst.id, max_p0, &set_idle_pkt, null, null);

    inst.boot_fallback = true;
    inst.descriptor_failures = 0;
    inst.silent_reports = 0;
    inst.last_report_len = 0;
    // The boot decoder compares against its own previous report and starts
    // from all keys released.
    inst.prev_report = @splat(0);
    inst.state = .{};

    serial.serialWrite("[HID] boot protocol fallback active id=");
    serial.serialWriteDec(inst.id);
    serial.serialWrite(" iface=");
    serial.serialWriteDec(inst.interface_num);
    serial.serialWrite(" reason=");
    serial.serialWrite(reason.text());
    serial.serialWrite(" set_protocol=");
    serial.serialWrite(if (switched) "ok" else "failed");
    serial.serialWrite(" reports=");
    serial.serialWriteDec(inst.packet_count);
    serial.serialWrite("\n");
    logDecodePath(inst);

    // The boot report owns the LEDs now (setDeviceLeds skips the descriptor
    // output field once boot_fallback is set).
    if (inst.dev_type == .keyboard) {
        _ = setDeviceLeds(inst, inst.num_lock, inst.caps_lock, inst.scroll_lock);
    }
    return true;
}

/// True when `report` differs from the previous one and is not all zeroes.
/// A held key repeats the same report and a release is all zeroes; neither
/// is evidence that the decoder failed.
fn reportChanged(inst: *HidDevice, report: []const u8) bool {
    var nonzero = false;
    for (report) |b| {
        if (b != 0) {
            nonzero = true;
            break;
        }
    }

    const len = @min(report.len, inst.last_report.len);
    var same = inst.last_report_len == report.len;
    if (same) {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (inst.last_report[i] != report[i]) {
                same = false;
                break;
            }
        }
    }
    @memcpy(inst.last_report[0..len], report[0..len]);
    inst.last_report_len = @intCast(len);

    return nonzero and !same;
}

fn logRejectedReport(inst: *HidDevice, report: []const u8, count: u8) void {
    serial.serialWrite("[HID] descriptor report rejected id=");
    serial.serialWriteDec(inst.id);
    serial.serialWrite(" iface=");
    serial.serialWriteDec(inst.interface_num);
    serial.serialWrite(" count=");
    serial.serialWriteDec(count);
    serial.serialWrite(" data=");
    const n = @min(report.len, 9);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        serial.serialWriteHex(report[i]);
        serial.serialWrite(" ");
    }
    serial.serialWrite("\n");
}

fn logSilentReport(inst: *HidDevice, report: []const u8, count: u8) void {
    serial.serialWrite("[HID] descriptor decoded no key id=");
    serial.serialWriteDec(inst.id);
    serial.serialWrite(" iface=");
    serial.serialWriteDec(inst.interface_num);
    serial.serialWrite(" count=");
    serial.serialWriteDec(count);
    serial.serialWrite(" data=");
    const n = @min(report.len, 9);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        serial.serialWriteHex(report[i]);
        serial.serialWrite(" ");
    }
    serial.serialWrite("\n");
}

/// Decode one report for one interface: the report descriptor first, the
/// boot protocol when the descriptor has been abandoned.
fn decodeReport(inst: *HidDevice, report: []const u8) void {
    if (inst.has_table and !inst.boot_fallback) {
        const activity_before = hid_input.keyboard_activity;
        const events_before = hid_input.key_events;
        const accepted = hid_input.handleDescriptorReport(&inst.table, report, &inst.state, onLedStateChanged);

        if (!accepted) {
            inst.descriptor_failures +|= 1;
            if (inst.descriptor_failures <= DESCRIPTOR_FAILURE_LIMIT) {
                logRejectedReport(inst, report, inst.descriptor_failures);
            }
            if (inst.descriptor_failures >= DESCRIPTOR_FAILURE_LIMIT) {
                _ = activateBootFallback(inst, .descriptor_failures);
            }
            return;
        }
        inst.descriptor_failures = 0;

        // The report carried keyboard usages (`keyboard_activity`) but none
        // reached the keyboard ring (`key_events`): the layout decoded to
        // something that is not the key the device meant.  Movement reports
        // of a combo interface carry no keyboard usages and are ignored.
        // Once a character has been decoded the descriptor is right; an
        // unmappable key (F1) is not evidence against it.
        if (inst.dev_type == .keyboard and !inst.ever_decoded and
            hid_input.keyboard_activity != activity_before and
            reportChanged(inst, report))
        {
            if (hid_input.key_events != events_before) {
                inst.ever_decoded = true;
                inst.silent_reports = 0;
            } else {
                inst.silent_reports +|= 1;
                if (inst.silent_reports <= SILENT_REPORT_LIMIT) {
                    logSilentReport(inst, report, inst.silent_reports);
                }
                if (inst.silent_reports >= SILENT_REPORT_LIMIT) {
                    _ = activateBootFallback(inst, .silent_reports);
                }
            }
        }
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

/// Periodic check for a boot keyboard that never delivered a report at all.
/// Called from `mod.poll()` (never from the tick handler): the fallback sends
/// control requests, which are not a bounded operation.
pub fn poll() void {
    var i: usize = 0;
    while (i < hid_instance_count) : (i += 1) {
        const inst = &hid_instances[i];
        if (!inst.active or !inst.has_table or inst.boot_fallback) continue;
        if (inst.dev_type != .keyboard or !inst.subclass_boot) continue;
        if (inst.packet_count != 0 or inst.registered_tick == 0) continue;
        const now = timer.tickCount();
        if (now -% inst.registered_tick < NO_REPORT_FALLBACK_TICKS) continue;
        if (!inst.no_report_logged) {
            inst.no_report_logged = true;
            serial.serialWrite("[HID] no report from keyboard id=");
            serial.serialWriteDec(inst.id);
            serial.serialWrite(" iface=");
            serial.serialWriteDec(inst.interface_num);
            serial.serialWrite(" after ");
            serial.serialWriteDec(now -% inst.registered_tick);
            serial.serialWrite(" ticks\n");
        }
        _ = activateBootFallback(inst, .no_reports);
    }
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

    // A boot interface's protocol code is part of the interface contract:
    // 1 is a keyboard, 2 is a mouse, and the device sends the fixed boot
    // report when asked.  When the descriptor that was read describes the
    // other kind of device, it is not the descriptor the reports follow (a
    // combo receiver whose second descriptor read returned the first
    // interface's table, or trailing zeroes from a short control transfer).
    // Trust the interface: decode the boot report instead.  `has_table`
    // stays false, so `registerHidDevice()` sends SET_PROTOCOL(BOOT).
    if (iface) |desc| {
        const expected: ?hid_report.Kind = switch (desc.protocol_code) {
            1 => .keyboard,
            2 => .mouse,
            else => null,
        };
        if (expected) |protocol_kind| {
            if (table.kind()) |kind| {
                if (kind != protocol_kind) {
                    serial.serialWrite("[HID] descriptor kind=");
                    serial.serialWrite(switch (kind) {
                        .keyboard => "keyboard",
                        .mouse => "mouse",
                    });
                    serial.serialWrite(" contradicts interface protocol=");
                    serial.serialWrite(switch (protocol_kind) {
                        .keyboard => "keyboard",
                        .mouse => "mouse",
                    });
                    serial.serialWrite(", using boot protocol id=");
                    serial.serialWriteDec(inst.id);
                    serial.serialWrite(" iface=");
                    serial.serialWriteDec(inst.interface_num);
                    serial.serialWrite(" fields=");
                    serial.serialWriteDec(table.field_count);
                    serial.serialWrite(" reports=");
                    serial.serialWriteDec(table.report_count);
                    serial.serialWrite("\n");
                    return;
                }
            }
        }
    }

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
    serial.serialWrite(" proto=");
    serial.serialWriteDec(if (iface) |desc| desc.protocol_code else 0);
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
        .registered_tick = timer.tickCount() +| 1,
    };

    const iface = findInterface(dev, iface_num);
    inst.subclass_boot = if (iface) |desc| desc.subclass_code == 0x01 else false;
    // A non-zero protocol code is the interface saying it speaks the boot
    // protocol: 1 for a keyboard, 2 for a mouse.  A combo receiver may
    // declare it without subclass 1, and it still has to be told which
    // protocol to use.
    const declares_boot = if (iface) |desc|
        desc.protocol_code == 1 or desc.protocol_code == 2
    else
        false;

    // 1. The descriptor is the layout.  When it parses, the device is put
    //    into report protocol; otherwise a boot keyboard stays in boot
    //    protocol, which is what the decoder below falls back to.
    loadReportDescriptor(inst, dev);

    const max_p0: u8 = @min(dev.ep0_max_packet, 64);
    if (inst.subclass_boot or (declares_boot and !inst.has_table)) {
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
    logDecodePath(inst);
    return inst;
}

/// Interrupt completion handler (corresponds to Linux hid_irq_in).
/// Extracts report data, dispatches to generic driver, and handles LED updates.
pub fn usbhidIrqIn(inst: *HidDevice, actual_len: usize) void {
    if (!inst.active or actual_len == 0 or actual_len > inst.report_buf.len) return;

    inst.packet_count +%= 1;
    decodeReport(inst, inst.report_buf[0..actual_len]);
}

/// Process an incoming HID packet from an underlying UsbDevice buffer.
pub fn processRawDeviceReport(dev: *device.UsbDevice, actual_len: usize) void {
    if (actual_len == 0 or actual_len > dev.report_buf.len) return;
    const report = dev.report_buf[0..actual_len];

    if (findForDevice(dev)) |inst| {
        inst.packet_count +%= 1;
        decodeReport(inst, report);
        return;
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
