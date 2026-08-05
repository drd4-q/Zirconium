const root = @import("root");
const port_io = @import("port.zig");
const pic = @import("pic.zig");
const serial = @import("../system/serial.zig");
const vga = @import("../system/vga.zig");

pub const InterruptFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    int_num: u64,
    error_code: u64,
    // CPU pushed:
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub const IrqHandler = *const fn (frame: *InterruptFrame) void;

var irq_handlers: [16]?IrqHandler = [_]?IrqHandler{null} ** 16;

pub fn registerIrq(irq: u8, handler: IrqHandler) void {
    irq_handlers[irq] = handler;
    pic.unmask(irq);
}

pub fn unregisterIrq(irq: u8) void {
    irq_handlers[irq] = null;
    pic.mask(irq);
}

const exception_names = [_][]const u8{
    "Division By Zero",
    "Debug",
    "Non Maskable Interrupt",
    "Breakpoint",
    "Overflow",
    "Bound Range Exceeded",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Segment Overrun",
    "Invalid TSS",
    "Segment Not Present",
    "Stack-Segment Fault",
    "General Protection Fault",
    "Page Fault",
    "Reserved",
    "x87 FPU Error",
    "Alignment Check",
    "Machine Check",
    "SIMD Floating-Point Exception",
    "Virtualization Exception",
    "Control Protection Exception",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Hypervisor Injection Exception",
    "VMM Communication Exception",
    "Security Exception",
    "Reserved",
};

export fn isr_handler(frame: *InterruptFrame) callconv(.c) void {
    const int_num = frame.int_num;

    if (int_num < 32) {
        serial.serialWrite("\n=== EXCEPTION: ");
        if (int_num < exception_names.len) {
            serial.serialWrite(exception_names[int_num]);
        } else {
            serial.serialWrite("Unknown");
        }
        serial.serialWrite(" ===\n");

        serial.serialWrite("  Error code: 0x");
        serial.serialWriteHex(frame.error_code);
        serial.serialWrite("\n");
        serial.serialWrite("  RAX=0x"); serial.serialWriteHex(frame.rax);
        serial.serialWrite(" RBX=0x"); serial.serialWriteHex(frame.rbx);
        serial.serialWrite(" RCX=0x"); serial.serialWriteHex(frame.rcx);
        serial.serialWrite(" RDX=0x"); serial.serialWriteHex(frame.rdx);
        serial.serialWrite("\n");
        serial.serialWrite("  RSI=0x"); serial.serialWriteHex(frame.rsi);
        serial.serialWrite(" RDI=0x"); serial.serialWriteHex(frame.rdi);
        serial.serialWrite(" RBP=0x"); serial.serialWriteHex(frame.rbp);
        serial.serialWrite(" RSP=0x"); serial.serialWriteHex(frame.rsp);
        serial.serialWrite("\n");
        serial.serialWrite("  RIP=0x"); serial.serialWriteHex(frame.rip);
        serial.serialWrite(" CS=0x"); serial.serialWriteHex(frame.cs);
        serial.serialWrite(" RFLAGS=0x"); serial.serialWriteHex(frame.rflags);
        serial.serialWrite(" SS=0x"); serial.serialWriteHex(frame.ss);
        serial.serialWrite("\n");

        if (int_num == 14) {
            var fault_addr: u64 = 0;
            asm volatile ("movq %%cr2, %[addr]" : [addr] "=r" (fault_addr));
            serial.serialWrite("  CR2 (fault addr): 0x");
            serial.serialWriteHex(fault_addr);
            serial.serialWrite("\n");
        }

        vga.setColor(.light_red, .black);
        vga.write("\n=== KERNEL PANIC ===\n");
        vga.write("Exception: ");
        if (int_num < exception_names.len) {
            vga.write(exception_names[int_num]);
        } else {
            vga.write("Unknown");
        }
        vga.putChar('\n');

        while (true) {
            asm volatile ("cli; hlt");
        }
    }

    if (int_num >= 32 and int_num < 48) {
        const irq: u8 = @intCast(int_num - 32);
        if (irq_handlers[irq]) |handler| {
            handler(frame);
        }

        pic.sendEoi(irq);
    }
}
