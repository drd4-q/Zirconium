const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;
const panic_mod = @import("panic.zig");

const pic = @import("../arch/pic.zig");
const idt = @import("../arch/idt.zig");

pub var multiboot_info_ptr: u64 = 0;

pub fn init(magic: u32, mbi_ptr: u32) void {
    vga.clear();
    vga.setColor(.green, .black);
    vga.write("[SYSTEM] Initializing...\n");
    port.serialWrite("[SYSTEM] Initializing...\n");

    if (magic != 0x2BADB002) {
        panic_mod.kernelPanic("Invalid multiboot magic");
    }

    multiboot_info_ptr = mbi_ptr;
    vga.setColor(.light_green, .black);
    vga.write("[SYSTEM] Multiboot verified OK\n");
    port.serialWrite("[SYSTEM] Multiboot verified OK\n");

    vga.write("[SYSTEM] Step 1: Initializing PIC...\n");
    pic.init();
    vga.write("[SYSTEM] Step 2: PIC initialized\n");
    port.serialWrite("[SYSTEM] PIC initialized\n");

    vga.write("[SYSTEM] Step 3: Loading IDT...\n");
    idt.init();
    vga.write("[SYSTEM] Step 4: IDT loaded\n");
    port.serialWrite("[SYSTEM] IDT loaded (256 entries)\n");

    vga.write("[SYSTEM] Step 5: Enabling interrupts (STI)...\n");
    port.serialWrite("[SYSTEM] Enabling interrupts...\n");
    asm volatile ("sti");
    port.serialWrite("[SYSTEM] Interrupts enabled\n");
    vga.write("[SYSTEM] Step 6: Interrupts enabled\n");

    vga.setColor(.white, .black);
    vga.write("[SYSTEM] System init complete\n");
    port.serialWrite("[SYSTEM] System init complete\n");
}
