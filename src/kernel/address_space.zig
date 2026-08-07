const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const serial = @import("../system/serial.zig");
const panic = @import("../system/panic.zig");

extern const __kernel_start: u8;
extern const __kernel_end: u8;

pub const USER_BASE: u64 = 0x2000000; // User code starts at 32MB (after kernel)
pub const USER_STACK_TOP: u64 = 0x80000000; // 2GB - user stack top
pub const USER_STACK_SIZE: u64 = 0x10000; // 64KB user stack

pub const AddressSpace = struct {
    pml4_phys: u64,

    pub fn create() ?AddressSpace {
        const pml4_page = pmm.allocPage() orelse return null;
        @memset(@as([*]u8, @ptrFromInt(pml4_page))[0..4096], 0);

        // Copy kernel mappings (upper half) from current page tables
        const current_pml4: [*]u64 = @ptrFromInt(vmm.getCurrentCr3());
        const new_pml4: [*]u64 = @ptrFromInt(pml4_page);

        // PML4 entries 256-511 are kernel space (shared across all processes)
        var i: u16 = 256;
        while (i < 512) : (i += 1) {
            new_pml4[i] = current_pml4[i];
        }

        serial.serialWrite("[ADDRSPACE] Created address space, PML4=0x");
        serial.serialWriteHex(pml4_page);
        serial.serialWrite("\n");

        const addr_space = AddressSpace{ .pml4_phys = pml4_page };
        const kernel_start = @intFromPtr(&__kernel_start);
        const kernel_end = @intFromPtr(&__kernel_end);
        
        serial.serialWrite("[ADDRSPACE] kernel_start = 0x");
        serial.serialWriteHex(kernel_start);
        serial.serialWrite(", kernel_end = 0x");
        serial.serialWriteHex(kernel_end);
        serial.serialWrite("\n");
        
        // Map kernel identity region in user PML4 (no PAGE_USER)
        addr_space.mapKernelRange(0, 0, kernel_end, vmm.PAGE_WRITE);

        return addr_space;
    }

    pub fn destroy(self: AddressSpace) void {
        // Free user-space page tables and their backing physical pages (entries 0-255)
        const pml4: [*]u64 = @ptrFromInt(self.pml4_phys);
        var i: u16 = 0;
        while (i < 256) : (i += 1) {
            const entry = pml4[i];
            if (entry & vmm.PAGE_PRESENT == 0) continue;

            const pdpt_phys = entry & 0x000FFFFFFFFFF000;
            const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);

            var j: u16 = 0;
            while (j < 512) : (j += 1) {
                const pdpt_entry = pdpt[j];
                if (pdpt_entry & vmm.PAGE_PRESENT == 0) continue;
                if (pdpt_entry & vmm.PAGE_SIZE != 0) {
                    // 1GB page — free the 2MB-aligned physical region
                    const phys = pdpt_entry & 0x000FFFFFC0000000;
                    pmm.freePages(phys, 512); // 512 × 2MB pages
                    continue;
                }

                const pd_phys = pdpt_entry & 0x000FFFFFFFFFF000;
                const pd: [*]u64 = @ptrFromInt(pd_phys);

                var k: u16 = 0;
                while (k < 512) : (k += 1) {
                    const pd_entry = pd[k];
                    if (pd_entry & vmm.PAGE_PRESENT == 0) continue;

                    if (pd_entry & vmm.PAGE_SIZE != 0) {
                        // 2MB page — free the physical region
                        const phys = pd_entry & 0x000FFFFFE0000000;
                        pmm.freePages(phys, 512); // 512 × 4KB pages
                        continue;
                    }

                    const pt_phys = pd_entry & 0x000FFFFFFFFFF000;
                    const pt: [*]u64 = @ptrFromInt(pt_phys);

                    // Free each 4KB page mapped in this PT
                    var l: u16 = 0;
                    while (l < 512) : (l += 1) {
                        const pt_entry = pt[l];
                        if (pt_entry & vmm.PAGE_PRESENT == 0) continue;
                        const page_phys = pt_entry & 0x000FFFFFFFFFF000;
                        pmm.freePage(page_phys);
                    }
                    pmm.freePage(pt_phys);
                }
                pmm.freePage(pd_phys);
            }
            pmm.freePage(pdpt_phys);
        }
        pmm.freePage(self.pml4_phys);
    }

    pub fn cloneUserSpace(parent: AddressSpace) ?AddressSpace {
        var child = create() orelse return null;
        const parent_pml4: [*]const u64 = @ptrFromInt(parent.pml4_phys);
        const child_pml4: [*]u64 = @ptrFromInt(child.pml4_phys);

        var pml4_idx: u16 = 0;
        while (pml4_idx < 256) : (pml4_idx += 1) {
            const pml4_entry = parent_pml4[pml4_idx];
            if (pml4_entry & vmm.PAGE_PRESENT == 0) continue;

            const parent_pdpt_phys = pml4_entry & 0x000FFFFFFFFFF000;
            const parent_pdpt: [*]const u64 = @ptrFromInt(parent_pdpt_phys);

            const child_pdpt_page = pmm.allocPage() orelse {
                child.destroy();
                return null;
            };
            @memset(@as([*]u8, @ptrFromInt(child_pdpt_page))[0..4096], 0);
            child_pml4[pml4_idx] = (child_pdpt_page & 0x000FFFFFFFFFF000) | (pml4_entry & 0xFFF) | vmm.PAGE_PRESENT;
            const child_pdpt: [*]u64 = @ptrFromInt(child_pdpt_page);

            var pdpt_idx: u16 = 0;
            while (pdpt_idx < 512) : (pdpt_idx += 1) {
                const pdpt_entry = parent_pdpt[pdpt_idx];
                if (pdpt_entry & vmm.PAGE_PRESENT == 0) continue;

                if (pdpt_entry & vmm.PAGE_SIZE != 0) {
                    const phys = pdpt_entry & 0x000FFFFFC0000000;
                    const new_phys = pmm.allocPages(512) orelse {
                        child.destroy();
                        return null;
                    };
                    @memcpy(@as([*]u8, @ptrFromInt(new_phys))[0 .. 512 * 2048], @as([*]const u8, @ptrFromInt(phys))[0 .. 512 * 2048]);
                    child_pdpt[pdpt_idx] = (new_phys & 0x000FFFFFC0000000) | (pdpt_entry & 0xFFF) | vmm.PAGE_PRESENT;
                    continue;
                }

                const parent_pd_phys = pdpt_entry & 0x000FFFFFFFFFF000;
                const parent_pd: [*]const u64 = @ptrFromInt(parent_pd_phys);

                const child_pd_page = pmm.allocPage() orelse {
                    child.destroy();
                    return null;
                };
                @memset(@as([*]u8, @ptrFromInt(child_pd_page))[0..4096], 0);
                child_pdpt[pdpt_idx] = (child_pd_page & 0x000FFFFFFFFFF000) | (pdpt_entry & 0xFFF) | vmm.PAGE_PRESENT;
                const child_pd: [*]u64 = @ptrFromInt(child_pd_page);

                var pd_idx: u16 = 0;
                while (pd_idx < 512) : (pd_idx += 1) {
                    const pd_entry = parent_pd[pd_idx];
                    if (pd_entry & vmm.PAGE_PRESENT == 0) continue;

                    if (pd_entry & vmm.PAGE_SIZE != 0) {
                        const phys = pd_entry & 0x000FFFFFE0000000;
                        const new_phys = pmm.allocPages(512) orelse {
                            child.destroy();
                            return null;
                        };
                        @memcpy(@as([*]u8, @ptrFromInt(new_phys))[0 .. 512 * 4096], @as([*]const u8, @ptrFromInt(phys))[0 .. 512 * 4096]);
                        child_pd[pd_idx] = (new_phys & 0x000FFFFFE0000000) | (pd_entry & 0xFFF) | vmm.PAGE_PRESENT;
                        continue;
                    }

                    const parent_pt_phys = pd_entry & 0x000FFFFFFFFFF000;
                    const parent_pt: [*]const u64 = @ptrFromInt(parent_pt_phys);

                    const child_pt_page = pmm.allocPage() orelse {
                        child.destroy();
                        return null;
                    };
                    @memset(@as([*]u8, @ptrFromInt(child_pt_page))[0..4096], 0);
                    child_pd[pd_idx] = (child_pt_page & 0x000FFFFFFFFFF000) | (pd_entry & 0xFFF) | vmm.PAGE_PRESENT;
                    const child_pt: [*]u64 = @ptrFromInt(child_pt_page);

                    var pt_idx: u16 = 0;
                    while (pt_idx < 512) : (pt_idx += 1) {
                        const pt_entry = parent_pt[pt_idx];
                        if (pt_entry & vmm.PAGE_PRESENT == 0) continue;

                        const page_phys = pt_entry & 0x000FFFFFFFFFF000;
                        const new_page = pmm.allocPage() orelse {
                            child.destroy();
                            return null;
                        };
                        @memcpy(@as([*]u8, @ptrFromInt(new_page))[0..4096], @as([*]const u8, @ptrFromInt(page_phys))[0..4096]);
                        child_pt[pt_idx] = (new_page & 0x000FFFFFFFFFF000) | (pt_entry & 0xFFF) | vmm.PAGE_PRESENT;
                    }
                }
            }
        }

        return child;
    }

    pub fn switchTo(self: AddressSpace) void {
        asm volatile ("movq %[cr3], %%cr3"
            :
            : [cr3] "r" (self.pml4_phys)
            : .{ .memory = true }
        );
    }

    pub fn mapUserPage(self: AddressSpace, vaddr: u64, paddr: u64, flags: u64) void {
        const pml4_idx: u16 = @intCast((vaddr >> 39) & 0x1FF);
        const pdpt_idx: u16 = @intCast((vaddr >> 30) & 0x1FF);
        const pd_idx: u16 = @intCast((vaddr >> 21) & 0x1FF);
        const pt_idx: u16 = @intCast((vaddr >> 12) & 0x1FF);

        const pml4: [*]u64 = @ptrFromInt(self.pml4_phys);
        const pdpt = nextPageTable(pml4, pml4_idx, vmm.PAGE_WRITE | vmm.PAGE_USER);
        const pd = nextPageTable(pdpt, pdpt_idx, vmm.PAGE_WRITE | vmm.PAGE_USER);

        if (flags & vmm.PAGE_SIZE != 0) {
            setTableEntry(pd, pd_idx, paddr, flags | vmm.PAGE_PRESENT);
            vmm.invalidatePage(vaddr);
            return;
        }

        const pt = nextPageTable(pd, pd_idx, vmm.PAGE_WRITE | vmm.PAGE_USER);
        setTableEntry(pt, pt_idx, paddr, flags | vmm.PAGE_PRESENT);
        vmm.invalidatePage(vaddr);
    }

    pub fn mapUserRange(self: AddressSpace, vaddr_start: u64, paddr_start: u64, size: u64, flags: u64) void {
        var vaddr = vaddr_start & ~@as(u64, 0xFFF);
        var paddr = paddr_start & ~@as(u64, 0xFFF);
        const end = vaddr_start + size;

        while (vaddr < end) : ({
            vaddr += 0x1000;
            paddr += 0x1000;
        }) {
            self.mapUserPage(vaddr, paddr, flags | vmm.PAGE_USER);
        }
    }

    pub fn mapKernelRange(self: AddressSpace, vaddr_start: u64, paddr_start: u64, size: u64, flags: u64) void {
        var vaddr = vaddr_start & ~@as(u64, 0xFFF);
        var paddr = paddr_start & ~@as(u64, 0xFFF);
        const end = vaddr_start + size;

        while (vaddr < end) : ({
            vaddr += 0x1000;
            paddr += 0x1000;
        }) {
            self.mapUserPage(vaddr, paddr, flags);
        }
    }
};

fn nextPageTable(table: [*]u64, index: u16, flags: u64) [*]u64 {
    const entry = table[index];
    if (entry & vmm.PAGE_PRESENT != 0) {
        return @ptrFromInt(entry & 0x000FFFFFFFFFF000);
    }

    const new_page = pmm.allocPage() orelse panic.kernelPanic("ADDRSPACE: out of memory allocating page table");
    @memset(@as([*]u8, @ptrFromInt(new_page))[0..4096], 0);
    setTableEntry(table, index, new_page, flags | vmm.PAGE_PRESENT);
    return @ptrFromInt(new_page);
}

fn setTableEntry(table: [*]u64, index: u16, phys_addr: u64, flags: u64) void {
    table[index] = (phys_addr & 0x000FFFFFFFFFF000) | flags;
}
