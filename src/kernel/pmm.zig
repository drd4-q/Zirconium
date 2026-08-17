const serial = @import("../system/serial.zig");
const system_init = @import("../system/init.zig");

pub const PAGE_SIZE: usize = 4096;
pub const MAX_MEMORY: usize = 1024 * 1024 * 1024; // 1 GB supported physical memory
pub const TOTAL_PAGES: usize = MAX_MEMORY / PAGE_SIZE; // 262,144 pages
const BITMAP_SIZE: usize = TOTAL_PAGES / 8; // 32,768 bytes

var bitmap: [BITMAP_SIZE]u8 = [_]u8{0xFF} ** BITMAP_SIZE;
var ref_counts: [TOTAL_PAGES]u16 = [_]u16{0} ** TOTAL_PAGES;
pub var total_pages: usize = 0;
pub var free_pages: usize = 0;

fn readU32(addr: usize) u32 {
    const p: *const u32 = @ptrFromInt(addr);
    return p.*;
}

fn readU64(addr: usize) u64 {
    const p: *const u64 = @ptrFromInt(addr);
    return p.*;
}

fn markPageFree(page: usize) void {
    if (page < TOTAL_PAGES) {
        const byte_idx = page / 8;
        const bit_idx: u3 = @intCast(page % 8);
        if (bitmap[byte_idx] & (@as(u8, 1) << bit_idx) != 0) {
            bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
            free_pages += 1;
        }
    }
}

pub fn init(kernel_start: usize, kernel_end: usize) void {
    @memset(&bitmap, 0xFF);
    @memset(&ref_counts, 0);
    free_pages = 0;
    total_pages = 0;

    const mbi_raw = system_init.multiboot_info_ptr;
    var parsed_mmap = false;

    if (mbi_raw != 0 and mbi_raw < 0xFFFFFFFF) {
        const mbi_addr: usize = @intCast(mbi_raw);
        const flags = readU32(mbi_addr);

        // Bit 6: Memory map is valid
        if ((flags & (1 << 6)) != 0) {
            const mmap_length = readU32(mbi_addr + 44);
            const mmap_addr = readU32(mbi_addr + 48);

            if (mmap_addr != 0 and mmap_length > 0) {
                var offset: usize = 0;
                while (offset < mmap_length) {
                    const entry_addr = @as(usize, mmap_addr) + offset;
                    const entry_size = readU32(entry_addr);
                    if (entry_size < 20) break;

                    const base_addr = readU64(entry_addr + 4);
                    const length = readU64(entry_addr + 12);
                    const entry_type = readU32(entry_addr + 20);

                    // Type 1: Available RAM
                    if (entry_type == 1 and base_addr < MAX_MEMORY) {
                        const start_addr = @max(base_addr, 0x100000); // Protect lower 1MB (BIOS, IVT, EBDA, trampoline)
                        const end_addr = @min(base_addr + length, @as(u64, MAX_MEMORY));

                        if (start_addr < end_addr) {
                            var p: usize = @intCast(start_addr / PAGE_SIZE);
                            const end_page: usize = @intCast(end_addr / PAGE_SIZE);

                            while (p < end_page) : (p += 1) {
                                const addr = p * PAGE_SIZE;
                                // Protect kernel image and multiboot structures
                                const is_kernel = (addr < kernel_end and (addr + PAGE_SIZE) > kernel_start);
                                const is_mbi = (addr <= mbi_addr and (addr + PAGE_SIZE) > mbi_addr);
                                const is_mmap = (addr <= mmap_addr and (addr + PAGE_SIZE) > (mmap_addr + mmap_length));

                                if (!is_kernel and !is_mbi and !is_mmap) {
                                    markPageFree(p);
                                }
                            }
                            if (end_page > total_pages) {
                                total_pages = end_page;
                            }
                        }
                    }

                    offset += entry_size + 4;
                }
                parsed_mmap = (free_pages > 0);
            }
        }

        // Fallback to mem_upper (Bit 0) if mmap wasn't present
        if (!parsed_mmap and (flags & (1 << 0)) != 0) {
            const mem_upper = readU32(mbi_addr + 8);
            const usable_end = @min(0x100000 + @as(usize, mem_upper) * 1024, MAX_MEMORY);
            var page: usize = 0x100000 / PAGE_SIZE;
            const end_page = usable_end / PAGE_SIZE;

            while (page < end_page) : (page += 1) {
                const addr = page * PAGE_SIZE;
                if (addr >= kernel_end or (addr + PAGE_SIZE) <= kernel_start) {
                    markPageFree(page);
                }
            }
            total_pages = end_page;
            parsed_mmap = (free_pages > 0);
        }
    }

    // Default fallback (128 MB) if no multiboot memory info
    if (!parsed_mmap) {
        const default_end = 128 * 1024 * 1024;
        var page: usize = 0x100000 / PAGE_SIZE;
        const end_page = default_end / PAGE_SIZE;

        while (page < end_page) : (page += 1) {
            const addr = page * PAGE_SIZE;
            if (addr >= kernel_end or (addr + PAGE_SIZE) <= kernel_start) {
                markPageFree(page);
            }
        }
        total_pages = end_page;
    }

    serial.serialWrite("[MEM] Physical memory manager initialized\n");
    serial.serialWrite("[MEM] Total pages: ");
    serial.serialWriteDec(total_pages);
    serial.serialWrite(", free: ");
    serial.serialWriteDec(free_pages);
    serial.serialWrite("\n");
}

pub fn allocPage() ?usize {
    var byte_idx: usize = 0;
    while (byte_idx < BITMAP_SIZE) : (byte_idx += 1) {
        if (bitmap[byte_idx] != 0xFF) {
            var bit: u8 = 0;
            while (bit < 8) : (bit += 1) {
                if (bitmap[byte_idx] & (@as(u8, 1) << @intCast(bit)) == 0) {
                    bitmap[byte_idx] |= @as(u8, 1) << @intCast(bit);
                    free_pages -= 1;
                    const p_idx = byte_idx * 8 + bit;
                    ref_counts[p_idx] = 1;
                    return p_idx * PAGE_SIZE;
                }
            }
        }
    }
    return null;
}

pub fn allocPages(count: usize) ?usize {
    if (count == 0) return null;
    if (count == 1) return allocPage();

    var start_byte: usize = 0;
    while (start_byte < BITMAP_SIZE) : (start_byte += 1) {
        if (bitmap[start_byte] == 0xFF) continue;

        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            if (bitmap[start_byte] & (@as(u8, 1) << @intCast(bit)) != 0) continue;

            const start_page = start_byte * 8 + bit;
            var found: usize = 0;
            var check_page = start_page;

            while (found < count and check_page < TOTAL_PAGES) {
                const check_byte = check_page / 8;
                const check_bit: u8 = @intCast(check_page % 8);
                if (bitmap[check_byte] & (@as(u8, 1) << @intCast(check_bit)) != 0) break;
                found += 1;
                check_page += 1;
            }

            if (found >= count) {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const p = start_page + i;
                    bitmap[p / 8] |= @as(u8, 1) << @intCast(p % 8);
                    ref_counts[p] = 1;
                }
                free_pages -= count;
                return start_page * PAGE_SIZE;
            }
        }
    }
    return null;
}

pub fn incRef(addr: usize) void {
    const page = addr / PAGE_SIZE;
    if (page < TOTAL_PAGES) {
        ref_counts[page] += 1;
    }
}

pub fn decRef(addr: usize) u16 {
    const page = addr / PAGE_SIZE;
    if (page < TOTAL_PAGES and ref_counts[page] > 0) {
        ref_counts[page] -= 1;
        if (ref_counts[page] == 0) {
            bitmap[page / 8] &= ~(@as(u8, 1) << @intCast(page % 8));
            free_pages += 1;
        }
        return ref_counts[page];
    }
    return 0;
}

pub fn getRef(addr: usize) u16 {
    const page = addr / PAGE_SIZE;
    if (page < TOTAL_PAGES) {
        return ref_counts[page];
    }
    return 0;
}

pub fn freePage(addr: usize) void {
    _ = decRef(addr);
}

pub fn freePages(addr: usize, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        freePage(addr + i * PAGE_SIZE);
    }
}

pub fn isPageFree(addr: usize) bool {
    const page = addr / PAGE_SIZE;
    if (page >= TOTAL_PAGES) return false;
    return bitmap[page / 8] & (@as(u8, 1) << @intCast(page % 8)) == 0;
}
