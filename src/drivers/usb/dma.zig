const std = @import("std");
const root = @import("root");
const pmm = root.pmm;
const serial = root.serial;

pub const PAGE_SIZE: usize = 4096;

pub fn allocPage() ?usize {
    const page = pmm.allocPage() orelse return null;
    const ptr: [*]u8 = @ptrFromInt(page);
    @memset(ptr[0..PAGE_SIZE], 0);
    return page;
}

pub fn allocPages(count: usize) ?usize {
    const pages = pmm.allocPages(count) orelse return null;
    const ptr: [*]u8 = @ptrFromInt(pages);
    @memset(ptr[0 .. count * PAGE_SIZE], 0);
    return pages;
}

pub fn freePage(addr: usize) void {
    pmm.freePage(addr);
}

pub fn freePages(addr: usize, count: usize) void {
    pmm.freePages(addr, count);
}

pub inline fn virtToPhys(ptr: anytype) usize {
    return @intFromPtr(ptr);
}

pub inline fn physToVirt(comptime T: type, phys: usize) *T {
    return @ptrFromInt(phys);
}

pub inline fn physToVirtSlice(comptime T: type, phys: usize, count: usize) []T {
    const ptr: [*]T = @ptrFromInt(phys);
    return ptr[0..count];
}

/// A slab/bump allocator backed by PMM 4KB pages for DMA structures
/// (UHCI 16-byte QHs/TDs, EHCI 32-byte QHs/qTDs, xHCI 64-byte TRBs/Contexts).
pub const UsbDmaPool = struct {
    pages: [16]usize = [_]usize{0} ** 16,
    page_count: usize = 0,
    current_offset: usize = PAGE_SIZE, // Forces allocation on first request

    pub fn init() UsbDmaPool {
        return UsbDmaPool{};
    }

    pub fn deinit(self: *UsbDmaPool) void {
        var i: usize = 0;
        while (i < self.page_count) : (i += 1) {
            if (self.pages[i] != 0) {
                freePage(self.pages[i]);
                self.pages[i] = 0;
            }
        }
        self.page_count = 0;
        self.current_offset = PAGE_SIZE;
    }

    fn ensurePage(self: *UsbDmaPool, needed_size: usize, alignment: usize) bool {
        if (self.page_count > 0) {
            const cur_page = self.pages[self.page_count - 1];
            const aligned = (self.current_offset + alignment - 1) & ~(alignment - 1);
            if (aligned + needed_size <= PAGE_SIZE) {
                _ = cur_page;
                return true;
            }
        }

        if (self.page_count >= self.pages.len) return false;

        const new_page = allocPage() orelse return false;
        self.pages[self.page_count] = new_page;
        self.page_count += 1;
        self.current_offset = 0;
        return true;
    }

    pub fn allocAligned(self: *UsbDmaPool, comptime T: type, alignment: usize) ?*T {
        const size = @sizeOf(T);
        if (!self.ensurePage(size, alignment)) return null;

        const cur_page = self.pages[self.page_count - 1];
        const aligned = (self.current_offset + alignment - 1) & ~(alignment - 1);
        if (aligned + size > PAGE_SIZE) return null;

        self.current_offset = aligned + size;
        const ptr: *T = @ptrCast(@alignCast(@as([*]u8, @ptrFromInt(cur_page + aligned))));
        return ptr;
    }

    pub fn allocSliceAligned(self: *UsbDmaPool, comptime T: type, count: usize, alignment: usize) ?[]T {
        const size = @sizeOf(T) * count;
        if (size > PAGE_SIZE) return null;
        if (!self.ensurePage(size, alignment)) return null;

        const cur_page = self.pages[self.page_count - 1];
        const aligned = (self.current_offset + alignment - 1) & ~(alignment - 1);
        if (aligned + size > PAGE_SIZE) return null;

        self.current_offset = aligned + size;
        const ptr: [*]T = @ptrCast(@alignCast(@as([*]u8, @ptrFromInt(cur_page + aligned))));
        return ptr[0..count];
    }
};
