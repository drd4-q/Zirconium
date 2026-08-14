const std = @import("std");
const root = @import("root");
const vga = root.vga;
pub const dillo_mod = @import("dillo/mod.zig");

pub const DilloState = dillo_mod.DilloBrowser;
pub const getDillo = dillo_mod.getBrowser;

pub fn run(args: []const u8) void {
    vga.setColor(.light_cyan, .black);
    vga.write("\n=== Dillo Web Browser ===\n\n");
    vga.setColor(.white, .black);

    const dillo = getDillo();
    if (args.len > 0) {
        dillo.loadUrl(args);
    } else {
        dillo.loadUrl("about:dillo");
    }

    var i: usize = 0;
    while (i < dillo.doc.line_count) : (i += 1) {
        vga.write("  ");
        vga.write(dillo.doc.lines[i][0..dillo.doc.line_lens[i]]);
        vga.write("\n");
    }
    vga.write("\n");
}
