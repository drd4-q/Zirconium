const std = @import("std");
pub const serial = @import("system/serial.zig");
pub const vga = @import("system/vga.zig");
const system_init = @import("system/init.zig");
const shell = @import("shell.zig");
const pci = @import("drivers/pci.zig");
pub const scheduler = @import("kernel/scheduler.zig");
pub const pmm = @import("kernel/pmm.zig");
pub const vmm = @import("kernel/vmm.zig");
pub const kalloc = @import("kernel/kalloc.zig");
pub const tty = @import("system/tty.zig");
const vga_fb = @import("system/framebuffer.zig");
const kernel_init = @import("kernel/init.zig");
const gdt = @import("arch/gdt.zig");
const klog = @import("system/kernel_log.zig");
const boot = @import("kernel/boot.zig");

const syscall = @import("kernel/syscall.zig");
const winapi = @import("kernel/winapi.zig");

pub var scheduler_ready: bool = false;

// Force export of the asm-referenced entry handlers.
comptime {
    _ = syscall.syscall_handler;
    _ = winapi.win_thunk_handler;
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    asm volatile ("cli");
    serial.serialWrite("\n=== PANIC ===\n");
    serial.serialWrite(msg);
    serial.serialWrite("\n");
    klog.flush();
    vga.setColor(.light_red, .black);
    vga.write("\n=== PANIC ===\n");
    vga.write(msg);
    vga.write("\n");
    var current_rbp: u64 = 0;
    asm volatile ("movq %%rbp, %[rbp]"
        : [rbp] "=r" (current_rbp),
    );
    @import("system/panic.zig").printBacktrace(current_rbp);
    while (true) {
        asm volatile ("hlt");
    }
}

/// Kernel entry point.
///
/// The boot sequence itself lives in `kernel/boot.zig` and is driven by the
/// declarative configuration (`config/kernel.json`): which stages run, in
/// what order, and which features they need.
export fn kernel_entry(magic: u32, mbi_ptr: u32) callconv(.c) noreturn {
    serial.init();
    serial.serialWrite("[BOOT] Kernel loaded\n");
    boot.run(magic, mbi_ptr);
}
