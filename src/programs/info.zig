const root = @import("root");
const vga = root.vga;
const timer = @import("../drivers/timer.zig");

pub fn run() void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== System Info ===\n\n");

    vga.setColor(.white, .black);
    vga.write("  Kernel:     ZigKernel v0.1.0\n");
    vga.write("  Arch:       x86_64\n");
    vga.write("  Display:    VGA text 80x25\n");
    vga.write("  CPU:        x86_64 baseline\n");
    vga.write("  Memory:     128 MB (QEMU)\n");

    vga.setColor(.yellow, .black);
    vga.write("\n  Uptime:     ");
    const t = timer.ticks / 100;
    vga.writeDec(t);
    vga.write(" seconds\n");

    vga.setColor(.light_green, .black);
    vga.write("\n  VGA Buffer: 0xB8000\n");
    vga.write("  VGA Size:   80 x 25 = 4000 cells\n");

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
