const root = @import("root");
const vga = root.vga;
const kb = @import("../drivers/keyboard.zig");

const colors = [_]vga.Color{
    .black, .blue, .green, .cyan, .red, .magenta, .brown, .light_gray,
    .dark_gray, .light_blue, .light_green, .light_cyan, .light_red,
    .pink, .yellow, .white,
};

const color_names = [_][]const u8{
    "black", "blue", "green", "cyan", "red", "magenta", "brown", "light_gray",
    "dark_gray", "light_blue", "light_green", "light_cyan", "light_red",
    "pink", "yellow", "white",
};

pub fn run() void {
    vga.setColor(.white, .black);
    vga.write("\n=== VGA Color Demo ===\n\n");

    var y: usize = 3;
    for (colors, 0..) |fg, i| {
        for (colors[0..@min(i + 1, colors.len)], 0..) |bg, j| {
            _ = j;
            vga.setColor(fg, bg);
            vga.write("##");
        }
        vga.setColor(.white, .black);
        vga.write("  ");
        vga.setColor(.white, .black);
        vga.putChar(' ');
        vga.write(color_names[i]);
        vga.write("\n");
        y += 1;
    }

    vga.setColor(.white, .black);
    vga.write("\n  Press any key to return.\n");

    while (true) {
        if (kb.pollKey() != null) return;
    }
}
