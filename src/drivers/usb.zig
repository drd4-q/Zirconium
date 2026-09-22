const std = @import("std");
pub const types = @import("usb/types.zig");
pub const dma = @import("usb/dma.zig");
pub const pci_detect = @import("usb/pci_detect.zig");
pub const uhci = @import("usb/uhci.zig");
pub const ehci = @import("usb/ehci.zig");
pub const xhci = @import("usb/xhci.zig");
pub const device = @import("usb/device.zig");
pub const hid = @import("usb/hid.zig");
pub const usbhid = @import("usb/usbhid.zig");
pub const hid_core = @import("usb/hid_core.zig");
pub const hid_generic = @import("usb/hid_generic.zig");
pub const hid_input = @import("usb/hid_input.zig");
pub const hub = @import("usb/hub.zig");
pub const mod = @import("usb/mod.zig");
pub const rtl8188eu = @import("usb/rtl8188eu.zig");
pub const storage = @import("usb/storage.zig");

// Re-export standard USB types and enumerations
pub const UsbControllerType = types.UsbControllerType;
pub const UsbSpeed = types.UsbSpeed;
pub const UsbTransferType = types.UsbTransferType;
pub const UsbTransferStatus = types.UsbTransferStatus;
pub const UsbDeviceClass = types.UsbDeviceClass;
pub const UsbDeviceType = types.UsbDeviceType;
pub const UsbPortStatus = types.UsbPortStatus;
pub const UsbSetupPacket = types.UsbSetupPacket;

// Descriptors
pub const UsbDeviceDescriptor = types.UsbDeviceDescriptor;
pub const UsbConfigDescriptor = types.UsbConfigDescriptor;
pub const UsbInterfaceDescriptor = types.UsbInterfaceDescriptor;
pub const UsbEndpointDescriptor = types.UsbEndpointDescriptor;
pub const UsbHidDescriptor = types.UsbHidDescriptor;

// Endpoints and Interfaces
pub const UsbEndpoint = types.UsbEndpoint;
pub const UsbInterface = types.UsbInterface;

// Hardware Descriptors
pub const UhciQh = uhci.UhciQh;
pub const UhciTd = uhci.UhciTd;
pub const EhciQh = ehci.EhciQh;
pub const EhciQtd = ehci.EhciQtd;
pub const XhciTrb = xhci.XhciTrb;

// Unified Abstractions
pub const UsbDevice = device.UsbDevice;
pub const UsbController = mod.UsbController;

// Capacities
pub const MAX_USB_CONTROLLERS: usize = mod.MAX_USB_CONTROLLERS;
pub const MAX_USB_DEVICES: usize = mod.MAX_USB_DEVICES;

// Global state variables for direct backwards compatibility
pub var controllers: [MAX_USB_CONTROLLERS]UsbController = undefined;
pub var controller_count: usize = 0;

pub var usb_devices: [MAX_USB_DEVICES]UsbDevice = undefined;
pub var usb_device_count: usize = 0;

fn syncState() void {
    controller_count = mod.controller_count;
    var i: usize = 0;
    while (i < controller_count) : (i += 1) {
        controllers[i] = mod.controllers[i];
    }
    usb_device_count = mod.usb_device_count;
    var j: usize = 0;
    while (j < usb_device_count) : (j += 1) {
        usb_devices[j] = mod.usb_devices[j];
    }
}

// Public API
pub fn init() void {
    mod.init();
    syncState();
}

pub fn scan() void {
    init();
}

pub fn poll() void {
    mod.poll();
    // Keep local packet counts and toggles in sync
    var j: usize = 0;
    while (j < usb_device_count) : (j += 1) {
        usb_devices[j].packet_count = mod.usb_devices[j].packet_count;
        usb_devices[j].caps_lock = mod.usb_devices[j].caps_lock;
    }
}

pub fn getControllers() []UsbController {
    return controllers[0..controller_count];
}

<<<<<<< HEAD
pub fn getControllerCount() usize {
    return controller_count;
}

pub fn getDevices() []UsbDevice {
    return usb_devices[0..usb_device_count];
}

pub fn getDeviceCount() usize {
    return usb_device_count;
=======
    // Bring up real hardware behind any xHCI controller we found.
    for (controllers[0..controller_count]) |*ctrl| {
        if (ctrl.ctrl_type == .xhci) {
            var probe_dev = pci.PciDevice{
                .bus = ctrl.bus,
                .dev = ctrl.dev,
                .func = ctrl.func,
                .vendor_id = ctrl.vendor_id,
                .device_id = ctrl.device_id,
                .class = 0x0C,
                .subclass = 0x03,
                .prog_if = 0x30,
                .bar0 = @intCast(ctrl.mmio_base & 0xFFFFFFFF),
                .bar1 = @intCast(ctrl.mmio_base >> 32),
                .irq = ctrl.irq,
            };
            if (@import("xhci.zig").init(&probe_dev)) {
                xhci_ready = true;
                break;
            }
        }
    }

    initialized = true;
>>>>>>> b588c390dec30ac14d775895765ce1109b2ad3db
}

var xhci_ready: bool = false;

/// Drain USB HID events (called from the scheduler tick).
pub fn pollHid() void {
    if (xhci_ready) @import("xhci.zig").pollHid();
}

pub fn printUsbStatus(writeFn: *const fn (s: []const u8) void, writeDecFn: *const fn (v: u64) void, writeHexFn: *const fn (v: u64) void) void {
    mod.printUsbStatus(writeFn, writeDecFn, writeHexFn);
}

pub const usbKeyToAscii = mod.usbKeyToAscii;
pub const usbControlTransfer = mod.usbControlTransfer;
pub const usbBulkTransfer = mod.usbBulkTransfer;
pub const usbBulkOutTransfer = mod.usbBulkOutTransfer;
pub const usbBulkInTransfer = mod.usbBulkInTransfer;
pub const usbClearHalt = mod.usbClearHalt;
