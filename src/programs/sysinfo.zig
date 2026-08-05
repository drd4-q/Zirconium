const root = @import("root");
const vga = root.vga;
const timer = @import("../drivers/timer.zig");
const pci = @import("../drivers/pci.zig");

pub fn run() void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== Extended System Info ===\n\n");

    vga.setColor(.white, .black);
    vga.write("  Kernel:     ZigKernel v0.2.0\n");
    vga.write("  Arch:       x86_64 (long mode)\n");
    vga.write("  CPU:        x86_64 baseline\n");
    vga.write("  Display:    VGA text 80x25\n");
    vga.write("  IRQs:       PIT timer 100Hz, PS/2 keyboard\n\n");

    vga.setColor(.yellow, .black);
    vga.write("  Timer ticks: ");
    vga.writeDec(timer.ticks);
    vga.write(" (");
    vga.writeDec(timer.ticks / 100);
    vga.write(" sec)\n");

    vga.setColor(.light_green, .black);
    vga.write("  RTC Time:   ");
    timer.updateTime();
    writePad(timer.hours);
    vga.putChar(':');
    writePad(timer.minutes);
    vga.putChar(':');
    writePad(timer.seconds);
    vga.write("\n\n");

    vga.setColor(.light_cyan, .black);
    vga.write("  Physical Memory:\n");
    vga.setColor(.white, .black);
    vga.write("    Total:     ");
    vga.writeDec(root.pmm.total_pages * 4);
    vga.write(" KB (");
    vga.writeDec(root.pmm.total_pages);
    vga.write(" pages)\n");
    vga.write("    Free:      ");
    vga.writeDec(root.pmm.free_pages * 4);
    vga.write(" KB (");
    vga.writeDec(root.pmm.free_pages);
    vga.write(" pages)\n");
    vga.write("    Used:      ");
    vga.writeDec((root.pmm.total_pages - root.pmm.free_pages) * 4);
    vga.write(" KB\n\n");

    vga.setColor(.light_cyan, .black);
    vga.write("  Scheduler:\n");
    vga.setColor(.white, .black);
    vga.write("    Tasks:     ");
    vga.writeDec(root.scheduler.taskCount());
    vga.write("\n");
    vga.write("    Current:   ");
    if (root.scheduler.current_task >= 0) {
        vga.writeDec(@intCast(root.scheduler.current_task));
    } else {
        vga.write("idle");
    }
    vga.write("\n");
    vga.write("    Ticks:     ");
    vga.writeDec(root.scheduler.tick_count);
    vga.write("\n\n");

    vga.setColor(.light_cyan, .black);
    vga.write("  PCI Devices: ");
    vga.writeDec(pci.device_count);
    vga.write("\n\n");
    vga.setColor(.white, .black);
    pci.printDevices();
}

fn writePad(val: u32) void {
    if (val < 10) vga.putChar('0');
    writeInt(val);
}

fn writeInt(val: u32) void {
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var digits: [10]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        digits[i] = @intCast(@as(u8, @intCast(n % 10)) + '0');
        n /= 10;
    }
    var j: usize = i;
    while (j > 0) {
        j -= 1;
        vga.putChar(digits[j]);
    }
}
