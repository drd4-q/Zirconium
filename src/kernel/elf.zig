const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const address_space = @import("address_space.zig");
const serial = @import("../system/serial.zig");
const vfs = @import("../fs/vfs.zig");
const kalloc = @import("kalloc.zig");

// ELF64 Headers
const Elf64_Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Elf64_Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

const PT_LOAD: u32 = 1;

pub fn loadElf(addr_space: address_space.AddressSpace, elf_data: []const u8) !u64 {
    if (elf_data.len < @sizeOf(Elf64_Ehdr)) {
        serial.serialWrite("[ELF] Error: data too small for header\n");
        return error.InvalidElfHeader;
    }

    const ehdr = @as(*const Elf64_Ehdr, @ptrCast(@alignCast(elf_data.ptr)));
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7fELF")) {
        serial.serialWrite("[ELF] Error: invalid magic number\n");
        return error.InvalidElfMagic;
    }
    if (ehdr.e_ident[4] != 2) { // ELFCLASS64
        serial.serialWrite("[ELF] Error: not 64-bit ELF\n");
        return error.InvalidElfClass;
    }

    const ph_offset = ehdr.e_phoff;
    const ph_num = ehdr.e_phnum;
    const ph_entsize = ehdr.e_phentsize;

    if (elf_data.len < ph_offset + ph_num * ph_entsize) {
        serial.serialWrite("[ELF] Error: truncated program headers\n");
        return error.TruncatedElf;
    }

    serial.serialWrite("[ELF] Loading binary segments...\n");

    var i: usize = 0;
    while (i < ph_num) : (i += 1) {
        const offset = ph_offset + i * ph_entsize;
        const ph = @as(*const Elf64_Phdr, @ptrCast(@alignCast(&elf_data[offset])));

        if (ph.p_type == PT_LOAD) {
            // Allocate physical memory pages (taking in-page offset alignment into account)
            const offset_in_page = ph.p_vaddr & 0xFFF;
            const page_count = (offset_in_page + ph.p_memsz + 4095) / 4096;
            const paddr = pmm.allocPages(page_count) orelse {
                serial.serialWrite("[ELF] Error: failed to allocate pages\n");
                return error.OutOfMemory;
            };

            // Map segment range in user space
            var page_flags: u64 = 0;
            if (ph.p_flags & 2 != 0) { // Writable
                page_flags |= vmm.PAGE_WRITE;
            }
            addr_space.mapUserRange(ph.p_vaddr, paddr, ph.p_memsz, page_flags);

            // Copy segment data to physical memory (identity mapped in kernel)
            const dest_ptr: [*]u8 = @ptrFromInt(paddr + offset_in_page);
            @memcpy(dest_ptr[0..ph.p_filesz], elf_data[ph.p_offset .. ph.p_offset + ph.p_filesz]);

            // Zero remaining memory (BSS)
            if (ph.p_memsz > ph.p_filesz) {
                @memset(dest_ptr[ph.p_filesz..ph.p_memsz], 0);
            }

            serial.serialWrite("[ELF] Loaded PT_LOAD segment: vaddr=0x");
            serial.serialWriteHex(ph.p_vaddr);
            serial.serialWrite(" size=0x");
            serial.serialWriteHex(ph.p_memsz);
            serial.serialWrite("\n");
        }
    }

    serial.serialWrite("[ELF] ELF loaded successfully, entry=0x");
    serial.serialWriteHex(ehdr.e_entry);
    serial.serialWrite("\n");

    return ehdr.e_entry;
}

pub fn loadElfFromPath(addr_space: address_space.AddressSpace, path: []const u8) !u64 {
    // Get file size
    const info = vfs.stat(path) orelse {
        serial.serialWrite("[ELF] File not found: ");
        serial.serialWrite(path);
        serial.serialWrite("\n");
        return error.FileNotFound;
    };
    if (info.size == 0) return error.InvalidElfHeader;

    // Allocate kernel buffer for the file
    const buf = @as([*]u8, @ptrFromInt(@intFromPtr(kalloc.kmalloc(@as(usize, @intCast(info.size))) orelse return error.OutOfMemory)));
    defer kalloc.kfree(@ptrFromInt(@intFromPtr(buf)));

    // Open and read file
    const handle = vfs.open(path, .{ .read = true }) orelse {
        serial.serialWrite("[ELF] Failed to open: ");
        serial.serialWrite(path);
        serial.serialWrite("\n");
        return error.FileNotFound;
    };
    defer vfs.close(handle);

    const bytes_read = vfs.read(handle, buf[0..@as(usize, @intCast(info.size))]);
    if (bytes_read < @as(usize, @intCast(info.size))) {
        serial.serialWrite("[ELF] Short read\n");
        return error.InvalidElfHeader;
    }

    return loadElf(addr_space, buf[0..bytes_read]);
}
