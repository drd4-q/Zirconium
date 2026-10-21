const port_io = @import("../arch/port.zig");
const isr_mod = @import("../arch/isr.zig");

const PIT_FREQ: u32 = 1193182;
// The tick rate comes from the declarative configuration
// (`timer.hz` in config/kernel.json).
const TARGET_FREQ: u32 = @import("config").timer_hz;

/// Written from the LAPIC/IRQ handler and read from every polling loop.
/// A 64-bit store is not atomic on x86-64, so the update and the reads go
/// through @atomic*; a plain `ticks += 1` can be observed torn by another CPU,
/// and - worse for correctness - a plain read in a spin loop can be hoisted out
/// of it, which silently removes the delay entirely.
pub var ticks: u64 = 0;
pub var seconds: u32 = 0;
pub var minutes: u32 = 0;
pub var hours: u32 = 0;

/// Monotonic tick count. Use this instead of reading `ticks` directly.
pub fn tickCount() u64 {
    return @atomicLoad(u64, &ticks, .monotonic);
}

pub fn init() void {
    const divisor: u32 = PIT_FREQ / TARGET_FREQ;
    const lo: u8 = @intCast(divisor & 0xFF);
    const hi: u8 = @intCast((divisor >> 8) & 0xFF);

    port_io.outb(0x43, 0x36);
    port_io.outb(0x40, lo);
    port_io.outb(0x40, hi);

    isr_mod.registerIrq(0, irqHandler);

    _ = @import("apic.zig").init();
}

fn irqHandler(frame: *isr_mod.InterruptFrame) void {
    _ = @atomicRmw(u64, &ticks, .Add, 1, .monotonic);
    if (@import("root").scheduler_ready) {
        // The frame is handed over so the scheduler can preempt: it rewrites
        // the saved ring-3 registers and this ISR's `iretq` resumes a different
        // task.
        @import("../kernel/scheduler.zig").scheduleTick(frame);
    }
}

pub fn sleep(ms: u32) void {
    const target = tickCount() + @as(u64, ms) / 10; // 100 Hz tick = 10 ms
    asm volatile ("sti");
    while (tickCount() < target) {
        // Memory clobber: without it the loop condition can be hoisted, leaving
        // a single check and no wait at all.
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

pub fn readRtcRegister(reg: u8) u8 {
    port_io.outb(0x70, reg);
    return port_io.inb(0x71);
}

pub fn updateTime() void {
    const sec = readRtcRegister(0x00);
    const min = readRtcRegister(0x02);
    const hr = readRtcRegister(0x04);

    seconds = bcdToDec(sec);
    minutes = bcdToDec(min);
    hours = bcdToDec(hr) & 0x7F;

    if (hours > 12) hours -= 12;
    if (hours == 0) hours = 12;
}

fn bcdToDec(bcd: u8) u32 {
    return @as(u32, (bcd >> 4) * 10) + @as(u32, bcd & 0x0F);
}

pub fn formatTime(buf: []u8) void {
    updateTime();
    const h = hours;
    const m = minutes;
    const s = seconds;

    buf[0] = @intCast('0' + (h / 10));
    buf[1] = @intCast('0' + (h % 10));
    buf[2] = ':';
    buf[3] = @intCast('0' + (m / 10));
    buf[4] = @intCast('0' + (m % 10));
    buf[5] = ':';
    buf[6] = @intCast('0' + (s / 10));
    buf[7] = @intCast('0' + (s % 10));
    buf[8] = 0;
}
