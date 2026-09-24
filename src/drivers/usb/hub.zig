const std = @import("std");
const root = @import("root");
const serial = root.serial;
const types = @import("types.zig");
const device = @import("device.zig");
const timer = @import("../timer.zig");

// USB 2.0 Hub Driver (USB 2.0 Spec Chapter 11)
// Enables power to downstream ports on internal/external USB hubs,
// resets connected peripherals, and triggers downstream enumeration.

pub const HUB_CLASS: u8 = 0x09;

// Hub Class Requests
pub const HUB_REQ_GET_STATUS: u8 = 0x00;
pub const HUB_REQ_CLEAR_FEATURE: u8 = 0x01;
pub const HUB_REQ_SET_FEATURE: u8 = 0x03;
pub const HUB_REQ_GET_DESCRIPTOR: u8 = 0x06;

// Port Feature Selectors
pub const PORT_FEAT_CONNECTION: u16 = 0;
pub const PORT_FEAT_ENABLE: u16 = 1;
pub const PORT_FEAT_SUSPEND: u16 = 2;
pub const PORT_FEAT_OVER_CURRENT: u16 = 3;
pub const PORT_FEAT_RESET: u16 = 4;
pub const PORT_FEAT_POWER: u16 = 8;
pub const PORT_FEAT_LOW_SPEED: u16 = 9;
pub const PORT_FEAT_C_CONNECTION: u16 = 16;
pub const PORT_FEAT_C_ENABLE: u16 = 17;
pub const PORT_FEAT_C_SUSPEND: u16 = 18;
pub const PORT_FEAT_C_OVER_CURRENT: u16 = 19;
pub const PORT_FEAT_C_RESET: u16 = 20;

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

pub fn makeSetPortFeaturePacket(port: u8, feature: u16) types.UsbSetupPacket {
    return types.UsbSetupPacket{
        .bmRequestType = 0x23, // Host-to-Device, Class, Other (Port)
        .bRequest = HUB_REQ_SET_FEATURE,
        .wValue = feature,
        .wIndex = @as(u16, port),
        .wLength = 0,
    };
}

pub fn makeClearPortFeaturePacket(port: u8, feature: u16) types.UsbSetupPacket {
    return types.UsbSetupPacket{
        .bmRequestType = 0x23,
        .bRequest = HUB_REQ_CLEAR_FEATURE,
        .wValue = feature,
        .wIndex = @as(u16, port),
        .wLength = 0,
    };
}

pub fn makeGetPortStatusPacket(port: u8) types.UsbSetupPacket {
    return types.UsbSetupPacket{
        .bmRequestType = 0xA3, // Device-to-Host, Class, Other (Port)
        .bRequest = HUB_REQ_GET_STATUS,
        .wValue = 0,
        .wIndex = @as(u16, port),
        .wLength = 4,
    };
}

pub fn makeGetHubDescriptorPacket(length: u16) types.UsbSetupPacket {
    return types.UsbSetupPacket{
        .bmRequestType = 0xA0, // Device-to-Host, Class, Device
        .bRequest = HUB_REQ_GET_DESCRIPTOR,
        .wValue = 0x2900, // Hub Descriptor (type 0x29)
        .wIndex = 0,
        .wLength = length,
    };
}

pub const HubPortInfo = struct {
    port: u8,
    connected: bool,
    enabled: bool,
    speed: types.UsbSpeed,
};

/// Initialize a USB Hub: read hub descriptor, apply port power to all downstream ports,
/// and wait for power stabilization.
pub fn configureHubPorts(
    addr: u8,
    maxp0: u8,
    ctrl_transfer_fn: *const fn (addr: u8, maxp0: u8, setup: *const types.UsbSetupPacket, dout: ?[]const u8, din: ?[]u8) bool,
    out_ports: []HubPortInfo,
    out_num_ports: ?*u8,
) usize {
    serial.serialWrite("[HUB] Querying Hub Descriptor for addr=");
    serial.serialWriteDec(addr);
    serial.serialWrite("...\n");

    var hub_desc: [16]u8 = [_]u8{0} ** 16;
    const get_desc_pkt = makeGetHubDescriptorPacket(8);
    if (!ctrl_transfer_fn(addr, maxp0, &get_desc_pkt, null, hub_desc[0..8])) {
        serial.serialWrite("[HUB] Failed to read Hub Descriptor\n");
        return 0;
    }

    const num_ports = hub_desc[2];
    if (out_num_ports) |out| out.* = num_ports;
    const pwr_good_time: u32 = @as(u32, hub_desc[5]) * 2; // bPwrOn2PwrGood is in 2ms units

    serial.serialWrite("[HUB] Found ");
    serial.serialWriteDec(num_ports);
    serial.serialWrite(" downstream ports, power-on delay: ");
    serial.serialWriteDec(pwr_good_time);
    serial.serialWrite(" ms\n");

    // Power on all downstream ports
    var p: u8 = 1;
    while (p <= num_ports and p <= out_ports.len) : (p += 1) {
        const pwr_pkt = makeSetPortFeaturePacket(p, PORT_FEAT_POWER);
        _ = ctrl_transfer_fn(addr, maxp0, &pwr_pkt, null, null);
    }

    // Power stabilization delay (mandatory on real hardware: VBUS ramp + device pullup)
    const delay = @max(pwr_good_time, 100);
    spinDelayMs(delay);

    var connected_count: usize = 0;
    p = 1;
    while (p <= num_ports and p <= out_ports.len) : (p += 1) {
        var status_buf: [4]u8 = [_]u8{0} ** 4;
        const st_pkt = makeGetPortStatusPacket(p);
        if (ctrl_transfer_fn(addr, maxp0, &st_pkt, null, &status_buf)) {
            const port_status = @as(u16, status_buf[0]) | (@as(u16, status_buf[1]) << 8);
            const connected = (port_status & 0x01) != 0;

            if (connected) {
                serial.serialWrite("[HUB] Port ");
                serial.serialWriteDec(p);
                serial.serialWrite(": device connected, issuing reset...\n");

                // Reset downstream port
                const rst_pkt = makeSetPortFeaturePacket(p, PORT_FEAT_RESET);
                _ = ctrl_transfer_fn(addr, maxp0, &rst_pkt, null, null);
                spinDelayMs(50);

                // Clear reset change
                const clr_pkt = makeClearPortFeaturePacket(p, PORT_FEAT_C_RESET);
                _ = ctrl_transfer_fn(addr, maxp0, &clr_pkt, null, null);
                spinDelayMs(20);

                // Read speed after reset
                if (ctrl_transfer_fn(addr, maxp0, &st_pkt, null, &status_buf)) {
                    const st2 = @as(u16, status_buf[0]) | (@as(u16, status_buf[1]) << 8);
                    const speed: types.UsbSpeed = if ((st2 & (1 << 9)) != 0)
                        .low
                    else if ((st2 & (1 << 10)) != 0)
                        .high
                    else
                        .full;

                    out_ports[connected_count] = .{
                        .port = p,
                        .connected = true,
                        .enabled = (st2 & (1 << 1)) != 0,
                        .speed = speed,
                    };
                    connected_count += 1;
                }
            }
        }
    }

    return connected_count;
}
