const root = @import("root");
const vga = root.vga;
const kb = @import("../drivers/keyboard.zig");
const timer = @import("../drivers/timer.zig");

pub fn run() void {
    vga.setColor(.white, .black);
    vga.write("\n=== Real-Time Clock ===\n");
    vga.write("Press any key to return.\n\n");

    var last_sec: u32 = 0;

    while (true) {
        timer.updateTime();

        if (timer.seconds != last_sec) {
            last_sec = timer.seconds;

            // Draw clock
            vga.setColor(.green, .black);
            vga.write("\r  ");
            writePad(timer.hours);
            vga.putChar(':');
            writePad(timer.minutes);
            vga.putChar(':');
            writePad(timer.seconds);

            // Draw progress bar for current second
            vga.setColor(.light_gray, .black);
            vga.write("  [");
            const filled = (timer.seconds * 20) / 60;
            var i: usize = 0;
            while (i < 20) : (i += 1) {
                if (i < filled) {
                    vga.setColor(.green, .black);
                    vga.putChar('#');
                } else {
                    vga.setColor(.dark_gray, .black);
                    vga.putChar('-');
                }
            }
            vga.setColor(.light_gray, .black);
            vga.putChar(']');
        }

        if (kb.pollKey() != null) {
            vga.write("\n");
            return;
        }
    }
}

fn writePad(val: u32) void {
    if (val < 10) {
        vga.putChar('0');
    }
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
