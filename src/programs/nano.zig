// A small nano-style text editor for the kernel shell.
// Renders into the VGA text screen, or into the framebuffer when one is active.
//
// Controls (nano-compatible subset):
//   Arrows / Home / End / PgUp / PgDn   move the cursor
//   Backspace / Del                     delete text
//   Enter                               split line
//   Tab                                 insert 4 spaces
//   ^O   save (writes file)
//   ^X   exit (asks to save if modified)
//   ^W   search (repeat ^W for next hit)
//   ^K   cut current line
//   ^U   paste cut line
//   ^L   redraw   ^G   show key help
const std = @import("std");
const root = @import("root");
const vga = root.vga;
const fb = @import("../system/framebuffer.zig");
const kb = @import("../drivers/keyboard.zig");
const vfs = @import("../fs/vfs.zig");

const MAX_LINES: usize = 1000;
const MAX_COL: usize = 256;

const STYLE_TEXT: usize = 0;
const STYLE_CURSOR: usize = 1;
const STYLE_STATUS: usize = 2;
const STYLE_HELP: usize = 3;

const CTRL_O: u8 = 0x0F;
const CTRL_X: u8 = 0x18;
const CTRL_W: u8 = 0x17;
const CTRL_K: u8 = 0x0B;
const CTRL_U: u8 = 0x15;
const CTRL_G: u8 = 0x07;
const CTRL_L: u8 = 0x0C;

var scr_cols: usize = 80;
var scr_rows: usize = 25;
var content_rows: usize = 23;

var lines: [MAX_LINES][MAX_COL]u8 = undefined;
var line_len: [MAX_LINES]usize = undefined;
var line_count: usize = 0;

var file_name: [128]u8 = undefined;
var file_name_len: usize = 0;

var modified: bool = false;
var row: usize = 0;
var col: usize = 0;
var top_line: usize = 0;
var left_col: usize = 0;

var status_msg: [160]u8 = undefined;
var status_msg_len: usize = 0;

var search_term: [64]u8 = undefined;
var search_term_len: usize = 0;

var cut_buf: [MAX_COL]u8 = undefined;
var cut_len: usize = 0;

var read_buf: [MAX_LINES * MAX_COL]u8 = undefined;

// ---- display helpers -------------------------------------------------------

fn drawCell(x: usize, y: usize, ch: u8, style: usize) void {
    if (x >= scr_cols or y >= scr_rows) return;
    if (fb.active) {
        const px: u32 = @intCast(x * fb.char_w);
        const py: u32 = @intCast(y * fb.char_h);
        switch (style) {
            STYLE_CURSOR => fb.drawGlyph(px, py, ch, 0, 0, 0, 255, 255, 255),
            STYLE_STATUS => fb.drawGlyph(px, py, ch, 255, 255, 255, 10, 10, 120),
            STYLE_HELP => fb.drawGlyph(px, py, ch, 0, 0, 0, 230, 230, 230),
            else => fb.drawGlyph(px, py, ch, 255, 255, 255, 0, 0, 0),
        }
        return;
    }

    const attr: u8 = switch (style) {
        STYLE_CURSOR => 0x70, // reverse video
        STYLE_STATUS => 0x1F, // white on blue
        STYLE_HELP => 0x70, // black on white
        else => 0x07,
    };
    const buf: [*]volatile u16 = @ptrFromInt(0xB8000);
    buf[y * 80 + x] = @as(u16, ch) | (@as(u16, attr) << 8);
}

fn fillRow(y: usize, style: usize, ch: u8) void {
    var x: usize = 0;
    while (x < scr_cols) : (x += 1) {
        drawCell(x, y, ch, style);
    }
}

pub fn run(args: []const u8) void {
    if (args.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: nano <file>\n");
        vga.setColor(.white, .black);
        return;
    }

    kb.flush();

    if (fb.active) {
        scr_cols = @min(fb.cols, 160);
        scr_rows = fb.rows;
    } else {
        scr_cols = 80;
        scr_rows = 25;
    }
    if (scr_rows < 3) scr_rows = 25;
    content_rows = scr_rows - 2;

    line_count = 0;
    modified = false;
    row = 0;
    col = 0;
    top_line = 0;
    left_col = 0;
    status_msg_len = 0;
    search_term_len = 0;
    cut_len = 0;

    file_name_len = @min(args.len, file_name.len - 1);
    @memcpy(file_name[0..file_name_len], args[0..file_name_len]);

    loadFile();

    ensureVisible();

    while (true) {
        render();
        if (kb.pollKey()) |ch| {
            if (!handleKey(ch)) break;
            ensureVisible();
        } else {
            asm volatile ("hlt");
        }
    }
}

// ---- file load / save ------------------------------------------------------

fn loadFile() void {
    const handle = vfs.open(file_name[0..file_name_len], .{ .read = true }) orelse {
        line_count = 1;
        line_len[0] = 0;
        setMsg("New Buffer");
        return;
    };
    defer vfs.close(handle);

    var total: usize = 0;
    while (total < read_buf.len) {
        const n = vfs.read(handle, read_buf[total..]);
        if (n == 0) break;
        total += n;
    }

    var lc: usize = 0;
    var cur: usize = 0;
    var truncated = false;
    var last_nl = false;
    while (cur < total) {
        var end = cur;
        while (end < total and read_buf[end] != '\n' and read_buf[end] != '\r') : (end += 1) {}
        var ln = end - cur;
        if (ln > MAX_COL - 1) {
            ln = MAX_COL - 1;
            truncated = true;
        }
        if (lc < MAX_LINES) {
            @memcpy(lines[lc][0..ln], read_buf[cur..][0..ln]);
            line_len[lc] = ln;
            lc += 1;
            if (lc == MAX_LINES) truncated = true;
        } else {
            truncated = true;
        }
        if (end >= total) {
            last_nl = false;
            break;
        }
        if (truncated and lc >= MAX_LINES) break;
        cur = end + 1;
        if (read_buf[end] == '\r' and end + 1 < total and read_buf[end + 1] == '\n') cur += 1;
        last_nl = true;
    }
    if (last_nl and lc < MAX_LINES) {
        line_len[lc] = 0;
        lc += 1;
    }
    if (lc == 0) {
        line_len[0] = 0;
        lc = 1;
    }
    line_count = lc;

    if (truncated) {
        setLinesMsg("Read ", line_count, " lines (truncated)");
    } else {
        setLinesMsg("Read ", line_count, " lines");
    }
}

fn setLinesMsg(prefix: []const u8, num: usize, suffix: []const u8) void {
    var msg: [48]u8 = undefined;
    var m: usize = 0;
    @memcpy(msg[m..][0..prefix.len], prefix[0..prefix.len]);
    m += prefix.len;
    var n = num;
    if (n == 0) {
        msg[m] = '0';
        m += 1;
    } else {
        var nb: [12]u8 = undefined;
        var ni: usize = 12;
        while (n > 0) {
            ni -= 1;
            nb[ni] = @intCast('0' + (n % 10));
            n /= 10;
        }
        while (ni < 12) : (ni += 1) {
            msg[m] = nb[ni];
            m += 1;
        }
    }
    @memcpy(msg[m..][0..suffix.len], suffix[0..suffix.len]);
    m += suffix.len;
    setMsg(msg[0..m]);
}

fn saveBuffer() bool {
    if (file_name_len == 0) return false;
    const handle = vfs.open(file_name[0..file_name_len], .{ .read = true, .write = true, .create = true, .truncate = true }) orelse {
        setMsg("Save failed: cannot open file");
        return false;
    };
    defer vfs.close(handle);

    _ = vfs.truncate(handle, 0);

    var bytes: usize = 0;
    var i: usize = 0;
    while (i < line_count) : (i += 1) {
        bytes += vfs.write(handle, lines[i][0..line_len[i]]);
        bytes += vfs.write(handle, "\n");
    }

    modified = false;
    setLinesMsg("Wrote ", bytes, " bytes");
    return true;
}

// ---- cursor movement -------------------------------------------------------

fn moveUp() void {
    if (row > 0) {
        row -= 1;
        if (col > line_len[row]) col = line_len[row];
    }
}

fn moveDown() void {
    if (row + 1 < line_count) {
        row += 1;
        if (col > line_len[row]) col = line_len[row];
    }
}

fn moveLeft() void {
    if (col > 0) {
        col -= 1;
    } else if (row > 0) {
        row -= 1;
        col = line_len[row];
    }
}

fn moveRight() void {
    if (col < line_len[row]) {
        col += 1;
    } else if (row + 1 < line_count) {
        row += 1;
        col = 0;
    }
}

fn ensureVisible() void {
    if (row < top_line) top_line = row;
    if (row >= top_line + content_rows) top_line = row - content_rows + 1;
    if (col < left_col) left_col = col;
    if (col >= left_col + scr_cols) left_col = col - scr_cols + 1;
}

// ---- edits -----------------------------------------------------------------

fn insertChar(c: u8) void {
    const ln = line_len[row];
    if (ln >= MAX_COL - 1) {
        setMsg("Line full");
        return;
    }
    var i: usize = ln;
    while (i > col) : (i -= 1) {
        lines[row][i] = lines[row][i - 1];
    }
    lines[row][col] = c;
    line_len[row] += 1;
    col += 1;
    modified = true;
}

fn doBackspace() void {
    if (col > 0) {
        var i: usize = col - 1;
        while (i < line_len[row] - 1) : (i += 1) {
            lines[row][i] = lines[row][i + 1];
        }
        line_len[row] -= 1;
        col -= 1;
    } else if (row > 0) {
        const left = line_len[row - 1];
        var i: usize = 0;
        while (i < line_len[row]) : (i += 1) {
            lines[row - 1][left + i] = lines[row][i];
        }
        line_len[row - 1] = left + line_len[row];
        deleteLineAt(row);
        row -= 1;
        col = left;
    }
    modified = true;
}

fn doDelete() void {
    if (col < line_len[row]) {
        var i: usize = col;
        while (i + 1 < line_len[row]) : (i += 1) {
            lines[row][i] = lines[row][i + 1];
        }
        line_len[row] -= 1;
    } else if (row + 1 < line_count) {
        const cl = line_len[row];
        var i: usize = 0;
        while (i < line_len[row + 1]) : (i += 1) {
            lines[row][cl + i] = lines[row + 1][i];
        }
        line_len[row] = cl + line_len[row + 1];
        deleteLineAt(row + 1);
    }
    modified = true;
}

fn doEnter() void {
    if (line_count >= MAX_LINES) {
        setMsg("Buffer full");
        return;
    }
    const tail = line_len[row] - col;
    _ = insertLineAt(row + 1);
    var i: usize = 0;
    while (i < tail) : (i += 1) {
        lines[row + 1][i] = lines[row][col + i];
    }
    line_len[row + 1] = tail;
    line_len[row] = col;
    row += 1;
    col = 0;
    modified = true;
}

fn deleteLineAt(idx: usize) void {
    var i: usize = idx;
    while (i + 1 < line_count) : (i += 1) {
        var j: usize = 0;
        while (j < line_len[i + 1]) : (j += 1) {
            lines[i][j] = lines[i + 1][j];
        }
        line_len[i] = line_len[i + 1];
    }
    line_count -= 1;
    if (line_count == 0) {
        line_len[0] = 0;
        line_count = 1;
    }
}

fn insertLineAt(idx: usize) bool {
    if (line_count >= MAX_LINES) {
        setMsg("Buffer full");
        return false;
    }
    var i: usize = line_count;
    while (i > idx and i > 0) : (i -= 1) {
        var j: usize = 0;
        while (j < line_len[i - 1]) : (j += 1) {
            lines[i][j] = lines[i - 1][j];
        }
        line_len[i] = line_len[i - 1];
    }
    line_len[idx] = 0;
    line_count += 1;
    return true;
}

fn doCut() void {
    cut_len = line_len[row];
    @memcpy(cut_buf[0..cut_len], lines[row][0..cut_len]);
    if (line_count > 1) {
        deleteLineAt(row);
        if (row >= line_count) row = line_count - 1;
    } else {
        line_len[0] = 0;
    }
    col = 0;
    modified = true;
}

fn doPaste() void {
    if (cut_len == 0) return;
    if (!insertLineAt(row)) return;
    @memcpy(lines[row][0..cut_len], cut_buf[0..cut_len]);
    line_len[row] = cut_len;
    col = cut_len;
    modified = true;
}

// ---- search ----------------------------------------------------------------

fn doSearch() void {
    if (search_term_len == 0) {
        if (!promptLine("Search:", search_term[0..search_term.len], &search_term_len)) return;
        if (search_term_len == 0) return;
    }
    findNext();
}

fn findNext() void {
    if (search_term_len == 0) return;
    const start_line = if (row < line_count) row else 0;
    var start_col = col;
    if (start_col + 1 <= line_len[start_line]) start_col += 1;

    var di: usize = 0;
    const total = line_count;
    while (di < total) : (di += 1) {
        const li = (start_line + di) % total;
        const from = if (li == start_line) start_col else 0;
        if (findInLine(li, from)) {
            setMsg("Search: string found");
            return;
        }
    }
    setMsg("Search: not found");
}

fn findInLine(li: usize, from: usize) bool {
    const ln = line_len[li];
    if (ln < search_term_len or from > ln) return false;
    var p = from;
    while (p + search_term_len <= ln) : (p += 1) {
        var ok = true;
        var k: usize = 0;
        while (k < search_term_len) : (k += 1) {
            if (lower(lines[li][p + k]) != lower(search_term[k])) {
                ok = false;
                break;
            }
        }
        if (ok) {
            row = li;
            col = p;
            return true;
        }
    }
    return false;
}

fn lower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

// ---- save / exit -----------------------------------------------------------

fn doSave() void {
    if (file_name_len == 0) {
        var nb: [128]u8 = undefined;
        var nbl: usize = 0;
        if (!promptLine("File Name to Write:", &nb, &nbl)) return;
        if (nbl == 0) {
            setMsg("Save cancelled — no file name");
            return;
        }
        file_name_len = @min(nbl, file_name.len - 1);
        @memcpy(file_name[0..file_name_len], nb[0..file_name_len]);
    }
    _ = saveBuffer();
}

fn doExit() bool {
    if (!modified) return false;
    const answer = confirmYN();
    switch (answer) {
        .yes => {
            if (file_name_len == 0) {
                var nb: [128]u8 = undefined;
                var nbl: usize = 0;
                if (!promptLine("File Name to Write:", &nb, &nbl)) return true;
                if (nbl == 0) {
                    setMsg("Save cancelled — press ^X again to discard");
                    return true;
                }
                file_name_len = @min(nbl, file_name.len - 1);
                @memcpy(file_name[0..file_name_len], nb[0..file_name_len]);
            }
            if (!saveBuffer()) return true;
            return false;
        },
        .no => return false,
        .cancel => return true,
    }
}

// ---- key handling ----------------------------------------------------------

fn handleKey(ch: u8) bool {
    switch (ch) {
        kb.KEY_UP => moveUp(),
        kb.KEY_DOWN => moveDown(),
        kb.KEY_LEFT => moveLeft(),
        kb.KEY_RIGHT => moveRight(),
        kb.KEY_HOME => col = 0,
        kb.KEY_END => col = line_len[row],
        kb.KEY_PAGE_UP => {
            if (row > content_rows) row -= content_rows else row = 0;
        },
        kb.KEY_PAGE_DOWN => {
            if (row + content_rows < line_count) row += content_rows else row = if (line_count > 0) line_count - 1 else 0;
        },
        0x08 => doBackspace(),
        kb.KEY_DELETE => doDelete(),
        '\n', '\r' => doEnter(),
        kb.KEY_TAB, '\t' => {
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                if (line_len[row] >= MAX_COL - 1) break;
                insertChar(' ');
            }
        },
        CTRL_O => doSave(),
        CTRL_X => return doExit(),
        CTRL_W => doSearch(),
        CTRL_K => doCut(),
        CTRL_U => doPaste(),
        CTRL_G => setMsg("^O Save  ^X Exit  ^W Search  ^K Cut  ^U Uncut  ^L Refresh"),
        CTRL_L => {},
        else => {
            if (ch >= 0x20 and ch < 0x7F) insertChar(ch);
        },
    }
    return true;
}

// ---- rendering -------------------------------------------------------------

fn render() void {
    var y: usize = 0;
    while (y < content_rows) : (y += 1) {
        const file_idx = top_line + y;
        if (file_idx < line_count) {
            drawLine(y, file_idx);
        } else {
            fillRow(y, STYLE_TEXT, ' ');
        }
    }
    drawHelpRow();
    drawStatusRow();
    if (fb.active) {
        fb.flush();
    }
}

fn drawLine(y: usize, file_idx: usize) void {
    var x: usize = 0;
    const is_cursor_line = file_idx == row;
    while (x < scr_cols) : (x += 1) {
        const ci = left_col + x;
        var ch: u8 = ' ';
        if (ci < line_len[file_idx]) {
            ch = lines[file_idx][ci];
            if (ch == '\t') ch = ' ';
        }
        const style = if (is_cursor_line and ci == col) STYLE_CURSOR else STYLE_TEXT;
        drawCell(x, y, ch, style);
    }
}

fn drawHelpRow() void {
    const help = "^G Help  ^O Save  ^W Search  ^K Cut  ^U Uncut  ^L Refresh  ^X Exit";
    fillRow(content_rows, STYLE_HELP, ' ');
    var i: usize = 0;
    while (i < help.len and i < scr_cols) : (i += 1) {
        drawCell(i, content_rows, help[i], STYLE_HELP);
    }
}

fn drawStatusRow() void {
    fillRow(scr_rows - 1, STYLE_STATUS, ' ');
    var x: usize = 1;
    if (x + file_name_len + 2 < scr_cols) {
        drawCell(x - 1, scr_rows - 1, '[', STYLE_STATUS);
        var i: usize = 0;
        while (i < file_name_len) : (i += 1) {
            drawCell(x + i, scr_rows - 1, file_name[i], STYLE_STATUS);
        }
        drawCell(x + file_name_len, scr_rows - 1, ']', STYLE_STATUS);
        x += file_name_len + 2;
    }
    if (modified and x + 10 < scr_cols) {
        const tag = " Modified";
        var i: usize = 0;
        while (i < 9) : (i += 1) {
            drawCell(x + i, scr_rows - 1, tag[i], STYLE_STATUS);
        }
        x += 10;
    }
    if (status_msg_len > 0 and x + status_msg_len < scr_cols) {
        var i: usize = 0;
        while (i < status_msg_len) : (i += 1) {
            drawCell(x + i, scr_rows - 1, status_msg[i], STYLE_STATUS);
        }
    }
}

fn setMsg(msg: []const u8) void {
    status_msg_len = @min(msg.len, status_msg.len);
    @memcpy(status_msg[0..status_msg_len], msg[0..status_msg_len]);
}

// ---- prompts ---------------------------------------------------------------

const confirm = enum { yes, no, cancel };

fn drawPromptRow(prompt: []const u8, text: []const u8, cursor_pos: usize) void {
    fillRow(scr_rows - 1, STYLE_STATUS, ' ');
    var x: usize = 0;
    var i: usize = 0;
    while (i < prompt.len and x + i < scr_cols) : (i += 1) {
        drawCell(x + i, scr_rows - 1, prompt[i], STYLE_STATUS);
    }
    x += i;
    i = 0;
    while (i < text.len and x + i < scr_cols) : (i += 1) {
        drawCell(x + i, scr_rows - 1, text[i], STYLE_STATUS);
    }
    const cx = @min(x + cursor_pos, scr_cols - 1);
    drawCell(cx, scr_rows - 1, ' ', STYLE_CURSOR);
}

fn promptLine(prompt: []const u8, out: []u8, out_len: *usize) bool {
    out_len.* = 0;
    drawPromptRow(prompt, "", 0);
    while (true) {
        if (kb.pollKey()) |ch| {
            if (ch == 0x1B or ch == 0x03) {
                out_len.* = 0;
                return false;
            }
            if (ch == '\r' or ch == '\n') {
                return true;
            }
            if (ch == 0x08) {
                if (out_len.* > 0) out_len.* -= 1;
            } else if (ch >= 0x20 and ch < 0x7F and out_len.* < out.len - 1) {
                out[out_len.*] = ch;
                out_len.* += 1;
            }
            drawPromptRow(prompt, out[0..out_len.*], out_len.*);
        } else {
            asm volatile ("hlt");
        }
    }
}

fn confirmYN() confirm {
    drawPromptRow("Save modified buffer? (Y/N)", "", 0);
    while (true) {
        if (kb.pollKey()) |ch| {
            if (ch == 'y' or ch == 'Y') return .yes;
            if (ch == 'n' or ch == 'N') return .no;
            if (ch == 0x1B or ch == 0x03) return .cancel;
        } else {
            asm volatile ("hlt");
        }
    }
}