//! PE32+ (x86-64) executable loader.
//!
//! Loads console-mode Windows executables: maps the sections at ImageBase (or a
//! relocated base, applying .reloc when the preferred base is unavailable), then
//! fills the import address table with kernel-provided thunks. Imported
//! functions are implemented in `winapi.zig`; anything not implemented gets a
//! stub that reports the missing symbol and terminates the process instead of
//! jumping to address zero.
//!
//! Not supported: GUI subsystem, TLS callbacks, delay-loaded imports, SEH,
//! forwarded exports. Those are reported, not silently ignored.

const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const address_space = @import("address_space.zig");
const serial = @import("../system/serial.zig");
const binfmt = @import("binfmt.zig");
const winapi = @import("winapi.zig");

const readU16 = binfmt.readU16;
const readU32 = binfmt.readU32;
const readU64 = binfmt.readU64;

const IMAGE_FILE_MACHINE_AMD64: u16 = 0x8664;
const PE32PLUS_MAGIC: u16 = 0x20B;

const SUBSYSTEM_NATIVE: u16 = 1;
const SUBSYSTEM_GUI: u16 = 2;
const SUBSYSTEM_CUI: u16 = 3;

const DIR_EXPORT: usize = 0;
const DIR_IMPORT: usize = 1;
const DIR_BASERELOC: usize = 5;
const DIR_TLS: usize = 9;
const DIR_DELAY_IMPORT: usize = 13;

const SCN_MEM_EXECUTE: u32 = 0x20000000;
const SCN_MEM_READ: u32 = 0x40000000;
const SCN_MEM_WRITE: u32 = 0x80000000;
const SCN_CNT_UNINIT_DATA: u32 = 0x00000080;

const IMAGE_REL_BASED_ABSOLUTE: u4 = 0;
const IMAGE_REL_BASED_DIR64: u4 = 10;

const IMAGE_ORDINAL_FLAG: u64 = 1 << 63;

/// Where a PE goes when its preferred ImageBase cannot be used. Windows images
/// normally want 0x140000000, which is above our user address range.
const PE_FALLBACK_BASE: u64 = 0x30000000;
/// Upper bound of the user address range we are willing to map an image into.
const USER_IMAGE_LIMIT: u64 = 0x70000000;

const Header = struct {
    machine: u16,
    section_count: u16,
    opt_size: u16,
    opt_off: usize,
    section_off: usize,
    entry_rva: u32,
    image_base: u64,
    image_size: u32,
    headers_size: u32,
    section_align: u32,
    subsystem: u16,
    dir_count: u32,
    dir_off: usize,

    fn dir(self: Header, data: []const u8, idx: usize) struct { rva: u32, size: u32 } {
        if (idx >= self.dir_count) return .{ .rva = 0, .size = 0 };
        const off = self.dir_off + idx * 8;
        return .{ .rva = readU32(data, off), .size = readU32(data, off + 4) };
    }
};

pub fn isPe(data: []const u8) bool {
    return binfmt.detect(data) == .pe;
}

pub fn load(addr_space: address_space.AddressSpace, data: []const u8) !binfmt.LoadedImage {
    const hdr = try parseHeader(data);

    if (hdr.subsystem == SUBSYSTEM_GUI) {
        serial.serialWrite("[PE] Error: GUI subsystem executables are not supported\n");
        return error.UnsupportedSubsystem;
    }
    if (hdr.subsystem != SUBSYSTEM_CUI and hdr.subsystem != SUBSYSTEM_NATIVE) {
        serial.serialWrite("[PE] Error: unsupported subsystem\n");
        return error.UnsupportedSubsystem;
    }

    const base = try chooseBase(data, hdr);

    try mapHeaders(addr_space, data, hdr, base);
    try mapSections(addr_space, data, hdr, base);

    if (base != hdr.image_base) {
        try applyRelocations(addr_space, data, hdr, base);
    }

    try resolveImports(addr_space, data, hdr, base);

    const tls = hdr.dir(data, DIR_TLS);
    if (tls.rva != 0) {
        serial.serialWrite("[PE] Warning: image has a TLS directory; callbacks are not run\n");
    }
    const delay = hdr.dir(data, DIR_DELAY_IMPORT);
    if (delay.rva != 0) {
        serial.serialWrite("[PE] Warning: delay-loaded imports are not resolved\n");
    }

    const image_end = base + alignUp(hdr.image_size, hdr.section_align);

    serial.serialWrite("[PE] Loaded: base=0x");
    serial.serialWriteHex(base);
    serial.serialWrite(" entry=0x");
    serial.serialWriteHex(base + hdr.entry_rva);
    serial.serialWrite(" end=0x");
    serial.serialWriteHex(image_end);
    serial.serialWrite("\n");

    return .{
        .entry = base + hdr.entry_rva,
        .format = .pe,
        .load_base = base,
        .phdr_vaddr = 0,
        .phentsize = 0,
        .phnum = 0,
        .image_end = image_end,
        .needs_interp = false,
    };
}

fn parseHeader(data: []const u8) !Header {
    if (data.len < 0x40) return error.TruncatedPe;
    const e_lfanew: usize = readU32(data, 0x3C);
    if (e_lfanew + 24 > data.len) return error.TruncatedPe;

    const coff = e_lfanew + 4;
    const machine = readU16(data, coff);
    if (machine != IMAGE_FILE_MACHINE_AMD64) {
        serial.serialWrite("[PE] Error: not an x86-64 image\n");
        return error.UnsupportedMachine;
    }

    const section_count = readU16(data, coff + 2);
    const opt_size = readU16(data, coff + 16);
    const opt_off = coff + 20;
    if (opt_off + opt_size > data.len) return error.TruncatedPe;
    if (opt_size < 112) return error.TruncatedPe;

    if (readU16(data, opt_off) != PE32PLUS_MAGIC) {
        serial.serialWrite("[PE] Error: not PE32+ (32-bit PE is unsupported)\n");
        return error.UnsupportedPeFormat;
    }

    const dir_count = readU32(data, opt_off + 108);
    const hdr = Header{
        .machine = machine,
        .section_count = section_count,
        .opt_size = opt_size,
        .opt_off = opt_off,
        .section_off = opt_off + opt_size,
        .entry_rva = readU32(data, opt_off + 16),
        .image_base = readU64(data, opt_off + 24),
        .section_align = readU32(data, opt_off + 32),
        .image_size = readU32(data, opt_off + 56),
        .headers_size = readU32(data, opt_off + 60),
        .subsystem = readU16(data, opt_off + 68),
        .dir_count = dir_count,
        .dir_off = opt_off + 112,
    };

    if (hdr.section_off + @as(usize, hdr.section_count) * 40 > data.len) return error.TruncatedPe;
    if (hdr.section_align == 0 or hdr.image_size == 0) return error.InvalidPeHeader;
    if (hdr.entry_rva == 0) {
        serial.serialWrite("[PE] Error: image has no entry point\n");
        return error.InvalidPeHeader;
    }

    return hdr;
}

/// Pick a load address. Prefer the image's own base when it fits our user range,
/// otherwise relocate — which requires a .reloc directory.
fn chooseBase(data: []const u8, hdr: Header) !u64 {
    const size = alignUp(hdr.image_size, hdr.section_align);

    if (hdr.image_base >= 0x10000 and hdr.image_base + size <= USER_IMAGE_LIMIT) {
        return hdr.image_base;
    }

    const reloc = hdr.dir(data, DIR_BASERELOC);
    if (reloc.rva == 0 or reloc.size == 0) {
        serial.serialWrite("[PE] Error: image must be relocated but has no .reloc section\n");
        return error.CannotRelocate;
    }
    if (PE_FALLBACK_BASE + size > USER_IMAGE_LIMIT) {
        serial.serialWrite("[PE] Error: image too large for the user address range\n");
        return error.ImageTooLarge;
    }
    return PE_FALLBACK_BASE;
}

fn mapHeaders(
    addr_space: address_space.AddressSpace,
    data: []const u8,
    hdr: Header,
    base: u64,
) !void {
    // The first page(s) hold the DOS/PE headers; some programs read them (and
    // GetModuleHandle-style tricks expect a valid DOS header at the base).
    const size = @min(@as(usize, hdr.headers_size), data.len);
    if (size == 0) return;
    if (!addr_space.allocUserRange(base, size, vmm.PAGE_WRITE)) return error.OutOfMemory;
    try copyInto(addr_space, base, data[0..size]);
}

fn mapSections(
    addr_space: address_space.AddressSpace,
    data: []const u8,
    hdr: Header,
    base: u64,
) !void {
    var i: usize = 0;
    while (i < hdr.section_count) : (i += 1) {
        const off = hdr.section_off + i * 40;
        const virt_size = readU32(data, off + 8);
        const virt_addr = readU32(data, off + 12);
        const raw_size = readU32(data, off + 16);
        const raw_off = readU32(data, off + 20);
        const chars = readU32(data, off + 36);

        const mem_size = if (virt_size != 0) virt_size else raw_size;
        if (mem_size == 0) continue;

        // Map every section writable: we have no per-page protection needs here
        // and the import thunk patching writes into .idata/.rdata.
        if (!addr_space.allocUserRange(base + virt_addr, mem_size, vmm.PAGE_WRITE)) {
            return error.OutOfMemory;
        }

        if (raw_size > 0 and chars & SCN_CNT_UNINIT_DATA == 0) {
            if (raw_off + raw_size > data.len) return error.TruncatedPe;
            const copy_len = @min(raw_size, mem_size);
            try copyInto(addr_space, base + virt_addr, data[raw_off..][0..copy_len]);
        }
    }
}

fn applyRelocations(
    addr_space: address_space.AddressSpace,
    data: []const u8,
    hdr: Header,
    base: u64,
) !void {
    const reloc = hdr.dir(data, DIR_BASERELOC);
    const delta = base -% hdr.image_base;

    const file_off = rvaToOffset(data, hdr, reloc.rva) orelse return error.InvalidPeHeader;
    var pos = file_off;
    const end = @min(file_off + reloc.size, data.len);
    var applied: usize = 0;

    while (pos + 8 <= end) {
        const page_rva = readU32(data, pos);
        const block_size = readU32(data, pos + 4);
        if (block_size < 8 or pos + block_size > end) break;

        var entry_off = pos + 8;
        while (entry_off + 2 <= pos + block_size) : (entry_off += 2) {
            const entry = readU16(data, entry_off);
            const kind: u4 = @intCast(entry >> 12);
            const offset: u16 = entry & 0x0FFF;
            if (kind == IMAGE_REL_BASED_ABSOLUTE) continue;
            if (kind != IMAGE_REL_BASED_DIR64) {
                serial.serialWrite("[PE] Error: unsupported relocation type\n");
                return error.UnsupportedRelocation;
            }
            const target = base + page_rva + offset;
            const old = try readU64At(addr_space, target);
            try writeU64At(addr_space, target, old +% delta);
            applied += 1;
        }

        pos += block_size;
    }

    serial.serialWrite("[PE] Applied ");
    serial.serialWriteDec(applied);
    serial.serialWrite(" relocations\n");
}

fn resolveImports(
    addr_space: address_space.AddressSpace,
    data: []const u8,
    hdr: Header,
    base: u64,
) !void {
    const imp = hdr.dir(data, DIR_IMPORT);
    if (imp.rva == 0) {
        serial.serialWrite("[PE] No imports\n");
        return;
    }

    var desc_off = rvaToOffset(data, hdr, imp.rva) orelse return error.InvalidPeHeader;
    var resolved: usize = 0;
    var missing: usize = 0;

    // Import descriptors: 20 bytes each, terminated by an all-zero entry.
    while (desc_off + 20 <= data.len) : (desc_off += 20) {
        const original_first_thunk = readU32(data, desc_off);
        const name_rva = readU32(data, desc_off + 12);
        const first_thunk = readU32(data, desc_off + 16);
        if (original_first_thunk == 0 and name_rva == 0 and first_thunk == 0) break;
        if (first_thunk == 0) continue;

        const dll = if (name_rva != 0) readCString(data, hdr, name_rva) else "";

        // The lookup table (OriginalFirstThunk) holds the names; FirstThunk is
        // the IAT we overwrite. Bound imports may only have FirstThunk.
        const lookup_rva = if (original_first_thunk != 0) original_first_thunk else first_thunk;
        var lookup_off = rvaToOffset(data, hdr, lookup_rva) orelse return error.InvalidPeHeader;
        var iat_addr = base + first_thunk;

        while (lookup_off + 8 <= data.len) : ({
            lookup_off += 8;
            iat_addr += 8;
        }) {
            const thunk = readU64(data, lookup_off);
            if (thunk == 0) break;

            var func_name: []const u8 = "";
            var ordinal: u16 = 0;
            if (thunk & IMAGE_ORDINAL_FLAG != 0) {
                ordinal = @intCast(thunk & 0xFFFF);
            } else {
                const hint_rva: u32 = @intCast(thunk & 0x7FFFFFFF);
                // Hint/Name table entry: u16 hint followed by a NUL-terminated name.
                func_name = readCString(data, hdr, hint_rva + 2);
            }

            const addr = winapi.resolve(dll, func_name, ordinal) orelse blk: {
                serial.serialWrite("[PE] Unimplemented import: ");
                serial.serialWrite(dll);
                serial.serialWrite("!");
                if (func_name.len > 0) {
                    serial.serialWrite(func_name);
                } else {
                    serial.serialWrite("#");
                    serial.serialWriteDec(ordinal);
                }
                serial.serialWrite("\n");
                missing += 1;
                break :blk winapi.unimplementedThunk();
            };

            try writeU64At(addr_space, iat_addr, addr);
            resolved += 1;
        }
    }

    serial.serialWrite("[PE] Imports: ");
    serial.serialWriteDec(resolved);
    serial.serialWrite(" bound (");
    serial.serialWriteDec(missing);
    serial.serialWrite(" unimplemented)\n");
}

// ---------------------------------------------------------------------------
// Helpers that write into the target address space through physical addresses.
// The image is not the current CR3 while we load it, so we cannot dereference
// user virtual addresses directly.
// ---------------------------------------------------------------------------

fn copyInto(addr_space: address_space.AddressSpace, vaddr: u64, src: []const u8) !void {
    var copied: usize = 0;
    while (copied < src.len) {
        const va = vaddr + copied;
        const page = va & ~@as(u64, 0xFFF);
        const in_page: usize = @intCast(va - page);
        const phys = addr_space.translate(page) orelse return error.UnmappedTarget;
        const chunk = @min(src.len - copied, 0x1000 - in_page);
        const dst: [*]u8 = @ptrFromInt(phys + in_page);
        @memcpy(dst[0..chunk], src[copied..][0..chunk]);
        copied += chunk;
    }
}

fn readU64At(addr_space: address_space.AddressSpace, vaddr: u64) !u64 {
    var buf: [8]u8 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const va = vaddr + i;
        const phys = addr_space.translate(va & ~@as(u64, 0xFFF)) orelse return error.UnmappedTarget;
        const p: [*]const u8 = @ptrFromInt(phys + @as(usize, @intCast(va & 0xFFF)));
        buf[i] = p[0];
    }
    return binfmt.readU64(&buf, 0);
}

fn writeU64At(addr_space: address_space.AddressSpace, vaddr: u64, value: u64) !void {
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const va = vaddr + i;
        const phys = addr_space.translate(va & ~@as(u64, 0xFFF)) orelse return error.UnmappedTarget;
        const p: [*]u8 = @ptrFromInt(phys + @as(usize, @intCast(va & 0xFFF)));
        p[0] = @intCast((value >> @intCast(i * 8)) & 0xFF);
    }
}

fn rvaToOffset(data: []const u8, hdr: Header, rva: u32) ?usize {
    var i: usize = 0;
    while (i < hdr.section_count) : (i += 1) {
        const off = hdr.section_off + i * 40;
        const virt_size = readU32(data, off + 8);
        const virt_addr = readU32(data, off + 12);
        const raw_size = readU32(data, off + 16);
        const raw_off = readU32(data, off + 20);
        const span = if (virt_size != 0) virt_size else raw_size;
        if (rva >= virt_addr and rva < virt_addr + span) {
            const delta = rva - virt_addr;
            if (delta >= raw_size) return null; // inside uninitialized data
            const file_off = raw_off + delta;
            if (file_off >= data.len) return null;
            return file_off;
        }
    }
    // RVAs inside the headers map 1:1 to file offsets.
    if (rva < hdr.headers_size and rva < data.len) return rva;
    return null;
}

fn readCString(data: []const u8, hdr: Header, rva: u32) []const u8 {
    const off = rvaToOffset(data, hdr, rva) orelse return "";
    var end = off;
    while (end < data.len and data[end] != 0) : (end += 1) {}
    return data[off..end];
}

fn alignUp(value: u32, alignment: u32) u64 {
    if (alignment == 0) return value;
    return (@as(u64, value) + alignment - 1) & ~(@as(u64, alignment) - 1);
}
