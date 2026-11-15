//! The HID++ driver: Logitech's 2.4 GHz receivers.
//!
//! Ported from the Linux kernel's `drivers/hid/hid-logitech-hidpp.c`.
//!
//! A Logitech receiver is a USB device, but the keyboard or the mouse
//! behind it is not: the receiver forwards the HID++ reports, and the
//! driver asks the receiver about the device it is interested in - its
//! name, its battery and its LED state.
//!
//! The driver keeps the state of the devices the receiver has paired, so
//! that a program can ask what is connected without knowing anything about
//! the receiver.

const serial = @import("../../system/serial.zig");
const proto = @import("hidpp_proto.zig");
const usb = @import("../usb/mod.zig");
const device = @import("../usb/device.zig");

pub const Report = proto.Report;
pub const Feature = proto.Feature;

/// The Logitech vendor ID.
pub const VENDOR_ID: u16 = 0x046D;

/// The maximum number of devices a receiver can have paired.
pub const MAX_DEVICES: usize = 6;

/// The state of one device behind a receiver.
pub const Device = struct {
    /// The index of the device inside the receiver.
    index: u8 = 0,
    /// The name of the device.
    name: [64]u8 = @splat(0),
    name_len: usize = 0,
    /// The battery level in percent, 0xff when it is not known.
    battery: u8 = 0xFF,
    /// The feature table of the device.
    features: proto.FeatureTable = .{},
    /// True when the device has answered at least once.
    present: bool = false,
};

pub const MAX_RECEIVERS: usize = 2;

/// One receiver and the devices behind it.
pub const Receiver = struct {
    /// The USB device the receiver is on.
    dev: *device.UsbDevice = undefined,
    /// The devices the receiver has paired.
    devices: [MAX_DEVICES]Device = @splat(.{}),
    /// The number of devices that answered.
    device_count: usize = 0,
    /// The reports that came in and the answers that went out.
    reports_in: u32 = 0,
    reports_out: u32 = 0,
};

pub var receivers: [MAX_RECEIVERS]Receiver = undefined;
pub var receiver_count: usize = 0;

/// True when a receiver has been found.
pub var initialized: bool = false;

/// Look for a Logitech receiver and bind to it.
///
/// This is Linux's `hidpp_probe()`: the receiver is a HID device whose
/// reports use the HID++ protocol instead of the ordinary boot protocol.
pub fn probe() bool {
    var i: usize = 0;
    while (i < usb.usb_device_count) : (i += 1) {
        const dev = &usb.usb_devices[i];
        if (!dev.active) continue;
        if (dev.vendor_id != VENDOR_ID) continue;
        if (receiver_count >= MAX_RECEIVERS) break;

        var receiver = Receiver{};
        receiver.dev = dev;

        serial.serialWrite("[HIDPP] Logitech receiver at ID ");
        serial.serialWriteDec(dev.id);
        serial.serialWrite(" vendor=0x");
        serial.serialWriteHex(dev.vendor_id);
        serial.serialWrite(" product=0x");
        serial.serialWriteHex(dev.product_id);
        serial.serialWrite("\n");

        receivers[receiver_count] = receiver;
        receiver_count += 1;
        initialized = true;
        return true;
    }
    return false;
}

/// Look for a receiver that turned up after the enumeration.
///
/// The xHCI controller finds its devices while it is polled, so a receiver
/// that is on an xHCI port is only visible after the first poll.
pub fn poll() void {
    if (initialized) return;
    _ = probe();
}

/// Handle one report that came from a receiver.
///
/// Linux's `hidpp_raw_event()` does the same: it tells whether the report
/// is an answer to something the host asked, and it hands the answer to
/// the feature that asked for it.
pub fn handleReport(dev: *device.UsbDevice, data: []const u8) bool {
    const receiver = receiverFor(dev) orelse return false;

    const report = Report.parse(data) orelse return false;
    receiver.reports_in += 1;

    // The answer to "what is the index of this feature" carries the index
    // in its first parameter byte.
    if (report.feature_index == 0x00 and
        report.function == proto.RootFunction.get_feature_index and
        report.param_len >= 3)
    {
        const feature_id = @as(u16, report.params[1]) | (@as(u16, report.params[2]) << 8);
        const target = deviceFor(receiver, report.device_index) orelse return true;
        target.features.set(feature_id, report.feature_index);
        return true;
    }

    // The name of a device comes in parts.
    if (report.feature_index != 0x00) {
        const target = deviceFor(receiver, report.device_index) orelse return true;
        var used = target.name_len;
        proto.appendName(&target.name, &used, report);
        target.name_len = used;
        target.present = true;
        return true;
    }

    return true;
}

/// Send a report to a receiver.
///
/// Linux sends the reports as HID *output* reports, with the report ID
/// and the payload.
pub fn sendReport(dev: *device.UsbDevice, data: []const u8) bool {
    const receiver = receiverFor(dev) orelse return false;
    if (data.len == 0) return false;

    // The output report has the report ID in the first byte; the rest is
    // the report itself.
    const setup = usb.types.UsbSetupPacket{
        .bmRequestType = 0x21, // class, interface, host to device
        .bRequest = 0x09, // SET_REPORT
        .wValue = 0x03, // the output report
        .wIndex = dev.interface_num,
        .wLength = @truncate(data.len),
    };
    const maxp0: u8 = @min(dev.ep0_max_packet, 64);
    if (!usb.usbControlTransferById(dev.id, maxp0, &setup, data, null)) return false;
    receiver.reports_out += 1;
    return true;
}

/// Ask a receiver for the index of a feature of one of its devices.
pub fn queryFeature(receiver_index: usize, device_index: u8, feature_id: u16) bool {
    if (receiver_index >= receiver_count) return false;
    const receiver = &receivers[receiver_index];

    var buf: [proto.SHORT_LENGTH]u8 = @splat(0);
    const len = proto.featureIndexRequest(&buf, device_index, feature_id) orelse return false;

    // The request goes out as a HID output report: the report ID, then
    // the report.
    var out: [proto.SHORT_LENGTH + 1]u8 = @splat(0);
    out[0] = proto.REPORT_ID_SHORT;
    @memcpy(out[1..1 + len], buf[0..len]);
    return sendReport(receiver.dev, &out);
}

/// Set the LED state of a keyboard behind a receiver.
pub fn setLeds(receiver_index: usize, device_index: u8, leds: u8) bool {
    if (receiver_index >= receiver_count) return false;
    const receiver = &receivers[receiver_index];
    const target = deviceFor(receiver, device_index) orelse return false;
    const feature_index = target.features.indexOf(Feature.led_state) orelse return false;

    var buf: [proto.SHORT_LENGTH]u8 = @splat(0);
    const len = proto.ledRequest(&buf, device_index, feature_index, leds) orelse return false;

    var out: [proto.SHORT_LENGTH + 1]u8 = @splat(0);
    out[0] = proto.REPORT_ID_SHORT;
    @memcpy(out[1..1 + len], buf[0..len]);
    return sendReport(receiver.dev, &out);
}

/// The receiver that a device belongs to.
fn receiverFor(dev: *device.UsbDevice) ?*Receiver {
    var i: usize = 0;
    while (i < receiver_count) : (i += 1) {
        if (receivers[i].dev == dev) return &receivers[i];
    }
    return null;
}

/// The device with an index inside a receiver.
fn deviceFor(receiver: *Receiver, index: u8) ?*Device {
    if (index >= receiver.devices.len) return null;
    return &receiver.devices[index];
}

/// Write the state of the driver to the serial log.
pub fn printStatus(
    write: *const fn (s: []const u8) void,
    writeDec: *const fn (v: u64) void,
) void {
    if (receiver_count == 0) {
        write("  No HID++ receivers.\n");
        return;
    }

    var r: usize = 0;
    while (r < receiver_count) : (r += 1) {
        const receiver = &receivers[r];
        write("  HID++ receiver ");
        writeDec(r);
        write("  reports in/out: ");
        writeDec(receiver.reports_in);
        write("/");
        writeDec(receiver.reports_out);
        write("\n");

        var d: usize = 0;
        while (d < receiver.devices.len) : (d += 1) {
            const dev = &receiver.devices[d];
            if (!dev.present) continue;
            write("    device ");
            writeDec(dev.index);
            write("  ");
            write(dev.name[0..dev.name_len]);
            write("  battery ");
            writeDec(dev.battery);
            write("%\n");
        }
    }
}
