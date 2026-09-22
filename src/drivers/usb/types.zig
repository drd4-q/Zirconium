const std = @import("std");

pub const UsbControllerType = enum(u8) {
    uhci = 0x00,
    ohci = 0x10,
    ehci = 0x20,
    xhci = 0x30,

    pub fn name(self: UsbControllerType) []const u8 {
        return switch (self) {
            .uhci => "UHCI (USB 1.1)",
            .ohci => "OHCI (USB 1.1)",
            .ehci => "EHCI (USB 2.0)",
            .xhci => "xHCI (USB 3.0)",
        };
    }
};

pub const UsbSpeed = enum(u8) {
    low = 0, // 1.5 Mbps (USB 1.1)
    full = 1, // 12 Mbps (USB 1.1 / 2.0)
    high = 2, // 480 Mbps (USB 2.0)
    super_speed = 3, // 5 Gbps (USB 3.0)
    super_speed_plus = 4, // 10 Gbps (USB 3.1)

    pub fn name(self: UsbSpeed) []const u8 {
        return switch (self) {
            .low => "Low-Speed (1.5 Mbps)",
            .full => "Full-Speed (12 Mbps)",
            .high => "High-Speed (480 Mbps)",
            .super_speed => "SuperSpeed (5 Gbps)",
            .super_speed_plus => "SuperSpeed+ (10 Gbps)",
        };
    }
};

pub const UsbTransferType = enum(u8) {
    control = 0,
    interrupt = 1,
    bulk = 2,
    isochronous = 3,
};

pub const UsbTransferStatus = enum(u8) {
    idle,
    pending,
    in_progress,
    completed,
    stalled,
    nak,
    babble,
    error_crc,
    error_timeout,
    error_io,
};

pub const UsbDeviceClass = enum(u8) {
    per_interface = 0x00,
    audio = 0x01,
    cdc = 0x02,
    hid = 0x03,
    physical = 0x05,
    image = 0x06,
    printer = 0x07,
    mass_storage = 0x08,
    hub = 0x09,
    vendor_specific = 0xFF,

    pub fn name(self: UsbDeviceClass) []const u8 {
        return switch (self) {
            .per_interface => "Device (Defined at Interface level)",
            .audio => "Audio Device",
            .cdc => "Communications Device (CDC)",
            .hid => "HID (Keyboard / Mouse / Gamepad)",
            .physical => "Physical Device",
            .image => "Imaging Device (Camera / Scanner)",
            .printer => "Printer",
            .mass_storage => "Mass Storage (USB Drive / Disk)",
            .hub => "USB Hub",
            .vendor_specific => "Vendor Specific",
        };
    }
};

pub const UsbDeviceType = enum(u8) {
    unknown,
    keyboard,
    mouse,
    hub,
    storage,
    wifi,

    pub fn name(self: UsbDeviceType) []const u8 {
        return switch (self) {
            .unknown => "Generic USB Device",
            .keyboard => "USB Keyboard (HID Boot)",
            .mouse => "USB Mouse (HID Boot)",
            .hub => "USB Hub",
            .storage => "USB Mass Storage",
            .wifi => "USB 2.4GHz Wi-Fi Adapter",
        };
    }
};

pub const UsbPortStatus = struct {
    port: u8,
    connected: bool,
    enabled: bool,
    speed: []const u8,
    device_desc: []const u8,
};

// Standard USB Request / Setup packet (8 bytes)
pub const UsbSetupPacket = extern struct {
    bmRequestType: u8,
    bRequest: u8,
    wValue: u16,
    wIndex: u16,
    wLength: u16,
};

// Standard USB Descriptors
pub const UsbDeviceDescriptor = extern struct {
    bLength: u8 = 18,
    bDescriptorType: u8 = 1,
    bcdUSB: u16 = 0x0200,
    bDeviceClass: u8 = 0,
    bDeviceSubClass: u8 = 0,
    bDeviceProtocol: u8 = 0,
    bMaxPacketSize0: u8 = 64,
    idVendor: u16 = 0,
    idProduct: u16 = 0,
    bcdDevice: u16 = 0x0100,
    iManufacturer: u8 = 0,
    iProduct: u8 = 0,
    iSerialNumber: u8 = 0,
    bNumConfigurations: u8 = 1,
};

pub const UsbConfigDescriptor = extern struct {
    bLength: u8 = 9,
    bDescriptorType: u8 = 2,
    wTotalLength: u16 = 9,
    bNumInterfaces: u8 = 1,
    bConfigurationValue: u8 = 1,
    iConfiguration: u8 = 0,
    bmAttributes: u8 = 0x80, // Bus powered
    bMaxPower: u8 = 50, // 100mA
};

pub const UsbInterfaceDescriptor = extern struct {
    bLength: u8 = 9,
    bDescriptorType: u8 = 4,
    bInterfaceNumber: u8 = 0,
    bAlternateSetting: u8 = 0,
    bNumEndpoints: u8 = 0,
    bInterfaceClass: u8 = 0,
    bInterfaceSubClass: u8 = 0,
    bInterfaceProtocol: u8 = 0,
    iInterface: u8 = 0,
};

pub const UsbEndpointDescriptor = extern struct {
    bLength: u8 = 7,
    bDescriptorType: u8 = 5,
    bEndpointAddress: u8 = 0,
    bmAttributes: u8 = 0,
    wMaxPacketSize: u16 = 8,
    bInterval: u8 = 10,
};

pub const UsbHidDescriptor = extern struct {
    bLength: u8 = 9,
    bDescriptorType: u8 = 0x21,
    bcdHID: u16 = 0x0110,
    bCountryCode: u8 = 0,
    bNumDescriptors: u8 = 1,
    bReportDescriptorType: u8 = 0x22,
    wDescriptorLength: u16 = 0,
};

// Standard USB Request Codes
pub const REQ_GET_STATUS: u8 = 0x00;
pub const REQ_CLEAR_FEATURE: u8 = 0x01;
pub const REQ_SET_FEATURE: u8 = 0x03;
pub const REQ_SET_ADDRESS: u8 = 0x05;
pub const REQ_GET_DESCRIPTOR: u8 = 0x06;
pub const REQ_SET_DESCRIPTOR: u8 = 0x07;
pub const REQ_GET_CONFIGURATION: u8 = 0x08;
pub const REQ_SET_CONFIGURATION: u8 = 0x09;
pub const REQ_GET_INTERFACE: u8 = 0x0A;
pub const REQ_SET_INTERFACE: u8 = 0x0B;
pub const REQ_SYNCH_FRAME: u8 = 0x0C;

// HID Class Requests
pub const HID_REQ_GET_REPORT: u8 = 0x01;
pub const HID_REQ_GET_IDLE: u8 = 0x02;
pub const HID_REQ_GET_PROTOCOL: u8 = 0x03;
pub const HID_REQ_SET_REPORT: u8 = 0x09;
pub const HID_REQ_SET_IDLE: u8 = 0x0A;
pub const HID_REQ_SET_PROTOCOL: u8 = 0x0B;

// USB Mass Storage Bulk-Only Transport (BOT)
pub const US_PR_BULK: u8 = 0x50; // Bulk-Only Transport
pub const US_SC_SCSI: u8 = 0x06; // Transparent SCSI command set
pub const US_BULK_RESET_REQUEST: u8 = 0xFF;
pub const US_BULK_GET_MAX_LUN: u8 = 0xFE;

// USB Standard Feature Selectors
pub const FEATURE_ENDPOINT_HALT: u16 = 0x0000;
pub const FEATURE_DEVICE_REMOTE_WAKEUP: u16 = 0x0001;

// SCSI Transparent Command Set (subset for Mass Storage)
pub const SCSI_TEST_UNIT_READY: u8 = 0x00;
pub const SCSI_REQUEST_SENSE: u8 = 0x03;
pub const SCSI_INQUIRY: u8 = 0x12;
pub const SCSI_READ_FORMAT_CAPACITIES: u8 = 0x23;
pub const SCSI_READ_CAPACITY_10: u8 = 0x25;
pub const SCSI_READ_10: u8 = 0x28;
pub const SCSI_WRITE_10: u8 = 0x2A;

// USB Command Block Wrapper (CBW) - 31 bytes
pub const UsbCbw = extern struct {
    dCBWSignature: u32 = 0x43425355, // "USBC" in little endian
    dCBWTag: u32 = 0,
    dCBWDataTransferLength: u32 = 0,
    bmCBWFlags: u8 = 0, // Bit 7: 1 = Data-In, 0 = Data-Out
    bCBWLUN: u8 = 0, // Target Logical Unit Number
    bCBWCBLength: u8 = 0, // Length of SCSI CDB (1..16)
    CBWCB: [16]u8 = [_]u8{0} ** 16, // SCSI Command Descriptor Block
};

// USB Command Status Wrapper (CSW) - 13 bytes
pub const UsbCsw = extern struct {
    dCSWSignature: u32 = 0, // "USBS" (0x53425355 in little endian)
    dCSWTag: u32 = 0,
    dCSWDataResidue: u32 = 0,
    bCSWStatus: u8 = 0, // 0 = Command Passed, 1 = Command Failed, 2 = Phase Error
};

// Descriptor Types
pub const DESC_DEVICE: u8 = 1;
pub const DESC_CONFIGURATION: u8 = 2;
pub const DESC_STRING: u8 = 3;
pub const DESC_INTERFACE: u8 = 4;
pub const DESC_ENDPOINT: u8 = 5;
pub const DESC_DEVICE_QUALIFIER: u8 = 6;
pub const DESC_OTHER_SPEED_CONFIGURATION: u8 = 7;
pub const DESC_INTERFACE_POWER: u8 = 8;
pub const DESC_HID: u8 = 0x21;
pub const DESC_REPORT: u8 = 0x22;
pub const DESC_PHYSICAL: u8 = 0x23;

pub const MAX_DEVICE_ENDPOINTS: usize = 4;
pub const MAX_DEVICE_INTERFACES: usize = 4;

pub const UsbEndpoint = struct {
    ep_addr: u8 = 0, // Bits 3:0 = ep number, bit 7 = direction (1=IN, 0=OUT)
    transfer_type: UsbTransferType = .interrupt,
    max_packet_size: u16 = 8,
    interval_ms: u8 = 10,
    toggle: u1 = 0,
    active: bool = false,

    hw_endpoint_id: u8 = 0, // xHCI Device Context Index (1..31)
    hw_queue_ptr: usize = 0, // EHCI / UHCI QH pointer

    pub fn isInput(self: UsbEndpoint) bool {
        return (self.ep_addr & 0x80) != 0;
    }

    pub fn epNumber(self: UsbEndpoint) u8 {
        return self.ep_addr & 0x0F;
    }
};

pub const UsbInterface = struct {
    interface_num: u8 = 0,
    class_code: u8 = 0,
    subclass_code: u8 = 0,
    protocol_code: u8 = 0,
    driver_type: UsbDeviceType = .unknown,
    endpoints: [MAX_DEVICE_ENDPOINTS]UsbEndpoint = [_]UsbEndpoint{.{}} ** MAX_DEVICE_ENDPOINTS,
    endpoint_count: usize = 0,

    report_buf: [64]u8 = [_]u8{0} ** 64,
    prev_report: [64]u8 = [_]u8{0} ** 64,
    report_len: usize = 0,
    caps_lock: bool = false,
};
