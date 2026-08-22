//! Model-specific register access shared by the APIC, SMP and syscall code.

pub const IA32_EFER: u32 = 0xC0000080;
pub const IA32_STAR: u32 = 0xC0000081;
pub const IA32_LSTAR: u32 = 0xC0000082;
pub const IA32_FMASK: u32 = 0xC0000084;
pub const IA32_FS_BASE: u32 = 0xC0000100;
pub const IA32_GS_BASE: u32 = 0xC0000101;
pub const IA32_KERNEL_GS_BASE: u32 = 0xC0000102;

pub const EFER_SCE: u64 = 1 << 0; // System Call Extensions (enables `syscall`)

pub fn read(msr: u32) u64 {
    var low: u32 = 0;
    var high: u32 = 0;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | low;
}

pub fn write(msr: u32, val: u64) void {
    const low: u32 = @intCast(val & 0xFFFFFFFF);
    const high: u32 = @intCast((val >> 32) & 0xFFFFFFFF);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}

pub fn setFsBase(base: u64) void {
    write(IA32_FS_BASE, base);
}

pub fn getFsBase() u64 {
    return read(IA32_FS_BASE);
}

/// GS base as user code sees it (no swapgs in this kernel: the same value is
/// visible in ring 0 and ring 3, which is fine because the kernel ignores GS).
pub fn setGsBase(base: u64) void {
    write(IA32_GS_BASE, base);
}
