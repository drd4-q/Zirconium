const root = @import("root");
const vga = root.vga;
const serial = @import("../system/serial.zig");

const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,
};

const IdtPtr = packed struct {
    limit: u16,
    base: u64,
};

extern fn load_idt(ptr: u64) void;
extern fn syscall_entry() callconv(.naked) void;
extern fn win_thunk_entry() callconv(.naked) void;

var idt_entries: [256]IdtEntry align(16) = undefined;
var idt_ptr: IdtPtr align(16) = undefined;

extern fn isr0() callconv(.naked) void;
extern fn isr1() callconv(.naked) void;
extern fn isr2() callconv(.naked) void;
extern fn isr3() callconv(.naked) void;
extern fn isr4() callconv(.naked) void;
extern fn isr5() callconv(.naked) void;
extern fn isr6() callconv(.naked) void;
extern fn isr7() callconv(.naked) void;
extern fn isr8() callconv(.naked) void;
extern fn isr9() callconv(.naked) void;
extern fn isr10() callconv(.naked) void;
extern fn isr11() callconv(.naked) void;
extern fn isr12() callconv(.naked) void;
extern fn isr13() callconv(.naked) void;
extern fn isr14() callconv(.naked) void;
extern fn isr15() callconv(.naked) void;
extern fn isr16() callconv(.naked) void;
extern fn isr17() callconv(.naked) void;
extern fn isr18() callconv(.naked) void;
extern fn isr19() callconv(.naked) void;
extern fn isr20() callconv(.naked) void;
extern fn isr21() callconv(.naked) void;
extern fn isr22() callconv(.naked) void;
extern fn isr23() callconv(.naked) void;
extern fn isr24() callconv(.naked) void;
extern fn isr25() callconv(.naked) void;
extern fn isr26() callconv(.naked) void;
extern fn isr27() callconv(.naked) void;
extern fn isr28() callconv(.naked) void;
extern fn isr29() callconv(.naked) void;
extern fn isr30() callconv(.naked) void;
extern fn isr31() callconv(.naked) void;
extern fn irq0() callconv(.naked) void;
extern fn irq1() callconv(.naked) void;
extern fn irq2() callconv(.naked) void;
extern fn irq3() callconv(.naked) void;
extern fn irq4() callconv(.naked) void;
extern fn irq5() callconv(.naked) void;
extern fn irq6() callconv(.naked) void;
extern fn irq7() callconv(.naked) void;
extern fn irq8() callconv(.naked) void;
extern fn irq9() callconv(.naked) void;
extern fn irq10() callconv(.naked) void;
extern fn irq11() callconv(.naked) void;
extern fn irq12() callconv(.naked) void;
extern fn irq13() callconv(.naked) void;
extern fn irq14() callconv(.naked) void;
extern fn irq15() callconv(.naked) void;

fn addr(f_ptr: anytype) u64 {
    return @intFromPtr(f_ptr);
}

fn setEntry(n: usize, handler_addr: u64) void {
    idt_entries[n] = .{
        .offset_low = @intCast(handler_addr & 0xFFFF),
        .selector = 0x08,
        .ist = 0,
        .type_attr = 0x8E,
        .offset_mid = @intCast((handler_addr >> 16) & 0xFFFF),
        .offset_high = @intCast((handler_addr >> 32) & 0xFFFFFFFF),
        .reserved = 0,
    };
}

fn setEntryDpl3(n: usize, handler_addr: u64) void {
    idt_entries[n] = .{
        .offset_low = @intCast(handler_addr & 0xFFFF),
        .selector = 0x08,
        .ist = 0,
        .type_attr = 0xEF, // P=1, DPL=3, TRAP gate (keeps IF=1 in the handler;
        //                            an interrupt gate clears IF and a blocking
        //                            syscall such as read() on empty input would
        //                            hlt forever with the keyboard IRQ masked)
        .offset_mid = @intCast((handler_addr >> 16) & 0xFFFF),
        .offset_high = @intCast((handler_addr >> 32) & 0xFFFFFFFF),
        .reserved = 0,
    };
}

pub fn init() void {
    vga.write("  [IDT] Zeroing entries...\n");
    serial.serialWrite("[IDT] Zeroing entries...\n");
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        idt_entries[i] = .{
            .offset_low = 0,
            .selector = 0,
            .ist = 0,
            .type_attr = 0,
            .offset_mid = 0,
            .offset_high = 0,
            .reserved = 0,
        };
    }

    vga.write("  [IDT] Setting ISRs 0-31...\n");
    serial.serialWrite("[IDT] Setting ISR entries 0-31...\n");
    setEntry(0, @intFromPtr(&isr0));
    setEntry(1, @intFromPtr(&isr1));
    setEntry(2, @intFromPtr(&isr2));
    setEntry(3, @intFromPtr(&isr3));
    setEntry(4, @intFromPtr(&isr4));
    setEntry(5, @intFromPtr(&isr5));
    setEntry(6, @intFromPtr(&isr6));
    setEntry(7, @intFromPtr(&isr7));
    setEntry(8, @intFromPtr(&isr8));
    setEntry(9, @intFromPtr(&isr9));
    setEntry(10, @intFromPtr(&isr10));
    setEntry(11, @intFromPtr(&isr11));
    setEntry(12, @intFromPtr(&isr12));
    setEntry(13, @intFromPtr(&isr13));
    setEntry(14, @intFromPtr(&isr14));
    setEntry(15, @intFromPtr(&isr15));
    setEntry(16, @intFromPtr(&isr16));
    setEntry(17, @intFromPtr(&isr17));
    setEntry(18, @intFromPtr(&isr18));
    setEntry(19, @intFromPtr(&isr19));
    setEntry(20, @intFromPtr(&isr20));
    setEntry(21, @intFromPtr(&isr21));
    setEntry(22, @intFromPtr(&isr22));
    setEntry(23, @intFromPtr(&isr23));
    setEntry(24, @intFromPtr(&isr24));
    setEntry(25, @intFromPtr(&isr25));
    setEntry(26, @intFromPtr(&isr26));
    setEntry(27, @intFromPtr(&isr27));
    setEntry(28, @intFromPtr(&isr28));
    setEntry(29, @intFromPtr(&isr29));
    setEntry(30, @intFromPtr(&isr30));
    setEntry(31, @intFromPtr(&isr31));

    vga.write("  [IDT] Setting IRQs 32-47...\n");
    serial.serialWrite("[IDT] Setting IRQ entries 32-47...\n");
    setEntry(32, @intFromPtr(&irq0));
    setEntry(33, @intFromPtr(&irq1));
    setEntry(34, @intFromPtr(&irq2));
    setEntry(35, @intFromPtr(&irq3));
    setEntry(36, @intFromPtr(&irq4));
    setEntry(37, @intFromPtr(&irq5));
    setEntry(38, @intFromPtr(&irq6));
    setEntry(39, @intFromPtr(&irq7));
    setEntry(40, @intFromPtr(&irq8));
    setEntry(41, @intFromPtr(&irq9));
    setEntry(42, @intFromPtr(&irq10));
    setEntry(43, @intFromPtr(&irq11));
    setEntry(44, @intFromPtr(&irq12));
    setEntry(45, @intFromPtr(&irq13));
    setEntry(46, @intFromPtr(&irq14));
    setEntry(47, @intFromPtr(&irq15));

    // INT 0x80 syscall gate (DPL=3, so user code can call it)
    vga.write("  [IDT] Setting syscall gate 0x80...\n");
    serial.serialWrite("[IDT] Setting syscall gate 0x80...\n");
    setEntryDpl3(0x80, @intFromPtr(&syscall_entry));

    // INT 0x81: Win32 import thunk gate for PE executables (also DPL=3).
    setEntryDpl3(0x81, @intFromPtr(&win_thunk_entry));

    idt_ptr = .{
        .limit = @sizeOf(IdtEntry) * 256 - 1,
        .base = @intFromPtr(&idt_entries),
    };

    vga.write("  [IDT] Calling load_idt...\n");
    serial.serialWrite("[IDT] Loading IDT register...\n");
    load_idt(@intFromPtr(&idt_ptr));
    vga.write("  [IDT] load_idt completed\n");
    serial.serialWrite("[IDT] IDT loaded OK\n");
}

pub fn idtAddr() *align(16) [256]IdtEntry {
    return &idt_entries;
}

pub fn idtLimit() u16 {
    return @intCast(@sizeOf(IdtEntry) * 256 - 1);
}
