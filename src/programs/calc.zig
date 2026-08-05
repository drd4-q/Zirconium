const root = @import("root");
const vga = root.vga;
const kb = @import("../drivers/keyboard.zig");

pub fn run() void {
    vga.setColor(.yellow, .black);
    vga.write("\n=== Calculator ===\n");
    vga.setColor(.white, .black);
    vga.write("Enter: a op b (e.g. 5+3, 10-4, 6*7, 20/4)\n");
    vga.write("Type 'exit' to quit.\n\n");

    var buf: [64]u8 = undefined;

    while (true) {
        vga.setColor(.light_green, .black);
        vga.write("calc> ");
        vga.setColor(.white, .black);

        const len = kb.readLine(&buf, 64);
        if (len == 0) continue;

        if (eql(buf[0..len], "exit")) return;

        var a: i64 = 0;
        var op: u8 = 0;
        var b: i64 = 0;
        var pos: usize = 0;
        var neg_a = false;

        if (pos < len and buf[pos] == '-') {
            neg_a = true;
            pos += 1;
        }

        while (pos < len and buf[pos] >= '0' and buf[pos] <= '9') {
            a = a * 10 + @as(i64, buf[pos] - '0');
            pos += 1;
        }
        if (neg_a) a = -a;

        if (pos < len) {
            op = buf[pos];
            pos += 1;
        } else {
            vga.setColor(.light_red, .black);
            vga.write("Error: no operator\n");
            continue;
        }

        var neg_b = false;
        if (pos < len and buf[pos] == '-') {
            neg_b = true;
            pos += 1;
        }

        while (pos < len and buf[pos] >= '0' and buf[pos] <= '9') {
            b = b * 10 + @as(i64, buf[pos] - '0');
            pos += 1;
        }
        if (neg_b) b = -b;

        var result: i64 = 0;
        var err = false;

        switch (op) {
            '+' => result = a + b,
            '-' => result = a - b,
            '*' => result = a * b,
            '/' => {
                if (b == 0) {
                    vga.setColor(.light_red, .black);
                    vga.write("Error: division by zero\n");
                    err = true;
                } else {
                    result = @divTrunc(a, b);
                }
            },
            '%' => {
                if (b == 0) {
                    vga.setColor(.light_red, .black);
                    vga.write("Error: division by zero\n");
                    err = true;
                } else {
                    result = @rem(a, b);
                }
            },
            else => {
                vga.setColor(.light_red, .black);
                vga.write("Error: unknown operator '");
                vga.putChar(op);
                vga.write("'\n");
                err = true;
            },
        }

        if (!err) {
            vga.setColor(.light_cyan, .black);
            vga.write("  = ");
            writeInt(result);
            vga.write("\n");
        }
    }
}

fn writeInt(val: i64) void {
    if (val < 0) {
        vga.putChar('-');
        writeInt(-val);
        return;
    }
    if (val == 0) {
        vga.putChar('0');
        return;
    }
    var digits: [20]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) : (i += 1) {
        digits[i] = @intCast(@as(u8, @intCast(@rem(n, 10))) + '0');
        n = @divTrunc(n, 10);
    }
    var j: usize = i;
    while (j > 0) {
        j -= 1;
        vga.putChar(digits[j]);
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
