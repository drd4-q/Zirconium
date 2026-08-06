const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;
const scheduler = @import("scheduler.zig");

fn idleTask() void {
    vga.setColor(.light_gray, .black);
    vga.write("[TASK] Idle task is running\n");
    port.serialWrite("[TASK] Idle task is running\n");
}

fn helloTask() void {
    vga.setColor(.pink, .black);
    vga.write("[TASK] Hello from kernel task!\n");
    port.serialWrite("[TASK] Hello from kernel task!\n");
}

pub fn init() void {
    vga.setColor(.magenta, .black);
    vga.write("[KERNEL] Initializing kernel...\n");
    port.serialWrite("[KERNEL] Initializing kernel...\n");

    scheduler.init();

    @import("../drivers/timer.zig").init();

    _ = scheduler.addKernelTask(&idleTask);
    _ = scheduler.addKernelTask(&helloTask);

    const user_test_bin = @import("user_test_bin");
    _ = scheduler.addElfUserTask(&user_test_bin.data);

    vga.setColor(.magenta, .black);
    vga.write("[KERNEL] Kernel init done, ");
    vga.writeDec(scheduler.taskCount());
    vga.write(" tasks loaded\n");
    port.serialWrite("[KERNEL] Kernel init done, ");
    port.serialWriteHex(scheduler.taskCount());
    port.serialWrite(" tasks loaded\n");
}
