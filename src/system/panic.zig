const serial = @import("serial.zig");
const vga = @import("vga.zig");

pub fn printBacktrace(start_rbp: u64) void {
    serial.serialWrite("\n=== STACK TRACE ===\n");
    vga.write("\n=== STACK TRACE ===\n");
    var rbp = start_rbp;
    var depth: usize = 0;
    while (rbp >= 0x100000 and rbp < 0x800000000000 and depth < 16) : (depth += 1) {
        const frame_ptr: [*]const u64 = @ptrFromInt(rbp);
        const next_rbp = frame_ptr[0];
        const return_rip = frame_ptr[1];

        if (return_rip == 0) break;

        serial.serialWrite("  #");
        serial.serialWriteDec(depth);
        serial.serialWrite(" RIP: 0x");
        serial.serialWriteHex(return_rip);
        serial.serialWrite(" RBP: 0x");
        serial.serialWriteHex(rbp);
        serial.serialWrite("\n");

        vga.write("  #");
        vga.writeDec(depth);
        vga.write(" RIP: 0x");
        vga.writeHex(return_rip);
        vga.write("\n");

        if (next_rbp <= rbp) break;
        rbp = next_rbp;
    }
}

fn announce(msg: []const u8, code: ?u64) void {
    serial.serialWrite("\n!!! KERNEL PANIC !!!\nMessage: ");
    serial.serialWrite(msg);
    if (code) |c| {
        serial.serialWrite(" Code: 0x");
        serial.serialWriteHex(c);
    }
    serial.serialWrite("\n");

    vga.setColor(.light_red, .black);
    vga.write("\n!!! KERNEL PANIC !!!\n");
    vga.write("Message: ");
    vga.write(msg);
    if (code) |c| {
        vga.write("\nError code: 0x");
        vga.writeHex(c);
    }
    vga.write("\n");
}

fn dumpBacktraceAndHalt() noreturn {
    var current_rbp: u64 = 0;
    asm volatile ("movq %%rbp, %[rbp]" : [rbp] "=r" (current_rbp));
    printBacktrace(current_rbp);
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn kernelPanic(msg: []const u8) noreturn {
    asm volatile ("cli");
    announce(msg, null);
    dumpBacktraceAndHalt();
}

pub fn panicWithCode(msg: []const u8, code: u64) noreturn {
    asm volatile ("cli");
    announce(msg, code);
    dumpBacktraceAndHalt();
}