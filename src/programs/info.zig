const root = @import("root");
const vga = root.vga;
const timer = @import("../drivers/timer.zig");
const fb = @import("../system/framebuffer.zig");
const acpi = @import("../arch/acpi.zig");
const smp = @import("../arch/smp.zig");
const pmm = root.pmm;

pub fn run() void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== System Info ===\n\n");

    vga.setColor(.white, .black);
    vga.write("  Kernel:     Zirconium v0.3.0\n");
    vga.write("  Arch:       x86_64\n");

    // Dynamic display info depending on the active renderer.
    if (fb.active) {
        vga.write("  Display:    Framebuffer ");
        vga.writeDec(fb.fb_width);
        vga.write("x");
        vga.writeDec(fb.fb_height);
        vga.write(" @ ");
        vga.writeDec(fb.fb_bpp);
        vga.write("bpp\n");
        vga.write("  FB Addr:    0x");
        vga.writeHex(fb.fb_addr);
        vga.write("  pitch ");
        vga.writeDec(fb.fb_pitch);
        vga.write("\n");
    } else {
        vga.write("  Display:    VGA text 80x25\n");
        vga.write("  VGA Buffer: 0xB8000\n");
        vga.write("  VGA Size:   80 x 25 = 4000 cells\n");
    }

    vga.write("  CPU:        x86_64 baseline");
    if (acpi.cpu_count > 0) {
        vga.write(", ");
        vga.writeDec(acpi.cpu_count);
        vga.write(" found / ");
        vga.writeDec(smp.cpuOnline());
        vga.write(" online");
    }
    vga.write("\n");

    vga.write("  Memory:     ");
    vga.writeDec(pmm.total_pages * 4);
    vga.write(" KB (");
    vga.writeDec(pmm.total_pages);
    vga.write(" pages)");

    vga.setColor(.yellow, .black);
    vga.write("\n  Uptime:     ");
    vga.writeDec(timer.ticks / 100);
    vga.write(" seconds\n");

    vga.setColor(.light_green, .black);
    vga.write("\n  Renderer:   ");
    if (fb.active) {
        vga.write("framebuffer (shadow + dirty-rect flush)\n");
    } else {
        vga.write("VGA text (0xB8000)\n");
    }
    vga.write("  Text cells: ");
    vga.writeDec(fb.cols);
    vga.write(" x ");
    vga.writeDec(fb.rows);
    vga.write(" (");
    vga.writeDec(fb.char_w);
    vga.write("x");
    vga.writeDec(fb.char_h);
    vga.write(" font)\n");

    vga.setColor(.white, .black);
    vga.write("\n  Commands:\n");
    vga.write("    help    - show this help\n");
    vga.write("    info    - system info\n");
    vga.write("    calc    - calculator\n");
    vga.write("    color   - color demo\n");
    vga.write("    clock   - show clock\n");
    vga.write("    clear   - clear screen\n");
    vga.write("    halt    - halt system\n");
}