//! The boot sequence, driven by the declarative configuration.
//!
//! The *order* of the boot is data: `config.boot_stages` lists the stages, and
//! `config/kernel.json` decides what is in that list.  A stage whose required
//! feature is switched off is not in the list at all, so turning a feature off
//! removes its initialisation without anybody having to remember to remove
//! the call as well.
//!
//! Each stage lives in its own function here rather than in `main.zig`, so
//! the switch below is exhaustive: a new stage name in the configuration
//! that nobody implemented is a compile error, not a boot that quietly skips
//! a subsystem.

const std = @import("std");
const root = @import("root");
const config = @import("config");

const serial = root.serial;
const vga = root.vga;
const scheduler = root.scheduler;
const pmm = root.pmm;
const vmm = root.vmm;
const kalloc = root.kalloc;

/// The multiboot values the loader handed us.  Several stages need them.
var mb_magic: u32 = 0;
var mb_info: u32 = 0;

/// The stage the boot is in.
///
/// The panic message says it, so that a machine that comes up with a black
/// screen still says how far it got - and the serial log says it too, but the
/// serial log needs a serial cable.
pub var current_stage: config.Stage = .gdt;
pub var stage_number: usize = 0;
pub var stage_total: usize = 0;

/// Run the configured boot sequence.
///
/// Never returns: the last stage hands control to the shell, and the shell
/// never gives it back.
pub fn run(magic: u32, mbi_ptr: u32) noreturn {
    mb_magic = magic;
    mb_info = mbi_ptr;

    stage_total = config.boot_stages.len;
    for (config.boot_stages) |stage| {
        current_stage = stage;
        stage_number += 1;
        serial.serialWrite("[BOOT] stage ");
        serial.serialWriteDec(stage_number);
        serial.serialWrite("/");
        serial.serialWriteDec(stage_total);
        serial.serialWrite(" ");
        serial.serialWrite(@tagName(stage));
        serial.serialWrite("\n");
        runStage(stage);

        // Write the log out after every stage.  The flush normally happens
        // from the shell's input loop, and a machine that hangs later never
        // gets there - but the log has to say how far it got.
        @import("../system/kernel_log.zig").flush();
    }

    // The configuration did not include a shell stage; there is nothing left
    // to do but halt.
    serial.serialWrite("[BOOT] Boot sequence finished with no shell stage\n");
    while (true) {
        asm volatile ("hlt");
    }
}

fn runStage(stage: config.Stage) void {
    switch (stage) {
        .gdt => stageGdt(),
        .framebuffer => stageFramebuffer(),
        .system => stageSystem(),
        .syscall64 => stageSyscall64(),
        .memory => stageMemory(),
        .filesystem => stageFilesystem(),
        .kernel => stageKernel(),
        .pci => stagePci(),
        .storage => stageStorage(),
        .machines => stageMachines(),
        .guests => stageGuests(),
        .network => stageNetwork(),
        .input => stageInput(),
        .bluetooth => stageBluetooth(),
        .smp => stageSmp(),
        .scheduler => stageScheduler(),
        .shell => stageShell(),
    }
}

// ─── Stages ─────────────────────────────────────────────────────────

fn stageGdt() void {
    const task = @import("task.zig");
    gdt().init(@intFromPtr(&scheduler.tasks[0].kernel_stack) + task.KERNEL_STACK_SIZE);
    serial.serialWrite("[BOOT] GDT initialized with ring 3 segments\n");
}

fn stageFramebuffer() void {
    vga.initFb(mb_info);
    if (vga.isFbActive()) {
        serial.serialWrite("[BOOT] Framebuffer active\n");
    }
}

fn stageSystem() void {
    @import("../system/init.zig").init(mb_magic, mb_info);
    serial.serialWrite("[BOOT] System init done\n");

    // Only now is the IDT live: a framebuffer the firmware reported but did
    // not back would fault here as a *reportable* exception instead of a
    // triple fault reboot with an empty log.
    //
    // A display that cannot be driven is **not** a reason to stop the boot.
    // The console falls back to the legacy VGA text mode, where the kernel
    // paints the characters itself - software rendering, no adapter needed -
    // and the boot goes on, so that the reason ends up in the kernel log
    // instead of nowhere.
    if (!@import("../system/framebuffer.zig").probeLfbSafe()) {
        serial.serialWrite("[BOOT] The framebuffer is not usable; the console falls back to the VGA text mode\n");
        serial.serialWrite("[BOOT] On a machine whose display is driven by an adapter the text mode\n");
        serial.serialWrite("[BOOT] may not be scanned out either; the serial log is the console then.\n");
        @import("../system/gfx/mod.zig").useText();
    }

    // The DRM model around the bootloader's framebuffer: the connector,
    // the CRTC, the fbdev and the EDID of the display.  It runs here and
    // not in the framebuffer stage because the IDT has to be live: the DDC
    // read talks to the display adapter.
    const fb = @import("../system/framebuffer.zig");
    if (fb.active) {
        @import("../drivers/drm/mod.zig").init(
            @intCast(fb.fb_addr),
            fb.fb_width,
            fb.fb_height,
            fb.fb_pitch,
            @intCast(fb.fb_bpp),
        );
    }

    // NXE (EFER bit 11) makes PTE bit 63 meaningful. entry.S sets it and
    // marks the identity map non-executable above the kernel image, so a
    // ring-3 task cannot execute kernel or RAM pages.
    const efer = @import("../arch/msr.zig").read(0xC0000080);
    serial.serialWrite("[BOOT] EFER NXE=");
    serial.serialWrite(if (efer & (1 << 11) != 0) "on" else "OFF");
    serial.serialWrite("\n");
}

fn stageSyscall64() void {
    // Enable the `syscall` instruction: Linux binaries enter the kernel that
    // way, not through INT 0x80.
    @import("../arch/syscall64.zig").init();
}

fn stageMemory() void {
    vga.write("[BOOT] Initializing PMM...\n");
    pmm.init(@intFromPtr(&__kernel_start), @intFromPtr(&__kernel_end));
    vga.write("[BOOT] PMM initialized\n");

    vga.write("[BOOT] Initializing VMM...\n");
    vmm.init();
    vga.write("[BOOT] VMM initialized\n");

    vga.write("[BOOT] Initializing kernel heap...\n");
    kalloc.init();
    vga.write("[BOOT] Kernel heap initialized\n");
}

fn stageFilesystem() void {
    vga.write("[BOOT] Initializing filesystem...\n");
    const ramfs = @import("../fs/ramfs.zig");
    const vfs = @import("../fs/vfs.zig");
    vfs.init();
    ramfs.init();
    ramfs.registerMount();
    @import("seedfs.zig").init();
    vga.write("[BOOT] Filesystem initialized\n");
}

fn stageKernel() void {
    vga.write("[BOOT] Initializing Kernel modules...\n");
    @import("init.zig").init();
    vga.write("[BOOT] Kernel modules initialized\n");
    serial.serialWrite("[BOOT] Kernel init done\n");
}

fn stagePci() void {
    // The bus must be enumerated before any driver looks for its device:
    // virtio_blk/ahci/usb all resolve through pci.findDevice(), which only
    // sees what the last scan filled in.
    @import("../drivers/pci.zig").scan();

    // The display adapters.  When the bootloader did not hand us a video mode
    // - the text mode it falls back to is not shown on a display that only
    // the adapter drives - a linear framebuffer on a PCI display adapter is
    // the next best thing.
    @import("../drivers/video/pcidisplay.zig").init();
    const fb = @import("../system/framebuffer.zig");
    if (!fb.active) {
        if (@import("../drivers/video/pcidisplay.zig").bindFramebuffer()) {
            serial.serialWrite("[BOOT] Console on the PCI display adapter\n");
        }
    }
}

fn stageStorage() void {
    vga.write("[BOOT] Initializing storage...\n");

    @import("../drivers/virtio_blk.zig").init();
    if (config.features.ahci) {
        _ = @import("../drivers/ahci.zig").init();
    }
    if (config.features.usb) {
        @import("../drivers/usb.zig").init();
    }
    @import("../fs/partition.zig").scanAll();
    @import("../fs/fat16.zig").init();
    if (config.features.fat32) {
        const fat32 = @import("../fs/fat32.zig");
        fat32.init();
    }

    // The kernel log needs somewhere to live: a FAT32 volume labelled ZLOG
    // wins over an unlabelled candidate, and FAT16 is the fallback.
    const klog = @import("../system/kernel_log.zig");
    const fat32 = @import("../fs/fat32.zig");
    if (fat32.isMounted()) {
        _ = klog.init(fat32.mountPoint());
    } else if (@import("../fs/vfs.zig").isMountedAt("/mnt/disk")) {
        _ = klog.init("/mnt/disk");
    } else {
        _ = klog.init("");
    }
    serial.serialWrite("[BOOT] Kernel log enabled\n");
    vga.write("[BOOT] Storage initialized\n");
}

/// Create the machines the configuration asks for.
///
/// This is the autoload: the machines come up without the operator having
/// to type anything.  It runs after the storage stage so that a machine can
/// be given a disk later, and before the network stage so the network is up
/// when the guests start asking for it.
fn stageMachines() void {
    @import("../vm/mod.zig").autoload();
}

/// Load the guest kernels of the autoloaded machines.
fn stageGuests() void {
    @import("../vm/mod.zig").loadGuests();
}

fn stageNetwork() void {
    vga.write("[BOOT] Initializing network...\n");
    const pci = @import("../drivers/pci.zig");
    var net_dev_idx: usize = 0;
    while (net_dev_idx < pci.device_count) : (net_dev_idx += 1) {
        const dev = &pci.devices[net_dev_idx];
        if (dev.class == 0x02 and (dev.subclass == 0x00 or dev.subclass == 0x80)) {
            if (@import("../drivers/e1000.zig").init(dev) or @import("../drivers/rtl8169.zig").init(dev)) {
                break;
            }
        }
    }
    @import("../net/mod.zig").init();
    @import("../net/mod.zig").refreshUsbNic();
    serial.serialWrite("[BOOT] Network init done\n");
    vga.write("[BOOT] Network initialized\n");
}

fn stageInput() void {
    vga.write("[BOOT] Initializing input...\n");
    const usb_state = @import("../drivers/usb.zig");
    serial.serialWrite("[USB] post-init summary: controllers=");
    serial.serialWriteDec(usb_state.getControllerCount());
    serial.serialWrite(", devices=");
    serial.serialWriteDec(usb_state.getDeviceCount());
    serial.serialWrite(", pci_devices=");
    serial.serialWriteDec(@import("../drivers/pci.zig").device_count);
    serial.serialWrite("\n");
    @import("../drivers/mouse.zig").init();
    vga.write("[BOOT] Input initialized\n");
}

fn stageBluetooth() void {
    // The Bluetooth stack: the protocol core, the USB transport for a real
    // controller and the virtual controller the hypervisor can hand to a
    // guest.
    @import("../drivers/bluetooth/mod.zig").init();
    vga.write("[BOOT] Bluetooth initialized\n");
}

fn stageSmp() void {
    vga.write("[BOOT] Bringing secondary CPUs online...\n");
    @import("../arch/smp.zig").init();
    vga.write("[BOOT] SMP init done\n");
}

fn stageScheduler() void {
    vga.write("[BOOT] Starting scheduler...\n");
    // The tick has to be live *before* the first task runs: scheduleTick is
    // what polls USB and what preempts a task whose slice expired. Leaving
    // this to shell.run() meant no preemption (and no USB polling) during
    // runAll().
    root.scheduler_ready = true;
    scheduler.runAll();
    serial.serialWrite("[BOOT] Scheduler completed\n");
}

fn stageShell() void {
    vga.write("[BOOT] Launching Shell...\n");
    serial.serialWrite("[BOOT] Launching Shell\n");
    // The shell never returns.
    @import("../shell.zig").run();
    serial.serialWrite("[BOOT] Shell exited\n");
    while (true) {
        asm volatile ("hlt");
    }
}

// ─── Helpers ────────────────────────────────────────────────────────

fn gdt() @TypeOf(@import("../arch/gdt.zig")) {
    return @import("../arch/gdt.zig");
}

extern const __kernel_start: u8;
extern const __kernel_end: u8;
