const std = @import("std");
const root = @import("root");
const vga = root.vga;

pub fn kernelPanic(msg: []const u8) noreturn {
    asm volatile ("cli");
    vga.setColor(.light_red, .black);
    vga.write("\n!!! KERNEL PANIC !!!\n");
    vga.write("Message: ");
    vga.write(msg);
    vga.write("\n");

    while (true) {
        asm volatile ("hlt");
    }
}

pub fn panicWithCode(msg: []const u8, code: u64) noreturn {
    asm volatile ("cli");
    vga.setColor(.light_red, .black);
    vga.write("\n!!! KERNEL PANIC !!!\n");
    vga.write("Message: ");
    vga.write(msg);
    vga.write("\nError code: 0x");
    vga.writeHex(code);
    vga.write("\n");

    while (true) {
        asm volatile ("hlt");
    }
}
