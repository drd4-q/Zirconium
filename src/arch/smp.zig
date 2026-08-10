// SMP bootstrap: wake secondary CPUs via APIC INIT-SIPI-SIPI, hand them the
// shared kernel page tables / GDT / IDT plus a per-CPU stack, and let each AP
// run its own idle loop inside ap_entry.

const serial = @import("../system/serial.zig");
const pmm = @import("../kernel/pmm.zig");
const vmm = @import("../kernel/vmm.zig");
const acpi = @import("acpi.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const timer = @import("../drivers/timer.zig");

const AP_BASE: u64 = 0x8000;
const AP_STACK_SIZE: usize = 16 * 1024;

// Fixed cells inside the trampoline blob (see src/arch/trampoline.S).
const CELL_GDT_DESC: usize = 0x600; // 10 bytes
const CELL_IDT_DESC: usize = 0x610; // 10 bytes
const CELL_PML4: usize = 0x700; // u64
const CELL_STACK: usize = 0x708; // u64
const CELL_INDEX: usize = 0x710; // u64
const CELL_ENTRY: usize = 0x718; // u64

const LAPIC_ICR_LO: u32 = 0x300;
const LAPIC_ICR_HI: u32 = 0x310;

const ICR_INIT_ASSERT: u32 = 0x0000C500; // delivery mode 5 (INIT), level+trigger
// SIPI: delivery mode 6 lives in bits 10:8 => 6 << 8 = 0x600 (IBM 0x6000
// would put the mode bits into 14:13, decoding as FIXED vector = never wakes).
const ICR_SIPI: u32 = (6 << 8) | @as(u32, @intCast(AP_BASE >> 12));

pub export var smp_cpus_online: u32 = 0;
pub var smp_booted: bool = false;
pub var ap_ticks: [acpi.MAX_CPU]u64 = [_]u64{0} ** acpi.MAX_CPU;
pub var online_flags: [acpi.MAX_CPU]bool = [_]bool{false} ** acpi.MAX_CPU;

var lapic_base_read: u64 = 0;
var boot_busy: u32 = 0;

fn rdmsr(msr: u32) u64 {
    var low: u32 = 0;
    var high: u32 = 0;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low), [high] "={edx}" (high)
        : [msr] "{ecx}" (msr)
        : .{ .memory = true }
    );
    return (@as(u64, high) << 32) | low;
}

fn lapicBase() u64 {
    if (lapic_base_read == 0) {
        lapic_base_read = rdmsr(0x1B) & 0xFFFFF000;
        if (lapic_base_read == 0) lapic_base_read = 0xFEE00000;
    }
    return lapic_base_read;
}

fn lapicRead(offset: u32) u32 {
    const p: *volatile u32 = @ptrFromInt(lapicBase() + offset);
    return p.*;
}

fn lapicWrite(offset: u32, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(lapicBase() + offset);
    p.* = value;
}

pub fn getLapicId() u32 {
    // LAPIC ID register (offset 0x20), bits 31:24.
    return (lapicRead(0x20) >> 24) & 0xFF;
}

fn tryLock() bool {
    return @atomicRmw(u32, &boot_busy, .Xchg, 1, .acquire) == 0;
}

fn unlock() void {
    @atomicStore(u32, &boot_busy, 0, .release);
}

fn writeU64Cell(offset: usize, value: u64) void {
    const p: *volatile u64 = @ptrFromInt(AP_BASE + offset);
    p.* = value;
}

fn writeBytesCell(offset: usize, buf: [10]u8) void {
    const dst: [*]volatile u8 = @ptrFromInt(AP_BASE + offset);
    for (buf, 0..) |b, i| dst[i] = b;
}

fn fillDescBytes(buf: *[10]u8, limit: u16, base: u64) void {
    buf[0] = @intCast(limit & 0xFF);
    buf[1] = @intCast((limit >> 8) & 0xFF);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        buf[2 + i] = @intCast((base >> @as(u6, @intCast(i * 8))) & 0xFF);
    }
}

// Copy the trampoline blob to 0x8000 and feed it the boot parameters.
fn prepareAp(index: u64, stack_top: u64) void {
    const blob = @import("ap_tramp_bin");

    const dst: [*]volatile u8 = @ptrFromInt(AP_BASE);
    for (blob.data, 0..) |b, i| dst[i] = b;

    var gdt_desc: [10]u8 = undefined;
    fillDescBytes(&gdt_desc, gdt.gdtLimit(), @intFromPtr(gdt.gdtAddr()));
    writeBytesCell(CELL_GDT_DESC, gdt_desc);

    var idt_desc: [10]u8 = undefined;
    fillDescBytes(&idt_desc, idt.idtLimit(), @intFromPtr(idt.idtAddr()));
    writeBytesCell(CELL_IDT_DESC, idt_desc);

    writeU64Cell(CELL_PML4, vmm.getCurrentCr3());
    writeU64Cell(CELL_STACK, stack_top);
    writeU64Cell(CELL_INDEX, index);
    writeU64Cell(CELL_ENTRY, @intFromPtr(&ap_entry));
}

inline fn lapicIpiWait() void {
    var spins: u32 = 0;
    while (lapicRead(LAPIC_ICR_LO) & 0x1000 != 0 and spins < 100000000) : (spins += 1) {
        asm volatile ("pause");
    }
}

// Send an IPI to a single AP (write destination then trigger on ICR_LO).
fn sendIpiTo(apic_id: u32, icr_lo: u32) void {
    lapicWrite(LAPIC_ICR_HI, apic_id << 24);
    lapicWrite(LAPIC_ICR_LO, icr_lo);
    lapicIpiWait();
}

// INIT pulse to a single AP.
fn sendInitAp(apic_id: u32) void {
    sendIpiTo(apic_id, ICR_INIT_ASSERT);
    timer.sleep(100); // let the AP settle into its wait-for-SIPI park
}

// Two STARTUP IPIs to a single AP (spec wants >= 200 us between them).
fn sendStartupAp(apic_id: u32) void {
    sendIpiTo(apic_id, ICR_SIPI);
    timer.sleep(2); // >= 200 us; timer granularity is 10 ms
    sendIpiTo(apic_id, ICR_SIPI);
    timer.sleep(2);
}

fn waitCpuOnline(expected: u32) void {
    var spins: u32 = 0;
    while (smp_cpus_online < expected and spins < 2000000) : (spins += 1) {
        asm volatile ("pause");
    }
}

pub export fn ap_entry(cpu_index: u64) callconv(.c) noreturn {
    while (!tryLock()) {
        asm volatile ("pause");
    }
    serial.serialWrite("[SMP] AP CPU ");
    serial.serialWriteDec(cpu_index);
    serial.serialWrite(" online, LAPIC ID ");
    serial.serialWriteHex(@intCast(getLapicId()));
    serial.serialWrite("\n");
    unlock();

    _ = @atomicRmw(u32, &smp_cpus_online, .Add, 1, .seq_cst);
    if (cpu_index < online_flags.len) {
        online_flags[cpu_index] = true;
    }

    var ticks: u64 = 0;
    while (true) {
        ticks +%= 1;
        if ((ticks & 0x1FFFF) == 0) {
            if (cpu_index < ap_ticks.len) ap_ticks[cpu_index] = ticks;
        }
        asm volatile ("pause");
    }
}

pub fn init() void {
    serial.serialWrite("[SMP] Detecting CPUs via ACPI...\n");
    _ = acpi.discover();

    const bsp_id = getLapicId();
    if (acpi.cpu_count <= 1) {
        serial.serialWrite("[SMP] Single CPU only (no SMP boot)\n");
        smp_booted = false;
        return;
    }

    serial.serialWrite("[SMP] BSP LAPIC ID ");
    serial.serialWriteDec(bsp_id);
    serial.serialWrite(", starting APs...\n");

    var ap_index: u32 = 0;
    var i: usize = 0;
    while (i < acpi.cpu_count) : (i += 1) {
        const ap_id = acpi.lapic_ids[i];
        if (ap_id == bsp_id) continue;

        ap_index += 1;
        const index = ap_index;

        const stack_phys = pmm.allocPages(AP_STACK_SIZE / 4096) orelse {
            serial.serialWrite("[SMP] Failed to allocate AP stack; aborting\n");
            return;
        };
        const stack_top: u64 = @intCast(stack_phys + AP_STACK_SIZE - 8);

        prepareAp(index, stack_top);

        serial.serialWrite("[SMP] Booting AP ");
        serial.serialWriteDec(index);
        serial.serialWrite(" (LAPIC ID ");
        serial.serialWriteDec(ap_id);
        serial.serialWrite(")...\n");

        sendInitAp(ap_id);
        sendStartupAp(ap_id);

        waitCpuOnline(index);
        serial.serialWrite("[SMP] AP ");
        serial.serialWriteDec(index);
        serial.serialWrite(" confirmed online (online=");
        serial.serialWriteDec(smp_cpus_online);
        serial.serialWrite(")\n");
    }

    smp_booted = true;
    serial.serialWrite("[SMP] SMP online: ");
    serial.serialWriteDec(smp_cpus_online);
    serial.serialWrite(" AP(s), ");
    serial.serialWriteDec(acpi.cpu_count);
    serial.serialWrite(" CPU(s) total\n");
}

pub fn cpuCount() usize {
    return acpi.cpu_count;
}

pub fn cpuOnline() u32 {
    return smp_cpus_online;
}