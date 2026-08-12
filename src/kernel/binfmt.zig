//! Binary format dispatch: decides how an executable file should be loaded and
//! provides the format-independent description the process setup code needs.
//!
//! Supported today:
//!   * ELF64 x86-64, static (ET_EXEC) and static-PIE (ET_DYN) — `elf.zig`
//!   * PE32+ x86-64 console executables — `pe.zig`
//!
//! Dynamically linked binaries are rejected with a clear error instead of being
//! loaded into a crash: there is no runtime loader in this kernel.

const std = @import("std");
const serial = @import("../system/serial.zig");
const vfs = @import("../fs/vfs.zig");
const kalloc = @import("kalloc.zig");
const address_space = @import("address_space.zig");

pub const Format = enum {
    elf,
    pe,

    pub fn name(self: Format) []const u8 {
        return switch (self) {
            .elf => "ELF64",
            .pe => "PE32+",
        };
    }
};

/// The ABI a loaded image expects from the kernel.
pub const Personality = enum {
    /// Zirconium's own INT 0x80 ABI (see syscall.zig).
    native,
    /// Linux x86-64: `syscall` instruction, Linux call numbers, SysV stack.
    linux,
    /// Win64: entry called with the Microsoft ABI, imports resolved to thunks.
    windows,
};

pub const LoadedImage = struct {
    entry: u64,
    format: Format,
    /// Bias applied to a PIE/relocatable image (0 for fixed-address images).
    load_base: u64,
    /// Address of the mapped program header table (ELF only, 0 if unknown).
    phdr_vaddr: u64,
    phentsize: u16,
    phnum: u16,
    /// Highest mapped virtual address of the image, page-aligned upward by the
    /// caller to become the initial program break.
    image_end: u64,
    needs_interp: bool,

    pub fn personality(self: LoadedImage) Personality {
        return switch (self.format) {
            .elf => .linux,
            .pe => .windows,
        };
    }
};

/// Sniff the format from the file header.
pub fn detect(data: []const u8) ?Format {
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "\x7fELF")) return .elf;
    if (data.len >= 0x40 and data[0] == 'M' and data[1] == 'Z') {
        const e_lfanew = readU32(data, 0x3C);
        if (e_lfanew + 4 <= data.len and
            data[e_lfanew] == 'P' and data[e_lfanew + 1] == 'E' and
            data[e_lfanew + 2] == 0 and data[e_lfanew + 3] == 0)
        {
            return .pe;
        }
    }
    return null;
}

pub fn load(addr_space: address_space.AddressSpace, data: []const u8) !LoadedImage {
    const fmt = detect(data) orelse {
        serial.serialWrite("[BINFMT] Unrecognized executable format\n");
        return error.UnknownFormat;
    };
    return switch (fmt) {
        .elf => @import("elf.zig").load(addr_space, data),
        .pe => @import("pe.zig").load(addr_space, data),
    };
}

/// Read a whole file from the VFS into a kernel heap buffer.
/// Caller must release it with `freeFile`.
pub fn readFile(path: []const u8) ![]u8 {
    const info = vfs.stat(path) orelse {
        serial.serialWrite("[BINFMT] File not found: ");
        serial.serialWrite(path);
        serial.serialWrite("\n");
        return error.FileNotFound;
    };
    if (info.size == 0) return error.EmptyFile;
    const size: usize = @intCast(info.size);

    const raw = kalloc.kmalloc(size) orelse return error.OutOfMemory;
    const buf = raw[0..size];

    const handle = vfs.open(path, .{ .read = true }) orelse {
        kalloc.kfree(raw);
        return error.FileNotFound;
    };
    defer vfs.close(handle);

    // Filesystems return at most one cluster/segment per read call, so loop
    // until the whole file is in memory. The previous single-read version
    // silently truncated anything larger than one FAT16 cluster.
    var got: usize = 0;
    while (got < size) {
        const n = vfs.read(handle, buf[got..]);
        if (n == 0) break;
        got += n;
    }
    if (got < size) {
        serial.serialWrite("[BINFMT] Short read: got ");
        serial.serialWriteDec(got);
        serial.serialWrite(" of ");
        serial.serialWriteDec(size);
        serial.serialWrite("\n");
        kalloc.kfree(raw);
        return error.ShortRead;
    }

    return buf;
}

pub fn freeFile(buf: []u8) void {
    kalloc.kfree(buf.ptr);
}

pub fn readU16(data: []const u8, off: usize) u16 {
    return @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);
}

pub fn readU32(data: []const u8, off: usize) u32 {
    return @as(u32, data[off]) |
        (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) |
        (@as(u32, data[off + 3]) << 24);
}

pub fn readU64(data: []const u8, off: usize) u64 {
    return @as(u64, readU32(data, off)) | (@as(u64, readU32(data, off + 4)) << 32);
}
