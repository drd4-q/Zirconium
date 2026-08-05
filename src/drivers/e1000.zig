const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;
const pci = @import("pci.zig");

const CTRL: u32 = 0x0000;
const STATUS: u32 = 0x0008;
const RCTL: u32 = 0x0100;
const TCTL: u32 = 0x0400;
const ICR: u32 = 0x00C0;
const IMS: u32 = 0x00D0;
const RDBAL: u32 = 0x02800;
const RDBAH: u32 = 0x02804;
const RDLEN: u32 = 0x02808;
const RDH: u32 = 0x02810;
const RDT: u32 = 0x02818;
const TDBAL: u32 = 0x03800;
const TDBAH: u32 = 0x03804;
const TDLEN: u32 = 0x03808;
const TDH: u32 = 0x03810;
const TDT: u32 = 0x03818;
const RAL: u32 = 0x05400;
const RAH: u32 = 0x05404;
const RLPML: u32 = 0x05004;
const RFCTL: u32 = 0x05008;
const EERD: u32 = 0x00014;

const RX_DESC_COUNT: u32 = 32;
const TX_DESC_COUNT: u32 = 8;
const PKT_SIZE: usize = 2048;

var mmio_base: u64 = 0;

// Descriptor rings must be 16-byte aligned, placed in a static buffer
const RxDesc = struct {
    addr: u64,
    length: u16,
    checksum: u16,
    status: u16,
    special: u16,
};

const TxDesc = struct {
    addr: u64,
    length: u16,
    cso: u8,
    cmd: u8,
    status: u8,
    css: u8,
    special: u16,
};

var rx_ring: [RX_DESC_COUNT]RxDesc align(16) = undefined;
var tx_ring: [TX_DESC_COUNT]TxDesc align(16) = undefined;
var rx_bufs: [RX_DESC_COUNT][PKT_SIZE]u8 align(16) = undefined;
var tx_bufs: [TX_DESC_COUNT][PKT_SIZE]u8 align(16) = undefined;
var rx_cur: u32 = 0;
var tx_cur: u32 = 0;
pub var mac: [6]u8 = undefined;

fn mmioRead(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + @as(u64, offset));
    return ptr.*;
}

fn mmioWrite(offset: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + @as(u64, offset));
    ptr.* = val;
}

fn delay() void {
    var i: u32 = 0;
    while (i < 100000) : (i += 1) {
        asm volatile ("nop");
    }
}

fn delayMs(ms: u32) void {
    var i: u32 = 0;
    while (i < ms) : (i += 1) {
        var j: u32 = 0;
        while (j < 1000) : (j += 1) {
            asm volatile ("nop");
        }
    }
}

fn readEeprom(addr: u32) u16 {
    mmioWrite(EERD, (addr << 2) | 0x01);
    var timeout: u32 = 0;
    while (timeout < 10000) : (timeout += 1) {
        const val = mmioRead(EERD);
        if ((val & 0x10) != 0) {
            return @intCast((val >> 16) & 0xFFFF);
        }
    }
    return 0;
}

pub fn init(dev: *pci.PciDevice) bool {
    mmio_base = @as(u64, dev.bar0 & 0xFFFFFFF0);
    port.serialWrite("[E1000] MMIO base: 0x");
    port.serialWriteHex(mmio_base);
    port.serialWrite("\n");

    pci.enableBusMaster(dev.bus, dev.dev, dev.func);

    // Mask all interrupts first
    mmioWrite(IMS, 0x00000000);

    // Clear any pending interrupts
    _ = mmioRead(ICR);

    // Disable RX and TX
    mmioWrite(RCTL, 0);
    mmioWrite(TCTL, 0);

    // Reset the device
    mmioWrite(CTRL, 0x04000000);
    delayMs(5);

    // Wait for reset to complete
    var timeout: u32 = 0;
    while ((mmioRead(STATUS) & 0x100) != 0 and timeout < 100) : (timeout += 1) {
        delayMs(1);
    }
    port.serialWrite("[E1000] Reset complete\n");

    // Try reading MAC from EEPROM
    const w0 = readEeprom(0);
    const w1 = readEeprom(1);
    const w2 = readEeprom(2);

    if (w0 != 0 or w1 != 0 or w2 != 0) {
        mac[0] = @intCast(w0 & 0xFF);
        mac[1] = @intCast((w0 >> 8) & 0xFF);
        mac[2] = @intCast(w1 & 0xFF);
        mac[3] = @intCast((w1 >> 8) & 0xFF);
        mac[4] = @intCast(w2 & 0xFF);
        mac[5] = @intCast((w2 >> 8) & 0xFF);
        port.serialWrite("[E1000] MAC from EEPROM\n");
    } else {
        // QEMU default e1000 MAC
        mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
        port.serialWrite("[E1000] MAC hardcoded (QEMU default)\n");
    }

    // Set link up
    mmioWrite(CTRL, mmioRead(CTRL) | 0x40);
    delayMs(50);

    port.serialWrite("[E1000] MAC: ");
    printMac();
    port.serialWrite("\n");

    // Set RAL/RAH from MAC
    const ral_val: u32 = @intCast(@as(u32, mac[0]) | (@as(u32, mac[1]) << 8) | (@as(u32, mac[2]) << 16) | (@as(u32, mac[3]) << 24));
    const rah_val: u32 = @intCast(@as(u32, mac[4]) | (@as(u32, mac[5]) << 8));
    mmioWrite(RAL, ral_val);
    mmioWrite(RAH, rah_val | 0x80000000); // Address valid

    // Set link up
    mmioWrite(CTRL, mmioRead(CTRL) | 0x40);
    delayMs(50);

    port.serialWrite("[E1000] Setting up RX\n");
    setupRx();
    port.serialWrite("[E1000] Setting up TX\n");
    setupTx();

    // Configure RX: enable, broadcast, no CRC strip, BSIZE=2048
    mmioWrite(RCTL, 0x00000040 | // BSIZE=2048
        0x00000008 | // BAM (broadcast accept)
        0x02000000 | // SECRC (strip ethernet CRC)
        0x00000002); // EN (enable RX)

    // Configure TX: enable, collision default
    mmioWrite(TCTL, 0x00000002 | // EN (enable TX)
        (0x0F << 12)); // COLD=0x0F (collision distance)

    // Enable interrupts for RX
    mmioWrite(IMS, 0x80); // RXDW - RX descriptor written

    port.serialWrite("[E1000] Init complete, link up\n");
    return true;
}

fn setupRx() void {
    var i: u32 = 0;
    while (i < RX_DESC_COUNT) : (i += 1) {
        rx_ring[i].addr = @intFromPtr(&rx_bufs[@as(usize, @intCast(i))]);
        rx_ring[i].length = 0;
        rx_ring[i].checksum = 0;
        rx_ring[i].status = 0;
        rx_ring[i].special = 0;
    }

    rx_cur = 0;

    const ring_addr = @intFromPtr(&rx_ring);
    mmioWrite(RDBAL, @intCast(ring_addr & 0xFFFFFFFF));
    mmioWrite(RDBAH, @intCast(ring_addr >> 32));
    mmioWrite(RDLEN, RX_DESC_COUNT * @sizeOf(RxDesc));
    mmioWrite(RDH, 0);
    mmioWrite(RDT, RX_DESC_COUNT - 1);

    port.serialWrite("[E1000] RX ring at 0x");
    port.serialWriteHex(ring_addr);
    port.serialWrite("\n");
}

fn setupTx() void {
    var i: u32 = 0;
    while (i < TX_DESC_COUNT) : (i += 1) {
        tx_ring[i].addr = @intFromPtr(&tx_bufs[@as(usize, @intCast(i))]);
        tx_ring[i].length = 0;
        tx_ring[i].cso = 0;
        tx_ring[i].cmd = 0;
        tx_ring[i].status = 0;
        tx_ring[i].css = 0;
        tx_ring[i].special = 0;
    }

    tx_cur = 0;

    const ring_addr = @intFromPtr(&tx_ring);
    mmioWrite(TDBAL, @intCast(ring_addr & 0xFFFFFFFF));
    mmioWrite(TDBAH, @intCast(ring_addr >> 32));
    mmioWrite(TDLEN, TX_DESC_COUNT * @sizeOf(TxDesc));
    mmioWrite(TDH, 0);
    mmioWrite(TDT, 0);

    port.serialWrite("[E1000] TX ring at 0x");
    port.serialWriteHex(ring_addr);
    port.serialWrite("\n");
}

pub fn transmit(data: []const u8) void {
    const len = @min(data.len, PKT_SIZE);
    @memcpy(tx_bufs[tx_cur][0..len], data[0..len]);

    tx_ring[tx_cur].addr = @intFromPtr(&tx_bufs[tx_cur]);
    tx_ring[tx_cur].length = @intCast(len);
    tx_ring[tx_cur].cmd = 0x03; // EOP + IFCS
    tx_ring[tx_cur].status = 0;
    tx_ring[tx_cur].cso = 0;

    const new_tail = (tx_cur + 1) % TX_DESC_COUNT;
    mmioWrite(TDT, new_tail);
    tx_cur = new_tail;

    // Wait for transmit to complete
    var t: u32 = 0;
    while (t < 10000) : (t += 1) {
        asm volatile ("nop");
    }
}

pub fn receive(buf: []u8) ?usize {
    const status = rx_ring[rx_cur].status;
    if (status & 0x01 == 0) {
        return null;
    }

    const len = @as(usize, rx_ring[rx_cur].length);
    const copy_len = @min(len, buf.len);
    @memcpy(buf[0..copy_len], rx_bufs[@as(usize, @intCast(rx_cur))][0..copy_len]);

    // Reset descriptor
    rx_ring[rx_cur].status = 0;
    rx_ring[rx_cur].length = 0;
    rx_ring[rx_cur].addr = @intFromPtr(&rx_bufs[@as(usize, @intCast(rx_cur))]);

    rx_cur = (rx_cur + 1) % RX_DESC_COUNT;
    mmioWrite(RDT, rx_cur);

    return copy_len;
}

pub fn printMac() void {
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        if (i > 0) port.serialWrite(":");
        const h = "0123456789ABCDEF";
        port.serialWrite(&[_]u8{ h[mac[i] >> 4], h[mac[i] & 0xF] });
    }
}

pub fn printMacVga() void {
    const h = "0123456789ABCDEF";
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        if (i > 0) vga.putChar(':');
        vga.putChar(h[mac[i] >> 4]);
        vga.putChar(h[mac[i] & 0xF]);
    }
}
