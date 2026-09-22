const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;
const pci = @import("pci.zig");

// Realtek RTL8169/8168/8111 register offsets (from Linux r8169_main.c)
const MAC0: u32 = 0x00;
const TxDescStartAddrLow: u32 = 0x20;
const TxDescStartAddrHigh: u32 = 0x24;
const ChipCmd: u32 = 0x37;
const TxPoll: u32 = 0x38;
const IntrMask: u32 = 0x3C;
const IntrStatus: u32 = 0x3E;
const TxConfig: u32 = 0x40;
const RxConfig: u32 = 0x44;
const Cfg9346: u32 = 0x50;
const RxMaxSize: u32 = 0xDA;
const CPlusCmd: u32 = 0xE0;
const RxDescAddrLow: u32 = 0xE4;
const RxDescAddrHigh: u32 = 0xE8;

// ChipCmd bits
const CmdReset: u8 = 0x10;
const CmdRxEnb: u8 = 0x08;
const CmdTxEnb: u8 = 0x04;

// Cfg9346 modes
const Cfg9346_Unlock: u8 = 0xC0;
const Cfg9346_Lock: u8 = 0x00;

// Descriptor flags (opts1)
const DESC_OWN: u32 = 1 << 31;
const DESC_EOR: u32 = 1 << 30;
const DESC_FS: u32 = 1 << 29;
const DESC_LS: u32 = 1 << 28;

const RX_DESC_COUNT: usize = 32;
const TX_DESC_COUNT: usize = 8;
const PKT_SIZE: usize = 2048;

const RxDesc = extern struct {
    opts1: u32,
    opts2: u32,
    addr: u64,
};

const TxDesc = extern struct {
    opts1: u32,
    opts2: u32,
    addr: u64,
};

var mmio_base: u64 = 0;
pub var initialized: bool = false;
pub var mac: [6]u8 = undefined;

var rx_ring: [RX_DESC_COUNT]RxDesc align(256) = undefined;
var tx_ring: [TX_DESC_COUNT]TxDesc align(256) = undefined;
var rx_bufs: [RX_DESC_COUNT][PKT_SIZE]u8 align(16) = undefined;
var tx_bufs: [TX_DESC_COUNT][PKT_SIZE]u8 align(16) = undefined;

var rx_cur: usize = 0;
var tx_cur: usize = 0;

fn mmioRead8(offset: u32) u8 {
    const ptr: *volatile u8 = @ptrFromInt(mmio_base + @as(u64, offset));
    return ptr.*;
}

fn mmioRead16(offset: u32) u16 {
    const ptr: *volatile u16 = @ptrFromInt(mmio_base + @as(u64, offset));
    return ptr.*;
}

fn mmioRead32(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + @as(u64, offset));
    return ptr.*;
}

fn mmioWrite8(offset: u32, val: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(mmio_base + @as(u64, offset));
    ptr.* = val;
}

fn mmioWrite16(offset: u32, val: u16) void {
    const ptr: *volatile u16 = @ptrFromInt(mmio_base + @as(u64, offset));
    ptr.* = val;
}

fn mmioWrite32(offset: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(mmio_base + @as(u64, offset));
    ptr.* = val;
}

pub fn isRealtekNic(vendor_id: u16, device_id: u16) bool {
    if (vendor_id != 0x10EC) return false;
    return switch (device_id) {
        0x8169, 0x8168, 0x8167, 0x8111, 0x8101, 0x8136, 0x8125, 0x8139, 0x8161 => true,
        else => false,
    };
}

pub fn init(dev: *pci.PciDevice) bool {
    if (!isRealtekNic(dev.vendor_id, dev.device_id)) {
        return false;
    }

    port.serialWrite("[RTL8169] Found Realtek NIC 0x10EC:0x");
    port.serialWriteHex(dev.device_id);
    port.serialWrite("\n");

    // Enable Bus Mastering and MMIO
    pci.enableBusMaster(dev.bus, dev.dev, dev.func);

    // BAR2 is standard 64-bit MMIO for PCIe 8168/8111, BAR1 for PCI 8169, fallback to BAR0.
    // All of these can be 64-bit BARs placed above 4GB on real hardware:
    // combine both halves instead of truncating to 32 bits (which would alias RAM).
    // BARs at/above the 64GB boot identity map are unusable: skip them.
    mmio_base = 0;
    const IDENTITY_LIMIT: u64 = 0x1000000000; // 64GB boot map
    var bar_i: u8 = 2;
    while (true) {
        const reg: u8 = @intCast(0x10 + @as(u16, bar_i) * 4);
        const lo = pci.readConfig(dev.bus, dev.dev, dev.func, reg);
        if (lo != 0 and lo != 0xFFFFFFFF and (lo & 1) == 0) {
            if ((lo & 0x06) == 0x04) {
                const hi = pci.readConfig(dev.bus, dev.dev, dev.func, reg + 4);
                const full = (@as(u64, hi) << 32) | (@as(u64, lo) & 0xFFFFFFF0);
                if (full != 0 and full != 0xFFFFFFFFFFFFFFFF and full < IDENTITY_LIMIT) {
                    mmio_base = full;
                    break;
                }
            } else if ((lo & 0xFFFFFFF0) != 0) {
                const base = @as(u64, lo & 0xFFFFFFF0);
                if (base < IDENTITY_LIMIT) {
                    mmio_base = base;
                    break;
                }
            }
        }
        if (bar_i == 2) {
            bar_i = 1;
        } else if (bar_i == 1) {
            bar_i = 0;
        } else {
            break;
        }
    }
    if (mmio_base == 0) {
        port.serialWrite("[RTL8169] Error: no MMIO BAR found\n");
        return false;
    }

    port.serialWrite("[RTL8169] MMIO base: 0x");
    port.serialWriteHex(mmio_base);
    port.serialWrite("\n");

    // Unlock config registers
    mmioWrite8(Cfg9346, Cfg9346_Unlock);

    // Software reset
    mmioWrite8(ChipCmd, CmdReset);
    var reset_timeout: u32 = 0;
    while ((mmioRead8(ChipCmd) & CmdReset) != 0 and reset_timeout < 100_000) : (reset_timeout += 1) {
        asm volatile ("pause");
    }

    // Read MAC address from MAC0..MAC5
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        mac[i] = mmioRead8(MAC0 + @as(u32, @intCast(i)));
    }

    port.serialWrite("[RTL8169] MAC: ");
    printMac();
    port.serialWrite("\n");

    // Setup RX descriptors
    rx_cur = 0;
    i = 0;
    while (i < RX_DESC_COUNT) : (i += 1) {
        var opts: u32 = DESC_OWN | @as(u32, @intCast(PKT_SIZE));
        if (i == RX_DESC_COUNT - 1) opts |= DESC_EOR;
        rx_ring[i] = .{
            .opts1 = opts,
            .opts2 = 0,
            .addr = @intFromPtr(&rx_bufs[i]),
        };
    }

    // Setup TX descriptors
    tx_cur = 0;
    i = 0;
    while (i < TX_DESC_COUNT) : (i += 1) {
        var opts: u32 = 0;
        if (i == TX_DESC_COUNT - 1) opts |= DESC_EOR;
        tx_ring[i] = .{
            .opts1 = opts,
            .opts2 = 0,
            .addr = @intFromPtr(&tx_bufs[i]),
        };
    }

    // Mask all interrupts (polling mode)
    mmioWrite16(IntrMask, 0x0000);
    _ = mmioRead16(IntrStatus);

    // Set descriptor ring addresses
    const rx_ring_phys = @intFromPtr(&rx_ring);
    const tx_ring_phys = @intFromPtr(&tx_ring);
    mmioWrite32(RxDescAddrLow, @intCast(rx_ring_phys & 0xFFFFFFFF));
    mmioWrite32(RxDescAddrHigh, @intCast((rx_ring_phys >> 32) & 0xFFFFFFFF));
    mmioWrite32(TxDescStartAddrLow, @intCast(tx_ring_phys & 0xFFFFFFFF));
    mmioWrite32(TxDescStartAddrHigh, @intCast((tx_ring_phys >> 32) & 0xFFFFFFFF));

    // Configure Rx Max Size (1536)
    mmioWrite16(RxMaxSize, 1536);

    // Configure Tx/Rx (Max DMA burst 7 << 8, Rx FIFO 7 << 13, Accept Physical/Multicast/Broadcast)
    mmioWrite32(TxConfig, (7 << 8) | (3 << 24));
    mmioWrite32(RxConfig, (7 << 8) | (7 << 13) | 0x0F);

    // Enable CPlus features (Rx Checksum offload + Dual Address)
    mmioWrite16(CPlusCmd, 0x0020);

    // Enable RX and TX
    mmioWrite8(ChipCmd, CmdRxEnb | CmdTxEnb);

    // Lock config registers
    mmioWrite8(Cfg9346, Cfg9346_Lock);

    initialized = true;
    port.serialWrite("[RTL8169] Driver initialized successfully\n");
    return true;
}

pub fn transmit(data: []const u8) void {
    if (!initialized or mmio_base == 0) return;
    if (data.len == 0 or data.len > PKT_SIZE) return;

    const idx = tx_cur;
    // Wait if descriptor is currently owned by hardware
    var spins: u32 = 0;
    while ((tx_ring[idx].opts1 & DESC_OWN) != 0 and spins < 1_000_000) : (spins += 1) {
        asm volatile ("pause");
    }

    const copy_len = @min(data.len, PKT_SIZE);
    @memcpy(tx_bufs[idx][0..copy_len], data[0..copy_len]);

    var opts: u32 = DESC_OWN | DESC_FS | DESC_LS | @as(u32, @intCast(copy_len));
    if (idx == TX_DESC_COUNT - 1) opts |= DESC_EOR;

    tx_ring[idx].opts2 = 0;
    tx_ring[idx].addr = @intFromPtr(&tx_bufs[idx]);
    tx_ring[idx].opts1 = opts;

    // Trigger normal priority TX poll
    mmioWrite8(TxPoll, 0x40);

    tx_cur = (tx_cur + 1) % TX_DESC_COUNT;
}

pub fn receive(buf: []u8) ?usize {
    if (!initialized or mmio_base == 0) return null;

    const idx = rx_cur;
    const opts = rx_ring[idx].opts1;

    // If OWN bit is set, hardware still owns descriptor (no packet ready)
    if ((opts & DESC_OWN) != 0) {
        return null;
    }

    const len = @as(usize, @intCast(opts & 0x3FFF));
    if (len > 4) { // Realtek includes 4-byte CRC at the end
        const data_len = len - 4;
        const copy_len = @min(data_len, buf.len);
        @memcpy(buf[0..copy_len], rx_bufs[idx][0..copy_len]);

        // Hand descriptor back to hardware
        var new_opts: u32 = DESC_OWN | @as(u32, @intCast(PKT_SIZE));
        if (idx == RX_DESC_COUNT - 1) new_opts |= DESC_EOR;
        rx_ring[idx].opts2 = 0;
        rx_ring[idx].addr = @intFromPtr(&rx_bufs[idx]);
        rx_ring[idx].opts1 = new_opts;

        rx_cur = (rx_cur + 1) % RX_DESC_COUNT;
        return copy_len;
    }

    // Reset corrupted/short descriptor
    var reset_opts: u32 = DESC_OWN | @as(u32, @intCast(PKT_SIZE));
    if (idx == RX_DESC_COUNT - 1) reset_opts |= DESC_EOR;
    rx_ring[idx].opts1 = reset_opts;
    rx_cur = (rx_cur + 1) % RX_DESC_COUNT;
    return null;
}

pub fn printMac() void {
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        if (i > 0) port.serialWrite(":");
        const h = "0123456789ABCDEF";
        port.serialWrite(&[_]u8{ h[mac[i] >> 4], h[mac[i] & 0xF] });
    }
}
