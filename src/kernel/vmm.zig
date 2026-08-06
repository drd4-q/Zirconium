const pmm = @import("pmm.zig");
const serial = @import("../system/serial.zig");

pub const PAGE_PRESENT: u64 = 1 << 0;
pub const PAGE_WRITE: u64 = 1 << 1;
pub const PAGE_USER: u64 = 1 << 2;
pub const PAGE_SIZE: u64 = 1 << 7;
pub const PAGE_NX: u64 = 1 << 63;

const PAGE_ADDR_MASK: u64 = 0x000FFFFFFFFFF000;

pub fn getCurrentCr3() u64 {
    return asm volatile ("movq %%cr3, %[ret]" : [ret] "=r" (-> u64));
}

pub fn invalidatePage(vaddr: u64) void {
    asm volatile ("invlpg (%[addr])" : : [addr] "r" (vaddr) : .{ .memory = true });
}

fn getTableEntry(table: [*]u64, index: u16) u64 {
    return table[index];
}

fn setTableEntry(table: [*]u64, index: u16, phys_addr: u64, flags: u64) void {
    table[index] = (phys_addr & PAGE_ADDR_MASK) | flags;
}

fn nextPageTable(table: [*]u64, index: u16, flags: u64) [*]u64 {
    const entry = getTableEntry(table, index);
    if (entry & PAGE_PRESENT != 0) {
        return @ptrFromInt(entry & PAGE_ADDR_MASK);
    }

    const new_page = pmm.allocPage() orelse return undefined;
    @memset(@as([*]u8, @ptrFromInt(new_page))[0..4096], 0);
    setTableEntry(table, index, new_page, flags | PAGE_PRESENT);
    return @ptrFromInt(new_page);
}

pub fn mapPage(vaddr: u64, paddr: u64, flags: u64) void {
    const pml4_idx: u16 = @intCast((vaddr >> 39) & 0x1FF);
    const pdpt_idx: u16 = @intCast((vaddr >> 30) & 0x1FF);
    const pd_idx: u16 = @intCast((vaddr >> 21) & 0x1FF);
    const pt_idx: u16 = @intCast((vaddr >> 12) & 0x1FF);

    const cr3 = getCurrentCr3();
    const pml4: [*]u64 = @ptrFromInt(cr3);

    const pdpt = nextPageTable(pml4, pml4_idx, flags | PAGE_WRITE);
    const pd = nextPageTable(pdpt, pdpt_idx, flags | PAGE_WRITE);

    if (flags & PAGE_SIZE != 0) {
        setTableEntry(pd, pd_idx, paddr, flags | PAGE_PRESENT);
        invalidatePage(vaddr);
        return;
    }

    const pt = nextPageTable(pd, pd_idx, flags | PAGE_WRITE);
    setTableEntry(pt, pt_idx, paddr, flags | PAGE_PRESENT);
    invalidatePage(vaddr);
}

pub fn unmapPage(vaddr: u64) void {
    const pml4_idx: u16 = @intCast((vaddr >> 39) & 0x1FF);
    const pdpt_idx: u16 = @intCast((vaddr >> 30) & 0x1FF);
    const pd_idx: u16 = @intCast((vaddr >> 21) & 0x1FF);
    const pt_idx: u16 = @intCast((vaddr >> 12) & 0x1FF);

    const cr3 = getCurrentCr3();
    const pml4: [*]u64 = @ptrFromInt(cr3);

    const pml4_entry = getTableEntry(pml4, pml4_idx);
    if (pml4_entry & PAGE_PRESENT == 0) return;
    const pdpt: [*]u64 = @ptrFromInt(pml4_entry & PAGE_ADDR_MASK);

    const pdpt_entry = getTableEntry(pdpt, pdpt_idx);
    if (pdpt_entry & PAGE_PRESENT == 0) return;

    if (pdpt_entry & PAGE_SIZE != 0) {
        setTableEntry(pdpt, pdpt_idx, 0, 0);
        invalidatePage(vaddr);
        return;
    }

    const pd: [*]u64 = @ptrFromInt(pdpt_entry & PAGE_ADDR_MASK);
    const pd_entry = getTableEntry(pd, pd_idx);
    if (pd_entry & PAGE_PRESENT == 0) return;

    if (pd_entry & PAGE_SIZE != 0) {
        setTableEntry(pd, pd_idx, 0, 0);
        invalidatePage(vaddr);
        return;
    }

    const pt: [*]u64 = @ptrFromInt(pd_entry & PAGE_ADDR_MASK);
    setTableEntry(pt, pt_idx, 0, 0);
    invalidatePage(vaddr);
}

pub fn virtToPhys(vaddr: u64) ?u64 {
    const pml4_idx: u16 = @intCast((vaddr >> 39) & 0x1FF);
    const pdpt_idx: u16 = @intCast((vaddr >> 30) & 0x1FF);
    const pd_idx: u16 = @intCast((vaddr >> 21) & 0x1FF);
    const pt_idx: u16 = @intCast((vaddr >> 12) & 0x1FF);
    const offset = vaddr & 0xFFF;

    const cr3 = getCurrentCr3();
    const pml4: [*]u64 = @ptrFromInt(cr3);

    const pml4_entry = getTableEntry(pml4, pml4_idx);
    if (pml4_entry & PAGE_PRESENT == 0) return null;
    const pdpt: [*]u64 = @ptrFromInt(pml4_entry & PAGE_ADDR_MASK);

    const pdpt_entry = getTableEntry(pdpt, pdpt_idx);
    if (pdpt_entry & PAGE_PRESENT == 0) return null;
    if (pdpt_entry & PAGE_SIZE != 0) return (pdpt_entry & 0x000FFFFFC0000000) + (vaddr & 0x3FFFFFFF);

    const pd: [*]u64 = @ptrFromInt(pdpt_entry & PAGE_ADDR_MASK);
    const pd_entry = getTableEntry(pd, pd_idx);
    if (pd_entry & PAGE_PRESENT == 0) return null;
    if (pd_entry & PAGE_SIZE != 0) return (pd_entry & 0x000FFFFFFFE00000) + (vaddr & 0x1FFFFF);

    const pt: [*]u64 = @ptrFromInt(pd_entry & PAGE_ADDR_MASK);
    const pt_entry = getTableEntry(pt, pt_idx);
    if (pt_entry & PAGE_PRESENT == 0) return null;

    return (pt_entry & PAGE_ADDR_MASK) + offset;
}

pub fn init() void {
    serial.serialWrite("[VMM] Virtual memory manager initialized\n");
    serial.serialWrite("[VMM] CR3=0x");
    serial.serialWriteHex(getCurrentCr3());
    serial.serialWrite("\n");
}
