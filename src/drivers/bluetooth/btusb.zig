//! Bluetooth HCI over USB.
//!
//! Ported from the Linux kernel's `drivers/bluetooth/btusb.c` (the USB
//! transport for a Bluetooth controller) and `drivers/bluetooth/hci_usb.c`
//! (the HCI framing).
//!
//! The transport is the one Linux uses for a USB dongle:
//!
//!   * the HCI **commands** go out as a class specific control transfer to
//!     endpoint 0 - `alloc_ctrl_urb()` in btusb.c sends them with
//!     `usb_fill_control_urb()` and `wLength = skb->len`;
//!   * the HCI **events** arrive on the interrupt IN endpoint;
//!   * the HCI **ACL data** travels over the bulk OUT and bulk IN
//!     endpoints.
//!
//! The Bluetooth USB class is interface class 0xe0, subclass 0x01, protocol
//! 0x01; `usb_find_common_endpoints()` in btusb.c picks the three endpoints
//! the same way this driver does.

const serial = @import("../../system/serial.zig");
const usb = @import("../usb/mod.zig");
const usb_types = @import("../usb/types.zig");
const device = @import("../usb/device.zig");
const hci = @import("hci.zig");

/// The USB class code for a Bluetooth device (Linux's `USB_BT_SIG`).
pub const CLASS_BLUETOOTH: u8 = 0xE0;
/// The subclass: the Bluetooth radio.
pub const SUBCLASS_RF: u8 = 0x01;
/// The protocol: the Bluetooth HCI.
pub const PROTOCOL_BLUETOOTH: u8 = 0x01;

/// The number of events that can be queued before the oldest one is
/// dropped.  Linux queues them in a socket buffer; a fixed ring is the
/// equivalent for a polled driver.
const EVENT_QUEUE_SIZE: usize = 16;

/// One Bluetooth USB controller.
pub const Adapter = struct {
    /// The USB device the controller lives on.
    dev: *device.UsbDevice = undefined,
    /// The interface number that carries the HCI endpoints.
    interface_num: u8 = 0,
    /// The interrupt IN endpoint the events arrive on.
    ep_event: u8 = 0,
    /// The bulk OUT endpoint the ACL data goes out on.
    ep_acl_out: u8 = 0,
    /// The bulk IN endpoint the ACL data arrives on.
    ep_acl_in: u8 = 0,

    /// The event queue.
    events: [EVENT_QUEUE_SIZE][hci.MAX_HCI_PACKET]u8 = @splat(@splat(0)),
    event_len: [EVENT_QUEUE_SIZE]u8 = @splat(0),
    event_head: usize = 0,
    event_tail: usize = 0,
    event_count: usize = 0,

    /// The controller that speaks through this adapter.
    controller: hci.Controller = undefined,

    /// The number of commands sent and the events received, for the
    /// diagnostic output.
    commands_sent: u32 = 0,
    events_received: u32 = 0,
};

pub const MAX_ADAPTERS: usize = 4;

pub var adapters: [MAX_ADAPTERS]Adapter = undefined;
pub var adapter_count: usize = 0;

/// Look for a Bluetooth USB device and bind to it.
///
/// This is Linux's `btusb_probe()` reduced to what a polled driver needs:
/// find the interface, find the endpoints and start the controller.
pub fn probe() bool {
    var i: usize = 0;
    while (i < usb.usb_device_count) : (i += 1) {
        var dev = &usb.usb_devices[i];
        if (!dev.active) continue;

        const iface = findBluetoothInterface(dev) orelse continue;
        if (adapter_count >= MAX_ADAPTERS) break;

        var adapter = Adapter{};
        adapter.dev = dev;
        adapter.interface_num = iface.interface_num;

        // The endpoints, exactly like `usb_find_common_endpoints()` in
        // btusb.c: the interrupt IN for the events, the bulk OUT for the
        // commands and the ACL data, the bulk IN for the incoming ACL.
        var k: usize = 0;
        while (k < iface.endpoint_count) : (k += 1) {
            const ep = &iface.endpoints[k];
            if (!ep.active) continue;
            switch (ep.transfer_type) {
                .interrupt => {
                    if (ep.isInput() and adapter.ep_event == 0) {
                        adapter.ep_event = ep.epNumber();
                    }
                },
                .bulk => {
                    if (ep.isInput()) {
                        if (adapter.ep_acl_in == 0) adapter.ep_acl_in = ep.epNumber();
                    } else {
                        if (adapter.ep_acl_out == 0) adapter.ep_acl_out = ep.epNumber();
                    }
                },
                else => {},
            }
        }

        if (adapter.ep_event == 0) {
            serial.serialWrite("[BTUSB] No interrupt endpoint, skipping\n");
            continue;
        }

        serial.serialWrite("[BTUSB] Found Bluetooth controller, interface ");
        serial.serialWriteDec(adapter.interface_num);
        serial.serialWrite(" event ep=");
        serial.serialWriteDec(adapter.ep_event);
        serial.serialWrite(" acl out=");
        serial.serialWriteDec(adapter.ep_acl_out);
        serial.serialWrite(" acl in=");
        serial.serialWriteDec(adapter.ep_acl_in);
        serial.serialWrite("\n");

        // The controller owns the interrupt endpoint from now on: the
        // events are HCI events, not HID reports.
        dev.intr_complete = onInterrupt;

        const transport = hci.Transport{
            .ctx = @ptrCast(&adapter),
            .send = sendCommand,
            .recv = recvEvent,
        };
        if (!adapter.controller.init(transport)) {
            serial.serialWrite("[BTUSB] Controller did not come up\n");
            continue;
        }

        adapters[adapter_count] = adapter;
        adapter_count += 1;
        return true;
    }
    return false;
}

/// The interface that carries the Bluetooth HCI endpoints.
fn findBluetoothInterface(dev: *device.UsbDevice) ?*device.UsbInterface {
    var i: usize = 0;
    while (i < dev.interface_count) : (i += 1) {
        const iface = &dev.interfaces[i];
        if (iface.class_code == CLASS_BLUETOOTH and
            iface.subclass_code == SUBCLASS_RF and
            iface.protocol_code == PROTOCOL_BLUETOOTH) return iface;
    }
    return null;
}

/// Send one HCI command packet.
///
/// The command goes out as a class specific control transfer, which is what
/// btusb.c does for a controller without a bulk command endpoint.
fn sendCommand(ctx: ?*anyopaque, data: []const u8) bool {
    const adapter: *Adapter = @ptrCast(@alignCast(ctx orelse return false));

    const setup = usb_types.UsbSetupPacket{
        .bmRequestType = 0x20, // class, host to device
        .bRequest = 0x00,
        .wValue = 0,
        .wIndex = adapter.interface_num,
        .wLength = @truncate(data.len),
    };

    const maxp0: u8 = @min(adapter.dev.ep0_max_packet, 64);
    const ok = usb.usbControlTransferById(adapter.dev.id, maxp0, &setup, data, null);
    if (ok) {
        adapter.commands_sent += 1;
    } else {
        serial.serialWrite("[BTUSB] Command transfer failed\n");
    }
    return ok;
}

/// Take the next queued event, if any.
fn recvEvent(ctx: ?*anyopaque, buf: []u8) ?usize {
    const adapter: *Adapter = @ptrCast(@alignCast(ctx orelse return null));
    if (adapter.event_count == 0) return null;

    const len = adapter.event_len[adapter.event_tail];
    const n = @min(len, buf.len);
    @memcpy(buf[0..n], adapter.events[adapter.event_tail][0..n]);

    adapter.event_tail = (adapter.event_tail + 1) % EVENT_QUEUE_SIZE;
    adapter.event_count -= 1;
    return n;
}

/// The interrupt endpoint completed: queue the HCI event.
fn onInterrupt(dev: *device.UsbDevice, len: usize) void {
    if (len == 0 or len > dev.report_buf.len) return;

    // Find the adapter that owns this device.
    var i: usize = 0;
    while (i < adapter_count) : (i += 1) {
        const adapter = &adapters[i];
        if (adapter.dev != dev) continue;

        if (adapter.event_count == EVENT_QUEUE_SIZE) {
            // The queue is full: drop the oldest event, exactly like a
            // socket buffer that overflows.
            adapter.event_tail = (adapter.event_tail + 1) % EVENT_QUEUE_SIZE;
            adapter.event_count -= 1;
        }

        const slot = adapter.event_head;
        const n = @min(len, adapter.events[slot].len);
        @memcpy(adapter.events[slot][0..n], dev.report_buf[0..n]);
        adapter.event_len[slot] = @intCast(n);
        adapter.event_head = (adapter.event_head + 1) % EVENT_QUEUE_SIZE;
        adapter.event_count += 1;
        adapter.events_received += 1;
        return;
    }
}

/// Read the pending events of every controller.
pub fn poll() void {
    var i: usize = 0;
    while (i < adapter_count) : (i += 1) {
        adapters[i].controller.poll();
    }
}

/// The controllers this driver found.
pub fn controllerCount() usize {
    return adapter_count;
}

/// The controller of one adapter.
pub fn controller(index: usize) ?*hci.Controller {
    if (index >= adapter_count) return null;
    return &adapters[index].controller;
}
