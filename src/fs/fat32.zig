const std = @import("std");
const root = @import("root");
const serial = root.serial;
const blockdev = @import("blockdev.zig");
const vfs = @import("vfs.zig");

// FAT32 driver.  FAT32 is intentionally kept separate from the legacy FAT16
// driver: the on-disk FAT entry and cluster numbers are 32-bit, and a log or
// distribution volume must not inherit FAT16's 64 KiB cluster ceiling.
//
// The first implementation deliberately uses 8.3 names only.  That is enough
// for the kernel log (KERNEL.LOG) and matches the existing foreign-binary
// assumptions; long-name support can be added without changing the VFS.

const SECTOR_SIZE: usize = 512;
const DIR_ENTRY_SIZE: usize = 32;
const MAX_FAT32_FILES: usize = 128;
const MAX_PATH_LEN: usize = 64;
const MAX_OPEN_HANDLES: usize = 32;
const ATTR_VOLUME_ID: u8 = 0x08;
const ATTR_DIRECTORY: u8 = 0x10;
const ATTR_LONG_NAME: u8 = 0x0F;
const FAT32_EOC: u32 = 0x0FFFFFFF;
const FAT32_MASK: u32 = 0x0FFFFFFF;
const MAX_U32: u64 = 0xFFFFFFFF;

const RawEntry = [DIR_ENTRY_SIZE]u8;

const FileInfo = struct {
    name: [MAX_PATH_LEN]u8 = undefined,
    name_len: usize = 0,
    is_dir: bool = false,
    first_cluster: u32 = 0,
    file_size: u32 = 0,
    parent_cluster: u32 = 0,
    used: bool = false,
    ref_count: u32 = 0,
};

const DirSlot = struct {
    sector: u64,
    offset: usize,
};

const ResolvedPath = struct {
    dir_cluster: u32,
    name_len: usize,
};

var fat_dev: ?*blockdev.BlockDevice = null;
var fs_mounted: bool = false;
var mount_point_buf: [64]u8 = undefined;
var mount_point_len: usize = 0;

var bytes_per_sector: u32 = SECTOR_SIZE;
var sectors_per_cluster: u32 = 0;
var reserved_sectors: u32 = 0;
var num_fats: u32 = 0;
var fat_size_sectors: u32 = 0;
var total_sectors: u64 = 0;
var fat_start_sector: u64 = 0;
var data_start_sector: u64 = 0;
var root_cluster: u32 = 0;
var cluster_count: u32 = 0;
var next_alloc_hint: u32 = 2;

var file_cache: [MAX_FAT32_FILES]FileInfo = [_]FileInfo{.{}} ** MAX_FAT32_FILES;
var file_count: usize = 0;
var root_handle: vfs.FileHandle = undefined;
var open_handles: [MAX_OPEN_HANDLES]vfs.FileHandle = undefined;
var open_handle_used: [MAX_OPEN_HANDLES]bool = [_]bool{false} ** MAX_OPEN_HANDLES;

fn readU16(buf: []const u8, off: usize) u16 {
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}

fn readU32(buf: []const u8, off: usize) u32 {
    return @as(u32, buf[off]) |
        (@as(u32, buf[off + 1]) << 8) |
        (@as(u32, buf[off + 2]) << 16) |
        (@as(u32, buf[off + 3]) << 24);
}

fn writeU16(buf: []u8, off: usize, value: u16) void {
    buf[off] = @intCast(value & 0xFF);
    buf[off + 1] = @intCast((value >> 8) & 0xFF);
}

fn writeU32(buf: []u8, off: usize, value: u32) void {
    buf[off] = @intCast(value & 0xFF);
    buf[off + 1] = @intCast((value >> 8) & 0xFF);
    buf[off + 2] = @intCast((value >> 16) & 0xFF);
    buf[off + 3] = @intCast((value >> 24) & 0xFF);
}

fn readSector(sector: u64, buf: *[SECTOR_SIZE]u8) bool {
    const dev = fat_dev orelse return false;
    return blockdev.readSectors(dev, sector, 1, buf);
}

fn writeSector(sector: u64, buf: *const [SECTOR_SIZE]u8) bool {
    const dev = fat_dev orelse return false;
    return blockdev.writeSectors(dev, sector, 1, buf);
}

fn clusterToSector(cluster: u32) u64 {
    return data_start_sector + @as(u64, cluster - 2) * sectors_per_cluster;
}

fn parseBootSector(buf: *const [SECTOR_SIZE]u8) bool {
    if (buf[510] != 0x55 or buf[511] != 0xAA) return false;

    bytes_per_sector = readU16(buf, 11);
    sectors_per_cluster = buf[13];
    reserved_sectors = readU16(buf, 14);
    num_fats = buf[16];
    const root_entries = readU16(buf, 17);
    const total16 = readU16(buf, 19);
    const fat_size16 = readU16(buf, 22);
    fat_size_sectors = readU32(buf, 36);
    total_sectors = if (total16 != 0) total16 else readU32(buf, 32);
    root_cluster = readU32(buf, 44);

    // FAT32 has no fixed root directory and normally has zero root entries.
    if (bytes_per_sector != SECTOR_SIZE or sectors_per_cluster == 0 or
        reserved_sectors == 0 or num_fats == 0 or num_fats > 4 or root_entries != 0 or
        total16 != 0 or fat_size16 != 0 or fat_size_sectors == 0 or
        total_sectors == 0 or root_cluster < 2 or sectors_per_cluster > 128 or
        (sectors_per_cluster & (sectors_per_cluster - 1)) != 0)
    {
        return false;
    }

    fat_start_sector = reserved_sectors;
    data_start_sector = fat_start_sector + @as(u64, num_fats) * fat_size_sectors;
    if (data_start_sector >= total_sectors) return false;
    cluster_count = @intCast((total_sectors - data_start_sector) / sectors_per_cluster);
    if (cluster_count < 65525 or cluster_count > 0x0FFFFFEF) return false;
    if (root_cluster >= cluster_count + 2) return false;
    return true;
}

fn fatEntry(cluster: u32) ?u32 {
    if (cluster < 2 or cluster >= cluster_count + 2) return null;
    const offset = @as(u64, cluster) * 4;
    const sector = fat_start_sector + offset / SECTOR_SIZE;
    const within: usize = @intCast(offset % SECTOR_SIZE);
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(sector, &buf)) return null;
    return readU32(&buf, within) & FAT32_MASK;
}

fn writeFatEntry(cluster: u32, value: u32) bool {
    if (cluster < 2 or cluster >= cluster_count + 2) return false;
    const offset = @as(u64, cluster) * 4;
    const sector = fat_start_sector + offset / SECTOR_SIZE;
    const within: usize = @intCast(offset % SECTOR_SIZE);
    var copy: u32 = 0;
    while (copy < num_fats) : (copy += 1) {
        var buf: [SECTOR_SIZE]u8 = undefined;
        if (!readSector(sector + @as(u64, copy) * fat_size_sectors, &buf)) return false;
        writeU32(&buf, within, value & FAT32_MASK);
        if (!writeSector(sector + @as(u64, copy) * fat_size_sectors, &buf)) return false;
    }
    return true;
}

fn zeroCluster(cluster: u32) bool {
    var zero: [SECTOR_SIZE]u8 = .{0} ** SECTOR_SIZE;
    var sector: u32 = 0;
    while (sector < sectors_per_cluster) : (sector += 1) {
        if (!writeSector(clusterToSector(cluster) + sector, &zero)) return false;
    }
    return true;
}

fn nextCluster(cluster: u32) ?u32 {
    const value = fatEntry(cluster) orelse return null;
    if (value < 2 or value >= cluster_count + 2 or value >= 0x0FFFFFF8) return null;
    return value;
}

fn allocateCluster() ?u32 {
    if (next_alloc_hint < 2) next_alloc_hint = 2;
    var candidate = next_alloc_hint;
    var scanned: u32 = 0;
    const limit = cluster_count + 2;
    while (scanned < cluster_count) : (scanned += 1) {
        if (candidate >= limit) candidate = 2;
        if ((fatEntry(candidate) orelse 0) == 0) {
            if (!writeFatEntry(candidate, FAT32_EOC)) return null;
            if (!zeroCluster(candidate)) {
                _ = writeFatEntry(candidate, 0);
                return null;
            }
            next_alloc_hint = candidate + 1;
            if (next_alloc_hint >= limit) next_alloc_hint = 2;
            return candidate;
        }
        candidate += 1;
    }
    return null;
}

fn freeChain(first: u32) void {
    var current = first;
    var guard: u32 = 0;
    while (current >= 2 and current < 0x0FFFFFF8 and guard < cluster_count + 2) : (guard += 1) {
        const next = fatEntry(current);
        _ = writeFatEntry(current, 0);
        current = next orelse 0;
    }
}

fn clusterAtIndex(first: u32, wanted: u32, allocate: bool) ?u32 {
    if (first == 0) return null;
    var current = first;
    var index: u32 = 0;
    while (index < wanted) : (index += 1) {
        if (nextCluster(current)) |next| {
            current = next;
        } else if (allocate) {
            const fresh = allocateCluster() orelse return null;
            if (!writeFatEntry(current, fresh)) {
                _ = writeFatEntry(fresh, 0);
                return null;
            }
            current = fresh;
        } else {
            return null;
        }
    }
    return current;
}

fn entryAttr(entry: *const RawEntry) u8 {
    return entry[11];
}

fn entryFirst(entry: *const RawEntry) u32 {
    // FAT stores FstClusLO at 0x1A and FstClusHI at 0x14.
    return @as(u32, readU16(entry, 26)) | (@as(u32, readU16(entry, 20)) << 16);
}

fn entrySize(entry: *const RawEntry) u32 {
    return readU32(entry, 28);
}

fn lower(value: u8) u8 {
    return if (value >= 'A' and value <= 'Z') value + 32 else value;
}

fn buildShortName(entry: *const RawEntry, out: []u8) usize {
    var pos: usize = 0;
    var i: usize = 0;
    while (i < 8 and entry[i] != ' ' and entry[i] != 0) : (i += 1) {
        if (pos < out.len) {
            out[pos] = entry[i];
            pos += 1;
        }
    }
    if (entry[8] != ' ' and entry[8] != 0) {
        if (pos < out.len) {
            out[pos] = '.';
            pos += 1;
        }
        i = 0;
        while (i < 3 and entry[8 + i] != ' ' and entry[8 + i] != 0) : (i += 1) {
            if (pos < out.len) {
                out[pos] = entry[8 + i];
                pos += 1;
            }
        }
    }
    return pos;
}

fn namesEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a != b and lower(a) != lower(b)) return false;
    }
    return true;
}

fn validShortChar(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or
        (ch >= 'a' and ch <= 'z') or
        (ch >= '0' and ch <= '9') or
        ch == '$' or ch == '%' or ch == '\'' or ch == '-' or
        ch == '_' or ch == '@' or ch == '~' or ch == '`' or
        ch == '!' or ch == '(' or ch == ')' or ch == '{' or
        ch == '}' or ch == '^' or ch == '#';
}

fn toShortName(name: []const u8, short_name: *[8]u8, short_ext: *[3]u8) bool {
    @memset(short_name, ' ');
    @memset(short_ext, ' ');
    var dot: usize = name.len;
    for (name, 0..) |c, i| {
        if (c == '.') dot = i;
    }
    const base = name[0..dot];
    const ext = if (dot < name.len) name[dot + 1 ..] else "";
    if (base.len == 0 or base.len > 8 or ext.len > 3) return false;
    for (base) |ch| if (!validShortChar(ch)) return false;
    for (ext) |ch| if (!validShortChar(ch)) return false;
    for (base, 0..) |c, i| short_name[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    for (ext, 0..) |c, i| short_ext[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    return true;
}

fn findInDir(dir_cluster: u32, name: []const u8) ?RawEntry {
    var current = dir_cluster;
    var guard: u32 = 0;
    while (current >= 2 and current < 0x0FFFFFF8 and guard < cluster_count + 2) : (guard += 1) {
        const base = clusterToSector(current);
        var sector_in_cluster: u32 = 0;
        while (sector_in_cluster < sectors_per_cluster) : (sector_in_cluster += 1) {
            var buf: [SECTOR_SIZE]u8 = undefined;
            if (!readSector(base + sector_in_cluster, &buf)) return null;
            var off: usize = 0;
            while (off < SECTOR_SIZE) : (off += DIR_ENTRY_SIZE) {
                const entry: RawEntry = buf[off..][0..DIR_ENTRY_SIZE].*;
                if (entry[0] == 0) return null;
                if (entry[0] == 0xE5) continue;
                if (entryAttr(&entry) & (ATTR_VOLUME_ID | ATTR_LONG_NAME) != 0) continue;
                var full: [13]u8 = undefined;
                const full_len = buildShortName(&entry, &full);
                if (namesEqual(name, full[0..full_len])) return entry;
            }
        }
        current = nextCluster(current) orelse return null;
    }
    return null;
}

fn findEntryLocation(dir_cluster: u32, name: []const u8) ?DirSlot {
    var current = dir_cluster;
    var guard: u32 = 0;
    while (current >= 2 and current < 0x0FFFFFF8 and guard < cluster_count + 2) : (guard += 1) {
        const base = clusterToSector(current);
        var sector_in_cluster: u32 = 0;
        while (sector_in_cluster < sectors_per_cluster) : (sector_in_cluster += 1) {
            var buf: [SECTOR_SIZE]u8 = undefined;
            if (!readSector(base + sector_in_cluster, &buf)) return null;
            var off: usize = 0;
            while (off < SECTOR_SIZE) : (off += DIR_ENTRY_SIZE) {
                const entry: RawEntry = buf[off..][0..DIR_ENTRY_SIZE].*;
                if (entry[0] == 0) return null;
                if (entry[0] == 0xE5) continue;
                if (entryAttr(&entry) & (ATTR_VOLUME_ID | ATTR_LONG_NAME) != 0) continue;
                var full: [13]u8 = undefined;
                const full_len = buildShortName(&entry, &full);
                if (namesEqual(name, full[0..full_len])) return .{ .sector = base + sector_in_cluster, .offset = off };
            }
        }
        current = nextCluster(current) orelse return null;
    }
    return null;
}

fn findFreeDirSlot(dir_cluster: u32) ?DirSlot {
    var current = dir_cluster;
    var last = dir_cluster;
    var guard: u32 = 0;
    while (current >= 2 and current < 0x0FFFFFF8 and guard < cluster_count + 2) : (guard += 1) {
        const base = clusterToSector(current);
        var sector_in_cluster: u32 = 0;
        while (sector_in_cluster < sectors_per_cluster) : (sector_in_cluster += 1) {
            var buf: [SECTOR_SIZE]u8 = undefined;
            if (!readSector(base + sector_in_cluster, &buf)) return null;
            var off: usize = 0;
            while (off < SECTOR_SIZE) : (off += DIR_ENTRY_SIZE) {
                if (buf[off] == 0 or buf[off] == 0xE5) return .{ .sector = base + sector_in_cluster, .offset = off };
            }
        }
        last = current;
        current = nextCluster(current) orelse {
            const fresh = allocateCluster() orelse return null;
            if (!writeFatEntry(last, fresh)) {
                _ = writeFatEntry(fresh, 0);
                return null;
            }
            var zero: [SECTOR_SIZE]u8 = .{0} ** SECTOR_SIZE;
            var s: u32 = 0;
            while (s < sectors_per_cluster) : (s += 1) {
                if (!writeSector(clusterToSector(fresh) + s, &zero)) {
                    _ = writeFatEntry(fresh, 0);
                    return null;
                }
            }
            return .{ .sector = clusterToSector(fresh), .offset = 0 };
        };
    }
    return null;
}

fn makeDirEntry(cluster: u32, parent: u32, dotdot: bool) RawEntry {
    var entry: RawEntry = .{0} ** DIR_ENTRY_SIZE;
    if (dotdot) {
        entry[0] = '.';
        entry[1] = '.';
        entry[11] = ATTR_DIRECTORY;
        writeU16(&entry, 20, @intCast((parent >> 16) & 0xFFFF));
        writeU16(&entry, 26, @intCast(parent & 0xFFFF));
    } else {
        entry[0] = '.';
        entry[11] = ATTR_DIRECTORY;
        writeU16(&entry, 20, @intCast((cluster >> 16) & 0xFFFF));
        writeU16(&entry, 26, @intCast(cluster & 0xFFFF));
    }
    return entry;
}

fn initDirCluster(cluster: u32, parent: u32) bool {
    var zero: [SECTOR_SIZE]u8 = .{0} ** SECTOR_SIZE;
    var s: u32 = 1;
    while (s < sectors_per_cluster) : (s += 1) {
        if (!writeSector(clusterToSector(cluster) + s, &zero)) return false;
    }
    var first: [SECTOR_SIZE]u8 = .{0} ** SECTOR_SIZE;
    const dot = makeDirEntry(cluster, parent, false);
    const dotdot = makeDirEntry(cluster, parent, true);
    @memcpy(first[0..32], &dot);
    @memcpy(first[32..64], &dotdot);
    return writeSector(clusterToSector(cluster), &first);
}

fn writeDirEntry(slot: DirSlot, name: []const u8, attributes: u8, first_cluster: u32, file_size: u32) bool {
    var short_name: [8]u8 = undefined;
    var short_ext: [3]u8 = undefined;
    if (!toShortName(name, &short_name, &short_ext)) return false;
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(slot.sector, &buf)) return false;
    @memset(buf[slot.offset..][0..DIR_ENTRY_SIZE], 0);
    @memcpy(buf[slot.offset..][0..8], &short_name);
    @memcpy(buf[slot.offset + 8 ..][0..3], &short_ext);
    buf[slot.offset + 11] = attributes;
    writeU16(buf[slot.offset..], 20, @intCast((first_cluster >> 16) & 0xFFFF));
    writeU16(buf[slot.offset..], 26, @intCast(first_cluster & 0xFFFF));
    writeU32(buf[slot.offset..], 28, file_size);
    return writeSector(slot.sector, &buf);
}

fn resolvePath(path: []const u8, out_name: []u8) ?ResolvedPath {
    if (path.len < 1 or path[0] != '/') return null;
    var dir_cluster = root_cluster;
    var start: usize = 1;
    while (start < path.len) {
        var end = start;
        while (end < path.len and path[end] != '/') : (end += 1) {}
        if (end == start) {
            start = end + 1;
            continue;
        }
        const component = path[start..end];
        if (component.len > MAX_PATH_LEN) return null;
        if (end == path.len) {
            @memcpy(out_name[0..component.len], component);
            return .{ .dir_cluster = dir_cluster, .name_len = component.len };
        }
        const entry = findInDir(dir_cluster, component) orelse return null;
        if (entryAttr(&entry) & ATTR_DIRECTORY == 0) return null;
        const child = entryFirst(&entry);
        if (child < 2 or child >= cluster_count + 2) return null;
        dir_cluster = child;
        start = end + 1;
    }
    return null;
}

fn updateFileEntry(fi: *const FileInfo) bool {
    const slot = findEntryLocation(fi.parent_cluster, fi.name[0..fi.name_len]) orelse return false;
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(slot.sector, &buf)) return false;
    writeU16(buf[slot.offset..], 20, @intCast((fi.first_cluster >> 16) & 0xFFFF));
    writeU16(buf[slot.offset..], 26, @intCast(fi.first_cluster & 0xFFFF));
    writeU32(buf[slot.offset..], 28, fi.file_size);
    return writeSector(slot.sector, &buf);
}

fn cacheName(entry: *const RawEntry, out: []u8) usize {
    return buildShortName(entry, out);
}

fn fat32Open(fs: *vfs.FileSystem, path: []const u8, flags: vfs.OpenFlags) ?*vfs.FileHandle {
    if (path.len == 0 or (path.len == 1 and path[0] == '/')) {
        if (flags.create or flags.write) return null;
        root_handle = .{ .fs = fs, .inode = 0, .offset = 0, .flags = flags, .data = null };
        return &root_handle;
    }
    var name_buf: [MAX_PATH_LEN]u8 = undefined;
    const resolved = resolvePath(path, &name_buf) orelse return null;
    var entry = findInDir(resolved.dir_cluster, name_buf[0..resolved.name_len]);
    if (entry == null and flags.create) {
        const slot = findFreeDirSlot(resolved.dir_cluster) orelse return null;
        if (!writeDirEntry(slot, name_buf[0..resolved.name_len], 0x20, 0, 0)) return null;
        entry = findInDir(resolved.dir_cluster, name_buf[0..resolved.name_len]);
    }
    const found = entry orelse return null;
    if (entryAttr(&found) & ATTR_DIRECTORY != 0 and !flags.directory) {
        // Directory handles are reserved for directory-aware callers; an
        // ordinary file open must never return a directory inode.
        return null;
    }

    var full_name: [MAX_PATH_LEN]u8 = undefined;
    const full_len = cacheName(&found, &full_name);
    var idx: ?usize = null;
    var free_idx: ?usize = null;
    var i: usize = 0;
    while (i < file_cache.len) : (i += 1) {
        if (file_cache[i].used) {
            if (file_cache[i].parent_cluster == resolved.dir_cluster and
                file_cache[i].name_len == full_len and
                namesEqual(file_cache[i].name[0..full_len], full_name[0..full_len]))
            {
                idx = i;
                break;
            }
        } else if (free_idx == null) free_idx = i;
    }
    const cache_idx = idx orelse free_idx orelse return null;
    if (idx == null) {
        file_cache[cache_idx] = .{};
        @memcpy(file_cache[cache_idx].name[0..full_len], full_name[0..full_len]);
        file_cache[cache_idx].name_len = full_len;
        file_cache[cache_idx].is_dir = entryAttr(&found) & ATTR_DIRECTORY != 0;
        file_cache[cache_idx].first_cluster = entryFirst(&found);
        file_cache[cache_idx].file_size = entrySize(&found);
        file_cache[cache_idx].parent_cluster = resolved.dir_cluster;
        file_cache[cache_idx].used = true;
        file_cache[cache_idx].ref_count = 1;
        if (cache_idx >= file_count) file_count = cache_idx + 1;
    } else {
        file_cache[cache_idx].first_cluster = entryFirst(&found);
        file_cache[cache_idx].file_size = entrySize(&found);
        file_cache[cache_idx].ref_count += 1;
    }

    if (flags.create and flags.truncate and !file_cache[cache_idx].is_dir) {
        freeChain(file_cache[cache_idx].first_cluster);
        file_cache[cache_idx].first_cluster = 0;
        file_cache[cache_idx].file_size = 0;
        _ = updateFileEntry(&file_cache[cache_idx]);
    }

    var h: usize = 0;
    while (h < open_handles.len) : (h += 1) {
        if (!open_handle_used[h]) {
            open_handles[h] = .{ .fs = fs, .inode = cache_idx, .offset = 0, .flags = flags, .data = null };
            if (flags.append and !flags.truncate and !file_cache[cache_idx].is_dir) {
                open_handles[h].offset = file_cache[cache_idx].file_size;
            }
            open_handle_used[h] = true;
            return &open_handles[h];
        }
    }
    if (file_cache[cache_idx].ref_count > 0) file_cache[cache_idx].ref_count -= 1;
    if (file_cache[cache_idx].ref_count == 0) file_cache[cache_idx].used = false;
    return null;
}

fn fat32Close(fs: *vfs.FileSystem, handle: *vfs.FileHandle) void {
    _ = fs;
    if (handle == &root_handle) return;
    var i: usize = 0;
    while (i < open_handles.len) : (i += 1) {
        if (&open_handles[i] == handle) {
            if (open_handle_used[i]) {
                open_handle_used[i] = false;
                const idx = open_handles[i].inode;
                if (idx < file_cache.len and file_cache[idx].used) {
                    if (file_cache[idx].ref_count > 0) file_cache[idx].ref_count -= 1;
                    if (file_cache[idx].ref_count == 0) file_cache[idx].used = false;
                }
            }
            return;
        }
    }
}

fn fat32Read(fs: *vfs.FileSystem, handle: *vfs.FileHandle, buf: []u8) usize {
    _ = fs;
    if (!handle.flags.read or handle.inode >= file_count) return 0;
    const fi = &file_cache[handle.inode];
    if (!fi.used or fi.is_dir or fi.file_size == 0 or handle.offset >= fi.file_size) return 0;
    const remaining = fi.file_size - @as(u32, @intCast(handle.offset));
    var wanted: usize = @intCast(remaining);
    if (wanted > buf.len) wanted = buf.len;
    const cluster_size = @as(u64, sectors_per_cluster) * SECTOR_SIZE;
    var pos = handle.offset;
    var written: usize = 0;
    while (written < wanted) {
        const cluster_index: u32 = @intCast(pos / cluster_size);
        const current = clusterAtIndex(fi.first_cluster, cluster_index, false) orelse break;
        const in_cluster: usize = @intCast(pos % cluster_size);
        const sector_in_cluster = in_cluster / SECTOR_SIZE;
        const within: usize = in_cluster % SECTOR_SIZE;
        var sector_buf: [SECTOR_SIZE]u8 = undefined;
        if (!readSector(clusterToSector(current) + sector_in_cluster, &sector_buf)) break;
        const chunk = @min(wanted - written, SECTOR_SIZE - within);
        @memcpy(buf[written..][0..chunk], sector_buf[within..][0..chunk]);
        written += chunk;
        pos += chunk;
    }
    handle.offset = pos;
    return written;
}

fn fat32Write(fs: *vfs.FileSystem, handle: *vfs.FileHandle, buf: []const u8) usize {
    _ = fs;
    if (!handle.flags.write or handle.inode >= file_count or buf.len == 0) return 0;
    if (handle.offset > MAX_U32 or handle.offset + buf.len > MAX_U32) return 0;
    const fi = &file_cache[handle.inode];
    if (fi.is_dir) return 0;
    var new_file = false;
    if (fi.first_cluster == 0) {
        const first = allocateCluster() orelse return 0;
        fi.first_cluster = first;
        new_file = true;
    }
    const cluster_size = @as(u64, sectors_per_cluster) * SECTOR_SIZE;
    var pos = handle.offset;
    var written: usize = 0;
    while (written < buf.len) {
        const cluster_index: u32 = @intCast(pos / cluster_size);
        const current = clusterAtIndex(fi.first_cluster, cluster_index, true) orelse break;
        const in_cluster: usize = @intCast(pos % cluster_size);
        const sector_in_cluster = in_cluster / SECTOR_SIZE;
        const within = in_cluster % SECTOR_SIZE;
        var sector_buf: [SECTOR_SIZE]u8 = undefined;
        if (!readSector(clusterToSector(current) + sector_in_cluster, &sector_buf)) break;
        const chunk = @min(buf.len - written, SECTOR_SIZE - within);
        @memcpy(sector_buf[within..][0..chunk], buf[written..][0..chunk]);
        if (!writeSector(clusterToSector(current) + sector_in_cluster, &sector_buf)) break;
        written += chunk;
        pos += chunk;
    }
    if (written == 0) {
        if (new_file) {
            freeChain(fi.first_cluster);
            fi.first_cluster = 0;
        }
        return 0;
    }
    handle.offset = pos;
    if (pos > fi.file_size) {
        if (pos > MAX_U32) return written;
        fi.file_size = @intCast(pos);
    }
    _ = updateFileEntry(fi);
    return written;
}

fn fat32Readdir(fs: *vfs.FileSystem, path: []const u8, entries: []vfs.DirEntry) usize {
    _ = fs;
    var dir_cluster = root_cluster;
    if (path.len > 1) {
        var name_buf: [MAX_PATH_LEN]u8 = undefined;
        const resolved = resolvePath(path, &name_buf) orelse return 0;
        const entry = findInDir(resolved.dir_cluster, name_buf[0..resolved.name_len]) orelse return 0;
        if (entryAttr(&entry) & ATTR_DIRECTORY == 0) return 0;
        const child = entryFirst(&entry);
        if (child < 2 or child >= cluster_count + 2) return 0;
        dir_cluster = child;
    }

    var out_count: usize = 0;
    var current = dir_cluster;
    var guard: u32 = 0;
    while (current >= 2 and current < 0x0FFFFFF8 and guard < cluster_count + 2) : (guard += 1) {
        const base = clusterToSector(current);
        var sector_in_cluster: u32 = 0;
        while (sector_in_cluster < sectors_per_cluster) : (sector_in_cluster += 1) {
            var buf: [SECTOR_SIZE]u8 = undefined;
            if (!readSector(base + sector_in_cluster, &buf)) return out_count;
            var off: usize = 0;
            while (off < SECTOR_SIZE and out_count < entries.len) : (off += DIR_ENTRY_SIZE) {
                const entry: RawEntry = buf[off..][0..DIR_ENTRY_SIZE].*;
                if (entry[0] == 0) return out_count;
                if (entry[0] == 0xE5) continue;
                if (entryAttr(&entry) & (ATTR_VOLUME_ID | ATTR_LONG_NAME) != 0) continue;
                if (entry[0] == '.' and (entry[1] == 0 or entry[1] == ' ')) continue;
                const name_len = buildShortName(&entry, &entries[out_count].name);
                entries[out_count].name_len = name_len;
                entries[out_count].file_type = if (entryAttr(&entry) & ATTR_DIRECTORY != 0) .directory else .file;
                entries[out_count].size = entrySize(&entry);
                out_count += 1;
            }
        }
        current = nextCluster(current) orelse return out_count;
    }
    return out_count;
}

fn fat32Mkdir(fs: *vfs.FileSystem, path: []const u8) bool {
    _ = fs;
    var name_buf: [MAX_PATH_LEN]u8 = undefined;
    const parent = resolvePath(path, &name_buf) orelse return false;
    if (parent.name_len == 0) return false;
    if (findInDir(parent.dir_cluster, name_buf[0..parent.name_len]) != null) return false;
    const slot = findFreeDirSlot(parent.dir_cluster) orelse return false;
    const cluster = allocateCluster() orelse return false;
    if (!initDirCluster(cluster, parent.dir_cluster)) {
        _ = writeFatEntry(cluster, 0);
        return false;
    }
    if (!writeDirEntry(slot, name_buf[0..parent.name_len], ATTR_DIRECTORY, cluster, 0)) {
        freeChain(cluster);
        return false;
    }
    return true;
}

fn fat32Unlink(fs: *vfs.FileSystem, path: []const u8) bool {
    _ = fs;
    var name_buf: [MAX_PATH_LEN]u8 = undefined;
    const resolved = resolvePath(path, &name_buf) orelse return false;
    const entry = findInDir(resolved.dir_cluster, name_buf[0..resolved.name_len]) orelse return false;
    if (entryAttr(&entry) & ATTR_DIRECTORY != 0) return false;
    var cache_index: usize = 0;
    while (cache_index < file_cache.len) : (cache_index += 1) {
        const cached = &file_cache[cache_index];
        if (cached.used and cached.parent_cluster == resolved.dir_cluster and
            namesEqual(cached.name[0..cached.name_len], name_buf[0..resolved.name_len]) and
            cached.ref_count > 0)
        {
            return false;
        }
    }
    const slot = findEntryLocation(resolved.dir_cluster, name_buf[0..resolved.name_len]) orelse return false;
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(slot.sector, &buf)) return false;
    buf[slot.offset] = 0xE5;
    if (!writeSector(slot.sector, &buf)) return false;
    freeChain(entryFirst(&entry));
    return true;
}

fn fat32Stat(fs: *vfs.FileSystem, path: []const u8) ?vfs.StatInfo {
    _ = fs;
    if (path.len == 0 or (path.len == 1 and path[0] == '/')) return .{ .file_type = .directory, .size = 0, .inode = root_cluster };
    var name_buf: [MAX_PATH_LEN]u8 = undefined;
    const resolved = resolvePath(path, &name_buf) orelse return null;
    const entry = findInDir(resolved.dir_cluster, name_buf[0..resolved.name_len]) orelse return null;
    return .{
        .file_type = if (entryAttr(&entry) & ATTR_DIRECTORY != 0) .directory else .file,
        .size = entrySize(&entry),
        .inode = entryFirst(&entry),
    };
}

fn fat32Truncate(fs: *vfs.FileSystem, handle: *vfs.FileHandle, size: u64) bool {
    _ = fs;
    if (handle.inode >= file_count or size > MAX_U32) return false;
    const fi = &file_cache[handle.inode];
    if (fi.is_dir) return false;

    if (size == 0) {
        freeChain(fi.first_cluster);
        fi.first_cluster = 0;
        fi.file_size = 0;
        handle.offset = 0;
        return updateFileEntry(fi);
    }

    const cluster_size = @as(u64, sectors_per_cluster) * SECTOR_SIZE;
    const wanted: u32 = @intCast((size + cluster_size - 1) / cluster_size);
    if (fi.first_cluster == 0) {
        var previous: u32 = 0;
        var i: u32 = 0;
        while (i < wanted) : (i += 1) {
            const fresh = allocateCluster() orelse return false;
            if (previous == 0) {
                fi.first_cluster = fresh;
            } else if (!writeFatEntry(previous, fresh)) {
                freeChain(fi.first_cluster);
                fi.first_cluster = 0;
                return false;
            }
            previous = fresh;
        }
        if (!writeFatEntry(previous, FAT32_EOC)) {
            freeChain(fi.first_cluster);
            fi.first_cluster = 0;
            return false;
        }
    } else {
        const last = clusterAtIndex(fi.first_cluster, wanted - 1, true) orelse return false;
        const old_next = fatEntry(last);
        if (!writeFatEntry(last, FAT32_EOC)) return false;
        if (old_next) |tail| {
            if (tail >= 2 and tail < 0x0FFFFFF8) freeChain(tail);
        }
    }

    fi.file_size = @intCast(size);
    if (handle.offset > size) handle.offset = size;
    return updateFileEntry(fi);
}

fn fat32Seek(fs: *vfs.FileSystem, handle: *vfs.FileHandle, offset: u64) bool {
    _ = fs;
    if (handle.inode >= file_count or offset > MAX_U32) return false;
    handle.offset = offset;
    return true;
}

fn mountFs(fs_name: []const u8, mount_point: []const u8) bool {
    if (fs_mounted) return true;
    var fs = vfs.FileSystem{
        .name = undefined,
        .mount_point = undefined,
        .mount_point_len = 0,
        .@"opaque" = null,
        .openFn = fat32Open,
        .closeFn = fat32Close,
        .readFn = fat32Read,
        .writeFn = fat32Write,
        .readdirFn = fat32Readdir,
        .mkdirFn = fat32Mkdir,
        .unlinkFn = fat32Unlink,
        .statFn = fat32Stat,
        .truncateFn = fat32Truncate,
        .seekFn = fat32Seek,
    };
    @memset(&fs.name, 0);
    @memcpy(fs.name[0..@min(fs_name.len, fs.name.len)], fs_name[0..@min(fs_name.len, fs.name.len)]);
    @memset(&fs.mount_point, 0);
    @memcpy(fs.mount_point[0..@min(mount_point.len, fs.mount_point.len)], mount_point[0..@min(mount_point.len, fs.mount_point.len)]);
    fs.mount_point_len = @min(mount_point.len, fs.mount_point.len);
    if (!vfs.mount("fat32", mount_point, &fs)) return false;
    fs_mounted = true;
    mount_point_len = @min(mount_point.len, mount_point_buf.len);
    @memcpy(mount_point_buf[0..mount_point_len], mount_point[0..mount_point_len]);
    serial.serialWrite("[FAT32] Mounted at ");
    serial.serialWrite(mount_point);
    serial.serialWrite("\n");
    return true;
}

fn tryMount(dev: *blockdev.BlockDevice, mount_point: []const u8) bool {
    if (dev.sector_size != SECTOR_SIZE) return false;
    fat_dev = dev;
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(0, &buf) or !parseBootSector(&buf) or total_sectors > blockdev.totalSectors(dev)) {
        fat_dev = null;
        return false;
    }
    if (!mountFs("fat32", mount_point)) {
        fat_dev = null;
        return false;
    }
    serial.serialWrite("[FAT32] ");
    serial.serialWrite(dev.name[0 .. std.mem.indexOfScalar(u8, &dev.name, 0) orelse dev.name.len]);
    serial.serialWrite(" sectors/cluster=");
    serial.serialWriteDec(sectors_per_cluster);
    serial.serialWrite(" FAT sectors=");
    serial.serialWriteDec(fat_size_sectors);
    serial.serialWrite(" root cluster=");
    serial.serialWriteDec(root_cluster);
    serial.serialWrite("\n");
    return true;
}

pub fn init() void {
    if (fs_mounted) return;
    var mounted: usize = 0;
    var i: usize = 0;
    while (i < blockdev.device_count) : (i += 1) {
        const dev = blockdev.devices[i];
        const point: []const u8 = if (!vfs.isMountedAt("/mnt/disk") and mounted == 0)
            "/mnt/disk"
        else
            "/log";
        if (tryMount(dev, point)) {
            mounted += 1;
            break; // MVP has one static FAT32 volume state
        }
    }
    if (mounted == 0) serial.serialWrite("[FAT32] No FAT32 filesystem found\n");
}

pub fn isMounted() bool {
    return fs_mounted;
}

pub fn mountPoint() []const u8 {
    return mount_point_buf[0..mount_point_len];
}
