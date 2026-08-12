//! SYSCALL/SYSRET setup.
//!
//! Linux binaries enter the kernel with the `syscall` instruction, not INT 0x80.
//! `syscall` does not switch stacks or push anything: it only loads CS/SS from
//! IA32_STAR, puts the return RIP in RCX and RFLAGS in R11, and jumps to
//! IA32_LSTAR. The assembly stub in `isr.S` builds an InterruptFrame-compatible
//! frame on the task's kernel stack and returns with `iretq`, so the C-side
//! handler is shared with the INT 0x80 path.

const msr = @import("msr.zig");
const gdt = @import("gdt.zig");
const serial = @import("../system/serial.zig");

extern fn syscall_entry_64() callconv(.naked) void;

/// Kernel RSP the `syscall` stub switches to. Updated per task, same value as
/// TSS.RSP0 (see scheduler.jumpToUser).
pub extern var syscall_kernel_rsp: u64;

pub fn init() void {
    // STAR[47:32] selects the kernel CS for `syscall`; SS becomes CS+8.
    // 0x08 -> CS=0x08 (kernel code), SS=0x10 (kernel data).
    // STAR[63:48] is only used by `sysret`, which we never execute (the stub
    // returns via iretq), so it is left pointing at the same descriptors.
    const star: u64 = (@as(u64, gdt.KERNEL_CODE_SEL) << 32) | (@as(u64, gdt.KERNEL_CODE_SEL) << 48);
    msr.write(msr.IA32_STAR, star);
    msr.write(msr.IA32_LSTAR, @intFromPtr(&syscall_entry_64));

    // FMASK = 0: keep RFLAGS (notably IF) as the caller had it. Masking IF here
    // would break every blocking syscall for the same reason the INT 0x80 gate
    // is a trap gate and not an interrupt gate — sleep()/recv() halt waiting for
    // the PIT tick and would never wake with interrupts off.
    msr.write(msr.IA32_FMASK, 0);

    // Enable the instruction itself.
    msr.write(msr.IA32_EFER, msr.read(msr.IA32_EFER) | msr.EFER_SCE);

    serial.serialWrite("[SYSCALL64] syscall/sysret enabled, LSTAR=0x");
    serial.serialWriteHex(@intFromPtr(&syscall_entry_64));
    serial.serialWrite("\n");
}

pub fn setKernelStack(rsp: u64) void {
    syscall_kernel_rsp = rsp;
}
