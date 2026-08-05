const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const serial = @import("../system/serial.zig");

pub const USER_BASE: u64 = 0x400000; // User code starts at 4MB (after kernel)
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

        return .{ .pml4_phys = pml4_page };
    }

    pub fn destroy(self: AddressSpace) void {
        // Free user-space page tables (entries 0-255)
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
                    // 1GB page - just free the PDPT entry's referenced page
                    continue;
                }

                const pd_phys = pdpt_entry & 0x000FFFFFFFFFF000;
                const pd: [*]u64 = @ptrFromInt(pd_phys);

                var k: u16 = 0;
                while (k < 512) : (k += 1) {
                    const pd_entry = pd[k];
                    if (pd_entry & vmm.PAGE_PRESENT == 0) continue;
                    if (pd_entry & vmm.PAGE_SIZE != 0) continue;

                    const pt_phys = pd_entry & 0x000FFFFFFFFFF000;
                    pmm.freePage(pt_phys);
                }
                pmm.freePage(pd_phys);
            }
            pmm.freePage(pdpt_phys);
        }
        pmm.freePage(self.pml4_phys);
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
        const pdpt = nextPageTable(pml4, pml4_idx, vmm.PAGE_WRITE);
        const pd = nextPageTable(pdpt, pdpt_idx, vmm.PAGE_WRITE);

        if (flags & vmm.PAGE_SIZE != 0) {
            setTableEntry(pd, pd_idx, paddr, flags | vmm.PAGE_PRESENT);
            vmm.invalidatePage(vaddr);
            return;
        }

        const pt = nextPageTable(pd, pd_idx, vmm.PAGE_WRITE);
        setTableEntry(pt, pt_idx, paddr, flags | vmm.PAGE_PRESENT);
        vmm.invalidatePage(vaddr);
    }

    pub fn mapUserRange(self: AddressSpace, vaddr_start: u64, paddr_start: u64, size: u64, flags: u64) void {
        var vaddr = vaddr_start & ~0xFFF;
        var paddr = paddr_start & ~0xFFF;
        const end = vaddr_start + size;

        while (vaddr < end) : ({
            vaddr += 0x1000;
            paddr += 0x1000;
        }) {
            self.mapUserPage(vaddr, paddr, flags | vmm.PAGE_USER);
        }
    }
};

fn nextPageTable(table: [*]u64, index: u16, flags: u64) [*]u64 {
    const entry = table[index];
    if (entry & vmm.PAGE_PRESENT != 0) {
        return @ptrFromInt(entry & 0x000FFFFFFFFFF000);
    }

    const new_page = pmm.allocPage() orelse return undefined;
    @memset(@as([*]u8, @ptrFromInt(new_page))[0..4096], 0);
    setTableEntry(table, index, new_page, flags | vmm.PAGE_PRESENT);
    return @ptrFromInt(new_page);
}

fn setTableEntry(table: [*]u64, index: u16, phys_addr: u64, flags: u64) void {
    table[index] = (phys_addr & 0x000FFFFFFFFFF000) | flags;
}
