const std = @import("std");
const root = @import("root");
const vga = root.vga;
const serial = @import("../system/serial.zig");
const kalloc = @import("../kernel/kalloc.zig");
const vfs = @import("vfs.zig");

const MAX_NODES: usize = 256;
const MAX_NAME: usize = 64;
const MAX_FILE_SIZE: usize = 64 * 1024; // 64KB max file
const MAX_ENTRIES: usize = 128; // max dir entries

const RamNode = struct {
    name: [MAX_NAME]u8,
    name_len: usize,
    file_type: vfs.FileType,
    size: u64,
    data: ?[*]u8,
    parent: ?usize, // index of parent node
    children: [MAX_ENTRIES]usize, // child node indices
    child_count: usize,
    used: bool = false,
};

var nodes: [MAX_NODES]RamNode = undefined;
var node_count: usize = 0;
var root_idx: usize = 0;

fn allocNode() ?usize {
    var i: usize = 0;
    while (i < MAX_NODES) : (i += 1) {
        if (!nodes[i].used) {
            nodes[i].used = true;
            nodes[i].data = null;
            nodes[i].child_count = 0;
            nodes[i].parent = null;
            @memset(&nodes[i].children, 0);
            return i;
        }
    }
    return null;
}

fn freeNode(idx: usize) void {
    if (idx >= MAX_NODES) return;
    if (nodes[idx].data) |d| {
        kalloc.kfree(d);
        nodes[idx].data = null;
    }
    nodes[idx].used = false;
}

fn findChild(parent_idx: usize, name: []const u8) ?usize {
    const parent = &nodes[parent_idx];
    var i: usize = 0;
    while (i < parent.child_count) : (i += 1) {
        const child_idx = parent.children[i];
        if (!nodes[child_idx].used) continue;
        if (nodes[child_idx].name_len != name.len) continue;
        var match = true;
        for (name, 0..) |ch, j| {
            if (nodes[child_idx].name[j] != ch) {
                match = false;
                break;
            }
        }
        if (match) return child_idx;
    }
    return null;
}

fn parsePath(path: []const u8) ?usize {
    if (path.len == 0 or path[0] != '/') return null;

    var current: usize = root_idx;
    var start: usize = 1;

    while (start < path.len) {
        // Find next '/'
        var end = start;
        while (end < path.len and path[end] != '/') {
            end += 1;
        }

        if (end == start) {
            start = end + 1;
            continue;
        }

        const name = path[start..end];
        const child = findChild(current, name) orelse return null;
        current = child;
        start = end + 1;
    }

    return current;
}

fn parseParentAndName(path: []const u8) ?struct { parent: usize, name: []const u8 } {
    if (path.len == 0 or path[0] != '/') return null;

    // Find last '/'
    var last_slash: i32 = -1;
    var i: i32 = @intCast(path.len - 1);
    while (i >= 0) : (i -= 1) {
        if (path[@intCast(i)] == '/') {
            last_slash = i;
            break;
        }
    }

    if (last_slash < 0) return null;

    const parent_path = path[0..@as(usize, @intCast(last_slash))];
    const name = path[@as(usize, @intCast(last_slash)) + 1 ..];

    if (name.len == 0) return null;

    const parent = if (parent_path.len == 0) root_idx else (parsePath(parent_path) orelse return null);

    return .{ .parent = parent, .name = name };
}

// VFS interface implementations

fn ramfsOpen(fs: *vfs.FileSystem, path: []const u8, flags: vfs.OpenFlags) ?*vfs.FileHandle {
    _ = fs;

    if (path.len == 0) return null;

    // Root directory
    if (path.len == 1 and path[0] == '/') {
        if (flags.create) {
            // Can't create root
            return null;
        }
        const handle = kalloc.kmalloc(@sizeOf(vfs.FileHandle)) orelse return null;
        const h: *vfs.FileHandle = @ptrFromInt(@intFromPtr(handle));
        h.inode = root_idx;
        h.offset = 0;
        h.flags = flags;
        h.data = null;
        return h;
    }

    // Try to find existing node
    if (parsePath(path)) |idx| {
        if (flags.create and flags.truncate) {
            // Truncate file
            if (nodes[idx].file_type == .file) {
                if (nodes[idx].data) |d| {
                    kalloc.kfree(d);
                    nodes[idx].data = null;
                }
                nodes[idx].size = 0;
            }
        }
        const handle = kalloc.kmalloc(@sizeOf(vfs.FileHandle)) orelse return null;
        const h: *vfs.FileHandle = @ptrFromInt(@intFromPtr(handle));
        h.inode = idx;
        h.offset = 0;
        h.flags = flags;
        h.data = null;
        return h;
    }

    // Create if requested
    if (flags.create) {
        const pn = parseParentAndName(path) orelse return null;
        const new_idx = allocNode() orelse return null;

        @memset(&nodes[new_idx].name, 0);
        for (pn.name, 0..) |ch, i| {
            if (i < MAX_NAME - 1) nodes[new_idx].name[i] = ch;
        }
        nodes[new_idx].name_len = pn.name.len;
        nodes[new_idx].file_type = if (flags.directory) .directory else .file;
        nodes[new_idx].size = 0;
        nodes[new_idx].parent = pn.parent;

        // Add to parent's children
        if (nodes[pn.parent].child_count < MAX_ENTRIES) {
            nodes[pn.parent].children[nodes[pn.parent].child_count] = new_idx;
            nodes[pn.parent].child_count += 1;
        }

        const handle = kalloc.kmalloc(@sizeOf(vfs.FileHandle)) orelse return null;
        const h: *vfs.FileHandle = @ptrFromInt(@intFromPtr(handle));
        h.inode = new_idx;
        h.offset = 0;
        h.flags = flags;
        h.data = null;
        return h;
    }

    return null;
}

fn ramfsClose(fs: *vfs.FileSystem, handle: *vfs.FileHandle) void {
    _ = fs;
    kalloc.kfree(@ptrFromInt(@intFromPtr(handle)));
}

fn ramfsRead(fs: *vfs.FileSystem, handle: *vfs.FileHandle, buf: []u8) usize {
    _ = fs;
    const node = &nodes[handle.inode];
    if (node.file_type != .file) return 0;
    if (node.data == null) return 0;

    const data = node.data.?;
    const available = node.size - handle.offset;
    const to_read = @min(buf.len, available);

    var i: usize = 0;
    while (i < to_read) : (i += 1) {
        buf[i] = data[handle.offset + i];
    }
    handle.offset += to_read;
    return to_read;
}

fn ramfsWrite(fs: *vfs.FileSystem, handle: *vfs.FileHandle, buf: []const u8) usize {
    _ = fs;
    const node = &nodes[handle.inode];
    if (node.file_type != .file) return 0;

    const new_size = handle.offset + buf.len;
    if (new_size > MAX_FILE_SIZE) return 0;

    // Allocate or reallocate data
    if (node.data == null) {
        node.data = @ptrFromInt(@intFromPtr(kalloc.kmalloc(new_size) orelse return 0));
    } else if (new_size > node.size) {
        const new_data = kalloc.krealloc(@ptrFromInt(@intFromPtr(node.data.?)), new_size) orelse return 0;
        node.data = @ptrFromInt(@intFromPtr(new_data));
    }

    const data = node.data.?;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        data[handle.offset + i] = buf[i];
    }

    if (new_size > node.size) {
        node.size = new_size;
    }
    handle.offset += buf.len;
    return buf.len;
}

fn ramfsReaddir(fs: *vfs.FileSystem, path: []const u8, entries: []vfs.DirEntry) usize {
    _ = fs;

    var dir_idx: usize = root_idx;
    if (path.len > 0 and !(path.len == 1 and path[0] == '/')) {
        dir_idx = parsePath(path) orelse return 0;
    }

    const node = &nodes[dir_idx];
    if (node.file_type != .directory) return 0;

    var count: usize = 0;
    var i: usize = 0;
    while (i < node.child_count and count < entries.len) : (i += 1) {
        const child_idx = node.children[i];
        if (!nodes[child_idx].used) continue;

        const child = &nodes[child_idx];
        @memset(&entries[count].name, 0);
        for (child.name[0..child.name_len], 0..) |ch, j| {
            entries[count].name[j] = ch;
        }
        entries[count].name_len = child.name_len;
        entries[count].file_type = child.file_type;
        entries[count].size = child.size;
        count += 1;
    }

    return count;
}

fn ramfsMkdir(fs: *vfs.FileSystem, path: []const u8) bool {
    _ = fs;

    const pn = parseParentAndName(path) orelse return false;

    // Check if already exists
    if (findChild(pn.parent, pn.name)) |_| return false;

    const new_idx = allocNode() orelse return false;

    @memset(&nodes[new_idx].name, 0);
    for (pn.name, 0..) |ch, i| {
        if (i < MAX_NAME - 1) nodes[new_idx].name[i] = ch;
    }
    nodes[new_idx].name_len = pn.name.len;
    nodes[new_idx].file_type = .directory;
    nodes[new_idx].size = 0;
    nodes[new_idx].parent = pn.parent;

    if (nodes[pn.parent].child_count < MAX_ENTRIES) {
        nodes[pn.parent].children[nodes[pn.parent].child_count] = new_idx;
        nodes[pn.parent].child_count += 1;
    }

    return true;
}

fn ramfsUnlink(fs: *vfs.FileSystem, path: []const u8) bool {
    _ = fs;

    const pn = parseParentAndName(path) orelse return false;
    const child = findChild(pn.parent, pn.name) orelse return false;

    // Remove from parent's children
    const parent = &nodes[pn.parent];
    var i: usize = 0;
    while (i < parent.child_count) : (i += 1) {
        if (parent.children[i] == child) {
            // Shift remaining entries
            var j = i;
            while (j + 1 < parent.child_count) : (j += 1) {
                parent.children[j] = parent.children[j + 1];
            }
            parent.child_count -= 1;
            break;
        }
    }

    // Free the node
    freeNode(child);
    return true;
}

fn ramfsStat(fs: *vfs.FileSystem, path: []const u8) ?vfs.StatInfo {
    _ = fs;

    var idx: usize = root_idx;
    if (path.len > 0 and !(path.len == 1 and path[0] == '/')) {
        idx = parsePath(path) orelse return null;
    }

    const node = &nodes[idx];
    return .{
        .file_type = node.file_type,
        .size = node.size,
        .inode = idx,
    };
}

fn ramfsTruncate(fs: *vfs.FileSystem, handle: *vfs.FileHandle, size: u64) bool {
    _ = fs;
    const node = &nodes[handle.inode];
    if (node.file_type != .file) return false;

    if (size == 0) {
        if (node.data) |d| {
            kalloc.kfree(d);
            node.data = null;
        }
        node.size = 0;
    } else if (size < node.size) {
        node.size = size;
        if (handle.offset > size) handle.offset = size;
    }
    return true;
}

fn ramfsSeek(fs: *vfs.FileSystem, handle: *vfs.FileHandle, offset: u64) bool {
    _ = fs;
    handle.offset = offset;
    return true;
}

pub fn init() void {
    @memset(&nodes, std.mem.zeroes(RamNode));

    // Create root directory
    root_idx = allocNode() orelse return;
    @memset(&nodes[root_idx].name, 0);
    nodes[root_idx].name[0] = '/';
    nodes[root_idx].name_len = 1;
    nodes[root_idx].file_type = .directory;
    nodes[root_idx].size = 0;
    nodes[root_idx].parent = null;

    // Create /dev, /tmp, /etc directories
    _ = ramfsMkdir(undefined, "/dev");
    _ = ramfsMkdir(undefined, "/tmp");
    _ = ramfsMkdir(undefined, "/etc");

    serial.serialWrite("[RAMFS] Initialized with root, /dev, /tmp, /etc\n");
}

pub fn registerMount() void {
    var fs = vfs.FileSystem{
        .name = undefined,
        .mount_point = undefined,
        .mount_point_len = 1,
        .@"opaque" = null,
        .openFn = ramfsOpen,
        .closeFn = ramfsClose,
        .readFn = ramfsRead,
        .writeFn = ramfsWrite,
        .readdirFn = ramfsReaddir,
        .mkdirFn = ramfsMkdir,
        .unlinkFn = ramfsUnlink,
        .statFn = ramfsStat,
        .truncateFn = ramfsTruncate,
        .seekFn = ramfsSeek,
    };

    @memset(&fs.name, 0);
    for ("ramfs", 0..) |ch, i| {
        if (i < 15) fs.name[i] = ch;
    }
    fs.name[4] = 'f';
    fs.name[5] = 's';

    @memset(&fs.mount_point, 0);
    fs.mount_point[0] = '/';

    _ = vfs.mount("ramfs", "/", &fs);
}
