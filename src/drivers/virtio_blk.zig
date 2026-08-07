const std = @import("std");
const root = @import("root");
const vga = root.vga;
const serial = @import("../system/serial.zig");
const pci = @import("pci.zig");
const blockdev = @import("../fs/blockdev.zig");
const kalloc = @import("../kernel/kalloc.zig");

const STATUS_ACK: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_FEATURES_OK: u32 = 8;
const STATUS_DRIVER_OK: u32 = 4;
const STATUS_FAILED: u32 = 128;

const VIRTQ_DESC_F_NEXT: u16 = 1;
const VIRTQ_DESC_F_WRITE: u16 = 2;

const VIRTIO_BLK_T_IN: u32 = 0;
const VIRTIO_BLK_T_OUT: u32 = 1;

const SECTOR_SIZE: usize = 512;
const QUEUE_SIZE: usize = 128;

// Virtio-blk I/O port offsets (legacy, no MSI-X)
const VIRTIO_PCI_HOST_FEATURES: u16 = 0;
const VIRTIO_PCI_GUEST_FEATURES: u16 = 4;
const VIRTIO_PCI_QUEUE_ADDR: u16 = 8;
const VIRTIO_PCI_QUEUE_SIZE: u16 = 12;
const VIRTIO_PCI_QUEUE_SELECT: u16 = 14;
const VIRTIO_PCI_QUEUE_NOTIFY: u16 = 16;
const VIRTIO_PCI_STATUS: u16 = 18;
const VIRTIO_PCI_ISR: u16 = 19;

// Legacy-transitional: config space at base + 20
const VIRTIO_PCI_CONFIG_OFFSET: u16 = 20;

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};

var io_base: u16 = 0;

// Descriptor table + available ring must be contiguous and page-aligned for legacy virtio
// Layout: [desc_table (16*QUEUE_SIZE)] [avail_ring (2+2+2*QUEUE_SIZE)] [padding to 4096] [used_ring]
var virtqueue_mem: [8192]u8 align(4096) = undefined;

var free_head: u16 = 0;
var num_sectors: u64 = 0;
var virtio_ready: bool = false;
var queue_size: u16 = 0;

var desc_table: [*]VirtqDesc = undefined;
var avail_ring_base: [*]u16 = undefined;
var used_ring_base: [*]u8 = undefined;

fn portIn16(addr: u16) u16 {
    return asm volatile ("inw %%dx, %%ax"
        : [result] "={ax}" (-> u16),
        : [port] "{dx}" (addr),
    );
}

fn portOut16(addr: u16, val: u16) void {
    asm volatile ("outw %%ax, %%dx"
        : : [val] "{ax}" (val), [port] "{dx}" (addr),
    );
}

fn portIn32(addr: u16) u32 {
    return asm volatile ("inl %%dx, %%eax"
        : [result] "={eax}" (-> u32),
        : [port] "{dx}" (addr),
    );
}

fn portOut32(addr: u16, val: u32) void {
    asm volatile ("outl %%eax, %%dx"
        : : [val] "{eax}" (val), [port] "{dx}" (addr),
    );
}

fn delayMs(ms: u32) void {
    var i: u32 = 0;
    while (i < ms) : (i += 1) {
        var j: u32 = 0;
        while (j < 10000) : (j += 1) {
            asm volatile ("nop");
        }
    }
}

fn allocDesc() ?u16 {
    if (free_head == 0xFFFF) return null;
    const idx = free_head;
    free_head = desc_table[idx].next;
    return idx;
}

fn freeDescChain(head: u16) void {
    var cur: u16 = head;
    while (true) {
        const next = desc_table[cur].next;
        const has_next = (desc_table[cur].flags & VIRTQ_DESC_F_NEXT) != 0;
        desc_table[cur].next = free_head;
        desc_table[cur].addr = 0;
        desc_table[cur].len = 0;
        desc_table[cur].flags = 0;
        free_head = cur;
        if (!has_next) break;
        cur = next;
    }
}

fn doIo(sector: u64, buf_ptr: [*]u8, buf_len: usize, is_write: bool) bool {
    if (buf_len == 0 or buf_len > SECTOR_SIZE) return false;

    const hdr_idx = allocDesc() orelse return false;
    const data_idx = allocDesc() orelse {
        freeDescChain(hdr_idx);
        return false;
    };
    const st_idx = allocDesc() orelse {
        freeDescChain(hdr_idx);
        freeDescChain(data_idx);
        return false;
    };

    if (data_idx >= REQ_BUF_SIZE) {
        freeDescChain(hdr_idx);
        freeDescChain(data_idx);
        freeDescChain(st_idx);
        return false;
    }

    // Use data_idx slot for all buffers (header + data + status packed together)
    const buf_base: [*]u8 = @ptrFromInt(@intFromPtr(&req_data[data_idx]));

    // Header at buf_base[0..16]
    @memset(buf_base[0..16], 0);
    const req_type: u32 = if (is_write) VIRTIO_BLK_T_OUT else VIRTIO_BLK_T_IN;
    buf_base[0] = @intCast(req_type & 0xFF);
    buf_base[4] = @intCast(sector & 0xFF);
    buf_base[5] = @intCast((sector >> 8) & 0xFF);
    buf_base[6] = @intCast((sector >> 16) & 0xFF);
    buf_base[7] = @intCast((sector >> 24) & 0xFF);
    buf_base[8] = @intCast((sector >> 32) & 0xFF);
    buf_base[9] = @intCast((sector >> 40) & 0xFF);
    buf_base[10] = @intCast((sector >> 48) & 0xFF);
    buf_base[11] = @intCast((sector >> 56) & 0xFF);

    // Status at buf_base[16+SECTOR_SIZE]
    buf_base[16 + SECTOR_SIZE] = 0;

    if (is_write) {
        @memcpy(buf_base[16..][0..SECTOR_SIZE], buf_ptr[0..@min(buf_len, SECTOR_SIZE)]);
    }

    desc_table[hdr_idx].addr = @intFromPtr(buf_base);
    desc_table[hdr_idx].len = 16;
    desc_table[hdr_idx].flags = VIRTQ_DESC_F_NEXT;
    desc_table[hdr_idx].next = data_idx;

    desc_table[data_idx].addr = @intFromPtr(buf_base + 16);
    desc_table[data_idx].len = SECTOR_SIZE;
    desc_table[data_idx].flags = VIRTQ_DESC_F_NEXT | (if (is_write) @as(u16, 0) else VIRTQ_DESC_F_WRITE);
    desc_table[data_idx].next = st_idx;

    desc_table[st_idx].addr = @intFromPtr(buf_base + 16 + SECTOR_SIZE);
    desc_table[st_idx].len = 1;
    desc_table[st_idx].flags = VIRTQ_DESC_F_WRITE;
    desc_table[st_idx].next = 0;

    // avail_ring layout: [flags:u16, idx:u16, ring:N*u16]
    const avail_idx_val = avail_ring_base[1]; // idx field
    avail_ring_base[2 + (avail_idx_val % queue_size)] = hdr_idx;
    // Write barrier: update idx AFTER writing ring entry
    avail_ring_base[1] = avail_idx_val +% 1;

    // Notify
    portOut16(io_base + VIRTIO_PCI_QUEUE_NOTIFY, 0);

    // Poll for completion
    // used_ring layout: [flags:u16, idx:u16, ring:N*VirtqUsedElem]
    const expected_used = avail_idx_val +% 1;
    var timeout: u32 = 0;
    while (timeout < 2000000) : (timeout += 1) {
        const used_idx_val: u16 = @as(*volatile u16, @ptrFromInt(@intFromPtr(used_ring_base) + 2)).*;
        if (used_idx_val == expected_used) {
            // Device has processed our request
            break;
        }
        asm volatile ("pause");
    }
    if (timeout >= 2000000) {
        freeDescChain(hdr_idx);
        return false;
    }

    freeDescChain(hdr_idx);

    if (buf_base[16 + SECTOR_SIZE] != 0) return false;

    if (!is_write) {
        @memcpy(buf_ptr[0..@min(buf_len, SECTOR_SIZE)], buf_base[16..][0..@min(buf_len, SECTOR_SIZE)]);
    }

    return true;
}

fn readSectors(_: *blockdev.BlockDevice, sector: u64, buf: []u8) bool {
    if (!virtio_ready) return false;
    var offset: usize = 0;
    while (offset < buf.len) : (offset += SECTOR_SIZE) {
        const to_read = @min(buf.len - offset, SECTOR_SIZE);
        const s = sector + @as(u64, @intCast(offset / SECTOR_SIZE));
        if (!doIo(s, buf[offset..].ptr, to_read, false)) return false;
    }
    return true;
}

fn writeSectors(_: *blockdev.BlockDevice, sector: u64, buf: []const u8) bool {
    if (!virtio_ready) return false;
    var offset: usize = 0;
    while (offset < buf.len) : (offset += SECTOR_SIZE) {
        const to_write = @min(buf.len - offset, SECTOR_SIZE);
        const s = sector + @as(u64, @intCast(offset / SECTOR_SIZE));
        if (!doIo(s, @constCast(buf[offset..].ptr), to_write, true)) return false;
    }
    return true;
}

fn totalSectorsFn(_: *blockdev.BlockDevice) u64 {
    return num_sectors;
}

pub fn init() void {
    const dev = pci.findByClass(0x01, 0x00) orelse {
        serial.serialWrite("[VIRTIO-BLK] No virtio-blk device found\n");
        return;
    };

    serial.serialWrite("[VIRTIO-BLK] Found device at PCI ");
    serial.serialWriteHex(@as(u64, dev.bus));
    serial.serialWrite(":");
    serial.serialWriteHex(@as(u64, dev.dev));
    serial.serialWrite("\n");

    // BAR0 is I/O port (bit 0 = 1)
    io_base = @intCast(dev.bar0 & 0xFFFC);
    serial.serialWrite("[VIRTIO-BLK] I/O base: 0x");
    serial.serialWriteHex(@as(u64, io_base));
    serial.serialWrite("\n");

    pci.enableBusMaster(dev.bus, dev.dev, dev.func);

    // Reset
    portOut32(io_base + VIRTIO_PCI_STATUS, 0);
    delayMs(1);

    // Acknowledge
    portOut32(io_base + VIRTIO_PCI_STATUS, STATUS_ACK);

    // Driver
    portOut32(io_base + VIRTIO_PCI_STATUS, STATUS_ACK | STATUS_DRIVER);

    // Read host features
    const host_features = portIn32(io_base + VIRTIO_PCI_HOST_FEATURES);
    serial.serialWrite("[VIRTIO-BLK] Host features: 0x");
    serial.serialWriteHex(@as(u64, host_features));
    serial.serialWrite("\n");

    // Write guest features (we accept what host offers, simplified)
    portOut32(io_base + VIRTIO_PCI_GUEST_FEATURES, host_features);

    // Select queue 0
    portOut16(io_base + VIRTIO_PCI_QUEUE_SELECT, 0);

    // Get queue size
    queue_size = portIn16(io_base + VIRTIO_PCI_QUEUE_SIZE);
    serial.serialWrite("[VIRTIO-BLK] Queue size: ");
    serial.serialWriteDec(@as(u64, queue_size));
    serial.serialWrite("\n");

    if (queue_size < 3) {
        serial.serialWrite("[VIRTIO-BLK] Queue too small\n");
        portOut32(io_base + VIRTIO_PCI_STATUS, STATUS_FAILED);
        return;
    }

    // Setup virtqueue memory layout:
    // [desc_table: 16*queue_size] [avail: 2+2+2*queue_size] [pad to 4KB] [used: 2+2+8*queue_size]
    const desc_bytes = @as(usize, queue_size) * @sizeOf(VirtqDesc);
    const avail_aligned = (desc_bytes + 4095) & ~@as(usize, 4095);
    const used_off = avail_aligned;

    desc_table = @as([*]VirtqDesc, @ptrFromInt(@intFromPtr(&virtqueue_mem)))[0..queue_size].ptr;
    avail_ring_base = @as([*]u16, @ptrFromInt(@intFromPtr(&virtqueue_mem[desc_bytes])));
    used_ring_base = @as([*]u8, @ptrFromInt(@intFromPtr(&virtqueue_mem[used_off])));

    // Zero the memory
    @memset(virtqueue_mem[0 .. used_off + 4 + @as(usize, queue_size) * @sizeOf(VirtqUsedElem)], 0);

    // Initialize free descriptor list
    var i: u16 = 0;
    while (i < queue_size - 1) : (i += 1) {
        desc_table[i].next = i + 1;
    }
    desc_table[queue_size - 1].next = 0xFFFF;
    free_head = 0;

    // Tell device the queue address (physical address / 4096)
    const queue_addr = @intFromPtr(&virtqueue_mem) / 4096;
    portOut32(io_base + VIRTIO_PCI_QUEUE_ADDR, @intCast(queue_addr));

    serial.serialWrite("[VIRTIO-BLK] Queue configured at page 0x");
    serial.serialWriteHex(queue_addr);
    serial.serialWrite("\n");

    // Set driver OK
    portOut32(io_base + VIRTIO_PCI_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);

    // Read capacity from config space (capacity is 8 bytes LE at config offset 0)
    const cfg_base = io_base + VIRTIO_PCI_CONFIG_OFFSET;
    const capacity_lo = portIn32(cfg_base);
    const capacity_hi = portIn32(cfg_base + 4);
    num_sectors = @as(u64, capacity_lo) | (@as(u64, capacity_hi) << 32);

    serial.serialWrite("[VIRTIO-BLK] Capacity: ");
    serial.serialWriteDec(num_sectors);
    serial.serialWrite(" sectors (");
    serial.serialWriteDec(num_sectors / 2);
    serial.serialWrite(" KB)\n");

    // Register block device
    const bd_ptr = kalloc.kmalloc(@sizeOf(blockdev.BlockDevice)) orelse {
        serial.serialWrite("[VIRTIO-BLK] Failed to alloc BlockDevice\n");
        return;
    };
    const bd: *blockdev.BlockDevice = @ptrFromInt(@intFromPtr(bd_ptr));
    bd.readFn = readSectors;
    bd.writeFn = writeSectors;
    bd.totalSectorsFn = totalSectorsFn;
    bd.sector_size = SECTOR_SIZE;
    @memset(&bd.name, 0);
    @memcpy(bd.name[0..10], "virtio-blk");

    blockdev.register(bd);
    virtio_ready = true;

    serial.serialWrite("[VIRTIO-BLK] Registered as block device\n");
    vga.setColor(.green, .black);
    vga.write("  [VIRTIO-BLK] Disk: ");
    vga.writeDec(num_sectors / 2);
    vga.write(" KB\n");
    vga.setColor(.white, .black);
}

const REQ_BUF_SIZE: usize = 256;
const REQ_ENTRY_SIZE: usize = 16 + SECTOR_SIZE + 1; // header + data + status
var req_data: [REQ_BUF_SIZE][REQ_ENTRY_SIZE]u8 align(16) = undefined;
