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
    parent_cluster: u16 = 0, // cluster of the directory holding this file (0 = root)
    used: bool = false,
    // Sequential-read cache: the chain position of the last read. Without it
    // every read() restarts at first_cluster, making large sequential reads
    // quadratic (a 1 MB binary took minutes through virtio).
    cur_valid: bool = false,
    cur_cluster: u16 = 0,
    cur_base: u64 = 0, // byte offset of cur_cluster within the file
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

fn writeSector(sector: u64, buf: *const [SECTOR_SIZE]u8) bool {
    const dev = fat_dev orelse return false;
    return blockdev.writeSectors(dev, sector, 1, buf);
}

// Read the 16-bit FAT entry for a cluster.
fn rawFATEntry(cluster: u16) ?u16 {
    var buf: [SECTOR_SIZE]u8 = undefined;
    const fat_offset = @as(u64, cluster) * 2;
    const fat_sector = fat_start_sector + (fat_offset / SECTOR_SIZE);
    const entry_offset = fat_offset % SECTOR_SIZE;
    if (!readSector(fat_sector, &buf)) return null;
    return @as(u16, buf[entry_offset]) | (@as(u16, buf[entry_offset + 1]) << 8);
}

// Write a 16-bit FAT entry to all FAT copies (so the FS survives a boot that
// only reads FAT#0).
fn writeFATEntry(cluster: u16, value: u16) bool {
    var buf: [SECTOR_SIZE]u8 = undefined;
    const fat_offset = @as(u64, cluster) * 2;
    const fat_sector = fat_start_sector + (fat_offset / SECTOR_SIZE);
    const entry_offset = fat_offset % SECTOR_SIZE;

    var copy: u8 = 0;
    while (copy < boot_sector.num_fats) : (copy += 1) {
        if (!readSector(fat_sector + @as(u64, copy) * boot_sector.fat_size_sectors, &buf)) return false;
        buf[entry_offset] = @intCast(value & 0xFF);
        buf[entry_offset + 1] = @intCast((value >> 8) & 0xFF);
        if (!writeSector(fat_sector + @as(u64, copy) * boot_sector.fat_size_sectors, &buf)) return false;
    }
    return true;
}

// Total number of usable clusters on the volume.
fn totalClusters() usize {
    const total = if (boot_sector.total_sectors_16 != 0)
        boot_sector.total_sectors_16
    else
        boot_sector.total_sectors_32;
    const cluster_count = (@as(u64, total) - data_start) / boot_sector.sectors_per_cluster;
    return @intCast(@min(cluster_count, 0xFF00));
}

// Find a free cluster (FAT entry == 0). Starts the scan at `start` to allow
// sequential allocation.
fn findFreeCluster(start: u16) ?u16 {
    const max_cluster = totalClusters();
    var c: u16 = start;
    while (c < max_cluster + 2) : (c += 1) {
        const e = rawFATEntry(c) orelse return null;
        if (e == 0x0000) return c;
    }
    if (start > 2) return findFreeCluster(2); // wrap around (first 2 entry scanned)
    return null;
}

// Allocate a single cluster and mark it end-of-chain.
fn allocateCluster() ?u16 {
    const c = findFreeCluster(2) orelse return null;
    if (!writeFATEntry(c, 0xFFFF)) return null;
    return c;
}

// Allocate `count` clusters and chain them: returns the first cluster.
fn allocateClusterChain(count: usize) ?u16 {
    var first: ?u16 = null;
    var prev: ?u16 = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const c = allocateCluster() orelse {
            if (prev) |p| {
                _ = writeFATEntry(p, 0xFFFF); // keep partial chain valid
            }
            return null;
        };
        if (first == null) first = c;
        if (prev) |p| {
            if (!writeFATEntry(p, c)) return null;
        }
        prev = c;
    }
    return first;
}

// Mark cluster N free (FAT entry = 0) in every FAT.
fn freeClusterEntry(cluster: u16) bool {
    return writeFATEntry(cluster, 0x0000);
}

fn clusterToSector(cluster: u16) u64 {
    if (cluster == 0) return root_dir_start; // root directory
    return data_start + @as(u64, cluster - 2) * boot_sector.sectors_per_cluster;
}

// Read a whole cluster into `out` (out.len must be >= spc*512).
fn readClusterBytes(cluster: u16, out: []u8) bool {
    const base = clusterToSector(cluster);
    var s: u8 = 0;
    while (s < boot_sector.sectors_per_cluster) : (s += 1) {
        const off = s * SECTOR_SIZE;
        if (off + SECTOR_SIZE > out.len) return false;
        if (!readSector(base + @as(u64, s), out[off..][0..SECTOR_SIZE])) return false;
    }
    return true;
}

// Write a whole cluster back from `data`.
fn writeClusterBytes(cluster: u16, data: []const u8) bool {
    const base = clusterToSector(cluster);
    var s: u8 = 0;
    while (s < boot_sector.sectors_per_cluster) : (s += 1) {
        const off = s * SECTOR_SIZE;
        if (off + SECTOR_SIZE > data.len) return false;
        if (!writeSector(base + @as(u64, s), data[off..][0..SECTOR_SIZE])) return false;
    }
    return true;
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
        if (a != b and lower(a) != lower(b)) return false;
    }
    return true;
}

fn lower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
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

// ---- write-support helpers -------------------------------------------------

// Convert "hello.txt" -> "HELLO     TXT" style short name + extension (uppercase).
fn toShortName(name: []const u8, short_name: *[8]u8, short_ext: *[3]u8) void {
    @memset(short_name, ' ');
    @memset(short_ext, ' ');
    var dot: usize = name.len;
    for (name, 0..) |c, i| {
        if (c == '.') dot = i;
    }
    const base = name[0..dot];
    const ext = if (dot + 1 <= name.len and dot != name.len) name[dot + 1 ..] else "";
    var j: usize = 0;
    while (j < base.len and j < 8) : (j += 1) {
        var c = base[j];
        if (c >= 'a' and c <= 'z') c -= 32;
        short_name[j] = c;
    }
    j = 0;
    while (j < ext.len and j < 3) : (j += 1) {
        var c = ext[j];
        if (c >= 'a' and c <= 'z') c -= 32;
        short_ext[j] = c;
    }
}

const DirSlot = struct { sector: u64, offset: usize };

// Find a free 32-byte slot (0x00 or 0xE5) in a directory, growing subdirectories
// with an extra cluster if the chain is full.
fn findFreeDirSlot(dir_cluster: u16) ?DirSlot {
    var buf: [SECTOR_SIZE]u8 = undefined;
    var sec: u64 = 0;
    var spc: u8 = 0;

    if (dir_cluster == 0) {
        const root_sectors = (@as(u64, boot_sector.root_entry_count) * 32 + SECTOR_SIZE - 1) / SECTOR_SIZE;
        while (sec < root_sectors) : (sec += 1) {
            if (!readSector(root_dir_start + sec, &buf)) return null;
            var e: usize = 0;
            while (e < SECTOR_SIZE / 32) : (e += 1) {
                const first = buf[e * 32];
                if (first == 0x00 or first == 0xE5) return .{ .sector = root_dir_start + sec, .offset = e * 32 };
            }
        }
        return null; // root directory is full
    }

    // subdirectory: follow cluster chain
    var current = dir_cluster;
    while (current >= 2) {
        const base = clusterToSector(current);
        spc = 0;
        while (spc < boot_sector.sectors_per_cluster) : (spc += 1) {
            if (!readSector(base + @as(u64, spc), &buf)) return null;
            var e: usize = 0;
            while (e < SECTOR_SIZE / 32) : (e += 1) {
                const first = buf[e * 32];
                if (first == 0x00 or first == 0xE5) return .{ .sector = base + @as(u64, spc), .offset = e * 32 };
            }
        }
        const nxt = nextCluster(current) orelse {
            // directory full: allocate a fresh cluster, link and zero it
            const c = allocateCluster() orelse return null;
            if (!writeFATEntry(current, c)) return null;
            var zbuf: [SECTOR_SIZE]u8 = .{0} ** SECTOR_SIZE;
            var zs: u8 = 0;
            while (zs < boot_sector.sectors_per_cluster) : (zs += 1) {
                if (!writeSector(clusterToSector(c) + @as(u64, zs), &zbuf)) return null;
            }
            return .{ .sector = clusterToSector(c), .offset = 0 };
        };
        current = nxt;
    }
    return null;
}

// Read a directory raw (returns true when a slot matching `name` was located).
fn findEntryLocation(dir_cluster: u16, name: []const u8) ?DirSlot {
    var buf: [SECTOR_SIZE]u8 = undefined;
    var sec: u64 = 0;
    var spc: u8 = 0;
    var current = dir_cluster;
    while (true) {
        if (current == 0) {
            const root_sectors = (@as(u64, boot_sector.root_entry_count) * 32 + SECTOR_SIZE - 1) / SECTOR_SIZE;
            while (sec < root_sectors) : (sec += 1) {
                if (!readSector(root_dir_start + sec, &buf)) return null;
                var e: usize = 0;
                while (e < SECTOR_SIZE / 32) : (e += 1) {
                    const entry: *const Fat16DirEntry = @ptrFromInt(@intFromPtr(&buf[e * 32]));
                    if (entry.name[0] == 0x00) return null;
                    if (entry.name[0] == 0xE5) continue;
                    if (matchName(name, entry)) return .{ .sector = root_dir_start + sec, .offset = e * 32 };
                }
            }
            return null;
        }
        const base = clusterToSector(current);
        spc = 0;
        while (spc < boot_sector.sectors_per_cluster) : (spc += 1) {
            if (!readSector(base + @as(u64, spc), &buf)) return null;
            var e: usize = 0;
            while (e < SECTOR_SIZE / 32) : (e += 1) {
                const entry: *const Fat16DirEntry = @ptrFromInt(@intFromPtr(&buf[e * 32]));
                if (entry.name[0] == 0x00) return null;
                if (entry.name[0] == 0xE5) continue;
                if (matchName(name, entry)) return .{ .sector = base + @as(u64, spc), .offset = e * 32 };
            }
        }
        current = nextCluster(current) orelse return null;
    }
}

fn writeDirEntry(slot: DirSlot, name: []const u8, attributes: u8, first_cluster: u16, file_size: u32) bool {
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(slot.sector, &buf)) return false;
    const o = slot.offset;
    @memset(buf[o..][0..32], 0);
    var short_name: [8]u8 = undefined;
    var short_ext: [3]u8 = undefined;
    toShortName(name, &short_name, &short_ext);
    @memcpy(buf[o..][0..8], &short_name);
    @memcpy(buf[o + 8..][0..3], &short_ext);
    buf[o + 11] = attributes;
    buf[o + 20] = @intCast(first_cluster & 0xFF);
    buf[o + 21] = @intCast((first_cluster >> 8) & 0xFF);
    buf[o + 26] = @intCast(first_cluster & 0xFF);
    buf[o + 27] = @intCast((first_cluster >> 8) & 0xFF);
    buf[o + 28] = @intCast(file_size & 0xFF);
    buf[o + 29] = @intCast((file_size >> 8) & 0xFF);
    buf[o + 30] = @intCast((file_size >> 16) & 0xFF);
    buf[o + 31] = @intCast((file_size >> 24) & 0xFF);
    return writeSector(slot.sector, &buf);
}

// Initialize a brand-new directory cluster with "." and ".." entries (parent_cluster
// 0 for the parent means the new dir's parent is the root).
fn initDirCluster(cluster: u16, parent_cluster: u16) bool {
    var zbuf: [SECTOR_SIZE]u8 = .{0} ** SECTOR_SIZE;
    var s: u8 = 0;
    while (s < boot_sector.sectors_per_cluster) : (s += 1) {
        if (!writeSector(clusterToSector(cluster) + @as(u64, s), &zbuf)) return false;
    }
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(clusterToSector(cluster), &buf)) return false;
    // "." entry (32 bytes at offset 0): name "." followed by spaces
    @memset(buf[0..32], 0);
    buf[0] = '.';
    @memset(buf[1..8], ' ');
    @memset(buf[8..11], ' ');
    buf[11] = 0x10;
    buf[26] = @intCast(cluster & 0xFF);
    buf[27] = @intCast((cluster >> 8) & 0xFF);
    // ".." entry (offset 32)
    buf[32] = '.';
    buf[33] = '.';
    @memset(buf[34..40], ' ');
    @memset(buf[40..43], ' ');
    buf[43] = 0x10;
    buf[58] = @intCast(parent_cluster & 0xFF);
    buf[59] = @intCast((parent_cluster >> 8) & 0xFF);
    return writeSector(clusterToSector(cluster), &buf);
}

// Return the cluster at chain position `want`, extending the chain (allocating)
// when needed. Returns null on allocation failure or when `first` is 0.
fn clusterAtIndex(first: u16, want: u32) ?u16 {
    if (first == 0) return null;
    var cur = first;
    var i: u32 = 0;
    while (i < want) : (i += 1) {
        if (nextCluster(cur)) |nxt| {
            cur = nxt;
        } else {
            const c = allocateCluster() orelse return null;
            if (!writeFATEntry(cur, c)) return null;
            cur = c;
        }
    }
    return cur;
}

// Sync file_size + first_cluster from the file cache back to its directory entry.
fn updateFileEntry(fi: *const FileInfo) bool {
    const loc = findEntryLocation(fi.parent_cluster, fi.name[0..fi.name_len]) orelse return false;
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(loc.sector, &buf)) return false;
    const o = loc.offset;
    buf[o + 26] = @intCast(fi.first_cluster & 0xFF);
    buf[o + 27] = @intCast((fi.first_cluster >> 8) & 0xFF);
    buf[o + 28] = @intCast(fi.file_size & 0xFF);
    buf[o + 29] = @intCast((fi.file_size >> 8) & 0xFF);
    buf[o + 30] = @intCast((fi.file_size >> 16) & 0xFF);
    buf[o + 31] = @intCast((fi.file_size >> 24) & 0xFF);
    return writeSector(loc.sector, &buf);
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

    var entry = findInDir(resolved.dir_cluster, name_buf[0..resolved.name_len]);
    if (entry == null) {
        if (!flags.create) return null;
        const slot = findFreeDirSlot(resolved.dir_cluster) orelse return null;
        if (!writeDirEntry(slot, name_buf[0..resolved.name_len], 0x20, 0, 0)) return null;
        entry = findInDir(resolved.dir_cluster, name_buf[0..resolved.name_len]) orelse return null;
    }

    const idx = file_count;
    if (idx >= MAX_FAT16_FILES) return null;

    file_cache[idx] = .{
        .name = undefined,
        .name_len = buildFullName(&entry.?, &file_cache[idx].name),
        .is_dir = entry.?.attributes & 0x10 != 0,
        .first_cluster = entry.?.first_cluster_low,
        .file_size = entry.?.file_size,
        .parent_cluster = resolved.dir_cluster,
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

    var cluster_buf: [4096]u8 = undefined;
    const cluster_size = @as(u64, boot_sector.sectors_per_cluster) * SECTOR_SIZE;

    // Resume the chain walk from the cached position when reading forward;
    // rewind to first_cluster after a backwards seek.
    if (!fi.cur_valid or fi.cur_base > handle.offset) {
        fi.cur_valid = true;
        fi.cur_cluster = fi.first_cluster;
        fi.cur_base = 0;
    }
    var current = fi.cur_cluster;
    var offset = fi.cur_base;

    while (current != 0 and offset + cluster_size <= handle.offset) {
        offset += cluster_size;
        current = nextCluster(current) orelse return 0;
    }
    if (current == 0) {
        fi.cur_valid = false;
        return 0;
    }

    // Read exactly ONE cluster: readClusterChain follows the FAT chain for as
    // long as `out` lasts, so handing it the full scratch buffer would consume
    // several clusters while our cache only advances one hop.
    const one_cluster = cluster_buf[0..@intCast(cluster_size)];
    const got = readClusterChain(current, one_cluster);
    if (got == 0) return 0;
    const start_in_cluster: usize = @intCast(handle.offset - offset);
    if (start_in_cluster >= got) {
        fi.cur_valid = false;
        return 0;
    }
    const copy_len = @min(to_read, got - start_in_cluster);
    @memcpy(buf[0..copy_len], cluster_buf[start_in_cluster..][0..copy_len]);
    handle.offset += copy_len;

    // Keep the cache pointing at where the next read continues from.
    fi.cur_base = offset;
    fi.cur_cluster = current;
    if (start_in_cluster + copy_len >= got) {
        const nxt = nextCluster(current);
        fi.cur_cluster = nxt orelse 0;
        fi.cur_base = offset + got;
        if (nxt == null) fi.cur_valid = false;
    }
    return copy_len;
}

fn fat16Write(fs: *vfs.FileSystem, handle: *vfs.FileHandle, buf: []const u8) usize {
    _ = fs;
    if (handle.inode >= file_count) return 0;
    const fi = &file_cache[handle.inode];
    if (fi.is_dir or buf.len == 0) return 0;
    fi.cur_valid = false; // the chain may grow/relink under us

    const cluster_size: u64 = @as(u64, boot_sector.sectors_per_cluster) * SECTOR_SIZE;

    if (fi.first_cluster == 0) {
        const c = allocateCluster() orelse return 0;
        fi.first_cluster = c;
        if (!writeFATEntry(c, 0xFFFF)) return 0;
    }

    var pos: u64 = handle.offset;
    var written: usize = 0;
    while (written < buf.len) {
        const cluster_index: u32 = @intCast(pos / cluster_size);
        const in_off = @as(usize, @intCast(pos % cluster_size));
        const cluster = clusterAtIndex(fi.first_cluster, cluster_index) orelse break;

        const chunk: usize = @intCast(@min(cluster_size - @as(u64, in_off), @as(u64, buf.len - written)));
        var cbuf: [4096]u8 = undefined;
        const cs: usize = @intCast(cluster_size);
        if (cs > cbuf.len) return written;
        if (!readClusterBytes(cluster, cbuf[0..cs])) break;
        @memcpy(cbuf[in_off..][0..chunk], buf[written..][0..chunk]);
        if (!writeClusterBytes(cluster, cbuf[0..cs])) break;

        pos += chunk;
        written += chunk;
    }
    if (written == 0) return 0;

    handle.offset = pos;
    if (pos > fi.file_size) {
        fi.file_size = @intCast(pos);
    }
    _ = updateFileEntry(fi);
    return written;
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
    var parent_buf: [13]u8 = undefined;
    const parent = resolvePathComponents(path, &parent_buf) orelse return false;
    if (parent.name_len == 0) return false;
    if (findInDir(parent.dir_cluster, parent_buf[0..parent.name_len]) != null) return false;

    const slot = findFreeDirSlot(parent.dir_cluster) orelse return false;
    const c = allocateCluster() orelse return false;
    if (!initDirCluster(c, parent.dir_cluster)) {
        _ = freeClusterEntry(c);
        return false;
    }
    if (!writeDirEntry(slot, parent_buf[0..parent.name_len], 0x10, c, 0)) {
        _ = freeClusterEntry(c);
        return false;
    }
    return true;
}

fn fat16Unlink(fs: *vfs.FileSystem, path: []const u8) bool {
    _ = fs;
    var name_buf: [13]u8 = undefined;
    const resolved = resolvePathComponents(path, &name_buf) orelse return false;

    const entry = findInDir(resolved.dir_cluster, name_buf[0..resolved.name_len]) orelse return false;
    const slot = findEntryLocation(resolved.dir_cluster, name_buf[0..resolved.name_len]) orelse return false;

    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(slot.sector, &buf)) return false;
    buf[slot.offset] = 0xE5;
    if (!writeSector(slot.sector, &buf)) return false;

    // free the whole cluster chain (files and also subdirs are chains)
    if (entry.first_cluster_low != 0) {
        var cur = entry.first_cluster_low;
        while (cur >= 2 and cur < 0xFFF8) {
            const nxt = nextCluster(cur);
            _ = freeClusterEntry(cur);
            cur = nxt orelse 0;
        }
    }
    return true;
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
    if (handle.inode >= file_count) return false;
    const fi = &file_cache[handle.inode];
    if (fi.is_dir) return false;
    fi.cur_valid = false;

    if (size == 0) {
        freeChain(fi.first_cluster);
        fi.first_cluster = 0;
        fi.file_size = 0;
        _ = updateFileEntry(fi);
        return true;
    }

    const cluster_size: u64 = @as(u64, boot_sector.sectors_per_cluster) * SECTOR_SIZE;
    const want: u32 = @intCast((size + cluster_size - 1) / cluster_size);
    if (want == 0) return false;

    if (fi.first_cluster == 0) {
        const first = allocateClusterChain(want) orelse return false;
        fi.first_cluster = first;
    } else {
        truncateChain(fi.first_cluster, want);
        if (clusterAtIndex(fi.first_cluster, want - 1) == null) return false;
    }
    fi.file_size = @intCast(size);
    _ = updateFileEntry(fi);
    return true;
}

// Free every cluster in a chain.
fn freeChain(first: u16) void {
    var cur = first;
    var guard: usize = 0;
    while (cur >= 2 and cur < 0xFFF8 and guard < 0xFFFF) : (guard += 1) {
        const nxt = nextCluster(cur);
        _ = freeClusterEntry(cur);
        if (nxt) |n| {
            cur = n;
        } else {
            break;
        }
    }
}

// Truncate a chain so it holds at most `keep` clusters; frees the tail. If the
// chain is already shorter it is left untouched.
fn truncateChain(first: u16, keep: u32) void {
    var cur = first;
    var i: u32 = 0;
    while (i < keep - 1) : (i += 1) {
        const nxt = nextCluster(cur) orelse return;
        cur = nxt;
    }
    const tail = nextCluster(cur) orelse return;
    if (!writeFATEntry(cur, 0xFFFF)) return;
    var t = tail;
    var count: usize = 0;
    while (count < 0xFFFF) : (count += 1) {
        const after = nextCluster(t);
        _ = freeClusterEntry(t);
        if (after) |n| {
            t = n;
        } else {
            break;
        }
    }
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
    if (boot_sector.bytes_per_sector != SECTOR_SIZE or boot_sector.fat_size_sectors == 0) {
        serial.serialWrite("[FAT16] No FAT16 filesystem found (bytes/sector=");
        serial.serialWriteDec(boot_sector.bytes_per_sector);
        serial.serialWrite(", fat size=");
        serial.serialWriteDec(boot_sector.fat_size_sectors);
        serial.serialWrite(") — formatting blank disk\n");
        _ = format();
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
    const eff_total = if (boot_sector.total_sectors_16 != 0)
        @as(u64, boot_sector.total_sectors_16)
    else
        @as(u64, boot_sector.total_sectors_32);
    serial.serialWrite(", total sectors=");
    serial.serialWriteDec(eff_total);
    serial.serialWrite("\n");

    tryMount();
}

pub fn isMounted() bool {
    return fs_mounted;
}

/// Forget the current mount so a following format() can register a fresh one.
pub fn resetMountState() void {
    file_count = 0;
    fs_mounted = false;
}

// ---------------------------------------------------------------------------
// Formatting: build a blank FAT16 filesystem directly on the block device so
// a raw disk image created by run.bat/test_prog becomes mountable with no
// host-side mkfs tooling.
// ---------------------------------------------------------------------------

/// Format the registered block device as a fresh FAT16 volume and mount it.
/// Destroys any previous contents.
pub fn format() bool {
    const dev = blockdev.getDevice(0) orelse {
        serial.serialWrite("[FAT16] format: no block device\n");
        return false;
    };
    const total_sectors = blockdev.totalSectors(dev);
    // Practical FAT16 ceiling: 256 MiB (65524 clusters x 8-sector clusters).
    // The driver reads the size via total_sectors_16 with a total_sectors_32
    // fallback, so anything above 65535 sectors just uses the 32-bit field.
    if (total_sectors < 4096 or total_sectors > 524288) {
        serial.serialWrite("[FAT16] format: unsupported disk size (");
        serial.serialWriteDec(total_sectors);
        serial.serialWrite(" sectors, need 2MB..256MB)\n");
        return false;
    }

    const reserved: u16 = 1;
    const nfats: u8 = 2;
    const root_entries: u16 = 512;
    const root_dir_sectors = (@as(u64, root_entries) * 32 + SECTOR_SIZE - 1) / SECTOR_SIZE;
    const spc: u8 = if (total_sectors < 16384) 1 else if (total_sectors < 131072) 4 else 8;

    // Smallest FAT that covers every cluster of the remaining data area.
    var fat_size: u16 = 1;
    while (fat_size < 1024) : (fat_size += 1) {
        const data_sectors = total_sectors - reserved - @as(u64, fat_size) * nfats - root_dir_sectors;
        const clusters = data_sectors / spc;
        if (clusters < 4085) break; // below this it would be a FAT12 volume
        const fat_bytes = (clusters + 2) * 2;
        if (@as(u64, fat_size) * SECTOR_SIZE >= fat_bytes) break;
    }

    // Boot sector / BPB.
    var bs = [_]u8{0} ** SECTOR_SIZE;
    bs[0] = 0xEB;
    bs[1] = 0x3C;
    bs[2] = 0x90;
    @memcpy(bs[3..11], "ZIRCOS  ");
    bs[11] = @intCast(SECTOR_SIZE & 0xFF);
    bs[12] = @intCast((SECTOR_SIZE >> 8) & 0xFF);
    bs[13] = spc;
    bs[14] = @intCast(reserved & 0xFF);
    bs[15] = @intCast((reserved >> 8) & 0xFF);
    bs[16] = nfats;
    bs[17] = @intCast(root_entries & 0xFF);
    bs[18] = @intCast((root_entries >> 8) & 0xFF);
    if (total_sectors <= 0xFFFF) {
        bs[19] = @intCast(total_sectors & 0xFF);
        bs[20] = @intCast((total_sectors >> 8) & 0xFF);
    } else {
        // Large volumes carry the size in the 32-bit field instead.
        bs[19] = 0;
        bs[20] = 0;
        bs[32] = @intCast(total_sectors & 0xFF);
        bs[33] = @intCast((total_sectors >> 8) & 0xFF);
        bs[34] = @intCast((total_sectors >> 16) & 0xFF);
        bs[35] = @intCast((total_sectors >> 24) & 0xFF);
    }
    bs[21] = 0xF8; // fixed disk media descriptor
    bs[22] = @intCast(fat_size & 0xFF);
    bs[23] = @intCast((fat_size >> 8) & 0xFF);
    bs[24] = 63; // sectors/track (cosmetic)
    bs[26] = 16; // heads (cosmetic)
    bs[38] = 0x29; // extended boot signature
    bs[39] = 0x01; // volume id
    bs[43] = 'Z'; // 11-byte volume label "ZIRCONIUM"
    bs[44] = 'I';
    bs[45] = 'R';
    bs[46] = 'C';
    bs[47] = 'O';
    bs[48] = 'N';
    bs[49] = 'I';
    bs[50] = 'U';
    bs[51] = 'M';
    bs[54] = 'F';
    bs[55] = 'A';
    bs[56] = 'T';
    bs[57] = '1';
    bs[58] = '6';
    bs[59] = ' ';
    bs[60] = ' ';
    bs[61] = ' ';
    bs[510] = 0x55;
    bs[511] = 0xAA;
    if (!blockdev.writeSectors(dev, 0, 1, &bs)) return false;

    // Zero the FAT copies and the root directory in bulk.
    var zeros = [_]u8{0} ** SECTOR_SIZE;
    const fat_sectors = reserved + @as(u64, fat_size) * nfats;
    var s: u64 = reserved;
    while (s < fat_sectors + root_dir_sectors) : (s += 1) {
        if (!blockdev.writeSectors(dev, s, 1, &zeros)) {
            serial.serialWrite("[FAT16] format: write failed\n");
            return false;
        }
    }

    // FAT[0]=media, FAT[1]=EOC in every copy; the rest stays zero.
    var i: u8 = 0;
    while (i < nfats) : (i += 1) {
        const base = reserved + @as(u64, i) * fat_size;
        zeros[0] = 0xF8;
        zeros[1] = 0xFF;
        zeros[2] = 0xFF;
        zeros[3] = 0xFF;
        if (!blockdev.writeSectors(dev, base, 1, &zeros)) return false;
        zeros[0] = 0;
        zeros[1] = 0;
        zeros[2] = 0;
        zeros[3] = 0;
    }

    serial.serialWrite("[FAT16] Formatted ");
    serial.serialWriteDec(@intCast(total_sectors / 2048)); // MiB
    serial.serialWrite(" MiB FAT16 (spc=");
    serial.serialWriteDec(spc);
    serial.serialWrite(", fat=");
    serial.serialWriteDec(fat_size);
    serial.serialWrite(" sectors)\n");

    fat_dev = dev;
    tryMount();
    _ = &zeros;
    return fs_mounted;
}

/// Count free clusters by walking FAT#0 (one sector read per 256 entries).
pub fn countFreeClusters() usize {
    if (!fs_mounted) return 0;
    var free: usize = 0;
    var buf: [SECTOR_SIZE]u8 = undefined;
    var loaded_sector: u64 = std.math.maxInt(u64);
    const max_cluster = totalClusters();
    var c: u16 = 2;
    while (c < @as(u16, @intCast(max_cluster)) + 2) : (c += 1) {
        const off = @as(u64, c) * 2;
        const sec = fat_start_sector + off / SECTOR_SIZE;
        if (sec != loaded_sector) {
            if (!readSector(sec, &buf)) return free;
            loaded_sector = sec;
        }
        const o: usize = @intCast(off % SECTOR_SIZE);
        const e = @as(u16, buf[o]) | (@as(u16, buf[o + 1]) << 8);
        if (e == 0x0000) free += 1;
    }
    return free;
}

/// One-line volume summary for the df command.
pub fn printInfo() void {
    if (!fs_mounted) {
        vga.write("  /mnt/disk: not mounted (try 'mkfs')\n");
        return;
    }
    const dev = fat_dev orelse return;
    var name_len: usize = 0;
    while (name_len < dev.name.len and dev.name[name_len] != 0) : (name_len += 1) {}
    const total_clusters = totalClusters();
    const free_clusters = countFreeClusters();
    const used_kb = (total_clusters - free_clusters) * boot_sector.sectors_per_cluster / 2;
    const total_kb = total_clusters * boot_sector.sectors_per_cluster / 2;

    vga.write("  /mnt/disk on ");
    vga.write(dev.name[0..name_len]);
    vga.write(": ");
    vga.writeDec(total_kb);
    vga.write(" KiB total, ");
    vga.writeDec(used_kb);
    vga.write(" KiB used, ");
    vga.writeDec(total_kb - used_kb);
    vga.write(" KiB free (");
    vga.writeDec(free_clusters);
    vga.write("/");
    vga.writeDec(total_clusters);
    vga.write(" clusters)\n");
}

fn tryMount() void {
    if (fs_mounted) return;
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
