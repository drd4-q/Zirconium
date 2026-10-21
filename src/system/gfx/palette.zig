/// The 16-colour VGA text palette, shared by every text surface.
///
/// The console stores a palette *index* per cell (not RGB), so a cell is two
/// bytes: character plus two 4-bit colour indices.  The framebuffer surface
/// expands an index through `rgb()` when it paints a glyph.
pub const Color = enum(u8) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    pink = 13,
    yellow = 14,
    white = 15,
};

/// Standard VGA RGB values for the 16 text colours.
pub const rgb_table = [16]u32{
    0x000000, 0x0000AA, 0x00AA00, 0x00AAAA,
    0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
    0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
    0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
};

/// RGB value of a palette index.  Out-of-range indices clamp to black so a
/// corrupt cell can never index outside the table.
pub inline fn rgb(index: u8) u32 {
    return rgb_table[index & 0x0F];
}

/// Split a 24-bit RGB value into its components.
pub inline fn split(value: u32) struct { r: u8, g: u8, b: u8 } {
    return .{
        .r = @intCast((value >> 16) & 0xFF),
        .g = @intCast((value >> 8) & 0xFF),
        .b = @intCast(value & 0xFF),
    };
}
