const std = @import("std");
pub const serial = @import("system/serial.zig");
pub const vga = @import("system/vga.zig");
const system_init = @import("system/init.zig");
const shell = @import("shell.zig");
pub const scheduler = @import("kernel/scheduler.zig");
pub const pmm = @import("kernel/pmm.zig");
pub const vmm = @import("kernel/vmm.zig");
pub const kalloc = @import("kernel/kalloc.zig");
const kernel_init = @import("kernel/init.zig");
const gdt = @import("arch/gdt.zig");

const syscall = @import("kernel/syscall.zig");

pub var scheduler_ready: bool = false;

// Force export of syscall_handler for asm reference
comptime {
    _ = syscall.syscall_handler;
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    asm volatile ("cli");
    serial.serialWrite("\n=== PANIC ===\n");
    serial.serialWrite(msg);
    serial.serialWrite("\n");
    vga.setColor(.light_red, .black);
    vga.write("\n=== PANIC ===\n");
    vga.write(msg);
    vga.write("\n");
    var current_rbp: u64 = 0;
    asm volatile ("movq %%rbp, %[rbp]" : [rbp] "=r" (current_rbp));
    @import("system/panic.zig").printBacktrace(current_rbp);
    while (true) {
        asm volatile ("hlt");
    }
}

export fn kernel_entry(magic: u32, mbi_ptr: u32) callconv(.c) noreturn {
    serial.init();
    serial.serialWrite("[BOOT] Kernel loaded\n");

    // Initialize GDT with ring 3 segments
    gdt.init(@intFromPtr(&scheduler.tasks[0].kernel_stack) + @import("kernel/task.zig").KERNEL_STACK_SIZE);
    serial.serialWrite("[BOOT] GDT initialized with ring 3 segments\n");

    // Initialize framebuffer from multiboot info (before system_init which uses VGA)
    vga.initFb(mbi_ptr);
    if (vga.isFbActive()) {
        serial.serialWrite("[BOOT] Framebuffer active\n");
    }

    system_init.init(magic, mbi_ptr);
    serial.serialWrite("[BOOT] System init done\n");

    vga.write("[BOOT] Initializing PMM...\n");
    pmm.init(@intFromPtr(&__kernel_start), @intFromPtr(&__kernel_end));
    vga.write("[BOOT] PMM initialized\n");

    vga.write("[BOOT] Initializing VMM...\n");
    vmm.init();
    vga.write("[BOOT] VMM initialized\n");

    vga.write("[BOOT] Initializing kernel heap...\n");
    kalloc.init();
    vga.write("[BOOT] Kernel heap initialized\n");

    vga.write("[BOOT] Initializing filesystem...\n");
    const ramfs = @import("fs/ramfs.zig");
    const vfs = @import("fs/vfs.zig");
    vfs.init();
    ramfs.init();
    ramfs.registerMount();
    vga.write("[BOOT] Filesystem initialized\n");

    vga.write("[BOOT] Initializing Kernel modules...\n");
    kernel_init.init();
    vga.write("[BOOT] Kernel modules initialized\n");
    serial.serialWrite("[BOOT] Kernel init done\n");

    vga.write("[BOOT] Starting scheduler...\n");
    scheduler.runAll();
    vga.write("[BOOT] Scheduler completed\n");

    vga.write("[BOOT] Launching Shell...\n");
    shell.run();

    serial.serialWrite("[BOOT] Shell exited\n");
    while (true) {
        asm volatile ("hlt");
    }
}

extern const __kernel_start: u8;
extern const __kernel_end: u8;
