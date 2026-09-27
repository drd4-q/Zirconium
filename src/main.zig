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
    // Only now is the IDT live: a framebuffer the firmware reported but did not
    // back would fault here as a *reportable* exception instead of a triple
    // fault reboot with an empty log.
    vga_fb.probeLfbSafe();
    {
        // NXE (EFER bit 11) makes PTE bit 63 meaningful. entry.S sets it and
        // marks the identity map non-executable above the kernel image, so a
        // ring-3 task cannot execute kernel or RAM pages.
        const efer = @import("arch/msr.zig").read(0xC0000080);
        serial.serialWrite("[BOOT] EFER NXE=");
        serial.serialWrite(if (efer & (1 << 11) != 0) "on" else "OFF");
        serial.serialWrite("\n");
    }

    // Enable the `syscall` instruction: Linux binaries enter the kernel that
    // way, not through INT 0x80.
    @import("arch/syscall64.zig").init();

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
    @import("kernel/seedfs.zig").init();
    vga.write("[BOOT] Filesystem initialized\n");

    vga.write("[BOOT] Initializing Kernel modules...\n");
    kernel_init.init();
    vga.write("[BOOT] Kernel modules initialized\n");
    serial.serialWrite("[BOOT] Kernel init done\n");

    // Bring up all block-device providers before scanning partitions.  This
    // is the single hardware-initialization pass; the shell no longer repeats
    // PCI/storage discovery during boot.
    //
    // Storage deliberately comes BEFORE the network: it is what brings up
    // klog, and the persistent log is the only evidence that survives a crash
    // later in boot.  With the network first, a fault in storage/USB left no
    // trace at all on real hardware.
    vga.write("[BOOT] Initializing storage and input...\n");
    @import("drivers/virtio_blk.zig").init();
    _ = @import("drivers/ahci.zig").init();
    @import("drivers/usb.zig").init();
    @import("fs/partition.zig").scanAll();
    @import("fs/fat16.zig").init();
    const fat32 = @import("fs/fat32.zig");
    fat32.init();
    if (fat32.isMounted()) {
        _ = klog.init(fat32.mountPoint());
    } else if (vfs.isMountedAt("/mnt/disk")) {
        // FAT16 remains a supported fallback and can host a small log too.
        _ = klog.init("/mnt/disk");
    } else {
        _ = klog.init("");
    }
    serial.serialWrite("[BOOT] Kernel log enabled\n");

    vga.write("[BOOT] Initializing network...\n");
    pci.scan();
    var net_dev_idx: usize = 0;
    while (net_dev_idx < pci.device_count) : (net_dev_idx += 1) {
        const dev = &pci.devices[net_dev_idx];
        if (dev.class == 0x02 and (dev.subclass == 0x00 or dev.subclass == 0x80)) {
            if (@import("drivers/e1000.zig").init(dev) or @import("drivers/rtl8169.zig").init(dev)) {
                break;
            }
        }
    }
    @import("net/mod.zig").init();
    @import("net/mod.zig").refreshUsbNic();
    serial.serialWrite("[BOOT] Network init done\n");
    const usb_state = @import("drivers/usb.zig");
    serial.serialWrite("[USB] post-init summary: controllers=");
    serial.serialWriteDec(usb_state.getControllerCount());
    serial.serialWrite(", devices=");
    serial.serialWriteDec(usb_state.getDeviceCount());
    serial.serialWrite(", pci_devices=");
    serial.serialWriteDec(pci.device_count);
    serial.serialWrite("\n");
    @import("drivers/mouse.zig").init();
    vga.write("[BOOT] Storage and input initialized\n");

    vga.write("[BOOT] Bringing secondary CPUs online...\n");
    @import("arch/smp.zig").init();
    vga.write("[BOOT] SMP init done\n");

    vga.write("[BOOT] Starting scheduler...\n");
    // The tick has to be live *before* the first task runs: scheduleTick is
    // what polls USB and what preempts a task whose slice expired. Leaving this
    // to shell.run() meant no preemption (and no USB polling) during runAll().
    scheduler_ready = true;
    scheduler.runAll();
    serial.serialWrite("[BOOT] Scheduler completed\n");

    // USB is already up from the storage/input pass above; usb.mod.init()
    // guards on `initialized` and would be a no-op here.
    vga.write("[BOOT] Launching Shell...\n");
    serial.serialWrite("[BOOT] Launching Shell\n");
    shell.run();

    serial.serialWrite("[BOOT] Shell exited\n");
    while (true) {
        asm volatile ("hlt");
    }
}

extern const __kernel_start: u8;
extern const __kernel_end: u8;
