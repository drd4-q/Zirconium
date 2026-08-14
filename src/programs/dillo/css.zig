const std = @import("std");

pub const Style = struct {
    fg_color: u32 = 0xE0E0E0,
    bg_color: u32 = 0x141824,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    centered: bool = false,

    pub fn parseInline(style_str: []const u8) Style {
        var s = Style{};
        var pos: usize = 0;
        while (pos < style_str.len) {
            while (pos < style_str.len and (style_str[pos] == ' ' or style_str[pos] == ';')) : (pos += 1) {}
            const prop_start = pos;
            while (pos < style_str.len and style_str[pos] != ':' and style_str[pos] != ';') : (pos += 1) {}
            const prop = std.mem.trim(u8, style_str[prop_start..pos], " \t");

            if (pos < style_str.len and style_str[pos] == ':') pos += 1;
            while (pos < style_str.len and (style_str[pos] == ' ' or style_str[pos] == '\t')) : (pos += 1) {}
            const val_start = pos;
            while (pos < style_str.len and style_str[pos] != ';') : (pos += 1) {}
            const val = std.mem.trim(u8, style_str[val_start..pos], " \t");

            if (std.ascii.eqlIgnoreCase(prop, "color")) {
                if (parseColor(val)) |c| s.fg_color = c;
            } else if (std.ascii.eqlIgnoreCase(prop, "background-color") or std.ascii.eqlIgnoreCase(prop, "background")) {
                if (parseColor(val)) |c| s.bg_color = c;
            } else if (std.ascii.eqlIgnoreCase(prop, "font-weight")) {
                if (std.ascii.eqlIgnoreCase(val, "bold") or std.ascii.eqlIgnoreCase(val, "700") or std.ascii.eqlIgnoreCase(val, "800")) {
                    s.bold = true;
                }
            } else if (std.ascii.eqlIgnoreCase(prop, "font-style")) {
                if (std.ascii.eqlIgnoreCase(val, "italic") or std.ascii.eqlIgnoreCase(val, "oblique")) {
                    s.italic = true;
                }
            } else if (std.ascii.eqlIgnoreCase(prop, "text-decoration")) {
                if (std.ascii.eqlIgnoreCase(val, "underline")) {
                    s.underline = true;
                }
            } else if (std.ascii.eqlIgnoreCase(prop, "text-align")) {
                if (std.ascii.eqlIgnoreCase(val, "center")) {
                    s.centered = true;
                }
            }

            if (pos < style_str.len and style_str[pos] == ';') pos += 1;
        }
        return s;
    }

    pub fn parseColor(val: []const u8) ?u32 {
        if (val.len == 0) return null;
        if (val[0] == '#') {
            const hex = val[1..];
            if (hex.len == 6) {
                var c: u32 = 0;
                for (hex) |ch| {
                    const digit: u32 = if (ch >= '0' and ch <= '9') (ch - '0') else if (ch >= 'a' and ch <= 'f') (ch - 'a' + 10) else if (ch >= 'A' and ch <= 'F') (ch - 'A' + 10) else return null;
                    c = (c << 4) | digit;
                }
                return c;
            } else if (hex.len == 3) {
                var c: u32 = 0;
                for (hex) |ch| {
                    const digit: u32 = if (ch >= '0' and ch <= '9') (ch - '0') else if (ch >= 'a' and ch <= 'f') (ch - 'a' + 10) else if (ch >= 'A' and ch <= 'F') (ch - 'A' + 10) else return null;
                    c = (c << 8) | (digit << 4) | digit;
                }
                return c;
            }
            return null;
        }

        if (std.ascii.eqlIgnoreCase(val, "red")) return 0xFF5555;
        if (std.ascii.eqlIgnoreCase(val, "green")) return 0x55FF55;
        if (std.ascii.eqlIgnoreCase(val, "blue")) return 0x38B6FF;
        if (std.ascii.eqlIgnoreCase(val, "yellow")) return 0xFFFF55;
        if (std.ascii.eqlIgnoreCase(val, "gold")) return 0xFFD700;
        if (std.ascii.eqlIgnoreCase(val, "cyan")) return 0x40E0D0;
        if (std.ascii.eqlIgnoreCase(val, "white")) return 0xFFFFFF;
        if (std.ascii.eqlIgnoreCase(val, "black")) return 0x000000;
        if (std.ascii.eqlIgnoreCase(val, "gray") or std.ascii.eqlIgnoreCase(val, "grey")) return 0x888888;
        if (std.ascii.eqlIgnoreCase(val, "orange")) return 0xFFA500;
        if (std.ascii.eqlIgnoreCase(val, "purple")) return 0xAA55FF;
        if (std.ascii.eqlIgnoreCase(val, "lime")) return 0x00FF00;
        if (std.ascii.eqlIgnoreCase(val, "navy")) return 0x000080;
        if (std.ascii.eqlIgnoreCase(val, "teal")) return 0x008080;
        if (std.ascii.eqlIgnoreCase(val, "silver")) return 0xC0C0C0;
        return null;
    }
};
