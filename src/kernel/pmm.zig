const serial = @import("../system/serial.zig");

const PAGE_SIZE: usize = 4096;
const TOTAL_MEMORY: usize = 128 * 1024 * 1024;
const TOTAL_PAGES: usize = TOTAL_MEMORY / PAGE_SIZE;
const BITMAP_SIZE: usize = TOTAL_PAGES / 8;

var bitmap: [BITMAP_SIZE]u8 = [_]u8{0} ** BITMAP_SIZE;
var ref_counts: [TOTAL_PAGES]u16 = [_]u16{0} ** TOTAL_PAGES;
pub var total_pages: usize = TOTAL_PAGES;
pub var free_pages: usize = 0;

pub fn init(kernel_start: usize, kernel_end: usize) void {
    @memset(&bitmap, 0xFF);
    @memset(&ref_counts, 0);

    const usable_start: usize = 0x100000;
    const usable_end: usize = TOTAL_MEMORY;

    var page: usize = usable_start / PAGE_SIZE;
    const end_page: usize = usable_end / PAGE_SIZE;

    while (page < end_page) : (page += 1) {
        const addr = page * PAGE_SIZE;
        if (addr >= kernel_end or (addr + PAGE_SIZE) <= kernel_start) {
            // Directly clear bitmap bit — ref_counts are 0 at init so decRef won't work
            bitmap[page / 8] &= ~(@as(u8, 1) << @intCast(page % 8));
            free_pages += 1;
        }
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
