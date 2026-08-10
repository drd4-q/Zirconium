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

        const current_pml4: [*]u64 = @ptrFromInt(vmm.getCurrentCr3());
        const new_pml4: [*]u64 = @ptrFromInt(pml4_page);

        // Copy upper half PML4 entries (256-511): kernel virtual address space.
        var i: u16 = 256;
        while (i < 512) : (i += 1) {
            new_pml4[i] = current_pml4[i];
        }

        // For the lower 4GB (PML4[0]): we need an *independent* PDPT so that the
        // ELF loader can map user pages without corrupting the kernel's shared PDs.
        // We still inherit the kernel identity map (including LAPIC at 0xFEE00000)
        // by copying PDPT entries, but use separate PD for the 0-1GB range where
        // user ELF lives (0x2000000), so kernel PDs are never modified.
        const kernel_pml4_0 = current_pml4[0];
        if (kernel_pml4_0 & vmm.PAGE_PRESENT != 0) {
            const kernel_pdpt_phys = kernel_pml4_0 & vmm.PAGE_ADDR_MASK;
            const kernel_pdpt: [*]u64 = @ptrFromInt(kernel_pdpt_phys);

            // Allocate new PDPT for user space
            const new_pdpt_phys = pmm.allocPage() orelse {
                pmm.freePage(pml4_page);
                return null;
            };
            @memset(@as([*]u8, @ptrFromInt(new_pdpt_phys))[0..4096], 0);
            new_pml4[0] = (new_pdpt_phys & vmm.PAGE_ADDR_MASK) | vmm.PAGE_PRESENT | vmm.PAGE_WRITE | vmm.PAGE_USER;
            const new_pdpt: [*]u64 = @ptrFromInt(new_pdpt_phys);

            // Copy PDPT entries 1-3 from kernel: covers 1-4GB.
            // PDPT[3] has LAPIC at 0xFEE00000 — accessible kernel-mode during IRQ.
            var j: u16 = 1;
            while (j < 4) : (j += 1) {
                new_pdpt[j] = kernel_pdpt[j] | vmm.PAGE_USER;
            }

            // PDPT[0] covers 0-1GB (user ELF lives at 0x2000000 here).
            // Create a new PD (copy of kernel PD0) so ELF mapper can modify it
            // without affecting the kernel's own page directory.
            const kernel_pdpt0 = kernel_pdpt[0];
            if (kernel_pdpt0 & vmm.PAGE_PRESENT != 0) {
                const kernel_pd0_phys = kernel_pdpt0 & vmm.PAGE_ADDR_MASK;
                const kernel_pd0: [*]u64 = @ptrFromInt(kernel_pd0_phys);

                const new_pd0_phys = pmm.allocPage() orelse {
                    pmm.freePage(new_pdpt_phys);
                    pmm.freePage(pml4_page);
                    return null;
                };
                // Copy all PD0 entries from kernel (2MB identity-mapped pages)
                @memcpy(@as([*]u8, @ptrFromInt(new_pd0_phys))[0..4096],
                        @as([*]u8, @ptrFromInt(kernel_pd0_phys))[0..4096]);
                new_pdpt[0] = (new_pd0_phys & vmm.PAGE_ADDR_MASK) | vmm.PAGE_PRESENT | vmm.PAGE_WRITE | vmm.PAGE_USER;
                _ = kernel_pd0; // suppress unused warning
            }
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

        return addr_space;
    }

    pub fn destroy(self: AddressSpace) void {
        // Free only what this address space itself allocated for user space:
        // 4KB leaf pages mapped through page tables plus the page-table pages
        // it created. NEVER free huge pages (2MB/1GB) — those entries were
        // copied from the kernel's identity map (PD0) or are shared kernel
        // PDPT entries (PDPT[1..3] point at the kernel's own PDs); freeing
        // them would hand the kernel's own text/data/heap back to the PMM.
        // The user stack lives through the shared kernel PD under PDPT[2],
        // so those leaf pages are freed on the task's exit path (see the
        // exec/caller that owns t.user_stack_phys), not here.
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
                // Huge (1GB) PD pages are shared kernel identity entries — skip.
                if (pdpt_entry & vmm.PAGE_SIZE != 0) continue;

                const pd_phys = pdpt_entry & 0x000FFFFFFFFFF000;
                const pd: [*]u64 = @ptrFromInt(pd_phys);

                // Skip shared kernel PDs (entries of the upper PDPT slots or any
                // PD whose huge slots point into the kernel identity region).
                if (isSharedKernelTable(pd_phys, j)) continue;

                var k: u16 = 0;
                while (k < 512) : (k += 1) {
                    const pd_entry = pd[k];
                    if (pd_entry & vmm.PAGE_PRESENT == 0) continue;
                    // 2MB huge pages back the kernel identity map — never free.
                    if (pd_entry & vmm.PAGE_SIZE != 0) continue;

                    const pt_phys = pd_entry & 0x000FFFFFFFFFF000;
                    const pt: [*]u64 = @ptrFromInt(pt_phys);

                    var l: u16 = 0;
                    while (l < 512) : (l += 1) {
                        const pt_entry = pt[l];
                        if (pt_entry & vmm.PAGE_PRESENT == 0) continue;
                        // User mappings are 4KB pages flagged PAGE_USER; guards
                        // against freeing anything inherited from the kernel.
                        if (pt_entry & vmm.PAGE_USER == 0) continue;
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

                        const page_phys = pt_entry & vmm.PAGE_ADDR_MASK;
                        const parent_vaddr = (@as(u64, pml4_idx) << 39) | (@as(u64, pdpt_idx) << 30) | (@as(u64, pd_idx) << 21) | (@as(u64, pt_idx) << 12);

                        if (pt_entry & vmm.PAGE_WRITE != 0) {
                            const parent_pt_mut: [*]u64 = @ptrFromInt(parent_pt_phys);
                            const cow_flags = (pt_entry & ~@as(u64, vmm.PAGE_WRITE)) | vmm.PAGE_COW;
                            parent_pt_mut[pt_idx] = cow_flags;
                            vmm.invalidatePage(parent_vaddr);

                            child_pt[pt_idx] = cow_flags;
                            pmm.incRef(page_phys);
                        } else {
                            child_pt[pt_idx] = pt_entry;
                            pmm.incRef(page_phys);
                        }
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

/// True if this PD page is one of the kernel's own identity-map PDs that this
/// address space merely references (copied PDPT entries), not a table we own.
fn isSharedKernelTable(pd_phys: u64, pdpt_idx: u16) bool {
    if (pdpt_idx == 0) return false; // PML4[0]/PDPT[0] PD is our private copy
    const current = vmm.getCurrentCr3();
    const pml4: [*]const u64 = @ptrFromInt(current);
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        const pml4_entry = pml4[i];
        if (pml4_entry & vmm.PAGE_PRESENT == 0) continue;
        const pdpt_phys = pml4_entry & vmm.PAGE_ADDR_MASK;
        if (pml4_entry & vmm.PAGE_SIZE != 0) continue;
        const pdpt: [*]const u64 = @ptrFromInt(pdpt_phys);
        const pdpt_entry = pdpt[pdpt_idx];
        if (pdpt_entry & vmm.PAGE_PRESENT == 0) continue;
        const kpd_phys = pdpt_entry & vmm.PAGE_ADDR_MASK;
        if (kpd_phys == pd_phys) return true;
    }
    return false;
}

fn nextPageTable(table: [*]u64, index: u16, flags: u64) [*]u64 {
    const entry = table[index];
    if (entry & vmm.PAGE_PRESENT != 0) {
        // If this is a 2MB huge page, we must NOT use its address as a page table.
        // Replace it with a fresh 4KB PT so the caller can map individual pages.
        if (entry & vmm.PAGE_SIZE != 0) {
            const new_page = pmm.allocPage() orelse panic.kernelPanic("ADDRSPACE: OOM splitting huge page");
            @memset(@as([*]u8, @ptrFromInt(new_page))[0..4096], 0);
            setTableEntry(table, index, new_page, flags | vmm.PAGE_PRESENT);
            return @ptrFromInt(new_page);
        }
        return @ptrFromInt(entry & vmm.PAGE_ADDR_MASK);
    }

    const new_page = pmm.allocPage() orelse panic.kernelPanic("ADDRSPACE: out of memory allocating page table");
    @memset(@as([*]u8, @ptrFromInt(new_page))[0..4096], 0);
    setTableEntry(table, index, new_page, flags | vmm.PAGE_PRESENT);
    return @ptrFromInt(new_page);
}

fn setTableEntry(table: [*]u64, index: u16, phys_addr: u64, flags: u64) void {
    table[index] = (phys_addr & vmm.PAGE_ADDR_MASK) | flags;
}
