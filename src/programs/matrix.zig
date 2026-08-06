const root = @import("root");
const vga = root.vga;
const kb = @import("../drivers/keyboard.zig");
const timer = @import("../drivers/timer.zig");

const WIDTH: usize = 80;
const HEIGHT: usize = 25;

var columns: [WIDTH]u16 = undefined;
var screen: [HEIGHT][WIDTH]u8 = undefined;
var colors: [HEIGHT][WIDTH]u8 = undefined;

pub fn run() void {
    vga.clear();

    // Zero-init screen and colors
    var si: usize = 0;
    while (si < HEIGHT) : (si += 1) {
        var sj: usize = 0;
        while (sj < WIDTH) : (sj += 1) {
            screen[si][sj] = ' ';
            colors[si][sj] = 0;
        }
    }

    // Init columns with random-ish starting heights
    var i: usize = 0;
    while (i < WIDTH) : (i += 1) {
        columns[i] = @intCast((i * 7 + 13) % HEIGHT);
    }

    var frame: u32 = 0;
    while (frame < 200) : (frame += 1) {
        // Update
        i = 0;
        while (i < WIDTH) : (i += 1) {
            const col = columns[i];
            const col_usize: usize = col;

            if (col_usize > 0 and col_usize < HEIGHT) {
                screen[col_usize - 1][i] = ' ';
                colors[col_usize - 1][i] = 0x02;
            }

            if (col_usize < HEIGHT) {
                screen[col_usize][i] = getRandomChar(frame, @intCast(i));
                colors[col_usize][i] = 0x0F;
                if (col_usize > 1) {
                    screen[col_usize - 1][i] = getRandomChar(frame +% 1, @intCast(i));
                    colors[col_usize - 1][i] = 0x0A;
                }
                if (col_usize > 2) {
                    screen[col_usize - 2][i] = getRandomChar(frame +% 2, @intCast(i));
                    colors[col_usize - 2][i] = 0x02;
                }
            }

            if (col_usize >= HEIGHT + 5) {
                columns[i] = 0;
            } else {
                columns[i] = col + 1;
            }
        }

        // Render to VGA
        var y: usize = 0;
        while (y < HEIGHT) : (y += 1) {
            var x: usize = 0;
            while (x < WIDTH) : (x += 1) {
                const ch = screen[y][x];
                const clr = colors[y][x];
                const cell: u16 = @as(u16, ch) | (@as(u16, clr) << 8);
                vgaBuffer()[y * WIDTH + x] = cell;
            }
        }

        timer.sleep(50);

        if (kb.pollKey() != null) {
            vga.clear();
            return;
        }
    }

    vga.clear();
}

fn vgaBuffer() [*]volatile u16 {
    return @ptrFromInt(0xB8000);
}

fn getRandomChar(seed: u32, x: u32) u8 {
    const hash = seed *% 2654435761 +% x *% 2246822519;
    const idx: u8 = @intCast(hash % 94);
    return idx + 0x21;
}
