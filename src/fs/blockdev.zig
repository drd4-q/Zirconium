const std = @import("std");

pub const SECTOR_SIZE: usize = 512;

pub const BlockDevice = struct {
    readFn: *const fn (self: *BlockDevice, sector: u64, buf: []u8) bool,
    writeFn: *const fn (self: *BlockDevice, sector: u64, buf: []const u8) bool,
    totalSectorsFn: *const fn (self: *BlockDevice) u64,
    name: [32]u8,
    sector_size: usize = SECTOR_SIZE,
};

pub var devices: [8]*BlockDevice = undefined;
pub var device_count: usize = 0;

pub fn register(dev: *BlockDevice) void {
    if (device_count < 8) {
        devices[device_count] = dev;
        device_count += 1;
    }
}

pub fn getDevice(index: usize) ?*BlockDevice {
    if (index < device_count) return devices[index];
    return null;
}

pub fn readSectors(dev: *BlockDevice, sector: u64, count: usize, buf: []u8) bool {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const offset = i * dev.sector_size;
        if (offset + dev.sector_size > buf.len) return false;
        if (!dev.readFn(dev, sector + @as(u64, @intCast(i)), buf[offset..][0..dev.sector_size])) {
            return false;
        }
    }
    return true;
}

pub fn writeSectors(dev: *BlockDevice, sector: u64, count: usize, buf: []const u8) bool {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const offset = i * dev.sector_size;
        if (offset + dev.sector_size > buf.len) return false;
        if (!dev.writeFn(dev, sector + @as(u64, @intCast(i)), buf[offset..][0..dev.sector_size])) {
            return false;
        }
    }
    return true;
}

pub fn totalSectors(dev: *BlockDevice) u64 {
    return dev.totalSectorsFn(dev);
}
