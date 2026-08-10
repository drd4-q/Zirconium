const std = @import("std");

const GdtEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    granularity: u8,
    base_high: u8,
};

const TssEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    granularity: u8,
    base_high: u8,
    base_upper: u32,
    reserved: u32,
};

extern fn load_gdt(ptr: u64) void;

pub const Tss = packed struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iopb_offset: u16 = 0,
};

pub const KERNEL_CODE_SEL: u16 = 0x08;
pub const KERNEL_DATA_SEL: u16 = 0x10;
pub const USER_CODE_SEL: u16 = 0x18 | 3; // RPL=3
pub const USER_DATA_SEL: u16 = 0x20 | 3; // RPL=3
pub const TSS_SEL: u16 = 0x40;

var gdt: [128]u8 align(16) = [_]u8{0} ** 128;
pub var tss: Tss align(16) = undefined;

fn setEntry(idx: usize, base: u32, limit: u32, access: u8, granularity: u8) void {
    const entry: *GdtEntry = @ptrFromInt(@intFromPtr(&gdt) + idx * @sizeOf(GdtEntry));
    entry.base_low = @intCast(base & 0xFFFF);
    entry.base_mid = @intCast((base >> 16) & 0xFF);
    entry.base_high = @intCast((base >> 24) & 0xFF);
    entry.limit_low = @intCast(limit & 0xFFFF);
    entry.access = access;
    entry.granularity = granularity | @as(u8, @intCast((limit >> 16) & 0x0F));
}

fn setTssEntry(idx: usize, base: u64, limit: u32) void {
    const entry: *TssEntry = @ptrFromInt(@intFromPtr(&gdt) + idx * @sizeOf(GdtEntry));
    entry.base_low = @intCast(base & 0xFFFF);
    entry.base_mid = @intCast((base >> 16) & 0xFF);
    entry.base_high = @intCast((base >> 24) & 0xFF);
    entry.base_upper = @intCast((base >> 32) & 0xFFFFFFFF);
    entry.limit_low = @intCast(limit & 0xFFFF);
    entry.access = 0x89;
    entry.granularity = 0x20;
    entry.reserved = 0;
}

pub fn init(stack_top: u64) void {
    // Zero GDT without SSE (compiler's @memset uses xorps/movaps)
    const gdt_bytes: *[128]u8 = &gdt;
    for (gdt_bytes) |*b| {
        b.* = 0;
    }

    // 0x00: Null
    setEntry(0, 0, 0, 0, 0);
    // 0x08: Kernel code (64-bit, DPL=0)
    setEntry(1, 0, 0xFFFFF, 0x9A, 0xA0);
    // 0x10: Kernel data (64-bit, DPL=0)
    setEntry(2, 0, 0xFFFFF, 0x92, 0xC0);
    // 0x18: User code (64-bit, DPL=3)
    setEntry(3, 0, 0xFFFFF, 0xFA, 0xA0);
    // 0x20: User data (64-bit, DPL=3)
    setEntry(4, 0, 0xFFFFF, 0xF2, 0xC0);
    // 0x28: Kernel code (duplicate, DPL=0)
    setEntry(5, 0, 0xFFFFF, 0x9A, 0xA0);
    // 0x30: Kernel data (duplicate, DPL=0)
    setEntry(6, 0, 0xFFFFF, 0x92, 0xC0);

    tss.rsp0 = stack_top;
    tss.iopb_offset = @sizeOf(Tss);

    const tss_addr = @intFromPtr(&tss);
    setTssEntry(8, tss_addr, @sizeOf(Tss) - 1);

    // Build LGDT descriptor manually (10 bytes: u16 limit + u64 base)
    const limit_val: u16 = @intCast(@sizeOf(GdtEntry) * 8 + @sizeOf(TssEntry) - 1);
    const base_val: u64 = @intFromPtr(&gdt);

    var lgdt_desc: [10]u8 align(16) = undefined;
    lgdt_desc[0] = @intCast(limit_val & 0xFF);
    lgdt_desc[1] = @intCast((limit_val >> 8) & 0xFF);
    lgdt_desc[2] = @intCast(base_val & 0xFF);
    lgdt_desc[3] = @intCast((base_val >> 8) & 0xFF);
    lgdt_desc[4] = @intCast((base_val >> 16) & 0xFF);
    lgdt_desc[5] = @intCast((base_val >> 24) & 0xFF);
    lgdt_desc[6] = @intCast((base_val >> 32) & 0xFF);
    lgdt_desc[7] = @intCast((base_val >> 40) & 0xFF);
    lgdt_desc[8] = @intCast((base_val >> 48) & 0xFF);
    lgdt_desc[9] = @intCast((base_val >> 56) & 0xFF);

    load_gdt(@intFromPtr(&lgdt_desc));
}

pub fn setRsp0(rsp: u64) void {
    tss.rsp0 = rsp;
}

pub fn gdtAddr() *align(16) [128]u8 {
    return &gdt;
}

pub fn gdtLimit() u16 {
    return @intCast(@sizeOf(GdtEntry) * 8 + @sizeOf(TssEntry) - 1);
}
