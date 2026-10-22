//! Loading a guest kernel into a machine's memory.
//!
//! This is the boot protocol's host side: the hypervisor reads the guest's
//! kernel image from the host's filesystem, places it in the guest's RAM,
//! builds the boot information the guest expects, and records where to start
//! executing.
//!
//! The protocol is **Multiboot 1**, because it is the cheapest one that
//! Linux, NetBSD and FreeBSD all understand:
//!
//!   * The guest's entry point is called in 32-bit protected mode with a
//!     flat 4 GB code segment, `EAX = 0x2BADB002` and `EBX` pointing at the
//!     information structure.
//!   * The guest's own 32-bit stub sets up long mode and jumps to the
//!     64-bit entry, which is the usual arrangement in a bzImage.
//!   * The information structure is a page-aligned block with the memory
//!     sizes, the command line and the module list, and it ends with the
//!     magic, the flags and the checksum that the guest checks.
//!
//! The guest's addresses are **guest physical** addresses: the guest's RAM
//! starts at zero, and the hypervisor knows where that lands in the host's
//! memory.

const std = @import("std");
const root = @import("root");
const serial = root.serial;
const mmu_mod = @import("mmu.zig");

pub const Memory = mmu_mod.Memory;

/// The Multiboot magic the guest expects in EAX.
pub const MULTIBOOT_MAGIC: u32 = 0x2BADB002;

/// Where the boot information block goes, in the guest's memory.
///
/// 0x1000 is where the Multiboot specification puts it, and it is the first
/// page the guest owns: the page below it is the traditional BIOS area
/// (the interrupt vector table and the BIOS data area), which a guest
/// expects to find already set up rather than have its own data there.
pub const MBINFO_GPA: u64 = 0x1000;

/// Where the command line goes.
pub const CMDLINE_GPA: u64 = 0x2000;

/// The guest's initial stack, in the low megabyte where the BIOS would have
/// put it.
pub const STACK_TOP_GPA: u64 = 0x0008_0000;

/// The size of the boot information block.
pub const MBINFO_SIZE: u64 = 4096;

/// The result of loading a guest.
pub const Loaded = struct {
    /// The guest physical address of the entry point.
    entry_gpa: u64,
    /// The guest physical address of the boot information block.
    mbinfo_gpa: u64,
    /// The guest physical address of the stack top.
    stack_gpa: u64,
    /// How many bytes of the image were loaded.
    bytes: usize,
    /// The image's path, for the log.
    path: []const u8,
};

pub const LoadError = error{
    /// The file could not be read.
    FileNotFound,
    /// The file is not an ELF image.
    NotAnElf,
    /// The image has no loadable segment.
    NoSegments,
    /// A segment does not fit in the guest's memory.
    OutOfGuestMemory,
    /// The guest has no RAM.
    NoMemory,
};

/// Load a guest kernel image into a machine's memory.
///
/// The image is read through the host's VFS, so a guest kernel is just a
/// file on the host's disk - the same disk the operator sees.  When the
/// file is not there, the **built-in sample guest** is loaded instead, so a
/// ZVM with nothing on its disk still has something to run.
pub fn loadFromPath(memory: Memory, path: []const u8) LoadError!Loaded {
    const binfmt = @import("../kernel/binfmt.zig");

    if (path.len != 0) {
        if (binfmt.readFile(path)) |image| {
            defer binfmt.freeFile(image);
            return load(memory, image, path);
        } else |_| {
            // No image on the disk.  The built-in sample is the fallback, and
            // the log says which one was used.
            serial.serialWrite("[ZVM] No image at ");
            serial.serialWrite(path);
            serial.serialWrite(", using the built-in sample guest\n");
        }
    }

    const builtin = @import("guest_kernel_bin");
    return load(memory, &builtin.data, "<built-in sample guest>");
}

/// Load a guest kernel image into a machine's memory.
///
/// The image is read through the host's VFS, so a guest kernel is just a
/// file on the host's disk - the same disk the operator sees.
pub fn load(memory: Memory, image: []const u8, path: []const u8) LoadError!Loaded {
    if (!memory.present()) return error.NoMemory;
    if (image.len < 64) return error.NotAnElf;
    if (!std.mem.eql(u8, image[0..4], "\x7fELF")) return error.NotAnElf;
    if (image[4] != 2) return error.NotAnElf; // ELFCLASS64
    if (image[5] != 1) return error.NotAnElf; // ELFDATA2LSB

    const phoff = readU64(image, 0x20);
    const phentsize = readU16(image, 0x36);
    const phnum = readU16(image, 0x38);
    const entry = readU64(image, 0x18);

    if (phoff + phnum * phentsize > image.len) return error.NotAnElf;

    var loaded: usize = 0;
    var segments: usize = 0;

    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const ph = phoff + i * phentsize;
        const p_type = readU32(image, ph);
        if (p_type != 1) continue; // PT_LOAD

        const p_offset = readU64(image, ph + 0x08);
        const p_vaddr = readU64(image, ph + 0x10);
        const p_filesz = readU64(image, ph + 0x20);
        const p_memsz = readU64(image, ph + 0x28);

        if (p_offset + p_filesz > image.len) return error.NotAnElf;
        if (p_vaddr + p_memsz > memory.ram_bytes) return error.OutOfGuestMemory;

        // Copy the file's part of the segment.
        if (p_filesz != 0) {
            copyIntoGuest(memory, p_vaddr, image[p_offset .. p_offset + p_filesz]);
        }
        // And zero the rest, so the guest sees the zeros it expects in .bss.
        if (p_memsz > p_filesz) {
            zeroInGuest(memory, p_vaddr + p_filesz, p_memsz - p_filesz);
        }

        // Compare what landed in the guest's memory with the file.  A
        // mismatch here is the difference between a guest that runs and one
        // that decodes garbage.
        {
            var k: u64 = 0;
            var bad: u64 = 0;
            while (k < p_filesz and bad < 8) : (k += 1) {
                const want = image[p_offset + k];
                const got = memory.readByte(p_vaddr + k) orelse 0;
                if (want != got) {
                    bad += 1;
                    serial.serialWrite("[ZVM]   segment mismatch at +0x");
                    serial.serialWriteHex(k);
                    serial.serialWrite(": file=0x");
                    serial.serialWriteHex(want);
                    serial.serialWrite(" mem=0x");
                    serial.serialWriteHex(got);
                    serial.serialWrite("\n");
                }
            }
            if (bad == 0) {
                serial.serialWrite("[ZVM]   segment at 0x");
                serial.serialWriteHex(p_vaddr);
                serial.serialWrite(" (");
                serial.serialWriteDec(p_filesz);
                serial.serialWrite(" bytes) verified\n");
            }
        }

        loaded += @intCast(p_filesz);
        segments += 1;
    }

    if (segments == 0) return error.NoSegments;

    // ── The boot information block ────────────────────────────────
    const cmdline = "zvm";
    buildMbinfo(memory, cmdline);

    return .{
        .entry_gpa = entry,
        .mbinfo_gpa = MBINFO_GPA,
        .stack_gpa = STACK_TOP_GPA,
        .bytes = loaded,
        .path = path,
    };
}

/// Build the Multiboot information block in the guest's memory.
///
/// The block is a page of mostly zeroes with the fields the guest reads at
/// the front and the magic, flags and checksum at the very end.
fn buildMbinfo(memory: Memory, cmdline: []const u8) void {
    // The command line, NUL terminated, in the guest's memory.
    var line_buf: [256]u8 = [_]u8{0} ** 256;
    const n = @min(cmdline.len, line_buf.len - 1);
    @memcpy(line_buf[0..n], cmdline[0..n]);
    copyIntoGuest(memory, CMDLINE_GPA, &line_buf);

    zeroInGuest(memory, MBINFO_GPA, MBINFO_SIZE);

    // flags: bit 0 = mem_lower/mem_upper valid, bit 2 = the command line is
    // present, bit 16 = the memory map is present.
    const flags: u32 = 1 | (1 << 2) | (1 << 16);
    putU32(memory, MBINFO_GPA + 0, flags);
    // mem_lower: the amount of conventional memory below 1 MB, in KB.
    putU32(memory, MBINFO_GPA + 4, 640);
    // mem_upper: the amount above 1 MB, in KB.
    const upper_kb: u32 = @intCast((memory.ram_bytes - (1024 * 1024)) / 1024);
    putU32(memory, MBINFO_GPA + 8, upper_kb);
    // boot_device: 0x01000000 is the "floppy" BIOS device number; a guest
    // that cares looks at the drive table instead.
    putU32(memory, MBINFO_GPA + 12, 0x0100_0000);
    // cmdline: the guest physical address of the string.
    putU32(memory, MBINFO_GPA + 16, @intCast(CMDLINE_GPA));
    // mods_count and mods_addr: no modules.
    putU32(memory, MBINFO_GPA + 20, 0);
    putU32(memory, MBINFO_GPA + 24, 0);

    // The memory map, right after the header: a sequence of entries
    // { base_addr: u64, length: u64, type: u32 } ending with a zero entry.
    const mmap = MBINFO_GPA + 32;
    putU64(memory, mmap + 0, 0);
    putU64(memory, mmap + 8, 0x0009_FC00); // the BIOS area
    putU32(memory, mmap + 16, 1); // available
    putU64(memory, mmap + 24, 0x0010_0000);
    putU64(memory, mmap + 32, memory.ram_bytes - 0x0010_0000);
    putU32(memory, mmap + 40, 1); // available
    // The terminating entry.
    putU64(memory, mmap + 48, 0);
    putU64(memory, mmap + 56, 0);
    putU32(memory, mmap + 64, 0);

    // The magic, the flags and the checksum live in the last 12 bytes of the
    // page, and the guest checks all three.
    putU32(memory, MBINFO_GPA + MBINFO_SIZE - 12, MULTIBOOT_MAGIC);
    putU32(memory, MBINFO_GPA + MBINFO_SIZE - 8, flags);
    var checksum: u32 = 0;
    var i: u32 = 0;
    while (i < MBINFO_SIZE / 4) : (i += 1) {
        checksum +%= readGuestU32(memory, MBINFO_GPA + i * 4);
    }
    putU32(memory, MBINFO_GPA + MBINFO_SIZE - 4, 0x1000_0000 - checksum);

    // Read it back: a guest that cannot find the magic will not boot, and
    // "the magic is not where I put it" is much easier to find here than from
    // inside the guest.
    const check = readGuestU32(memory, MBINFO_GPA + MBINFO_SIZE - 12);
    serial.serialWrite("[ZVM]   mbinfo magic at 0x");
    serial.serialWriteHex(MBINFO_GPA + MBINFO_SIZE - 12);
    serial.serialWrite(" = 0x");
    serial.serialWriteHex(check);
    serial.serialWrite("\n");
}

/// Copy bytes into the guest's memory.
fn copyIntoGuest(memory: Memory, gpa: u64, data: []const u8) void {
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const host = memory.guestToHost(gpa + i) orelse return;
        const p: [*]volatile u8 = @ptrFromInt(host);
        p[0] = data[i];
    }
}

/// Zero a range of the guest's memory.
fn zeroInGuest(memory: Memory, gpa: u64, len: u64) void {
    var i: u64 = 0;
    while (i < len) : (i += 1) {
        const host = memory.guestToHost(gpa + i) orelse return;
        const p: [*]volatile u8 = @ptrFromInt(host);
        p[0] = 0;
    }
}

fn putU32(memory: Memory, gpa: u64, value: u32) void {
    const host = memory.guestToHost(gpa) orelse return;
    const p: [*]volatile u32 = @ptrFromInt(host);
    p[0] = value;
}

fn putU64(memory: Memory, gpa: u64, value: u64) void {
    const host = memory.guestToHost(gpa) orelse return;
    const p: [*]volatile u64 = @ptrFromInt(host);
    p[0] = value;
}

fn readGuestU32(memory: Memory, gpa: u64) u32 {
    const host = memory.guestToHost(gpa) orelse return 0;
    const p: [*]const volatile u32 = @ptrFromInt(host);
    return p[0];
}

fn readU16(data: []const u8, at: usize) u16 {
    if (at + 2 > data.len) return 0;
    return @as(u16, data[at]) | (@as(u16, data[at + 1]) << 8);
}

fn readU32(data: []const u8, at: usize) u32 {
    if (at + 4 > data.len) return 0;
    return @as(u32, data[at]) |
        (@as(u32, data[at + 1]) << 8) |
        (@as(u32, data[at + 2]) << 16) |
        (@as(u32, data[at + 3]) << 24);
}

fn readU64(data: []const u8, at: usize) u64 {
    if (at + 8 > data.len) return 0;
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        v |= @as(u64, data[at + i]) << @intCast(i * 8);
    }
    return v;
}
