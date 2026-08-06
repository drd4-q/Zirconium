const std = @import("std");
const root = @import("root");
const vga = root.vga;
const serial = @import("../system/serial.zig");

// File types
pub const FileType = enum(u8) {
    unknown = 0,
    file = 1,
    directory = 2,
    symlink = 3,
};

// Open flags
pub const OpenFlags = struct {
    read: bool = true,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    directory: bool = false,
};

// Directory entry
pub const DirEntry = struct {
    name: [64]u8,
    name_len: usize,
    file_type: FileType,
    size: u64,
};

// Stat info
pub const StatInfo = struct {
    file_type: FileType,
    size: u64,
    inode: usize,
};

// FileSystem operations (interface)
pub const FileSystem = struct {
    name: [16]u8,
    mount_point: [64]u8,
    mount_point_len: usize,
    @"opaque": ?*anyopaque,

    // Function pointers
    openFn: *const fn (self: *FileSystem, path: []const u8, flags: OpenFlags) ?*FileHandle,
    closeFn: *const fn (self: *FileSystem, handle: *FileHandle) void,
    readFn: *const fn (self: *FileSystem, handle: *FileHandle, buf: []u8) usize,
    writeFn: *const fn (self: *FileSystem, handle: *FileHandle, buf: []const u8) usize,
    readdirFn: *const fn (self: *FileSystem, path: []const u8, entries: []DirEntry) usize,
    mkdirFn: *const fn (self: *FileSystem, path: []const u8) bool,
    unlinkFn: *const fn (self: *FileSystem, path: []const u8) bool,
    statFn: *const fn (self: *FileSystem, path: []const u8) ?StatInfo,
    truncateFn: *const fn (self: *FileSystem, handle: *FileHandle, size: u64) bool,
    seekFn: *const fn (self: *FileSystem, handle: *FileHandle, offset: u64) bool,
};

// File handle
pub const FileHandle = struct {
    fs: *FileSystem,
    inode: usize,
    offset: u64,
    flags: OpenFlags,
    data: ?*anyopaque,
};

// Maximum mounted filesystems
const MAX_MOUNTS: usize = 8;
const MAX_OPEN_FILES: usize = 32;

var mounts: [MAX_MOUNTS]FileSystem = undefined;
var mount_count: usize = 0;
var open_files: [MAX_OPEN_FILES]FileHandle = undefined;
var file_used: [MAX_OPEN_FILES]bool = [_]bool{false} ** MAX_OPEN_FILES;

// Current working directory
var cwd: [256]u8 = undefined;
var cwd_len: usize = 1;

pub fn init() void {
    mount_count = 0;
    cwd[0] = '/';
    cwd_len = 1;
    serial.serialWrite("[VFS] Initialized\n");
}

pub fn mount(name: []const u8, mount_point: []const u8, fs: *FileSystem) bool {
    if (mount_count >= MAX_MOUNTS) return false;

    @memset(&mounts[mount_count].name, 0);
    for (name, 0..) |ch, i| {
        if (i < 15) mounts[mount_count].name[i] = ch;
    }

    @memset(&mounts[mount_count].mount_point, 0);
    for (mount_point, 0..) |ch, i| {
        if (i < 63) mounts[mount_count].mount_point[i] = ch;
    }
    mounts[mount_count].mount_point_len = mount_point.len;

    mounts[mount_count].@"opaque" = fs.@"opaque";
    mounts[mount_count].openFn = fs.openFn;
    mounts[mount_count].closeFn = fs.closeFn;
    mounts[mount_count].readFn = fs.readFn;
    mounts[mount_count].writeFn = fs.writeFn;
    mounts[mount_count].readdirFn = fs.readdirFn;
    mounts[mount_count].mkdirFn = fs.mkdirFn;
    mounts[mount_count].unlinkFn = fs.unlinkFn;
    mounts[mount_count].statFn = fs.statFn;
    mounts[mount_count].truncateFn = fs.truncateFn;
    mounts[mount_count].seekFn = fs.seekFn;

    mount_count += 1;

    serial.serialWrite("[VFS] Mounted ");
    serial.serialWrite(name);
    serial.serialWrite(" at ");
    serial.serialWrite(mount_point);
    serial.serialWrite("\n");

    return true;
}

fn findMount(path: []const u8) ?*FileSystem {
    var best_len: usize = 0;
    var best_idx: usize = 0;
    var i: usize = 0;
    while (i < mount_count) : (i += 1) {
        const mp = mounts[i].mount_point[0..mounts[i].mount_point_len];
        if (path.len >= mp.len) {
            var matches = true;
            for (mp, 0..) |ch, j| {
                if (path[j] != ch) {
                    matches = false;
                    break;
                }
            }
            if (matches and mp.len > best_len) {
                best_len = mp.len;
                best_idx = i;
            }
        }
    }
    if (best_len > 0) return &mounts[best_idx];
    return null;
}

fn resolvePath(path: []const u8) []const u8 {
    // Simple: if path starts with '/', it's absolute
    if (path.len > 0 and path[0] == '/') return path;

    // Otherwise prepend CWD
    return path; // TODO: proper relative path resolution
}

pub fn open(path: []const u8, flags: OpenFlags) ?*FileHandle {
    const resolved = resolvePath(path);
    const fs = findMount(resolved) orelse {
        serial.serialWrite("[VFS] No filesystem for path: ");
        serial.serialWrite(path);
        serial.serialWrite("\n");
        return null;
    };

    // Get relative path within mount
    const rel_path = resolved[fs.mount_point_len..];

    const handle = fs.openFn(fs, rel_path, flags) orelse return null;

    // Find free file handle slot
    var i: usize = 0;
    while (i < MAX_OPEN_FILES) : (i += 1) {
        if (!file_used[i]) {
            open_files[i] = handle.*;
            file_used[i] = true;
            return &open_files[i];
        }
    }

    // No free slot — close the handle
    fs.closeFn(fs, handle);
    return null;
}

pub fn close(handle: *FileHandle) void {
    handle.fs.closeFn(handle.fs, handle);

    // Mark slot as free
    var i: usize = 0;
    while (i < MAX_OPEN_FILES) : (i += 1) {
        if (&open_files[i] == handle) {
            file_used[i] = false;
            return;
        }
    }
}

pub fn read(handle: *FileHandle, buf: []u8) usize {
    return handle.fs.readFn(handle.fs, handle, buf);
}

pub fn write(handle: *FileHandle, buf: []const u8) usize {
    return handle.fs.writeFn(handle.fs, handle, buf);
}

pub fn readdir(path: []const u8, entries: []DirEntry) usize {
    const resolved = resolvePath(path);
    const fs = findMount(resolved) orelse return 0;
    const rel_path = resolved[fs.mount_point_len..];
    return fs.readdirFn(fs, rel_path, entries);
}

pub fn mkdir(path: []const u8) bool {
    const resolved = resolvePath(path);
    const fs = findMount(resolved) orelse return false;
    const rel_path = resolved[fs.mount_point_len..];
    return fs.mkdirFn(fs, rel_path);
}

pub fn unlink(path: []const u8) bool {
    const resolved = resolvePath(path);
    const fs = findMount(resolved) orelse return false;
    const rel_path = resolved[fs.mount_point_len..];
    return fs.unlinkFn(fs, rel_path);
}

pub fn stat(path: []const u8) ?StatInfo {
    const resolved = resolvePath(path);
    const fs = findMount(resolved) orelse return null;
    const rel_path = resolved[fs.mount_point_len..];
    return fs.statFn(fs, rel_path);
}

pub fn truncate(handle: *FileHandle, size: u64) bool {
    return handle.fs.truncateFn(handle.fs, handle, size);
}

pub fn seek(handle: *FileHandle, offset: u64) bool {
    return handle.fs.seekFn(handle.fs, handle, offset);
}

pub fn getCwd() []const u8 {
    return cwd[0..cwd_len];
}

pub fn setCwd(path: []const u8) void {
    if (path.len < 256) {
        for (path, 0..) |ch, i| {
            cwd[i] = ch;
        }
        cwd_len = path.len;
    }
}

pub fn printMounts() void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== Mounted Filesystems ===\n\n");
    vga.setColor(.white, .black);

    if (mount_count == 0) {
        vga.setColor(.light_gray, .black);
        vga.write("  No filesystems mounted\n\n");
        vga.setColor(.white, .black);
        return;
    }

    var i: usize = 0;
    while (i < mount_count) : (i += 1) {
        vga.write("  ");
        // Find name length
        var name_len: usize = 0;
        while (name_len < 16 and mounts[i].name[name_len] != 0) : (name_len += 1) {}
        vga.write(mounts[i].name[0..name_len]);
        vga.write(" on ");
        vga.write(mounts[i].mount_point[0..mounts[i].mount_point_len]);
        vga.write("\n");
    }
    vga.write("\n");
}
