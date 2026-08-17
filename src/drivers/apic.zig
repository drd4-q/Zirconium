const serial = @import("../system/serial.zig");
const isr_mod = @import("../arch/isr.zig");
const port_io = @import("../arch/port.zig");
const pic = @import("../arch/pic.zig");

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

fn calibrateLapicTimer() u32 {
    // Set PIT channel 2 to one-shot mode for 10ms (100 Hz): 1193182 / 100 = 11931 ticks
    const orig_port61 = port_io.inb(0x61);
    port_io.outb(0x61, (orig_port61 & 0xFC)); // bit 0 = 0 (gate off), bit 1 = 0 (speaker off)
    port_io.outb(0x43, 0xB0); // Channel 2, lobyte/hibyte, mode 0 (one-shot), binary
    port_io.outb(0x42, @intCast(11931 & 0xFF));
    port_io.outb(0x42, @intCast((11931 >> 8) & 0xFF));

    // Reset LAPIC timer counter to max with divider 16
    writeReg(REG_TIMER_DIV, 0x3);
    writeReg(REG_TIMER_INIT, 0xFFFFFFFF);

    // Gate PIT channel 2 on to start countdown
    port_io.outb(0x61, (orig_port61 & 0xFC) | 0x01);

    // Wait until PIT2 output goes high (bit 5 of port 0x61)
    var timeout: u32 = 0;
    while ((port_io.inb(0x61) & 0x20) == 0 and timeout < 1_000_000) : (timeout += 1) {
        asm volatile ("pause");
    }

    const current_lapic = readReg(REG_TIMER_CURR);
    const elapsed = 0xFFFFFFFF - current_lapic;

    // Reset port 61
    port_io.outb(0x61, orig_port61);

    if (elapsed > 1000 and elapsed < 0xFFFFFFFF) {
        return elapsed;
    }
    return 100000; // Fallback reasonable value for ~10ms
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

    // Calibrate LAPIC timer against 10ms PIT pulse
    const ticks_per_10ms = calibrateLapicTimer();

    // Configure Periodic LAPIC Timer on Vector 32 (100 Hz)
    const timer_vector: u32 = 32;
    const periodic_mode: u32 = 0x20000; // Bit 17 = Periodic
    writeReg(REG_LVT_TIMER, periodic_mode | timer_vector);
    writeReg(REG_TIMER_INIT, ticks_per_10ms);

    // Mask legacy PIT IRQ 0 in 8259 PIC so LAPIC timer is the single clean 100 Hz source
    pic.mask(0);

    apic_enabled = true;
    serial.serialWrite("[APIC] Local APIC timer initialized at 0x");
    serial.serialWriteHex(apic_base);
    serial.serialWrite(" (Vector 32, Periodic 100 Hz)\n");

    return true;
}

pub fn isEnabled() bool {
    return apic_enabled;
}

