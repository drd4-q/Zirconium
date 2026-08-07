const std = @import("std");
const root = @import("root");
const vga = root.vga;
const serial = @import("../system/serial.zig");
const blockdev = @import("../fs/blockdev.zig");
const vfs = @import("../fs/vfs.zig");

const SECTOR_SIZE: usize = 512;
const MAX_FAT16_FILES: usize = 128;
const MAX_PATH_LEN: usize = 64;

const Fat16BootSector = struct {
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    num_fats: u8,
    root_entry_count: u16,
    total_sectors_16: u16,
    media_type: u8,
    fat_size_sectors: u16,
    sectors_per_track: u16,
    num_heads: u16,
    hidden_sectors: u32,
    total_sectors_32: u32,
};

const Fat16DirEntry = extern struct {
    name: [8]u8,
    ext: [3]u8,
    attributes: u8,
    _reserved: u8,
    create_time_tenth: u8,
    create_time: u16,
    create_date: u16,
    access_date: u16,
    first_cluster_high: u16,
    modify_time: u16,
    modify_date: u16,
    first_cluster_low: u16,
    file_size: u32,
};

const FileInfo = struct {
    name: [MAX_PATH_LEN]u8,
    name_len: usize,
    is_dir: bool,
    first_cluster: u16,
    file_size: u32,
    used: bool = false,
};

var boot_sector: Fat16BootSector = undefined;
var fat_start_sector: u64 = 0;
var root_dir_start: u64 = 0;
var data_start: u64 = 0;
var fat_dev: ?*blockdev.BlockDevice = null;
var fs_mounted: bool = false;

var file_cache: [MAX_FAT16_FILES]FileInfo = undefined;
var file_count: usize = 0;

fn readSector(sector: u64, buf: *[SECTOR_SIZE]u8) bool {
    const dev = fat_dev orelse return false;
    return blockdev.readSectors(dev, sector, 1, buf);
}

fn clusterToSector(cluster: u16) u64 {
    if (cluster == 0) return root_dir_start; // root directory
    return data_start + @as(u64, cluster - 2) * boot_sector.sectors_per_cluster;
}

fn nextCluster(cluster: u16) ?u16 {
    var buf: [SECTOR_SIZE]u8 = undefined;
    const fat_offset = @as(u64, cluster) * 2;
    const fat_sector = fat_start_sector + (fat_offset / SECTOR_SIZE);
    const entry_offset = fat_offset % SECTOR_SIZE;

    if (!readSector(fat_sector, &buf)) return null;

    const val = @as(u16, buf[entry_offset]) | (@as(u16, buf[entry_offset + 1]) << 8);
    if (val >= 0x0002 and val < 0xFFF8) return val;
    return null;
}

fn readClusterChain(cluster: u16, out: []u8) usize {
    var buf: [SECTOR_SIZE]u8 = undefined;
    var current = cluster;
    var written: usize = 0;

    while (written < out.len) {
        const sector = clusterToSector(current);
        var s: u8 = 0;
        while (s < boot_sector.sectors_per_cluster and written < out.len) : (s += 1) {
            if (!readSector(sector + @as(u64, s), &buf)) break;
            const copy_len = @min(out.len - written, SECTOR_SIZE);
            @memcpy(out[written..][0..copy_len], buf[0..copy_len]);
            written += copy_len;
        }
        current = nextCluster(current) orelse break;
    }
    return written;
}

fn readDirEntries(cluster: u16, entries: []Fat16DirEntry) usize {
    var buf: [SECTOR_SIZE]u8 = undefined;
    var count: usize = 0;

    if (cluster == 0) {
        // Root directory: fixed location, fixed number of entries
        const root_sectors = (@as(u64, boot_sector.root_entry_count) * 32 + SECTOR_SIZE - 1) / SECTOR_SIZE;
        var sec: u64 = 0;
        while (sec < root_sectors and count < entries.len) : (sec += 1) {
            if (!readSector(root_dir_start + sec, &buf)) break;
            var e: usize = 0;
            while (e < SECTOR_SIZE / 32 and count < entries.len) : (e += 1) {
                const entry: *const Fat16DirEntry = @ptrFromInt(@intFromPtr(&buf[e * 32]));
                entries[count] = entry.*;
                count += 1;
                if (entry.name[0] == 0x00) return count;
            }
        }
        return count;
    }

    // Subdirectory: follow cluster chain
    var current = cluster;
    while (count < entries.len) {
        const sector = clusterToSector(current);
        var s: u8 = 0;
        while (s < boot_sector.sectors_per_cluster) : (s += 1) {
            if (!readSector(sector + @as(u64, s), &buf)) break;
            var e: usize = 0;
            while (e < SECTOR_SIZE / 32 and count < entries.len) : (e += 1) {
                const entry: *const Fat16DirEntry = @ptrFromInt(@intFromPtr(&buf[e * 32]));
                entries[count] = entry.*;
                count += 1;
                if (entry.name[0] == 0x00) return count;
            }
        }
        current = nextCluster(current) orelse break;
    }
    return count;
}

fn buildFullName(entry: *const Fat16DirEntry, out: []u8) usize {
    var pos: usize = 0;

    // Copy name (strip trailing spaces)
    var i: usize = 0;
    while (i < 8 and entry.name[i] != ' ' and entry.name[i] != 0) : (i += 1) {
        if (pos < out.len) {
            out[pos] = entry.name[i];
            if (entry.attributes & 0x10 != 0) {
                // directory — lowercase for display
                if (out[pos] >= 'A' and out[pos] <= 'Z') out[pos] += 32;
            }
            pos += 1;
        }
    }

    // Extension
    if (entry.ext[0] != ' ' and entry.ext[0] != 0) {
        if (pos < out.len) {
            out[pos] = '.';
            pos += 1;
        }
        i = 0;
        while (i < 3 and entry.ext[i] != ' ' and entry.ext[i] != 0) : (i += 1) {
            if (pos < out.len) {
                out[pos] = entry.ext[i];
                if (out[pos] >= 'A' and out[pos] <= 'Z') out[pos] += 32;
                pos += 1;
            }
        }
    }

    return pos;
}

fn matchName(name: []const u8, entry: *const Fat16DirEntry) bool {
    var full: [13]u8 = undefined;
    const len = buildFullName(entry, &full);
    if (len != name.len) return false;
    for (name, full[0..len]) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn findInDir(cluster: u16, name: []const u8) ?Fat16DirEntry {
    var entries: [32]Fat16DirEntry = undefined;
    const count = readDirEntries(cluster, &entries);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (entries[i].name[0] == 0x00) break;
        if (entries[i].name[0] == 0xE5) continue;
        if (entries[i].attributes & 0x08 != 0) continue; // volume label
        if (matchName(name, &entries[i])) return entries[i];
    }
    return null;
}

// Resolve path like "/subdir/file.txt" to its directory cluster and filename
fn resolvePathComponents(path: []const u8, out_name: []u8) ?struct { dir_cluster: u16, name_len: usize } {
    if (path.len == 0 or path[0] != '/') return null;

    var dir_cluster: u16 = 0; // root

    var start: usize = 1;
    while (start < path.len) {
        var end = start;
        while (end < path.len and path[end] != '/') : (end += 1) {
            if (end - start >= 13) return null;
        }

        if (end == start) {
            start = end + 1;
            continue;
        }

        const comp = path[start..end];

        // If this is the last component, return it as the filename
        if (end >= path.len) {
            var i: usize = 0;
            while (i < comp.len and i < out_name.len) : (i += 1) {
                out_name[i] = comp[i];
            }
            return .{ .dir_cluster = dir_cluster, .name_len = comp.len };
        }

        // Otherwise it's a directory component — traverse
        if (dir_cluster == 0) {
            // Searching root directory
            var entries: [32]Fat16DirEntry = undefined;
            const count = readDirEntries(0, &entries);
            var found = false;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (entries[i].name[0] == 0x00) break;
                if (entries[i].name[0] == 0xE5) continue;
                if (entries[i].attributes & 0x10 == 0) continue; // not a dir
                if (matchName(comp, &entries[i])) {
                    dir_cluster = entries[i].first_cluster_low;
                    found = true;
                    break;
                }
            }
            if (!found) return null;
        } else {
            const entry = findInDir(dir_cluster, comp) orelse return null;
            if (entry.attributes & 0x10 == 0) return null; // not a dir
            dir_cluster = entry.first_cluster_low;
        }

        start = end + 1;
    }

    return null;
}

// VFS interface

var root_handle: vfs.FileHandle = undefined;
var open_handles: [32]vfs.FileHandle = undefined;
var open_handle_used: [32]bool = [_]bool{false} ** 32;

fn fat16Open(fs: *vfs.FileSystem, path: []const u8, flags: vfs.OpenFlags) ?*vfs.FileHandle {
    if (path.len <= 1) {
        // Root directory
        if (flags.create) return null;
        root_handle = .{ .fs = fs, .inode = 0, .offset = 0, .flags = flags, .data = null };
        return &root_handle;
    }

    var name_buf: [13]u8 = undefined;
    const resolved = resolvePathComponents(path, &name_buf) orelse return null;

    const entry = findInDir(resolved.dir_cluster, name_buf[0..resolved.name_len]) orelse {
        if (flags.create) {
            return null; // TODO: create file
        }
        return null;
    };

    const idx = file_count;
    if (idx >= MAX_FAT16_FILES) return null;

    file_cache[idx] = .{
        .name = undefined,
        .name_len = buildFullName(&entry, &file_cache[idx].name),
        .is_dir = entry.attributes & 0x10 != 0,
        .first_cluster = entry.first_cluster_low,
        .file_size = entry.file_size,
        .used = true,
    };
    file_count += 1;

    // Find free handle slot
    var h: usize = 0;
    while (h < 32) : (h += 1) {
        if (!open_handle_used[h]) {
            open_handles[h] = .{ .fs = fs, .inode = idx, .offset = 0, .flags = flags, .data = null };
            open_handle_used[h] = true;
            return &open_handles[h];
        }
    }
    return null;
}

fn fat16Close(fs: *vfs.FileSystem, handle: *vfs.FileHandle) void {
    _ = fs;
    _ = handle;
}

fn fat16Read(fs: *vfs.FileSystem, handle: *vfs.FileHandle, buf: []u8) usize {
    _ = fs;
    if (handle.inode >= file_count) return 0;
    const fi = &file_cache[handle.inode];
    if (fi.is_dir or fi.file_size == 0) return 0;

    const remaining = fi.file_size - @as(u32, @intCast(handle.offset));
    const to_read = @min(buf.len, @as(usize, @intCast(remaining)));
    if (to_read == 0) return 0;

    // Read full clusters then copy relevant portion
    var cluster_buf: [4096]u8 = undefined;
    var current = fi.first_cluster;
    var offset: u64 = 0;

    while (offset < handle.offset + to_read and current != 0) {
        const cluster_size = @as(u64, boot_sector.sectors_per_cluster) * SECTOR_SIZE;
        const read = readClusterChain(current, cluster_buf[0..@min(cluster_size, 4096)]);

        if (handle.offset >= offset and handle.offset < offset + read) {
            const start_in_cluster = handle.offset - offset;
            const copy_from = start_in_cluster;
            const copy_len = @min(to_read, read - start_in_cluster);
            @memcpy(buf[0..copy_len], cluster_buf[copy_from..][0..copy_len]);
            handle.offset += copy_len;
            return copy_len;
        }

        offset += read;
        current = nextCluster(current) orelse break;
    }
    return 0;
}

fn fat16Write(fs: *vfs.FileSystem, handle: *vfs.FileHandle, buf: []const u8) usize {
    _ = fs;
    _ = handle;
    _ = buf;
    return 0; // read-only for now
}

fn fat16Readdir(fs: *vfs.FileSystem, path: []const u8, entries: []vfs.DirEntry) usize {
    _ = fs;

    var dir_cluster: u16 = 0; // root

    if (path.len > 1) {
        var name_buf: [13]u8 = undefined;
        const resolved = resolvePathComponents(path, &name_buf) orelse return 0;

        const entry = findInDir(resolved.dir_cluster, name_buf[0..resolved.name_len]) orelse return 0;
        if (entry.attributes & 0x10 == 0) return 0;
        dir_cluster = entry.first_cluster_low;
    }

    var fat_entries: [32]Fat16DirEntry = undefined;
    const count = readDirEntries(dir_cluster, &fat_entries);

    var out_count: usize = 0;
    var i: usize = 0;
    while (i < count and out_count < entries.len) : (i += 1) {
        if (fat_entries[i].name[0] == 0x00) break;
        if (fat_entries[i].name[0] == 0xE5) continue;
        if (fat_entries[i].attributes & 0x08 != 0) continue; // volume label

        const name_len = buildFullName(&fat_entries[i], &entries[out_count].name);
        entries[out_count].name_len = name_len;
        entries[out_count].file_type = if (fat_entries[i].attributes & 0x10 != 0) .directory else .file;
        entries[out_count].size = fat_entries[i].file_size;
        out_count += 1;
    }

    return out_count;
}

fn fat16Mkdir(fs: *vfs.FileSystem, path: []const u8) bool {
    _ = fs;
    _ = path;
    return false; // read-only
}

fn fat16Unlink(fs: *vfs.FileSystem, path: []const u8) bool {
    _ = fs;
    _ = path;
    return false; // read-only
}

fn fat16Stat(fs: *vfs.FileSystem, path: []const u8) ?vfs.StatInfo {
    _ = fs;

    if (path.len <= 1) {
        return .{ .file_type = .directory, .size = 0, .inode = 0 };
    }

    var name_buf: [13]u8 = undefined;
    const resolved = resolvePathComponents(path, &name_buf) orelse return null;

    const entry = findInDir(resolved.dir_cluster, name_buf[0..resolved.name_len]) orelse return null;

    return .{
        .file_type = if (entry.attributes & 0x10 != 0) .directory else .file,
        .size = entry.file_size,
        .inode = entry.first_cluster_low,
    };
}

fn fat16Truncate(fs: *vfs.FileSystem, handle: *vfs.FileHandle, size: u64) bool {
    _ = fs;
    _ = handle;
    _ = size;
    return false;
}

fn fat16Seek(fs: *vfs.FileSystem, handle: *vfs.FileHandle, offset: u64) bool {
    _ = fs;
    handle.offset = offset;
    return true;
}

pub fn init() void {
    const dev = blockdev.getDevice(0) orelse {
        serial.serialWrite("[FAT16] No block device found\n");
        return;
    };

    fat_dev = dev;

    // Read boot sector
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(0, &buf)) {
        serial.serialWrite("[FAT16] Failed to read boot sector\n");
        return;
    }

    boot_sector = .{
        .bytes_per_sector = @as(u16, buf[11]) | (@as(u16, buf[12]) << 8),
        .sectors_per_cluster = buf[13],
        .reserved_sectors = @as(u16, buf[14]) | (@as(u16, buf[15]) << 8),
        .num_fats = buf[16],
        .root_entry_count = @as(u16, buf[17]) | (@as(u16, buf[18]) << 8),
        .total_sectors_16 = @as(u16, buf[19]) | (@as(u16, buf[20]) << 8),
        .media_type = buf[21],
        .fat_size_sectors = @as(u16, buf[22]) | (@as(u16, buf[23]) << 8),
        .sectors_per_track = @as(u16, buf[24]) | (@as(u16, buf[25]) << 8),
        .num_heads = @as(u16, buf[26]) | (@as(u16, buf[27]) << 8),
        .hidden_sectors = @as(u32, buf[28]) | (@as(u32, buf[29]) << 8) | (@as(u32, buf[30]) << 16) | (@as(u32, buf[31]) << 24),
        .total_sectors_32 = @as(u32, buf[32]) | (@as(u32, buf[33]) << 8) | (@as(u32, buf[34]) << 16) | (@as(u32, buf[35]) << 24),
    };

    // Validate
    if (boot_sector.bytes_per_sector != SECTOR_SIZE) {
        serial.serialWrite("[FAT16] Invalid bytes per sector: ");
        serial.serialWriteDec(boot_sector.bytes_per_sector);
        serial.serialWrite("\n");
        return;
    }

    if (boot_sector.fat_size_sectors == 0) {
        serial.serialWrite("[FAT16] FAT size is 0\n");
        return;
    }

    // Calculate layout
    fat_start_sector = boot_sector.reserved_sectors;
    root_dir_start = fat_start_sector + @as(u64, boot_sector.fat_size_sectors) * boot_sector.num_fats;
    const root_dir_sectors = (@as(u64, boot_sector.root_entry_count) * 32 + SECTOR_SIZE - 1) / SECTOR_SIZE;
    data_start = root_dir_start + root_dir_sectors;

    serial.serialWrite("[FAT16] FAT16 found! Sectors/cluster=");
    serial.serialWriteDec(boot_sector.sectors_per_cluster);
    serial.serialWrite(", FAT size=");
    serial.serialWriteDec(boot_sector.fat_size_sectors);
    serial.serialWrite(", root entries=");
    serial.serialWriteDec(boot_sector.root_entry_count);
    serial.serialWrite(", total sectors=");
    serial.serialWriteDec(boot_sector.total_sectors_16);
    serial.serialWrite("\n");

    // Mount
    var fs = vfs.FileSystem{
        .name = undefined,
        .mount_point = undefined,
        .mount_point_len = 0,
        .@"opaque" = null,
        .openFn = fat16Open,
        .closeFn = fat16Close,
        .readFn = fat16Read,
        .writeFn = fat16Write,
        .readdirFn = fat16Readdir,
        .mkdirFn = fat16Mkdir,
        .unlinkFn = fat16Unlink,
        .statFn = fat16Stat,
        .truncateFn = fat16Truncate,
        .seekFn = fat16Seek,
    };

    @memset(&fs.name, 0);
    for ("fat16", 0..) |ch, i| {
        if (i < 15) fs.name[i] = ch;
    }

    @memset(&fs.mount_point, 0);
    for ("/mnt/disk", 0..) |ch, i| {
        if (i < 63) fs.mount_point[i] = ch;
    }
    fs.mount_point_len = 9;

    if (vfs.mount("fat16", "/mnt/disk", &fs)) {
        fs_mounted = true;
        vga.setColor(.green, .black);
        vga.write("  [FAT16] Auto-mounted at /mnt/disk\n");
        vga.setColor(.white, .black);
    }
}

pub fn isMounted() bool {
    return fs_mounted;
}
