const std = @import("std");
const root = @import("root");
const port = root.serial;
const blockdev = @import("blockdev.zig");

pub const MAX_PARTITIONS: usize = 8;

pub const Partition = struct {
    parent_dev: *blockdev.BlockDevice,
    start_lba: u64,
    sector_count: u64,
    block_dev: blockdev.BlockDevice,
};

pub var partitions: [MAX_PARTITIONS]Partition = undefined;
pub var partition_count: usize = 0;

var sector_buf: [512]u8 align(16) = undefined;

fn readU16(buf: []const u8, off: usize) u16 {
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}

fn readU32(buf: []const u8, off: usize) u32 {
    return @as(u32, buf[off]) |
        (@as(u32, buf[off + 1]) << 8) |
        (@as(u32, buf[off + 2]) << 16) |
        (@as(u32, buf[off + 3]) << 24);
}

fn readU64(buf: []const u8, off: usize) u64 {
    const lo = @as(u64, readU32(buf, off));
    const hi = @as(u64, readU32(buf, off + 4));
    return (hi << 32) | lo;
}

fn readPartSector(dev: *blockdev.BlockDevice, sector: u64, buf: []u8) bool {
    const p = getPartitionFromDev(dev) orelse return false;
    if (sector >= p.sector_count) return false;
    return p.parent_dev.readFn(p.parent_dev, p.start_lba + sector, buf);
}

fn writePartSector(dev: *blockdev.BlockDevice, sector: u64, buf: []const u8) bool {
    const p = getPartitionFromDev(dev) orelse return false;
    if (sector >= p.sector_count) return false;
    return p.parent_dev.writeFn(p.parent_dev, p.start_lba + sector, buf);
}

fn totalPartSectors(dev: *blockdev.BlockDevice) u64 {
    const p = getPartitionFromDev(dev) orelse return 0;
    return p.sector_count;
}

fn getPartitionFromDev(dev: *blockdev.BlockDevice) ?*Partition {
    var i: usize = 0;
    while (i < partition_count) : (i += 1) {
        if (&partitions[i].block_dev == dev) return &partitions[i];
    }
    return null;
}

fn registerPartition(parent: *blockdev.BlockDevice, start_lba: u64, count: u64, part_num: usize) void {
    const parent_sectors = parent.totalSectorsFn(parent);
    if (count == 0 or start_lba >= parent_sectors) return;
    if (count > parent_sectors - start_lba) return;
    var existing: usize = 0;
    while (existing < partition_count) : (existing += 1) {
        const p = &partitions[existing];
        if (p.parent_dev == parent and p.start_lba == start_lba and p.sector_count == count) return;
    }
    if (partition_count >= MAX_PARTITIONS) return;

    const p = &partitions[partition_count];
    p.parent_dev = parent;
    p.start_lba = start_lba;
    p.sector_count = count;

    @memset(p.block_dev.name[0..], 0);
    const parent_name_len = std.mem.indexOfScalar(u8, &parent.name, 0) orelse parent.name.len;
    const p_len = @min(parent_name_len, 28);
    @memcpy(p.block_dev.name[0..p_len], parent.name[0..p_len]);
    p.block_dev.name[p_len] = 'p';
    p.block_dev.name[p_len + 1] = @intCast('1' + part_num);
    p.block_dev.sector_size = 512;
    p.block_dev.readFn = readPartSector;
    p.block_dev.writeFn = writePartSector;
    p.block_dev.totalSectorsFn = totalPartSectors;

    blockdev.register(&p.block_dev);

    port.serialWrite("[PART] Registered partition ");
    port.serialWrite(p.block_dev.name[0 .. p_len + 2]);
    port.serialWrite(" (LBA ");
    port.serialWriteDec(start_lba);
    port.serialWrite("..");
    port.serialWriteDec(start_lba + count);
    port.serialWrite(", ");
    port.serialWriteDec(count * 512 / (1024 * 1024));
    port.serialWrite(" MB)\n");

    partition_count += 1;
}

pub fn scanAll() void {
    const orig_dev_count = blockdev.device_count;
    var i: usize = 0;
    while (i < orig_dev_count) : (i += 1) {
        const dev = blockdev.devices[i];
        if (getPartitionFromDev(dev) != null) continue;
        scanDevice(dev);
    }
}

pub fn scanDevice(dev: *blockdev.BlockDevice) void {
    // Read MBR sector 0
    if (!dev.readFn(dev, 0, &sector_buf)) {
        return;
    }

    if (sector_buf[510] != 0x55 or sector_buf[511] != 0xAA) {
        return; // No valid MBR signature
    }

    // Check for Protective MBR (indicates GPT table)
    var is_gpt = false;
    var p_idx: usize = 0;
    while (p_idx < 4) : (p_idx += 1) {
        const entry_off = 446 + p_idx * 16;
        const part_type = sector_buf[entry_off + 4];
        if (part_type == 0xEE) {
            is_gpt = true;
            break;
        }
    }

    if (is_gpt) {
        scanGpt(dev);
    } else {
        scanMbr(dev);
    }
}

fn scanMbr(dev: *blockdev.BlockDevice) void {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const off = 446 + i * 16;
        const part_type = sector_buf[off + 4];
        const lba_start = readU32(&sector_buf, off + 8);
        const sector_count = readU32(&sector_buf, off + 12);

        if (part_type != 0 and sector_count > 0) {
            registerPartition(dev, lba_start, sector_count, i);
        }
    }
}

fn scanGpt(dev: *blockdev.BlockDevice) void {
    // Read GPT Header at LBA 1
    if (!dev.readFn(dev, 1, &sector_buf)) return;

    if (!std.mem.eql(u8, sector_buf[0..8], "EFI PART")) {
        return;
    }

    port.serialWrite("[GPT] Valid GPT header detected on device\n");

    const entry_lba = readU64(&sector_buf, 72);
    const num_entries = @min(readU32(&sector_buf, 80), 128);
    const entry_size = readU32(&sector_buf, 84);
    if (entry_size == 0 or entry_size > 512) return;

    var cur_entry: usize = 0;
    var cur_sector = entry_lba;

    while (cur_entry < num_entries) {
        if (!dev.readFn(dev, cur_sector, &sector_buf)) break;

        const entries_per_sector = 512 / entry_size;
        var s_idx: usize = 0;
        while (s_idx < entries_per_sector and cur_entry < num_entries) : (s_idx += 1) {
            const off = s_idx * entry_size;
            // Check if GUID is non-zero
            var guid_sum: u32 = 0;
            for (sector_buf[off .. off + 16]) |b| guid_sum += b;

            const start_lba = readU64(&sector_buf, off + 32);
            const end_lba = readU64(&sector_buf, off + 40);

            if (guid_sum > 0 and end_lba >= start_lba) {
                const count = end_lba - start_lba + 1;
                registerPartition(dev, start_lba, count, cur_entry);
            }
            cur_entry += 1;
        }
        cur_sector += 1;
    }
}
