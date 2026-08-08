const port_io = @import("../arch/port.zig");
const isr_mod = @import("../arch/isr.zig");

const PIT_FREQ: u32 = 1193182;
const TARGET_FREQ: u32 = 100;

pub var ticks: u64 = 0;
pub var seconds: u32 = 0;
pub var minutes: u32 = 0;
pub var hours: u32 = 0;

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

fn irqHandler(_: *isr_mod.InterruptFrame) void {
    ticks += 1;
    if (@import("root").scheduler_ready) {
        @import("../kernel/scheduler.zig").scheduleTick();
    }
}

pub fn sleep(ms: u32) void {
    const target = ticks + @as(u64, ms) / 10; // 100 Hz tick = 10 ms
    asm volatile ("sti");
    while (ticks < target) {
        asm volatile ("hlt");
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
