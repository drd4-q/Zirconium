const root = @import("root");
const vga = root.vga;

pub fn run() void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== Fibonacci Sequence ===\n\n");

    vga.setColor(.white, .black);
    var a: u64 = 0;
    var b: u64 = 1;
    var i: u32 = 0;

    while (i < 40) : (i += 1) {
        vga.write("  F(");
        writeInt(i);
        vga.write(") = ");
        writeInt64(a);
        vga.write("\n");

        const next = a + b;
        a = b;
        b = next;
    }

    vga.setColor(.yellow, .black);
    vga.write("\n  F(40) = ");
    vga.setColor(.white, .black);
    writeInt64(a);
    vga.write("\n\n");
}

fn writeInt(val: u32) void {
    if (val == 0) { vga.putChar('0'); return; }
    var digits: [10]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        digits[i] = @intCast(@as(u8, @intCast(n % 10)) + '0');
        n /= 10;
    }
    var j: usize = i;
    while (j > 0) { j -= 1; vga.putChar(digits[j]); }
}

fn writeInt64(val: u64) void {
    if (val == 0) { vga.putChar('0'); return; }
    var digits: [20]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        digits[i] = @intCast(@as(u8, @intCast(n % 10)) + '0');
        n /= 10;
    }
    var j: usize = i;
    while (j > 0) { j -= 1; vga.putChar(digits[j]); }
}
