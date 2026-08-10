const serial = @import("../system/serial.zig");
const isr_mod = @import("../arch/isr.zig");

const APIC_BASE_MSR: u32 = 0x1B;
const DEFAULT_APIC_BASE: u64 = 0xFEE00000;

// LAPIC Register offsets
const REG_ID: u32 = 0x020;
const REG_TPR: u32 = 0x080;
const REG_EOI: u32 = 0x0B0;
const REG_SVR: u32 = 0x0F0;
const REG_LVT_TIMER: u32 = 0x320;
const REG_TIMER_INIT: u32 = 0x380;
const REG_TIMER_CURR: u32 = 0x390;
const REG_TIMER_DIV: u32 = 0x3E0;

var apic_base: u64 = DEFAULT_APIC_BASE;
var apic_enabled: bool = false;

fn rdmsr(msr: u32) u64 {
    var low: u32 = 0;
    var high: u32 = 0;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high)
        : [msr] "{ecx}" (msr)
    );
    return (@as(u64, high) << 32) | low;
}

fn wrmsr(msr: u32, val: u64) void {
    const low: u32 = @intCast(val & 0xFFFFFFFF);
    const high: u32 = @intCast((val >> 32) & 0xFFFFFFFF);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high)
    );
}

fn readReg(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(apic_base + offset);
    return ptr.*;
}

fn writeReg(offset: u32, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(apic_base + offset);
    ptr.* = value;
}

pub fn sendEoi() void {
    if (apic_enabled) {
        writeReg(REG_EOI, 0);
    }
}

pub fn init() bool {
    const msr_val = rdmsr(APIC_BASE_MSR);
    apic_base = msr_val & 0xFFFFF000;
    if (apic_base == 0) apic_base = DEFAULT_APIC_BASE;

    // Enable LAPIC globally via MSR
    wrmsr(APIC_BASE_MSR, msr_val | (1 << 11));

    // Enable LAPIC software mode via Spurious Vector Register (SVR)
    // Bit 8 = Software Enable, Vector = 0xFF (255)
    writeReg(REG_SVR, 0x100 | 0xFF);

    // Set Task Priority Register to 0 (accept all interrupts)
    writeReg(REG_TPR, 0);

    // Configure Timer divide register (0x3 = divide by 16)
    writeReg(REG_TIMER_DIV, 0x3);

    // LVT Timer Register: MASKED (bit 16). The LAPIC exists to deliver IPIs
    // (SMP) and EOI handling, while the PIT remains the single 100 Hz tick
    // source. Programming the periodic LAPIC timer to vector 32 (the same IDT
    // vector as the PIT IRQ handler, which is what the old code did) makes
    // BOTH sources fire into timer.irqHandler, doubling every tick and making
    // sleep()/time()/TCP timers run 2x fast.
    const timer_vector: u32 = 32;
    const masked: u32 = 1 << 16;
    writeReg(REG_LVT_TIMER, masked | timer_vector);
    writeReg(REG_TIMER_INIT, 0);

    apic_enabled = true;
    serial.serialWrite("[APIC] Local APIC timer initialized at 0x");
    serial.serialWriteHex(apic_base);
    serial.serialWrite(" (Vector 32, Periodic 100 Hz)\n");

    return true;
}

pub fn isEnabled() bool {
    return apic_enabled;
}
