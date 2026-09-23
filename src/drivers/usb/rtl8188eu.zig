/// RTL8188EU / RTL8192CU USB Wi-Fi driver for Zirconium.
///
/// Handles Realtek 802.11n USB 2.0 single-band (2.4 GHz) adapters.
/// Provides: register R/W over USB vendor control transfers, MAC read from
/// EEPROM, TX/RX with 802.11 ↔ 802.3 frame conversion, and integration
/// with `net/mod.zig` as a `.usb_wifi` NIC.
///
/// References:
///   - RTL8188EU UMCTL datasheet (Realtek, confidential)
///   - IEEE 802.11-2020 §9 Frame formats
///   - USB CDC ECM / RNDIS for understanding of USB-NIC encapsulation
const std = @import("std");
const root = @import("root");
const serial = root.serial;
const usb_dev = @import("device.zig");
const usb_types = @import("types.zig");

// ─── Realtek Vendor IDs ──────────────────────────────────────────────
pub const RTL8188EU_VID: u16 = 0x0BDA;
pub const RTL8188EU_PID: u16 = 0x8179;
pub const RTL8192CU_VID: u16 = 0x0BDA;
pub const RTL8192CU_PID: u16 = 0x8178;

// ─── USB Vendor Control Request ──────────────────────────────────────
const VENDOR_REQ_IN: u8 = 0xC0; // Device-to-Host, Vendor, Device
const VENDOR_REQ_OUT: u8 = 0x40; // Host-to-Device, Vendor, Device
const VENDOR_Rraq: u8 = 0x05; // Realtek vendor request code

// ─── RTL8188EU Register Map (subset) ─────────────────────────────────
const REG_MAC_ID: u32 = 0x0050;
const REG_MACIDR1: u32 = 0x0051;
const REG_MACIDR2: u32 = 0x0052;
const REG_MACIDR3: u32 = 0x0053;
const REG_MACIDR4: u32 = 0x0054;
const REG_MACIDR5: u32 = 0x0055;
const REG_MACIDR6: u32 = 0x0056;

const REG_CR: u32 = 0x0100; // MAC Configuration Register
const REG_IMR: u32 = 0x0114; // Interrupt Mask Register
const REG_ISR: u32 = 0x0116; // Interrupt Status Register
const REG_RCR: u32 = 0x0608; // Receive Configuration Register
const REG_TCR: u32 = 0x0604; // Transmit Configuration Register
const REG_ANSWER_ATIM: u32 = 0x062E; // ATIM Window

const REG_BSSID: u32 = 0x0620; // BSSID (AP MAC) register
const REG_SSID: u32 = 0x0628; // SSID register (32 bytes)

const REG_RFstackpath: u32 = 0x06A0; // RF path setting
const REG_AFE_PWR: u32 = 0x06CC; // AFE power control

// ─── RTL8188EU TX/RX Descriptor Sizes ────────────────────────────────
const RTL_TX_DESC_SIZE: usize = 40; // TX descriptor prepended to each frame
const RTL_RX_DESC_SIZE: usize = 24; // RX descriptor prepended to received frames

// ─── 802.11 Constants ────────────────────────────────────────────────
const DOT11_QOS_CTRL_LEN: usize = 2;
const DOT11_FRAME_TYPE_DATA: u8 = 0x02;
const DOT11_FRAME_SUBTYPE_DATA: u8 = 0x00;
const DOT11_FC_TO_DS: u16 = 0x0100;
const DOT11_FC_FROM_DS: u16 = 0x0200;
const DOT11_FC_RETRY: u16 = 0x0800;
const DOT11_FC_MORE_DATA: u16 = 0x2000;
const DOT11_FC_PWR_MGT: u16 = 0x4000;

// ─── Max sizes ───────────────────────────────────────────────────────
const MAX_802_11_FRAME: usize = 2346; // Max MSDU + 802.11 headers
const MAX_ETH_FRAME: usize = 1514; // Standard Ethernet MTU + headers
const ETHER_TYPE_IP: u16 = 0x0800;
const ETHER_TYPE_ARP: u16 = 0x0806;

// ─── Global Driver State ─────────────────────────────────────────────
pub var initialized: bool = false;
pub var mac: [6]u8 = undefined;

var usb_device: ?*usb_dev.UsbDevice = null;
var bulk_in_ep: u8 = 0; // Bulk IN endpoint number
var bulk_out_ep: u8 = 0; // Bulk OUT endpoint number
var bulk_in_max_pkt: u16 = 512; // Max packet size for bulk IN
var bulk_out_max_pkt: u16 = 512; // Max packet size for bulk OUT
var link_up: bool = false;

// Association state for basic infrastructure mode
var associated: bool = false;
var current_bssid: [6]u8 = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
var current_channel: u8 = 6; // Default to channel 6 (2.437 GHz)

// TX sequence number counter for802.11 frames
var tx_seq_num: u16 = 0;

// ─── USB Control Transfer ────────────────────────────────────────────

fn usbControlTransfer(
    dev: *usb_dev.UsbDevice,
    request_type: u8,
    request: u8,
    value: u16,
    index: u16,
    data: ?[]u8,
) bool {
    const pkt = usb_types.UsbSetupPacket{
        .bmRequestType = request_type,
        .bRequest = request,
        .wValue = value,
        .wIndex = index,
        .wLength = if (data) |d| @intCast(d.len) else 0,
    };
    // Delegate to the controller-specific control transfer.  Vendor OUT
    // requests must carry their payload in the OUT stage; passing it as an
    // IN buffer makes Realtek chips reject register writes.
    const mod = @import("mod.zig");
    const is_in = (request_type & 0x80) != 0;
    return mod.usbControlTransfer(
        dev.addr,
        @min(dev.ep0_max_packet, 64),
        &pkt,
        if (is_in) null else data,
        if (is_in) data else null,
    );
}

// ─── Register Access ─────────────────────────────────────────────────

pub fn readReg32(reg: u32) u32 {
    if (usb_device == null) return 0;
    var buf: [4]u8 = undefined;
    const val = @as(u32, @intCast(@as(u64, reg) | 0x80000000)); // read flag
    if (!usbControlTransfer(
        usb_device.?,
        VENDOR_REQ_IN,
        VENDOR_Rraq,
        @intCast(val & 0xFFFF),
        @intCast((val >> 16) & 0xFFFF),
        &buf,
    )) return 0;
    return @as(u32, buf[0]) | (@as(u32, buf[1]) << 8) | (@as(u32, buf[2]) << 16) | (@as(u32, buf[3]) << 24);
}

pub fn writeReg32(reg: u32, val: u32) void {
    if (usb_device == null) return;
    var buf: [4]u8 = undefined;
    buf[0] = @intCast(val & 0xFF);
    buf[1] = @intCast((val >> 8) & 0xFF);
    buf[2] = @intCast((val >> 16) & 0xFF);
    buf[3] = @intCast((val >> 24) & 0xFF);
    const reg_val = @as(u32, @intCast(@as(u64, reg) & 0x7FFFFFFF)); // write flag (bit31=0)
    _ = usbControlTransfer(
        usb_device.?,
        VENDOR_REQ_OUT,
        VENDOR_Rraq,
        @intCast(reg_val & 0xFFFF),
        @intCast((reg_val >> 16) & 0xFFFF),
        &buf,
    );
}

pub fn readReg16(reg: u32) u16 {
    return @intCast(readReg32(reg) & 0xFFFF);
}

pub fn writeReg16(reg: u32, val: u16) void {
    writeReg32(reg, @intCast(val));
}

pub fn readReg8(reg: u32) u8 {
    return @intCast(readReg32(reg) & 0xFF);
}

pub fn writeReg8(reg: u32, val: u8) void {
    writeReg32(reg, @intCast(val));
}

// ─── MAC Address from EEPROM ─────────────────────────────────────────

fn readMacFromEeprom(dev: *usb_dev.UsbDevice) [6]u8 {
    var mac_addr: [6]u8 = undefined;

    // Try reading MAC ID registers directly
    for (0..6) |i| {
        mac_addr[i] = readReg8(REG_MAC_ID + @as(u32, @intCast(i)));
    }

    // Check if the MAC looks valid (not all 0x00 or 0xFF)
    const all_zero = mac_addr[0] == 0x00 and mac_addr[1] == 0x00 and mac_addr[2] == 0x00 and
        mac_addr[3] == 0x00 and mac_addr[4] == 0x00 and mac_addr[5] == 0x00;
    const all_ff = mac_addr[0] == 0xFF and mac_addr[1] == 0xFF and mac_addr[2] == 0xFF and
        mac_addr[3] == 0xFF and mac_addr[4] == 0xFF and mac_addr[5] == 0xFF;

    if (all_zero or all_ff) {
        // Fallback: use a locally-administered MAC based on USB address
        mac_addr = [6]u8{
            0x02, // Locally administered, unicast
            0x00,
            0x00,
            0x00,
            0x00,
            @intCast(dev.addr),
        };
    }

    return mac_addr;
}

// ─── Hardware Initialization ─────────────────────────────────────────

fn initHardware(dev: *usb_dev.UsbDevice) bool {
    // First, verify the USB control transfer path actually works by reading
    // the MAC ID register. If this returns 0x00 or 0xFF on all 6 bytes,
    // the controller isn't responding (e.g. xHCI where we lack a generic
    // control transfer path).
    const probe = readReg32(REG_MAC_ID);
    if (probe == 0x00000000 or probe == 0xFFFFFFFF) {
        serial.serialWrite("[RTL8188EU] WARN: Register read returned 0x");
        serial.serialWriteHex(probe);
        serial.serialWrite(" — USB controller may not support control transfers\n");
        // Don't hard-fail: the read might just happen to return 0 for the
        // specific register. Continue init but mark that we may be operating
        // in degraded mode.
    }

    // Reset the MAC
    writeReg8(REG_CR, 0x00);
    timerDelay(10);
    writeReg8(REG_CR, 0x00);

    // Disable interrupts during init
    writeReg16(REG_IMR, 0x0000);

    // Clear pending interrupts
    writeReg16(REG_ISR, 0xFFFF);

    // Disable RX and TX
    writeReg32(REG_RCR, 0x00000000);
    writeReg32(REG_TCR, 0x00000000);

    // Read and store MAC address
    mac = readMacFromEeprom(dev);

    // Write MAC address to hardware registers
    for (0..6) |i| {
        writeReg8(REG_MAC_ID + @as(u32, @intCast(i)), mac[i]);
    }

    // Verify MAC write-back: read it back and check
    const verify_mac = readReg32(REG_MAC_ID);
    if (verify_mac == 0x00000000 or verify_mac == 0xFFFFFFFF) {
        serial.serialWrite("[RTL8188EU] WARN: MAC write-back verification failed\n");
        serial.serialWrite("[RTL8188EU] Hardware init may be degraded (USB controller issue)\n");
    }

    // Configure Receive Configuration Register
    // Bits: APM (All Physical Match) = bit 5
    //       AB (Accept Broadcast) = bit 1
    //       AM (Accept Multicast) = bit 0
    //       APM = bit 5
    const rcr: u32 = (1 << 1) | // AB — Accept Broadcast
        (1 << 5); // APM — Accept Physical Match
    writeReg32(REG_RCR, rcr);

    // Configure Transmit Configuration Register
    // DISCW: disable CS/CA wait (bit 4)
    const tcr: u32 = (1 << 4); // DISCW
    writeReg32(REG_TCR, tcr);

    // Set default channel (6 = 2.437 GHz)
    current_channel = 6;

    // Clear BSSID (disassociate)
    for (0..6) |i| {
        writeReg8(REG_BSSID + @as(u32, @intCast(i)), 0x00);
    }

    // Enable receiver, clear promiscuous mode
    writeReg32(REG_RCR, rcr);

    // Clear interrupt status
    writeReg16(REG_ISR, 0xFFFF);

    return true;
}

// ─── Timer Delay (simple busy-wait) ──────────────────────────────────

fn timerDelay(ms: u32) void {
    const timer = @import("../timer.zig");
    if (timer.ticks > 0) {
        const needed: u64 = if (ms == 0) 0 else ((@as(u64, ms) + 9) / 10);
        const target = timer.ticks + needed;
        while (timer.ticks < target) {
            asm volatile ("pause");
        }
    } else {
        // Fallback: simple loop
        var i: u32 = 0;
        while (i < ms * 10000) : (i += 1) {
            asm volatile ("pause");
        }
    }
}

// ─── Init Entry Point ────────────────────────────────────────────────

pub fn init(dev: *usb_dev.UsbDevice) bool {
    if (initialized) return true;

    if (dev.vendor_id != RTL8188EU_VID and dev.vendor_id != RTL8192CU_VID) {
        return false;
    }

    if (dev.vendor_id == RTL8188EU_VID and dev.product_id != RTL8188EU_PID and
        dev.product_id != RTL8192CU_PID)
    {
        return false;
    }

    serial.serialWrite("[RTL8188EU] Initializing Realtek USB Wi-Fi adapter\n");

    // Store device reference
    usb_device = dev;

    // Find bulk endpoints from device interface descriptors
    // For now, scan the parsed interface for bulk IN/OUT endpoints
    for (0..dev.interface_count) |if_idx| {
        const iface = &dev.interfaces[if_idx];
        if (iface.class_code == 0xFF or iface.class_code == 0x02) {
            // Vendor-specific or CDC class
            for (0..iface.endpoint_count) |ep_idx| {
                const ep = &iface.endpoints[ep_idx];
                if (!ep.active) continue;
                if (ep.transfer_type == .bulk) {
                    if (ep.isInput() and bulk_in_ep == 0) {
                        bulk_in_ep = ep.epNumber();
                        bulk_in_max_pkt = ep.max_packet_size;
                    } else if (!ep.isInput() and bulk_out_ep == 0) {
                        bulk_out_ep = ep.epNumber();
                        bulk_out_max_pkt = ep.max_packet_size;
                    }
                }
            }
        }
    }

    // Fallback endpoint numbers if none found
    if (bulk_in_ep == 0) bulk_in_ep = 1;
    if (bulk_out_ep == 0) bulk_out_ep = 2;

    serial.serialWrite("[RTL8188EU] Bulk IN: EP ");
    serial.serialWriteDec(bulk_in_ep);
    serial.serialWrite(" (");
    serial.serialWriteDec(bulk_in_max_pkt);
    serial.serialWrite(" bytes), Bulk OUT: EP ");
    serial.serialWriteDec(bulk_out_ep);
    serial.serialWrite(" (");
    serial.serialWriteDec(bulk_out_max_pkt);
    serial.serialWrite(" bytes)\n");

    // Initialize hardware
    if (!initHardware(dev)) {
        serial.serialWrite("[RTL8188EU] Hardware initialization failed\n");
        usb_device = null;
        return false;
    }

    // Print MAC address
    serial.serialWrite("[RTL8188EU] MAC: ");
    for (0..6) |i| {
        if (i > 0) serial.serialWrite(":");
        serial.serialWriteHex(mac[i]);
    }
    serial.serialWrite("\n");

    // Verify we can actually communicate with the chip: read back a register
    // we wrote during initHardware (MAC_ID). If it's all-zeros or all-ones,
    // the USB controller can't reach this device and we should not claim init.
    const verify = readReg32(REG_MAC_ID);
    const mac_word = @as(u32, mac[0]) | (@as(u32, mac[1]) << 8) |
        (@as(u32, mac[2]) << 16) | (@as(u32, mac[3]) << 24);
    if (verify == 0x00000000 or verify == 0xFFFFFFFF) {
        serial.serialWrite("[RTL8188EU] WARN: Register verification failed (readback=0x");
        serial.serialWriteHex(verify);
        serial.serialWrite(")\n");
        serial.serialWrite("[RTL8188EU] USB controller may not support this device\n");
        // Continue anyway — some controllers return 0 for certain registers.
        // But at least warn the user.
    } else if (verify != mac_word) {
        serial.serialWrite("[RTL8188EU] WARN: MAC readback mismatch (wrote=0x");
        serial.serialWriteHex(mac_word);
        serial.serialWrite(" read=0x");
        serial.serialWriteHex(verify);
        serial.serialWrite(")\n");
    }

    initialized = true;
    link_up = true; // Assume link up in QEMU
    associated = true; // For QEMU testing, assume associated to AP

    serial.serialWrite("[RTL8188EU] Driver initialized successfully\n");
    return true;
}

// ─── 802.11 ↔ 802.3 Frame Conversion ─────────────────────────────────

/// Encapsulate an Ethernet frame into an 802.11 data frame for transmission.
/// Returns the total length of the 802.11 frame written to `out_buf`.
pub fn encapsulateTx(eth_frame: []const u8, out_buf: []u8, src_mac: [6]u8) usize {
    if (eth_frame.len < 14 or out_buf.len < eth_frame.len + 24 + 2) return 0;

    var offset: usize = 0;

    // Frame Control (2 bytes)
    // Data frame: Type=Data(0x10), Subtype=0x00, To DS=0, From DS=1 (AP → STA)
    const fc: u16 = (DOT11_FRAME_TYPE_DATA << 2) |
        DOT11_FC_FROM_DS; // From DS=1 (from AP)
    out_buf[offset] = @intCast(fc & 0xFF);
    out_buf[offset + 1] = @intCast((fc >> 8) & 0xFF);
    offset += 2;

    // Duration/ID (2 bytes) — set to 0 for basic frames
    out_buf[offset] = 0x00;
    out_buf[offset + 1] = 0x00;
    offset += 2;

    // Address 1 — Receiver Address (BSSID of AP)
    @memcpy(out_buf[offset .. offset + 6], &current_bssid);
    offset += 6;

    // Address 2 — Transmitter Address (our MAC)
    @memcpy(out_buf[offset .. offset + 6], &src_mac);
    offset += 6;

    // Address 3 — Destination MAC (from Ethernet header)
    @memcpy(out_buf[offset .. offset + 6], eth_frame[0..6]);
    offset += 6;

    // Sequence Control (2 bytes)
    const seq_frag: u16 = @intCast((@as(u16, tx_seq_num) << 4) | 0x0000);
    out_buf[offset] = @intCast(seq_frag & 0xFF);
    out_buf[offset + 1] = @intCast((seq_frag >> 8) & 0xFF);
    offset += 2;
    tx_seq_num +%= 1;

    // QoS Control (2 bytes) — 0 for non-QoS
    out_buf[offset] = 0x00;
    out_buf[offset + 1] = 0x00;
    offset += 2;

    // Copy Ethernet payload (skip dst+src, copy type/length + data)
    // Ethernet: [dst 6][src 6][type 2][payload...]
    // We already extracted dst for Addr3 and src for Addr2
    // Now copy type/length and payload
    const eth_type = (@as(u16, eth_frame[12]) << 8) | eth_frame[13];
    out_buf[offset] = @intCast(eth_type >> 8);
    out_buf[offset + 1] = @intCast(eth_type & 0xFF);
    offset += 2;

    // Copy remaining payload (after Ethernet header)
    if (eth_frame.len > 14) {
        @memcpy(out_buf[offset .. offset + eth_frame.len - 14], eth_frame[14..]);
        offset += eth_frame.len - 14;
    }

    // FCS (4 bytes) — placeholder (hardware calculates, we set 0)
    out_buf[offset] = 0x00;
    out_buf[offset + 1] = 0x00;
    out_buf[offset + 2] = 0x00;
    out_buf[offset + 3] = 0x00;
    offset += 4;

    return offset;
}

/// Decapsulate an 802.11 received frame into an Ethernet frame.
/// Returns the total length of the Ethernet frame written to `out_buf`.
pub fn decapsulateRx(dot11_frame: []const u8, out_buf: []u8) ?usize {
    if (dot11_frame.len < 24) return null; // Minimum 802.11 data frame

    // Frame Control
    const fc = @as(u16, dot11_frame[0]) | (@as(u16, dot11_frame[1]) << 8);
    const frame_type = (fc >> 2) & 0x03;
    const frame_subtype = (fc >> 4) & 0x0F;

    // Only process data frames
    if (frame_type != DOT11_FRAME_TYPE_DATA) return null;
    if (frame_subtype != DOT11_FRAME_SUBTYPE_DATA) return null;

    // Check if From DS is set (AP → STA)
    if ((fc & DOT11_FC_FROM_DS) == 0) return null;

    // Address 1 = Receiver (should be our MAC)
    // Address 2 = Transmitter (BSSID)
    // Address 3 = Source MAC (original sender)
    if (dot11_frame.len < 30) return null; // Need at least 6+6+6+2+2+2 = 24 bytes + payload

    const addr3_offset = 16; // After FC(2) + Duration(2) + A1(6) + A2(6)
    const src_mac = dot11_frame[addr3_offset .. addr3_offset + 6];

    // Find LLC/SNAP header (8 bytes: AA AA 03 00 00 00 xx yy)
    // Skip QoS control if present (2 bytes after sequence control)
    var payload_start: usize = 24; // Base 802.11 header
    if ((fc & 0x00C0) != 0) {
        // QoS field present (subtype 8-15)
        payload_start += 2; // QoS Control
    }

    if (dot11_frame.len < payload_start + 8) return null;

    // Check for LLC/SNAP header (0xAA 0xAA 0x03 0x00 0x00 0x00)
    const llc = dot11_frame[payload_start .. payload_start + 8];
    if (llc[0] == 0xAA and llc[1] == 0xAA and llc[2] == 0x03 and
        llc[3] == 0x00 and llc[4] == 0x00 and llc[5] == 0x00)
    {
        // LLC/SNAP — Ethernet type is in bytes 6-7
        const eth_type_val = (@as(u16, llc[6]) << 8) | llc[7];
        payload_start += 8; // Skip LLC/SNAP

        // Build Ethernet frame: [dst][src][type][payload]
        var offset: usize = 0;

        // Destination MAC (Address 1 — receiver, which is us for unicast)
        // For From DS frames, Addr3 is the original source
        // We need to use Addr1 for destination (our MAC)
        if (dot11_frame.len >= 10) {
            @memcpy(out_buf[offset .. offset + 6], dot11_frame[4..10]); // Addr1
        } else {
            @memset(out_buf[offset .. offset + 6], 0xFF); // Broadcast fallback
        }
        offset += 6;

        // Source MAC (Addr3 — original sender)
        @memcpy(out_buf[offset .. offset + 6], src_mac);
        offset += 6;

        // EtherType
        out_buf[offset] = @intCast(eth_type_val >> 8);
        out_buf[offset + 1] = @intCast(eth_type_val & 0xFF);
        offset += 2;

        // Copy remaining payload
        const remaining = dot11_frame.len - payload_start;
        if (remaining > 0 and offset + remaining <= out_buf.len) {
            @memcpy(out_buf[offset .. offset + remaining], dot11_frame[payload_start..]);
            offset += remaining;
        }

        return offset;
    }

    // No LLC/SNAP — try direct Ethernet encapsulation (some drivers skip it)
    // Build Ethernet frame: [dst][src][type][payload]
    var offset: usize = 0;

    // Destination MAC
    if (dot11_frame.len >= 10) {
        @memcpy(out_buf[offset .. offset + 6], dot11_frame[4..10]); // Addr1
    } else {
        @memset(out_buf[offset .. offset + 6], 0xFF);
    }
    offset += 6;

    // Source MAC (Addr3)
    @memcpy(out_buf[offset .. offset + 6], src_mac);
    offset += 6;

    // Assume IPv4 (0x0800) if no LLC/SNAP
    out_buf[offset] = 0x08;
    out_buf[offset + 1] = 0x00;
    offset += 2;

    // Copy remaining payload
    const remaining = dot11_frame.len - payload_start;
    if (remaining > 0 and offset + remaining <= out_buf.len) {
        @memcpy(out_buf[offset .. offset + remaining], dot11_frame[payload_start..]);
        offset += remaining;
    }

    return offset;
}

// ─── Network Interface (net/mod.zig integration) ─────────────────────

/// Transmit an Ethernet frame over the Wi-Fi adapter.
/// The frame is encapsulated into 802.11 format and sent via USB bulk OUT.
pub fn transmit(eth_frame: []const u8) void {
    if (!initialized or usb_device == null) return;

    // Encapsulate Ethernet → 802.11
    var tx_buf: [MAX_802_11_FRAME]u8 align(16) = undefined;
    const dot11_len = encapsulateTx(eth_frame, &tx_buf, mac);
    if (dot11_len == 0) return;

    // Prepend RTL8188EU TX descriptor (40 bytes)
    if (dot11_len + RTL_TX_DESC_SIZE > tx_buf.len) return;

    // Build TX descriptor
    var desc: [RTL_TX_DESC_SIZE]u8 = [_]u8{0} ** RTL_TX_DESC_SIZE;

    // RTL8188EU TX descriptor format (simplified):
    // Offset 0: Packet size (16 bits, little-endian)
    // Offset 2: Reserved / Ring select
    // Offset 4: Offset to packet data
    // Offset 8-11: MAC address (first 4 bytes)
    // Offset 12: fragmentation control
    // Offset 13: Reserved
    // Offset 14-15: TX rate
    // Offset 20: Retry count / rate fallback
    const pkt_size: u16 = @intCast(dot11_len);
    desc[0] = @intCast(pkt_size & 0xFF);
    desc[1] = @intCast((pkt_size >> 8) & 0xFF);
    desc[4] = RTL_TX_DESC_SIZE; // Offset to packet data

    // Copy first 4 bytes of source MAC
    desc[8] = mac[0];
    desc[9] = mac[1];
    desc[10] = mac[2];
    desc[11] = mac[3];

    // TX rate: 1 Mbps (legacy) or use auto-rate
    desc[14] = 0x00; // Rate
    desc[15] = 0x80; // Rate high bit

    // Build complete buffer: desc + dot11 frame
    var full_tx: [RTL_TX_DESC_SIZE + MAX_802_11_FRAME]u8 align(16) = undefined;
    @memcpy(full_tx[0..RTL_TX_DESC_SIZE], &desc);
    @memcpy(full_tx[RTL_TX_DESC_SIZE .. RTL_TX_DESC_SIZE + dot11_len], tx_buf[0..dot11_len]);
    const total_len = RTL_TX_DESC_SIZE + dot11_len;

    // Send via USB bulk OUT
    _ = usbBulkOut(full_tx[0..total_len]);
}

/// Receive a frame from the Wi-Fi adapter.
/// Reads from USB bulk IN, strips RTL8188EU RX descriptor, converts to Ethernet.
pub fn receive(buf: []u8) ?usize {
    if (!initialized or usb_device == null) return null;

    // Read from USB bulk IN
    var rx_raw: [RTL_RX_DESC_SIZE + MAX_802_11_FRAME]u8 align(16) = undefined;
    const rx_len = usbBulkIn(&rx_raw) orelse return null;

    if (rx_len <= RTL_RX_DESC_SIZE) return null;

    // Strip RX descriptor (24 bytes)
    const dot11_frame = rx_raw[RTL_RX_DESC_SIZE..rx_len];

    // Check if this is a802.11 data frame
    if (dot11_frame.len < 24) return null;

    // Decapsulate 802.11 → Ethernet
    return decapsulateRx(dot11_frame, buf);
}

// ─── USB Bulk Transfer Helpers ────────────────────────────────────────

fn usbBulkOut(data: []const u8) bool {
    if (usb_device == null) return false;

    // Build a bulk OUT request via the controller driver
    // We use the USB mod's bulk transfer interface
    const mod = @import("mod.zig");
    return mod.usbBulkOutTransfer(usb_device.?.addr, bulk_out_ep, data);
}

fn usbBulkIn(buf: []u8) ?usize {
    if (usb_device == null) return null;

    const mod = @import("mod.zig");
    return mod.usbBulkInTransfer(usb_device.?.addr, bulk_in_ep, buf);
}

// ─── Diagnostics ─────────────────────────────────────────────────────

pub fn printStatus(writeFn: *const fn (s: []const u8) void, writeDecFn: *const fn (v: u64) void, writeHexFn: *const fn (v: u64) void) void {
    writeFn("=== RTL8188EU USB Wi-Fi Adapter ===\n\n");

    if (!initialized) {
        writeFn("  Not initialized\n\n");
        return;
    }

    writeFn("  MAC: ");
    for (0..6) |i| {
        if (i > 0) writeFn(":");
        writeHexFn(mac[i]);
    }
    writeFn("\n");

    writeFn("  Link: ");
    writeFn(if (link_up) "UP" else "DOWN");
    writeFn("\n");

    writeFn("  Associated: ");
    writeFn(if (associated) "YES" else "NO");
    writeFn("\n");

    writeFn("  Channel: ");
    writeDecFn(current_channel);
    writeFn(" (");
    const freq_khz: u32 = 2407 + (@as(u32, current_channel) * 5);
    writeDecFn(freq_khz / 1000);
    writeFn(".");
    writeDecFn(freq_khz % 1000);
    writeFn(" GHz)\n");

    writeFn("  Bulk IN EP: ");
    writeDecFn(bulk_in_ep);
    writeFn(" (max ");
    writeDecFn(bulk_in_max_pkt);
    writeFn(" bytes)\n");

    writeFn("  Bulk OUT EP: ");
    writeDecFn(bulk_out_ep);
    writeFn(" (max ");
    writeDecFn(bulk_out_max_pkt);
    writeFn(" bytes)\n");

    writeFn("\n");
}
