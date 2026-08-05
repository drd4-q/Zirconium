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

    // Init columns with random-ish heights
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

            if (col > 0 and col < HEIGHT) {
                screen[col - 1][i] = ' ';
                colors[col - 1][i] = 0x0A;
            }

            if (col < HEIGHT) {
                screen[col][i] = getRandomChar(frame, i);
                colors[col][i] = 0x0F;
                if (col > 1) {
                    screen[col - 1][i] = getRandomChar(frame + 1, i);
                    colors[col - 1][i] = 0x0A;
                }
                if (col > 2) {
                    screen[col - 2][i] = getRandomChar(frame + 2, i);
                    colors[col - 2][i] = 0x02;
                }
            }

            if (col >= HEIGHT + 5) {
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

fn getRandomChar(seed: u32, x: usize) u8 {
    const hash = seed * 2654435761 +% @as(u32, @intCast(x)) * 2246822519;
    const idx = @as(u8, @intCast(hash % 94));
    return idx + 0x21;
}
