//! ELF64 program loader.
//!
//! Produces a `LoadedImage` describing everything the process setup code needs:
//! entry point, the mapped program-header table (for AT_PHDR/AT_PHNUM, which
//! glibc/musl walk to find PT_TLS), and the end of the image (the initial brk).

const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const address_space = @import("address_space.zig");
const serial = @import("../system/serial.zig");
const vfs = @import("../fs/vfs.zig");
const kalloc = @import("kalloc.zig");
const binfmt = @import("binfmt.zig");

// ELF64 Headers
pub const Elf64_Ehdr = extern struct {
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

pub const Elf64_Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;
pub const PT_PHDR: u32 = 6;
pub const PT_TLS: u32 = 7;

const ET_EXEC: u16 = 2;
const ET_DYN: u16 = 3;
const EM_X86_64: u16 = 62;

const PF_X: u32 = 1;
const PF_W: u32 = 2;

/// Base applied to ET_DYN (static-PIE) images, which are linked at vaddr 0.
const PIE_BASE: u64 = 0x10000000;

pub fn isElf(data: []const u8) bool {
    return data.len >= @sizeOf(Elf64_Ehdr) and std.mem.eql(u8, data[0..4], "\x7fELF");
}

pub fn load(addr_space: address_space.AddressSpace, data: []const u8) !binfmt.LoadedImage {
    if (data.len < @sizeOf(Elf64_Ehdr)) {
        serial.serialWrite("[ELF] Error: data too small for header\n");
        return error.InvalidElfHeader;
    }

    var ehdr: Elf64_Ehdr = undefined;
    @memcpy(@as([*]u8, @ptrCast(&ehdr))[0..@sizeOf(Elf64_Ehdr)], data[0..@sizeOf(Elf64_Ehdr)]);

    if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7fELF")) {
        serial.serialWrite("[ELF] Error: invalid magic number\n");
        return error.InvalidElfMagic;
    }
    if (ehdr.e_ident[4] != 2) { // ELFCLASS64
        serial.serialWrite("[ELF] Error: not 64-bit ELF\n");
        return error.InvalidElfClass;
    }
    if (ehdr.e_ident[5] != 1) { // ELFDATA2LSB
        serial.serialWrite("[ELF] Error: not little-endian\n");
        return error.InvalidElfClass;
    }
    if (ehdr.e_machine != EM_X86_64) {
        serial.serialWrite("[ELF] Error: not x86-64\n");
        return error.UnsupportedMachine;
    }
    if (ehdr.e_type != ET_EXEC and ehdr.e_type != ET_DYN) {
        serial.serialWrite("[ELF] Error: not an executable\n");
        return error.UnsupportedElfType;
    }
    if (ehdr.e_phentsize < @sizeOf(Elf64_Phdr) or ehdr.e_phnum == 0) {
        serial.serialWrite("[ELF] Error: no program headers\n");
        return error.TruncatedElf;
    }
    if (data.len < ehdr.e_phoff + @as(u64, ehdr.e_phnum) * ehdr.e_phentsize) {
        serial.serialWrite("[ELF] Error: truncated program headers\n");
        return error.TruncatedElf;
    }

    const bias: u64 = if (ehdr.e_type == ET_DYN) PIE_BASE else 0;

    var image: binfmt.LoadedImage = .{
        .entry = ehdr.e_entry + bias,
        .format = .elf,
        .load_base = bias,
        .phdr_vaddr = 0,
        .phentsize = ehdr.e_phentsize,
        .phnum = ehdr.e_phnum,
        .image_end = 0,
        .needs_interp = false,
    };

    var i: usize = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        var ph: Elf64_Phdr = undefined;
        const off = ehdr.e_phoff + i * ehdr.e_phentsize;
        @memcpy(@as([*]u8, @ptrCast(&ph))[0..@sizeOf(Elf64_Phdr)], data[off..][0..@sizeOf(Elf64_Phdr)]);

        if (ph.p_type == PT_INTERP) {
            // A dynamic loader would have to be mapped and run; we have no
            // ld.so, so tell the caller instead of loading a broken image.
            image.needs_interp = true;
            serial.serialWrite("[ELF] Error: dynamically linked (needs an interpreter)\n");
            return error.NeedsInterpreter;
        }
        if (ph.p_type == PT_PHDR) {
            image.phdr_vaddr = ph.p_vaddr + bias;
        }
        if (ph.p_type != PT_LOAD) continue;
        if (ph.p_filesz > ph.p_memsz) return error.InvalidElfHeader;
        if (ph.p_offset + ph.p_filesz > data.len) return error.TruncatedElf;

        try mapSegment(addr_space, data, ph, bias);

        const seg_end = ph.p_vaddr + bias + ph.p_memsz;
        if (seg_end > image.image_end) image.image_end = seg_end;
    }

    if (image.image_end == 0) return error.InvalidElfHeader;

    // Without PT_PHDR (common for hand-linked binaries) derive the phdr address
    // from the segment that contains file offset e_phoff.
    if (image.phdr_vaddr == 0) {
        image.phdr_vaddr = phdrVaddrFromSegments(data, ehdr, bias);
    }

    serial.serialWrite("[ELF] Loaded: entry=0x");
    serial.serialWriteHex(image.entry);
    serial.serialWrite(" phdr=0x");
    serial.serialWriteHex(image.phdr_vaddr);
    serial.serialWrite(" end=0x");
    serial.serialWriteHex(image.image_end);
    serial.serialWrite("\n");

    return image;
}

/// Map one PT_LOAD segment page by page.
///
/// Segments are not page-aligned and adjacent segments routinely share a page
/// (a RX segment ending mid-page followed by a RW one starting in the same
/// page). The old loader allocated a fresh physical run per segment, so the
/// second segment silently replaced the shared page's first half with zeroes.
/// Mapping per page and reusing whatever is already mapped fixes that.
fn mapSegment(
    addr_space: address_space.AddressSpace,
    data: []const u8,
    ph: Elf64_Phdr,
    bias: u64,
) !void {
    const vstart = ph.p_vaddr + bias;
    const vend = vstart + ph.p_memsz;
    const page_start = vstart & ~@as(u64, 0xFFF);
    const page_end = (vend + 0xFFF) & ~@as(u64, 0xFFF);

    var flags: u64 = vmm.PAGE_USER;
    if (ph.p_flags & PF_W != 0) flags |= vmm.PAGE_WRITE;
    // Everything stays executable: we do not set PAGE_NX because the kernel
    // never enabled EFER.NXE, and setting bit 63 without it faults.

    var vaddr = page_start;
    while (vaddr < page_end) : (vaddr += 0x1000) {
        const existing = addr_space.translate(vaddr);
        const phys = existing orelse blk: {
            const p = pmm.allocPage() orelse {
                serial.serialWrite("[ELF] Error: out of physical memory\n");
                return error.OutOfMemory;
            };
            @memset(@as([*]u8, @ptrFromInt(p))[0..4096], 0);
            break :blk p;
        };

        // A page shared with an earlier segment must gain the union of flags.
        addr_space.mapUserPage(vaddr, phys, flags);

        // Copy the file-backed part of this page, if any.
        const file_end = vstart + ph.p_filesz;
        const copy_lo = @max(vaddr, vstart);
        const copy_hi = @min(vaddr + 0x1000, file_end);
        if (copy_hi > copy_lo) {
            const dst: [*]u8 = @ptrFromInt(phys + (copy_lo - vaddr));
            const src_off = ph.p_offset + (copy_lo - vstart);
            const len: usize = @intCast(copy_hi - copy_lo);
            @memcpy(dst[0..len], data[@intCast(src_off)..][0..len]);
        }
    }
}

fn phdrVaddrFromSegments(data: []const u8, ehdr: Elf64_Ehdr, bias: u64) u64 {
    var i: usize = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        var ph: Elf64_Phdr = undefined;
        const off = ehdr.e_phoff + i * ehdr.e_phentsize;
        @memcpy(@as([*]u8, @ptrCast(&ph))[0..@sizeOf(Elf64_Phdr)], data[off..][0..@sizeOf(Elf64_Phdr)]);
        if (ph.p_type != PT_LOAD) continue;
        if (ehdr.e_phoff >= ph.p_offset and ehdr.e_phoff < ph.p_offset + ph.p_filesz) {
            return ph.p_vaddr + bias + (ehdr.e_phoff - ph.p_offset);
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Backwards-compatible helpers used by the existing scheduler/exec paths.
// ---------------------------------------------------------------------------

pub fn loadElf(addr_space: address_space.AddressSpace, elf_data: []const u8) !u64 {
    const image = try load(addr_space, elf_data);
    return image.entry;
}

pub fn loadElfFromPath(addr_space: address_space.AddressSpace, path: []const u8) !u64 {
    const file = try binfmt.readFile(path);
    defer binfmt.freeFile(file);
    return loadElf(addr_space, file);
}
