const std = @import("std");
const css = @import("css.zig");

pub const MAX_LINES: usize = 96;
pub const LINE_LEN: usize = 76;
pub const MAX_LINKS: usize = 32;

pub const Link = struct {
    text: [32]u8 = undefined,
    text_len: usize = 0,
    url: [128]u8 = undefined,
    url_len: usize = 0,
    line_idx: usize = 0,
};

pub const Document = struct {
    lines: [MAX_LINES][LINE_LEN]u8 = undefined,
    line_lens: [MAX_LINES]usize = [_]usize{0} ** MAX_LINES,
    line_colors: [MAX_LINES]u32 = [_]u32{0xE0E0E0} ** MAX_LINES,
    line_count: usize = 0,

    links: [MAX_LINKS]Link = undefined,
    link_count: usize = 0,

    pub fn reset(self: *Document) void {
        self.line_count = 0;
        self.link_count = 0;
        for (&self.line_lens) |*l| l.* = 0;
    }

    pub fn appendLine(self: *Document, text: []const u8, color: u32) void {
        if (self.line_count >= MAX_LINES) return;
        const idx = self.line_count;
        const tlen = @min(text.len, LINE_LEN);
        @memcpy(self.lines[idx][0..tlen], text[0..tlen]);
        self.line_lens[idx] = tlen;
        self.line_colors[idx] = color;
        self.line_count += 1;
    }

    pub fn registerLink(self: *Document, text: []const u8, url: []const u8, line_idx: usize) void {
        if (self.link_count >= MAX_LINKS) return;
        const l = &self.links[self.link_count];
        l.text_len = @min(text.len, 32);
        @memcpy(l.text[0..l.text_len], text[0..l.text_len]);
        l.url_len = @min(url.len, 128);
        @memcpy(l.url[0..l.url_len], url[0..l.url_len]);
        l.line_idx = line_idx;
        self.link_count += 1;
    }
};
