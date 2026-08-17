const std = @import("std");
const root = @import("root");
const vga = root.vga;
const serial = @import("../system/serial.zig");
const pci = @import("pci.zig");
const timer = @import("timer.zig");
const keyboard = @import("keyboard.zig");
const mouse = @import("mouse.zig");

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

    pub fn name(self: UsbDeviceType) []const u8 {
        return switch (self) {
            .unknown => "Generic USB Device",
            .keyboard => "USB Keyboard (HID Boot)",
            .mouse => "USB Mouse (HID Boot)",
            .hub => "USB Hub",
            .storage => "USB Mass Storage",
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
    num_ports: u8,
    ports: [8]UsbPortStatus,
};

// Standard USB Request / Setup packet (8 bytes)
pub const UsbSetupPacket = extern struct {
    bmRequestType: u8,
    bRequest: u8,
    wValue: u16,
    wIndex: u16,
    wLength: u16,
};

// UHCI Queue Head (16 bytes aligned)
pub const UhciQh = extern struct {
    head_link: u32 = 1,     // Next QH or Terminate (bit 0 = 1)
    element_link: u32 = 1,  // First TD in queue or Terminate (bit 0 = 1)
    _pad0: u32 = 0,
    _pad1: u32 = 0,
};

// UHCI Transfer Descriptor (16 bytes aligned)
pub const UhciTd = extern struct {
    link: u32 = 1,          // Next TD or Terminate (bit 0 = 1)
    ctrl_status: u32 = 0,   // Control and status bits
    token: u32 = 0,         // Packet token: PID, dev addr, EP, toggle, max len
    buffer: u32 = 0,        // 32-bit physical buffer pointer
};

pub const MAX_USB_DEVICES: usize = 8;

pub const UsbDevice = struct {
    active: bool = false,
    ctrl_idx: u8 = 0,
    port: u8 = 0,
    addr: u8 = 0,
    low_speed: bool = false,
    dev_type: UsbDeviceType = .unknown,
    vendor_id: u16 = 0,
    product_id: u16 = 0,
    interface_num: u8 = 0,
    ep_in: u8 = 0,
    ep_max_packet: u16 = 8,
    ep_interval: u8 = 10,
    toggle: u1 = 0,
    qh: UhciQh align(16) = .{},
    td: UhciTd align(16) = .{},
    report_buf: [16]u8 align(16) = [_]u8{0} ** 16,
    prev_report: [16]u8 = [_]u8{0} ** 16,
    packet_count: u32 = 0,
    caps_lock: bool = false,
};

pub const MAX_USB_CONTROLLERS: usize = 4;
pub var controllers: [MAX_USB_CONTROLLERS]UsbController = undefined;
pub var controller_count: usize = 0;

pub var usb_devices: [MAX_USB_DEVICES]UsbDevice = undefined;
pub var usb_device_count: usize = 0;

var initialized: bool = false;

// 4KB-aligned UHCI Frame List (1024 pointers)
var frame_list: [1024]u32 align(4096) = [_]u32{1} ** 1024;

// UHCI Control transfer resources
var ctrl_qh: UhciQh align(16) = .{};
var ctrl_tds: [16]UhciTd align(16) = [_]UhciTd{.{}} ** 16;
var ctrl_setup_pkt: UsbSetupPacket align(16) = undefined;
var ctrl_buf: [512]u8 align(16) = [_]u8{0} ** 512;

fn inb(port: u16) u8 {
    return asm volatile ("inb %%dx, %%al" : [result] "={al}" (-> u8), : [port] "{dx}" (port));
}

fn outb(port: u16, val: u8) void {
    asm volatile ("outb %%al, %%dx" : : [val] "{al}" (val), [port] "{dx}" (port));
}

fn inw(port: u16) u16 {
    return asm volatile ("inw %%dx, %%ax" : [result] "={ax}" (-> u16), : [port] "{dx}" (port));
}

fn outw(port: u16, val: u16) void {
    asm volatile ("outw %%ax, %%dx" : : [val] "{ax}" (val), [port] "{dx}" (port));
}

fn inl(port: u16) u32 {
    return asm volatile ("inl %%dx, %%eax" : [result] "={eax}" (-> u32), : [port] "{dx}" (port));
}

fn outl(port: u16, val: u32) void {
    asm volatile ("outl %%eax, %%dx" : : [val] "{eax}" (val), [port] "{dx}" (port));
}

fn delayMs(ms: u32) void {
    if (timer.ticks > 0) {
        const needed: u64 = if (ms == 0) 0 else ((@as(u64, ms) + 9) / 10);
        const target = timer.ticks + needed;
        asm volatile ("sti");
        while (timer.ticks < target) {
            asm volatile ("hlt");
        }
    } else {
        var i: u32 = 0;
        while (i < ms * 100000) : (i += 1) {
            asm volatile ("pause");
        }
    }
}

// Convert USB HID Usage ID to ASCII / key code
pub fn usbKeyToAscii(key: u8, shift: bool, ctrl: bool, caps: bool) ?u8 {
    // Letters A-Z: HID codes 0x04..0x1D
    if (key >= 0x04 and key <= 0x1D) {
        const base: u8 = 'a' + (key - 0x04);
        if (ctrl) {
            return base & 0x1F;
        }
        if (shift != caps) {
            return base - 32;
        }
        return base;
    }

    // Ctrl + '[' gives ESC (0x1B)
    if (ctrl and key == 0x2F) return 0x1B;

    // Digits 1-9, 0: HID codes 0x1E..0x27
    if (key >= 0x1E and key <= 0x27) {
        if (shift) {
            return switch (key) {
                0x1E => '!',
                0x1F => '@',
                0x20 => '#',
                0x21 => '$',
                0x22 => '%',
                0x23 => '^',
                0x24 => '&',
                0x25 => '*',
                0x26 => '(',
                0x27 => ')',
                else => 0,
            };
        } else {
            if (key == 0x27) return '0';
            return '1' + (key - 0x1E);
        }
    }

    // Enter, Esc, Backspace, Tab, Space & symbols
    switch (key) {
        0x28 => return '\n',
        0x29 => return 0x1B, // Esc
        0x2A => return 0x08, // Backspace
        0x2B => return '\t', // Tab
        0x2C => return ' ',
        0x2D => return if (shift) '_' else '-',
        0x2E => return if (shift) '+' else '=',
        0x2F => return if (shift) '{' else '[',
        0x30 => return if (shift) '}' else ']',
        0x31 => return if (shift) '|' else '\\',
        0x33 => return if (shift) ':' else ';',
        0x34 => return if (shift) '"' else '\'',
        0x35 => return if (shift) '~' else '`',
        0x36 => return if (shift) '<' else ',',
        0x37 => return if (shift) '>' else '.',
        0x38 => return if (shift) '?' else '/',
        // Cursor / navigation keys
        0x49 => return keyboard.KEY_INSERT,
        0x4A => return keyboard.KEY_HOME,
        0x4B => return keyboard.KEY_PAGE_UP,
        0x4C => return keyboard.KEY_DELETE,
        0x4D => return keyboard.KEY_END,
        0x4E => return keyboard.KEY_PAGE_DOWN,
        0x4F => return keyboard.KEY_RIGHT,
        0x50 => return keyboard.KEY_LEFT,
        0x51 => return keyboard.KEY_DOWN,
        0x52 => return keyboard.KEY_UP,
        // Keypad keys
        0x54 => return '/',
        0x55 => return '*',
        0x56 => return '-',
        0x57 => return '+',
        0x58 => return '\n',
        0x59 => return '1',
        0x5A => return '2',
        0x5B => return '3',
        0x5C => return '4',
        0x5D => return '5',
        0x5E => return '6',
        0x5F => return '7',
        0x60 => return '8',
        0x61 => return '9',
        0x62 => return '0',
        0x63 => return '.',
        else => return null,
    }
}

const TD_CTRL_ACTIVE: u32 = 1 << 23;
const TD_CTRL_3ERRORS: u32 = 3 << 27;
const TD_CTRL_LOWSPEED: u32 = 1 << 26;
const TD_CTRL_SPD: u32 = 1 << 29;

fn relinkUhciSchedule() void {
    var prev_qh: ?*UhciQh = null;

    var i: usize = 0;
    while (i < usb_device_count) : (i += 1) {
        const dev = &usb_devices[i];
        if (!dev.active) continue;

        dev.td.link = 1; // Terminate
        dev.td.ctrl_status = TD_CTRL_ACTIVE | TD_CTRL_3ERRORS | (if (dev.low_speed) TD_CTRL_LOWSPEED else 0) | TD_CTRL_SPD; // Active + 3 errors + LS + SPD
        dev.td.token = 0x69 | (@as(u32, dev.addr) << 8) | (@as(u32, dev.ep_in) << 15) | (@as(u32, dev.toggle) << 19) | ((@as(u32, @min(dev.ep_max_packet, 16)) - 1) << 21);
        dev.td.buffer = @intCast(@intFromPtr(&dev.report_buf));

        dev.qh.element_link = @intCast(@intFromPtr(&dev.td));
        dev.qh.head_link = 1;

        if (prev_qh) |pq| {
            pq.head_link = @intCast(@intFromPtr(&dev.qh) | 0x02);
        } else {
            const qh_ptr: u32 = @intCast(@intFromPtr(&dev.qh) | 0x02);
            var f: usize = 0;
            while (f < 1024) : (f += 1) {
                frame_list[f] = qh_ptr;
            }
        }
        prev_qh = &dev.qh;
    }

    if (prev_qh) |pq| {
        pq.head_link = @intCast(@intFromPtr(&ctrl_qh) | 0x02);
    } else {
        const qh_ptr: u32 = @intCast(@intFromPtr(&ctrl_qh) | 0x02);
        var f: usize = 0;
        while (f < 1024) : (f += 1) {
            frame_list[f] = qh_ptr;
        }
    }
    ctrl_qh.head_link = 1; // Terminate
    ctrl_qh.element_link = 1;
}

fn readVolatileU32(ptr: *const u32) u32 {
    return @as(*const volatile u32, @ptrCast(ptr)).*;
}

fn writeVolatileU32(ptr: *u32, val: u32) void {
    @as(*volatile u32, @ptrCast(ptr)).* = val;
}

fn uhciControlTransfer(
    dev_addr: u8,
    low_speed: bool,
    max_packet0: u8,
    setup: *const UsbSetupPacket,
    data_out: ?[]const u8,
    data_in: ?[]u8,
) bool {
    ctrl_setup_pkt = setup.*;

    // Setup stage TD
    ctrl_tds[0].ctrl_status = TD_CTRL_ACTIVE | TD_CTRL_3ERRORS | (if (low_speed) TD_CTRL_LOWSPEED else 0);
    ctrl_tds[0].token = 0x2D | (@as(u32, dev_addr) << 8) | (0 << 15) | (0 << 19) | ((8 - 1) << 21); // PID_SETUP, DATA0, len 8
    ctrl_tds[0].buffer = @intCast(@intFromPtr(&ctrl_setup_pkt));

    var td_idx: usize = 1;
    var toggle: u32 = 1; // Data stage starts with DATA1

    if (data_in) |din| {
        var transferred: usize = 0;
        const total = din.len;
        const mp: usize = if (max_packet0 > 0) max_packet0 else 8;
        while (transferred < total) {
            const chunk = @min(total - transferred, mp);
            ctrl_tds[td_idx - 1].link = @intCast(@intFromPtr(&ctrl_tds[td_idx]) | 0x04);
            ctrl_tds[td_idx].token = 0x69 | (@as(u32, dev_addr) << 8) | (0 << 15) | (toggle << 19) | ((@as(u32, @intCast(chunk - 1)) & 0x7FF) << 21);
            ctrl_tds[td_idx].ctrl_status = TD_CTRL_ACTIVE | TD_CTRL_3ERRORS | (if (low_speed) TD_CTRL_LOWSPEED else 0) | TD_CTRL_SPD;
            ctrl_tds[td_idx].buffer = @intCast(@intFromPtr(&ctrl_buf[transferred]));
            toggle ^= 1;
            transferred += chunk;
            td_idx += 1;
        }
    } else if (data_out) |dout| {
        var transferred: usize = 0;
        const total = dout.len;
        const mp: usize = if (max_packet0 > 0) max_packet0 else 8;
        while (transferred < total) {
            const chunk = @min(total - transferred, mp);
            @memcpy(ctrl_buf[transferred .. transferred + chunk], dout[transferred .. transferred + chunk]);
            ctrl_tds[td_idx - 1].link = @intCast(@intFromPtr(&ctrl_tds[td_idx]) | 0x04);
            ctrl_tds[td_idx].token = 0xE1 | (@as(u32, dev_addr) << 8) | (0 << 15) | (toggle << 19) | ((@as(u32, @intCast(chunk - 1)) & 0x7FF) << 21);
            ctrl_tds[td_idx].ctrl_status = TD_CTRL_ACTIVE | TD_CTRL_3ERRORS | (if (low_speed) TD_CTRL_LOWSPEED else 0);
            ctrl_tds[td_idx].buffer = @intCast(@intFromPtr(&ctrl_buf[transferred]));
            toggle ^= 1;
            transferred += chunk;
            td_idx += 1;
        }
    }

    // Status stage TD
    ctrl_tds[td_idx - 1].link = @intCast(@intFromPtr(&ctrl_tds[td_idx]) | 0x04);
    const is_read = (setup.bmRequestType & 0x80) != 0;
    if (is_read) {
        // Device-to-Host (Read) -> Status is OUT, DATA1, 0 bytes
        ctrl_tds[td_idx].token = 0xE1 | (@as(u32, dev_addr) << 8) | (0 << 15) | (1 << 19) | (0x7FF << 21);
    } else {
        // Host-to-Device (Write) -> Status is IN, DATA1, 0 bytes
        ctrl_tds[td_idx].token = 0x69 | (@as(u32, dev_addr) << 8) | (0 << 15) | (1 << 19) | (0x7FF << 21);
    }
    ctrl_tds[td_idx].ctrl_status = TD_CTRL_ACTIVE | TD_CTRL_3ERRORS | (if (low_speed) TD_CTRL_LOWSPEED else 0);
    ctrl_tds[td_idx].buffer = 0;
    ctrl_tds[td_idx].link = 1; // Terminate

    const last_td = td_idx;

    // Attach to Control QH (volatile write)
    writeVolatileU32(&ctrl_qh.element_link, @intCast(@intFromPtr(&ctrl_tds[0])));

    // Poll for completion
    var timeout: u32 = 0;
    while (timeout < 50) : (timeout += 1) {
        const st_last = readVolatileU32(&ctrl_tds[last_td].ctrl_status);
        if ((st_last & (1 << 23)) == 0) {
            // Check for errors across TDs
            var err = false;
            var k: usize = 0;
            while (k <= last_td) : (k += 1) {
                const st_k = readVolatileU32(&ctrl_tds[k].ctrl_status);
                if ((st_k & 0x007E0000) != 0) {
                    err = true;
                    serial.serialWrite("[USB-DBG] TD error: 0x");
                    serial.serialWriteHex(st_k);
                    serial.serialWrite("\n");
                    break;
                }
            }
            writeVolatileU32(&ctrl_qh.element_link, 1);
            if (err) return false;

            if (data_in) |din| {
                @memcpy(din, ctrl_buf[0..din.len]);
            }
            return true;
        }
        delayMs(10);
    }

    writeVolatileU32(&ctrl_qh.element_link, 1);
    return false;
}

fn enumerateUhciDevice(ctrl_idx: u8, port_idx: u8, low_speed: bool) void {
    if (usb_device_count >= MAX_USB_DEVICES) return;

    // Step 1: Read first 8 bytes of Device Descriptor at address 0
    var dev_desc_8: [8]u8 = [_]u8{0} ** 8;
    const get_desc_pkt = UsbSetupPacket{
        .bmRequestType = 0x80,
        .bRequest = 0x06, // GET_DESCRIPTOR
        .wValue = 0x0100, // DEVICE descriptor
        .wIndex = 0,
        .wLength = 8,
    };

    if (!uhciControlTransfer(0, low_speed, 8, &get_desc_pkt, null, &dev_desc_8)) {
        serial.serialWrite("[USB] Failed to read Device Descriptor (8 bytes) at addr 0\n");
        return;
    }

    const max_packet0: u8 = if (dev_desc_8[7] > 0) dev_desc_8[7] else 8;
    const new_addr: u8 = @intCast(usb_device_count + 1);

    // Step 2: Set Address
    const set_addr_pkt = UsbSetupPacket{
        .bmRequestType = 0x00,
        .bRequest = 0x05, // SET_ADDRESS
        .wValue = new_addr,
        .wIndex = 0,
        .wLength = 0,
    };

    if (!uhciControlTransfer(0, low_speed, max_packet0, &set_addr_pkt, null, null)) {
        serial.serialWrite("[USB] Failed to SET_ADDRESS\n");
        return;
    }
    delayMs(20); // Device recovery time after address assignment

    // Step 3: Read full 18-byte Device Descriptor at new address
    var dev_desc: [18]u8 = [_]u8{0} ** 18;
    const get_full_desc_pkt = UsbSetupPacket{
        .bmRequestType = 0x80,
        .bRequest = 0x06,
        .wValue = 0x0100,
        .wIndex = 0,
        .wLength = 18,
    };

    if (!uhciControlTransfer(new_addr, low_speed, max_packet0, &get_full_desc_pkt, null, &dev_desc)) {
        serial.serialWrite("[USB] Failed to read full Device Descriptor\n");
        return;
    }

    const vendor_id = @as(u16, dev_desc[8]) | (@as(u16, dev_desc[9]) << 8);
    const product_id = @as(u16, dev_desc[10]) | (@as(u16, dev_desc[11]) << 8);
    const dev_class = dev_desc[4];

    // Step 4: Read 9-byte Configuration Descriptor Header to get total length
    var cfg_hdr: [9]u8 = [_]u8{0} ** 9;
    const get_cfg_hdr_pkt = UsbSetupPacket{
        .bmRequestType = 0x80,
        .bRequest = 0x06,
        .wValue = 0x0200, // CONFIGURATION descriptor
        .wIndex = 0,
        .wLength = 9,
    };

    if (!uhciControlTransfer(new_addr, low_speed, max_packet0, &get_cfg_hdr_pkt, null, &cfg_hdr)) {
        serial.serialWrite("[USB] Failed to read Config Descriptor Header\n");
        return;
    }

    var total_cfg_len = @as(u16, cfg_hdr[2]) | (@as(u16, cfg_hdr[3]) << 8);
    total_cfg_len = @min(total_cfg_len, 256);

    // Step 5: Read full Configuration Descriptor tree
    var cfg_buf: [256]u8 = [_]u8{0} ** 256;
    const get_full_cfg_pkt = UsbSetupPacket{
        .bmRequestType = 0x80,
        .bRequest = 0x06,
        .wValue = 0x0200,
        .wIndex = 0,
        .wLength = total_cfg_len,
    };

    if (!uhciControlTransfer(new_addr, low_speed, max_packet0, &get_full_cfg_pkt, null, cfg_buf[0..total_cfg_len])) {
        serial.serialWrite("[USB] Failed to read full Config Descriptor\n");
        return;
    }

    // Step 6: Parse interfaces and endpoints
    var iface_num: u8 = 0;
    var iface_class: u8 = dev_class;
    var iface_protocol: u8 = 0;
    var ep_in: u8 = 1;
    var ep_max: u16 = 8;
    var ep_interval: u8 = 10;

    var off: usize = 0;
    while (off + 2 <= total_cfg_len) {
        const desc_len = cfg_buf[off];
        if (desc_len < 2 or off + desc_len > total_cfg_len) break;
        const desc_type = cfg_buf[off + 1];

        if (desc_type == 4 and desc_len >= 9) { // INTERFACE Descriptor
            iface_num = cfg_buf[off + 2];
            iface_class = cfg_buf[off + 5];
            iface_protocol = cfg_buf[off + 7];
        } else if (desc_type == 5 and desc_len >= 7) { // ENDPOINT Descriptor
            const ep_addr = cfg_buf[off + 2];
            const ep_attr = cfg_buf[off + 3];
            if ((ep_addr & 0x80) != 0 and (ep_attr & 3) == 3) { // Interrupt IN endpoint
                ep_in = ep_addr & 0x0F;
                ep_max = @as(u16, cfg_buf[off + 4]) | (@as(u16, cfg_buf[off + 5]) << 8);
                ep_interval = cfg_buf[off + 6];
            }
        }
        off += desc_len;
    }

    // Step 7: Set Configuration 1
    const set_cfg_pkt = UsbSetupPacket{
        .bmRequestType = 0x00,
        .bRequest = 0x09, // SET_CONFIGURATION
        .wValue = 1,
        .wIndex = 0,
        .wLength = 0,
    };
    _ = uhciControlTransfer(new_addr, low_speed, max_packet0, &set_cfg_pkt, null, null);
    delayMs(10);

    var dtype: UsbDeviceType = .unknown;

    // Step 8: If HID device, set Boot Protocol (0) and Idle (0)
    if (iface_class == 0x03 or dev_class == 0x03) {
        if (iface_protocol == 1) {
            dtype = .keyboard;
        } else if (iface_protocol == 2) {
            dtype = .mouse;
        } else {
            // Default to keyboard or mouse
            dtype = if (port_idx == 0) .keyboard else .mouse;
        }

        // SET_PROTOCOL: 0 = Boot Protocol
        const set_proto_pkt = UsbSetupPacket{
            .bmRequestType = 0x21,
            .bRequest = 0x0B, // SET_PROTOCOL
            .wValue = 0,
            .wIndex = iface_num,
            .wLength = 0,
        };
        _ = uhciControlTransfer(new_addr, low_speed, max_packet0, &set_proto_pkt, null, null);

        // SET_IDLE: 0 = Report on change
        const set_idle_pkt = UsbSetupPacket{
            .bmRequestType = 0x21,
            .bRequest = 0x0A, // SET_IDLE
            .wValue = 0,
            .wIndex = iface_num,
            .wLength = 0,
        };
        _ = uhciControlTransfer(new_addr, low_speed, max_packet0, &set_idle_pkt, null, null);
    } else if (iface_class == 0x08 or dev_class == 0x08) {
        dtype = .storage;
    } else if (iface_class == 0x09 or dev_class == 0x09) {
        dtype = .hub;
    }

    // Step 9: Register device in active table
    var dev = &usb_devices[usb_device_count];
    dev.active = true;
    dev.ctrl_idx = ctrl_idx;
    dev.port = port_idx + 1;
    dev.addr = new_addr;
    dev.low_speed = low_speed;
    dev.dev_type = dtype;
    dev.vendor_id = vendor_id;
    dev.product_id = product_id;
    dev.interface_num = iface_num;
    dev.ep_in = ep_in;
    dev.ep_max_packet = if (ep_max > 0) ep_max else 8;
    dev.ep_interval = ep_interval;
    dev.toggle = 0;
    dev.packet_count = 0;
    dev.caps_lock = false;
    @memset(&dev.report_buf, 0);
    @memset(&dev.prev_report, 0);

    // Update port status description
    controllers[ctrl_idx].ports[port_idx].device_desc = dtype.name();

    usb_device_count += 1;

    serial.serialWrite("[USB] Registered ");
    serial.serialWrite(dtype.name());
    serial.serialWrite(" at Addr ");
    serial.serialWriteDec(new_addr);
    serial.serialWrite(" (Vendor=0x");
    serial.serialWriteHex(vendor_id);
    serial.serialWrite(" Product=0x");
    serial.serialWriteHex(product_id);
    serial.serialWrite(" EP_IN=");
    serial.serialWriteDec(ep_in);
    serial.serialWrite(")\n");
}

pub fn init() void {
    if (initialized) return;
    controller_count = 0;
    usb_device_count = 0;

    serial.serialWrite("[USB] Scanning PCI for USB host controllers...\n");

    for (pci.devices[0..pci.device_count]) |dev| {
        if (dev.class == 0x0C and dev.subclass == 0x03) {
            if (controller_count >= MAX_USB_CONTROLLERS) break;

            const ctype: UsbControllerType = switch (dev.prog_if) {
                0x00 => .uhci,
                0x10 => .ohci,
                0x20 => .ehci,
                0x30 => .xhci,
                else => .uhci,
            };

            var ctrl = &controllers[controller_count];
            ctrl.ctrl_type = ctype;
            ctrl.bus = dev.bus;
            ctrl.dev = dev.dev;
            ctrl.func = dev.func;
            ctrl.vendor_id = dev.vendor_id;
            ctrl.device_id = dev.device_id;
            ctrl.irq = dev.irq;
            ctrl.num_ports = 0;

            if (ctype == .uhci) {
                const bar4 = pci.readBar(dev.bus, dev.dev, dev.func, 4);
                ctrl.io_base = @intCast(bar4 & 0xFFFC);
                ctrl.mmio_base = 0;
                ctrl.num_ports = 2;

                pci.enableBusMaster(dev.bus, dev.dev, dev.func);

                if (ctrl.io_base != 0) {
                    // Reset UHCI controller
                    outw(ctrl.io_base + 0x00, 0x0002); // USBCMD: HCRESET
                    delayMs(10);
                    outw(ctrl.io_base + 0x04, 0x0000); // USBINTR: disable IRQs
                    outw(ctrl.io_base + 0x02, 0x00FF); // USBSTS: clear status
                    outw(ctrl.io_base + 0x06, 0x0000); // FRNUM: reset frame num
                    outb(ctrl.io_base + 0x0C, 0x40);   // SOFMOD: 1ms SOF

                    // Setup Frame List and Control Queue Head
                    ctrl_qh.head_link = 1;
                    ctrl_qh.element_link = 1;
                    const qh_phys: u32 = @intCast(@intFromPtr(&ctrl_qh) | 0x02);
                    var f: usize = 0;
                    while (f < 1024) : (f += 1) {
                        frame_list[f] = qh_phys;
                    }
                    outl(ctrl.io_base + 0x08, @intCast(@intFromPtr(&frame_list)));

                    // Start UHCI Schedule (Run = 1, Configured = 1, Max Packet 64 = 1)
                    outw(ctrl.io_base + 0x00, 0x00C1);

                    // Scan and initialize root ports
                    var p: u8 = 0;
                    while (p < ctrl.num_ports) : (p += 1) {
                        const port_reg = ctrl.io_base + 0x10 + (@as(u16, p) * 2);
                        var status = inw(port_reg);
                        const connected = (status & 0x01) != 0;

                        if (connected) {
                            // Reset port (assert reset for 50ms, then clear reset and enable port)
                            outw(port_reg, 0x0204);
                            delayMs(50);
                            outw(port_reg, 0x0004);
                            delayMs(20);

                            status = inw(port_reg);
                            const enabled = (status & 0x04) != 0;
                            const low_speed = (status & 0x0100) != 0;

                            ctrl.ports[p] = .{
                                .port = p + 1,
                                .connected = true,
                                .enabled = enabled,
                                .speed = if (low_speed) "Low-Speed (1.5 Mbps)" else "Full-Speed (12 Mbps)",
                                .device_desc = if (low_speed) "USB HID (Keyboard/Mouse)" else "USB Full-Speed Device",
                            };

                            if (enabled) {
                                enumerateUhciDevice(@intCast(controller_count), p, low_speed);
                            }
                        } else {
                            ctrl.ports[p] = .{
                                .port = p + 1,
                                .connected = false,
                                .enabled = false,
                                .speed = "Full-Speed (12 Mbps)",
                                .device_desc = "No device",
                            };
                        }
                    }

                    relinkUhciSchedule();
                }
            } else if (ctype == .ehci or ctype == .xhci) {
                ctrl.io_base = 0;
                ctrl.mmio_base = dev.bar0 & 0xFFFFFFF0;
                ctrl.num_ports = 4;

                var p: u8 = 0;
                while (p < ctrl.num_ports) : (p += 1) {
                    ctrl.ports[p] = .{
                        .port = p + 1,
                        .connected = (p == 0),
                        .enabled = true,
                        .speed = if (ctype == .xhci) "SuperSpeed (5 Gbps)" else "High-Speed (480 Mbps)",
                        .device_desc = if (p == 0) (if (ctype == .xhci) "USB 3.0 Storage / Hub" else "USB 2.0 High-Speed Hub") else "No device",
                    };
                }
            } else {
                ctrl.io_base = 0;
                ctrl.mmio_base = dev.bar0 & 0xFFFFFFF0;
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
            }

            serial.serialWrite("[USB] Found ");
            serial.serialWrite(ctype.name());
            serial.serialWrite(" Controller at PCI ");
            serial.serialWriteDec(dev.bus);
            serial.serialWrite(":");
            serial.serialWriteDec(dev.dev);
            serial.serialWrite(" (Vendor=0x");
            serial.serialWriteHex(dev.vendor_id);
            serial.serialWrite(" Device=0x");
            serial.serialWriteHex(dev.device_id);
            serial.serialWrite(")\n");

            controller_count += 1;
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

    initialized = true;
}

// Poll USB HID devices for keyboard keypresses and mouse movements
pub fn poll() void {
    if (!initialized or usb_device_count == 0) return;

    var i: usize = 0;
    while (i < usb_device_count) : (i += 1) {
        var dev = &usb_devices[i];
        if (!dev.active) continue;

        const st = readVolatileU32(&dev.td.ctrl_status);
        // Check if Active bit (bit 23) has cleared (TD transfer completed)
        if ((st & (1 << 23)) == 0) {
            // Check for error bits (bits 22..17)
            if ((st & 0x007E0000) == 0) {
                dev.packet_count +%= 1;

                if (dev.dev_type == .keyboard) {
                    const mod = dev.report_buf[0];
                    const shift = (mod & 0x22) != 0; // Left or Right Shift
                    const ctrl = (mod & 0x11) != 0;  // Left or Right Ctrl

                    // Check up to 6 pressed keys in boot report (bytes 2..7)
                    var k: usize = 2;
                    while (k < 8) : (k += 1) {
                        const key = dev.report_buf[k];
                        if (key == 0) continue;

                        // Check if key was not pressed in previous report
                        var was_pressed = false;
                        var prev_k: usize = 2;
                        while (prev_k < 8) : (prev_k += 1) {
                            if (dev.prev_report[prev_k] == key) {
                                was_pressed = true;
                                break;
                            }
                        }

                        if (!was_pressed) {
                            if (key == 0x39) {
                                dev.caps_lock = !dev.caps_lock;
                            } else if (usbKeyToAscii(key, shift, ctrl, dev.caps_lock)) |ch| {
                                keyboard.pushKey(ch);
                            }
                        }
                    }
                    @memcpy(&dev.prev_report, &dev.report_buf);
                } else if (dev.dev_type == .mouse) {
                    const buttons = dev.report_buf[0];
                    const dx = @as(i32, @as(i8, @bitCast(dev.report_buf[1])));
                    const dy = @as(i32, @as(i8, @bitCast(dev.report_buf[2])));

                    if (dx != 0 or dy != 0 or buttons != dev.prev_report[0]) {
                        mouse.updateFromUsb(buttons, dx, dy);
                    }
                    @memcpy(&dev.prev_report, &dev.report_buf);
                }
            }

            // Re-arm TD for next interrupt transfer
            dev.toggle ^= 1;
            dev.td.token = 0x69 | (@as(u32, dev.addr) << 8) | (@as(u32, dev.ep_in) << 15) | (@as(u32, dev.toggle) << 19) | ((@as(u32, @min(dev.ep_max_packet, 16)) - 1) << 21);
            dev.td.link = 1;
            writeVolatileU32(&dev.td.ctrl_status, TD_CTRL_ACTIVE | TD_CTRL_3ERRORS | (if (dev.low_speed) TD_CTRL_LOWSPEED else 0) | TD_CTRL_SPD);
            writeVolatileU32(&dev.qh.element_link, @intCast(@intFromPtr(&dev.td)));
        }
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
}
