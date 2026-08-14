const std = @import("std");
const root = @import("root");
const vga = root.vga;
const fb = @import("framebuffer.zig");
const mouse = @import("../drivers/mouse.zig");
const kb = @import("../drivers/keyboard.zig");
const timer = @import("../drivers/timer.zig");
const pmm = root.pmm;
const vfs = @import("../fs/vfs.zig");
const net = @import("../net/mod.zig");
const scheduler = root.scheduler;

const TITLE_H: i32 = 18;
const BORDER: i32 = 1;
const TASKBAR_H: i32 = 26;
const MAX_WINDOWS: usize = 12;

const ContentType = enum(u8) {
    clock,
    system,
    about,
    terminal,
    calculator,
    notepad,
    launcher,
};

const Window = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 200,
    h: i32 = 140,
    title: [32]u8 = undefined,
    title_len: usize = 0,
    content: ContentType = .about,
    focused: bool = false,
    visible: bool = true,
};

var windows: [MAX_WINDOWS]Window = undefined;
var num_windows: usize = 0;
var drag_index: i32 = -1;
var drag_off_x: i32 = 0;
var drag_off_y: i32 = 0;
var prev_left: bool = false;
var prev_right: bool = false;
var drag_button: enum { none, left, right } = .none;
var cursor_drawn: bool = false;
var cursor_x: i32 = 0;
var cursor_y: i32 = 0;
var next_clock_tick: u64 = 0;

// Start menu state
var start_menu_open: bool = false;
const START_BTN_X: i32 = 4;
const START_BTN_W: i32 = 64;
const START_BTN_H: i32 = 20;
const MENU_ITEM_H: i32 = 22;
const MENU_W: i32 = 200;
const MENU_ITEMS_COUNT: usize = 8;
const menu_items = [_][]const u8{
    "[>] Terminal / Shell",
    "[*] Clock & Uptime",
    "[@] System Monitor",
    "[#] Calculator",
    "[=] Notepad",
    "[+] Program Launcher",
    "[i] About Zirconium",
    "[x] Exit to Shell",
};

// Terminal window state
const TERM_MAX_LINES: usize = 128;
const TERM_LINE_LEN: usize = 44;
const TERM_VISIBLE_LINES: usize = 11;
var term_lines: [TERM_MAX_LINES][TERM_LINE_LEN]u8 = undefined;
var term_line_lens: [TERM_MAX_LINES]usize = [_]usize{0} ** TERM_MAX_LINES;
var term_line_colors: [TERM_MAX_LINES]u32 = [_]u32{0xE0E0E0} ** TERM_MAX_LINES;
var term_line_count: usize = 0;
var term_scroll_offset: usize = 0;

var term_cmd_buf: [64]u8 = undefined;
var term_cmd_len: usize = 0;

// Terminal History
const TERM_HIST_MAX: usize = 16;
var term_history: [TERM_HIST_MAX][64]u8 = undefined;
var term_hist_lens: [TERM_HIST_MAX]usize = [_]usize{0} ** TERM_HIST_MAX;
var term_hist_count: usize = 0;
var term_hist_idx: i32 = -1;

// Calculator window state
var calc_display: [32]u8 = undefined;
var calc_len: usize = 0;
var calc_val1: i64 = 0;
var calc_op: u8 = 0;
var calc_new_num: bool = true;

// Notepad window state
const NOTE_MAX_LINES: usize = 12;
const NOTE_LINE_LEN: usize = 40;
var note_lines: [NOTE_MAX_LINES][NOTE_LINE_LEN]u8 = undefined;
var note_lens: [NOTE_MAX_LINES]usize = [_]usize{0} ** NOTE_MAX_LINES;
var note_cur_line: usize = 0;

// ----- Window management -----

fn createWindow(c: ContentType, x: i32, y: i32, w: i32, h: i32, title: []const u8) void {
    if (num_windows >= MAX_WINDOWS) return;
    const win = &windows[num_windows];
    win.* = .{};
    win.content = c;
    win.x = x;
    win.y = y;
    win.w = w;
    win.h = h;
    win.title_len = @min(title.len, 32);
    @memcpy(win.title[0..win.title_len], title[0..win.title_len]);
    win.focused = true;
    win.visible = true;
    allFocused(num_windows);
    num_windows += 1;
}

fn openOrCreateWindow(c: ContentType) void {
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (windows[i].content == c) {
            windows[i].visible = true;
            allFocused(i);
            return;
        }
    }

    const sw = @as(i32, @intCast(fb.fb_width));
    const sh = @as(i32, @intCast(fb.fb_height));

    switch (c) {
        .terminal => createWindow(.terminal, 30, 40, 380, 240, "Terminal"),
        .calculator => createWindow(.calculator, sw - 210, 50, 180, 190, "Calculator"),
        .notepad => createWindow(.notepad, @divTrunc(sw, 2) - 140, @divTrunc(sh, 3), 280, 200, "Notepad"),
        .launcher => createWindow(.launcher, 50, 90, 300, 200, "Program Launcher"),
        .system => createWindow(.system, sw - 220, 50, 200, 160, "System Monitor"),
        .clock => createWindow(.clock, 50, 50, 180, 120, "Clock"),
        .about => createWindow(.about, @divTrunc(sw, 2) - 120, @divTrunc(sh, 4), 240, 140, "Welcome"),
    }
}

fn topmostAt(gx: i32, gy: i32) i32 {
    var best: i32 = -1;
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (!windows[i].visible) continue;
        if (gx >= windows[i].x and gx < windows[i].x + windows[i].w and
            gy >= windows[i].y and gy < windows[i].y + windows[i].h)
        {
            best = @intCast(i);
        }
    }
    if (best >= 0 and !windows[@intCast(best)].focused) {
        var k: usize = 0;
        while (k < num_windows) : (k += 1) {
            if (windows[k].focused and
                gx >= windows[k].x and gx < windows[k].x + windows[k].w and
                gy >= windows[k].y and gy < windows[k].y + windows[k].h)
            {
                return @intCast(k);
            }
        }
    }
    return best;
}

fn allFocused(fi: usize) void {
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        windows[i].focused = (i == fi);
    }
}

// ----- Cursor (XOR with saved background) -----

const CURSOR_W: usize = 12;
const CURSOR_H: usize = 16;
const CURSOR_MASK = [CURSOR_H]u16{
    0b100000000000,
    0b110000000000,
    0b111000000000,
    0b111100000000,
    0b111110000000,
    0b111111000000,
    0b111111100000,
    0b111111110000,
    0b111111111000,
    0b111111111100,
    0b111111100000,
    0b110111100000,
    0b110011000000,
    0b100011000000,
    0b000011000000,
    0b000011000000,
};
var cursor_bg: [CURSOR_W * CURSOR_H]u32 = undefined;

fn inBounds(x: i32, y: i32) bool {
    return x >= 0 and y >= 0 and @as(u32, @intCast(x)) < fb.fb_width and @as(u32, @intCast(y)) < fb.fb_height;
}

fn saveCursorBg(x: i32, y: i32) void {
    var cy: usize = 0;
    while (cy < CURSOR_H) : (cy += 1) {
        var cx: usize = 0;
        while (cx < CURSOR_W) : (cx += 1) {
            const px = x + @as(i32, @intCast(cx));
            const py = y + @as(i32, @intCast(cy));
            cursor_bg[cy * CURSOR_W + cx] = if (inBounds(px, py)) getDisplayed(px, py) else 0;
        }
    }
}

fn restoreCursorBg() void {
    var cy: usize = 0;
    while (cy < CURSOR_H) : (cy += 1) {
        var cx: usize = 0;
        while (cx < CURSOR_W) : (cx += 1) {
            const px = cursor_x + @as(i32, @intCast(cx));
            const py = cursor_y + @as(i32, @intCast(cy));
            if (inBounds(px, py)) putDisplayed(px, py, cursor_bg[cy * CURSOR_W + cx]);
        }
    }
}

fn drawCursorShape() void {
    var cy: usize = 0;
    while (cy < CURSOR_H) : (cy += 1) {
        const row = CURSOR_MASK[cy];
        var cx: usize = 0;
        while (cx < CURSOR_W) : (cx += 1) {
            if ((row >> @intCast(CURSOR_W - 1 - cx)) & 1 != 0) {
                const px = cursor_x + @as(i32, @intCast(cx));
                const py = cursor_y + @as(i32, @intCast(cy));
                if (inBounds(px, py)) {
                    const c = getDisplayed(px, py) ^ 0x00FFFFFF;
                    putDisplayed(px, py, c);
                }
            }
        }
    }
}

fn getDisplayed(x: i32, y: i32) u32 {
    return fb.rawPixel(@intCast(x), @intCast(y));
}

fn putDisplayed(x: i32, y: i32, color: u32) void {
    fb.rawPutPixel(@intCast(x), @intCast(y), @intCast((color >> 16) & 0xFF), @intCast((color >> 8) & 0xFF), @intCast(color & 0xFF));
}

fn restoreCursor() void {
    if (!cursor_drawn) return;
    restoreCursorBg();
    cursor_drawn = false;
}

fn drawCursor() void {
    if (cursor_drawn) restoreCursorBg();
    cursor_x = mouse.mx;
    cursor_y = mouse.my;
    saveCursorBg(cursor_x, cursor_y);
    drawCursorShape();
    cursor_drawn = true;
}

// ----- Drawing Helpers -----

fn fmtDec(val: u64, buf: []u8) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = buf.len;
    var v = val;
    while (v > 0 and i > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    return buf[i..];
}

fn termAddLineWithColor(s: []const u8, col: u32) void {
    if (term_line_count < TERM_MAX_LINES) {
        const len = @min(s.len, TERM_LINE_LEN);
        @memcpy(term_lines[term_line_count][0..len], s[0..len]);
        term_line_lens[term_line_count] = len;
        term_line_colors[term_line_count] = col;
        term_line_count += 1;
    } else {
        var i: usize = 0;
        while (i < TERM_MAX_LINES - 1) : (i += 1) {
            term_lines[i] = term_lines[i + 1];
            term_line_lens[i] = term_line_lens[i + 1];
            term_line_colors[i] = term_line_colors[i + 1];
        }
        const len = @min(s.len, TERM_LINE_LEN);
        @memcpy(term_lines[TERM_MAX_LINES - 1][0..len], s[0..len]);
        term_line_lens[TERM_MAX_LINES - 1] = len;
        term_line_colors[TERM_MAX_LINES - 1] = col;
    }
    if (term_line_count > TERM_VISIBLE_LINES) {
        term_scroll_offset = term_line_count - TERM_VISIBLE_LINES;
    }
}

fn termAddLine(s: []const u8) void {
    termAddLineWithColor(s, 0xE0E0E0);
}

// ----- Shell Command Execution in GUI Terminal -----

fn executeTermCmd() void {
    if (term_cmd_len == 0) return;
    const raw_cmd = term_cmd_buf[0..term_cmd_len];

    // Save to history
    if (term_hist_count < TERM_HIST_MAX) {
        @memcpy(term_history[term_hist_count][0..term_cmd_len], raw_cmd);
        term_hist_lens[term_hist_count] = term_cmd_len;
        term_hist_count += 1;
    } else {
        var h: usize = 0;
        while (h < TERM_HIST_MAX - 1) : (h += 1) {
            term_history[h] = term_history[h + 1];
            term_hist_lens[h] = term_hist_lens[h + 1];
        }
        @memcpy(term_history[TERM_HIST_MAX - 1][0..term_cmd_len], raw_cmd);
        term_hist_lens[TERM_HIST_MAX - 1] = term_cmd_len;
    }
    term_hist_idx = -1;

    // Display prompt and command
    var prompt_buf: [70]u8 = undefined;
    @memcpy(prompt_buf[0..5], "zig> ");
    const plen = @min(raw_cmd.len, 60);
    @memcpy(prompt_buf[5..][0..plen], raw_cmd[0..plen]);
    termAddLineWithColor(prompt_buf[0 .. 5 + plen], 0x70E070);

    // Parse command and args
    var cmd_end: usize = raw_cmd.len;
    var args_start: usize = raw_cmd.len;
    for (raw_cmd, 0..) |ch, i| {
        if (ch == ' ') {
            cmd_end = i;
            args_start = i + 1;
            break;
        }
    }
    const cmd_name = raw_cmd[0..cmd_end];
    const args = if (args_start < raw_cmd.len) raw_cmd[args_start..] else "";

    if (std.mem.eql(u8, cmd_name, "help")) {
        termAddLineWithColor("=== Zirconium Shell Commands ===", 0x80D0FF);
        termAddLine("  help, clear, ls, cat, touch, mkdir, rm");
        termAddLine("  pwd, cd, mem, ps, sysinfo, info, smp");
        termAddLine("  net, ping, calc, fib, date, time, uname");
        termAddLine("  exec <path>, user");
    } else if (std.mem.eql(u8, cmd_name, "clear") or std.mem.eql(u8, cmd_name, "cls")) {
        term_line_count = 0;
        term_scroll_offset = 0;
    } else if (std.mem.eql(u8, cmd_name, "pwd")) {
        termAddLine(vfs.getCwd());
    } else if (std.mem.eql(u8, cmd_name, "cd")) {
        if (args.len == 0) {
            vfs.setCwd("/");
        } else {
            vfs.setCwd(args);
        }
        termAddLine(vfs.getCwd());
    } else if (std.mem.eql(u8, cmd_name, "ls")) {
        const path = if (args.len > 0) args else vfs.getCwd();
        var entries: [16]vfs.DirEntry = undefined;
        const count = vfs.readdir(path, &entries);
        if (count == 0) {
            termAddLine("  (empty directory or not found)");
        } else {
            var idx: usize = 0;
            while (idx < count) : (idx += 1) {
                const name = entries[idx].name[0..entries[idx].name_len];
                var lbuf: [44]u8 = undefined;
                if (entries[idx].file_type == .directory) {
                    @memcpy(lbuf[0..2], "d ");
                    const nlen = @min(name.len, 38);
                    @memcpy(lbuf[2..][0..nlen], name[0..nlen]);
                    lbuf[2 + nlen] = '/';
                    termAddLineWithColor(lbuf[0 .. 3 + nlen], 0x80D0FF);
                } else {
                    @memcpy(lbuf[0..2], "- ");
                    const nlen = @min(name.len, 39);
                    @memcpy(lbuf[2..][0..nlen], name[0..nlen]);
                    termAddLine(lbuf[0 .. 2 + nlen]);
                }
            }
        }
    } else if (std.mem.eql(u8, cmd_name, "cat")) {
        if (args.len == 0) {
            termAddLineWithColor("Usage: cat <file>", 0xFF8080);
        } else if (vfs.open(args, .{ .read = true })) |handle| {
            defer vfs.close(handle);
            var fbuf: [128]u8 = undefined;
            const n = vfs.read(handle, &fbuf);
            if (n == 0) {
                termAddLine("  (empty file)");
            } else {
                termAddLine(fbuf[0..n]);
            }
        } else {
            termAddLineWithColor("Error: file not found", 0xFF8080);
        }
    } else if (std.mem.eql(u8, cmd_name, "touch")) {
        if (args.len == 0) {
            termAddLineWithColor("Usage: touch <file>", 0xFF8080);
        } else if (vfs.open(args, .{ .write = true, .create = true })) |handle| {
            vfs.close(handle);
            termAddLineWithColor("Created file successfully.", 0x80FF80);
        } else {
            termAddLineWithColor("Error: cannot create file", 0xFF8080);
        }
    } else if (std.mem.eql(u8, cmd_name, "mkdir")) {
        if (args.len == 0) {
            termAddLineWithColor("Usage: mkdir <dir>", 0xFF8080);
        } else if (vfs.mkdir(args)) {
            termAddLineWithColor("Directory created.", 0x80FF80);
        } else {
            termAddLineWithColor("Error: cannot create directory", 0xFF8080);
        }
    } else if (std.mem.eql(u8, cmd_name, "rm")) {
        if (args.len == 0) {
            termAddLineWithColor("Usage: rm <file>", 0xFF8080);
        } else if (vfs.unlink(args)) {
            termAddLineWithColor("File removed.", 0x80FF80);
        } else {
            termAddLineWithColor("Error: cannot delete file", 0xFF8080);
        }
    } else if (std.mem.eql(u8, cmd_name, "mem")) {
        var dbuf: [32]u8 = undefined;
        termAddLineWithColor("=== Memory Information ===", 0x80D0FF);
        termAddLine("Total Memory: 128 MB");
        const free_kb = fmtDec(@as(u64, @intCast(pmm.free_pages * 4)), dbuf[0..]);
        var mbuf: [40]u8 = undefined;
        @memcpy(mbuf[0..11], "Free PMM:  ");
        @memcpy(mbuf[11..][0..free_kb.len], free_kb);
        @memcpy(mbuf[11 + free_kb.len ..][0..3], " KB");
        termAddLine(mbuf[0 .. 14 + free_kb.len]);
    } else if (std.mem.eql(u8, cmd_name, "ps")) {
        termAddLineWithColor("PID  NAME       STATE    TYPE", 0x80D0FF);
        termAddLine(" 0   idle       running  kernel");
        termAddLine(" 1   shell/gui  running  kernel");
    } else if (std.mem.eql(u8, cmd_name, "uname") or std.mem.eql(u8, cmd_name, "uname -a")) {
        termAddLineWithColor("Linux zirconium 6.0.0-zirconium #1 x86_64", 0x80FF80);
    } else if (std.mem.eql(u8, cmd_name, "sysinfo") or std.mem.eql(u8, cmd_name, "info")) {
        termAddLineWithColor("=== System Information ===", 0x80D0FF);
        termAddLine("OS: Zirconium Kernel (x86_64)");
        termAddLine("SMP: 4 CPUs Active (ACPI MADT)");
        termAddLine("Network: e1000 Gigabit Ethernet");
    } else if (std.mem.eql(u8, cmd_name, "net") or std.mem.eql(u8, cmd_name, "ip")) {
        termAddLineWithColor("=== Network Status ===", 0x80D0FF);
        termAddLine("IP: 10.0.2.15  Mask: 255.255.255.0");
        termAddLine("Gateway: 10.0.2.2  DNS: 10.0.2.3");
        termAddLine("Device: Intel e1000 (PCI)");
    } else if (std.mem.eql(u8, cmd_name, "date") or std.mem.eql(u8, cmd_name, "time")) {
        var tbuf: [32]u8 = undefined;
        timer.formatTime(tbuf[0..9]);
        termAddLine(tbuf[0..8]);
    } else if (std.mem.eql(u8, cmd_name, "fib")) {
        termAddLine("Fibonacci(10) = 55");
        termAddLine("Fibonacci(20) = 6765");
    } else if (std.mem.eql(u8, cmd_name, "user")) {
        const user_test_bin = @import("user_test_bin");
        termAddLine("Spawning Ring 3 user ELF test task...");
        if (scheduler.spawnProgramImage(&user_test_bin.data, "user_test")) |task_id| {
            scheduler.runTask(task_id);
            termAddLineWithColor("User task finished OK (Ring 3).", 0x80FF80);
        } else |err| {
            termAddLineWithColor(@errorName(err), 0xFF8080);
        }
    } else if (std.mem.eql(u8, cmd_name, "exec")) {
        if (args.len == 0) {
            termAddLineWithColor("Usage: exec <path> [args...]", 0xFF8080);
        } else {
            termAddLine("Spawning program...");
            if (scheduler.spawnProgram(args, raw_cmd)) |task_id| {
                scheduler.runTask(task_id);
                termAddLineWithColor("Program executed successfully.", 0x80FF80);
            } else |err| {
                termAddLineWithColor(@errorName(err), 0xFF8080);
            }
        }
    } else {
        // Try to execute directly from /mnt/disk
        if (vfs.stat(cmd_name) != null) {
            if (scheduler.spawnProgram(cmd_name, raw_cmd)) |task_id| {
                scheduler.runTask(task_id);
                termAddLineWithColor("Executed OK.", 0x80FF80);
            } else |err| {
                termAddLineWithColor(@errorName(err), 0xFF8080);
            }
        } else {
            termAddLineWithColor("Unknown command. Type 'help'.", 0xFF8080);
        }
    }

    term_cmd_len = 0;
}

fn drawWindowBody(win: *Window) void {
    const body_y = win.y + TITLE_H + BORDER;
    const body_h = win.h - TITLE_H - BORDER;
    const body_color: u32 = 0x1A1C23;
    fb.fillRect(@intCast(win.x + BORDER), @intCast(body_y), @intCast(win.w - 2 * BORDER), @intCast(body_h), @intCast((body_color >> 16) & 0xFF), @intCast((body_color >> 8) & 0xFF), @intCast(body_color & 0xFF));

    const tx = win.x + 8;
    var line_y = body_y + 6;

    switch (win.content) {
        .clock => {
            var tbuf: [32]u8 = undefined;
            timer.formatTime(tbuf[0..9]);
            fb.drawString(@intCast(tx), @intCast(line_y), tbuf[0..8], 240, 240, 240, 26, 28, 35);
            line_y += 22;
            fb.drawString(@intCast(tx), @intCast(line_y), "Uptime: ", 170, 170, 170, 26, 28, 35);
            const up = fmtDec(timer.ticks / 100, tbuf[0..]);
            fb.drawString(@intCast(tx + 64), @intCast(line_y), up, 140, 220, 140, 26, 28, 35);
            fb.drawString(@intCast(tx + 64 + @as(i32, @intCast(up.len)) * 8), @intCast(line_y), " sec", 120, 120, 120, 26, 28, 35);
            line_y += 22;
            fb.drawString(@intCast(tx), @intCast(line_y), "Timer: 100 Hz PIT", 150, 180, 200, 26, 28, 35);
        },
        .system => {
            var tbuf: [32]u8 = undefined;
            fb.drawString(@intCast(tx), @intCast(line_y), "Pages Free: ", 180, 180, 180, 26, 28, 35);
            const free = fmtDec(pmm.free_pages, tbuf[0..]);
            fb.drawString(@intCast(tx + 96), @intCast(line_y), free, 120, 220, 120, 26, 28, 35);
            line_y += 20;
            fb.drawString(@intCast(tx), @intCast(line_y), "Total Pages:", 180, 180, 180, 26, 28, 35);
            const total = fmtDec(pmm.total_pages, tbuf[0..]);
            fb.drawString(@intCast(tx + 96), @intCast(line_y), total, 140, 180, 240, 26, 28, 35);
            line_y += 20;
            fb.drawString(@intCast(tx), @intCast(line_y), "Resolution: ", 180, 180, 180, 26, 28, 35);
            const rw = fmtDec(fb.fb_width, tbuf[0..]);
            fb.drawString(@intCast(tx + 96), @intCast(line_y), rw, 220, 220, 120, 26, 28, 35);
            line_y += 20;
            fb.drawString(@intCast(tx), @intCast(line_y), "Mouse: (", 180, 180, 180, 26, 28, 35);
            const mxv = fmtDec(@as(u64, @intCast(mouse.mx)), tbuf[0..]);
            const myv = fmtDec(@as(u64, @intCast(mouse.my)), tbuf[0..]);
            var xpos = tx + 64;
            fb.drawString(@intCast(xpos), @intCast(line_y), mxv, 220, 220, 120, 26, 28, 35);
            xpos += @as(i32, @intCast(mxv.len)) * 8;
            fb.drawString(@intCast(xpos), @intCast(line_y), ",", 180, 180, 180, 26, 28, 35);
            xpos += 8;
            fb.drawString(@intCast(xpos), @intCast(line_y), myv, 220, 220, 120, 26, 28, 35);
            xpos += @as(i32, @intCast(myv.len)) * 8;
            fb.drawString(@intCast(xpos), @intCast(line_y), ")", 180, 180, 180, 26, 28, 35);
        },
        .terminal => {
            fb.fillRect(@intCast(win.x + BORDER), @intCast(body_y), @intCast(win.w - 2 * BORDER), @intCast(body_h), 12, 14, 18);
            
            const max_vis = @min(TERM_VISIBLE_LINES, @as(usize, @intCast(@divTrunc(body_h - 24, 18))));
            var start_idx: usize = term_scroll_offset;
            if (term_line_count > max_vis and start_idx + max_vis > term_line_count) {
                start_idx = term_line_count - max_vis;
            }

            var lidx: usize = start_idx;
            const end_idx = @min(start_idx + max_vis, term_line_count);
            while (lidx < end_idx) : (lidx += 1) {
                const col = term_line_colors[lidx];
                fb.drawString(@intCast(tx), @intCast(line_y), term_lines[lidx][0..term_line_lens[lidx]], @intCast((col >> 16) & 0xFF), @intCast((col >> 8) & 0xFF), @intCast(col & 0xFF), 12, 14, 18);
                line_y += 18;
            }

            // Input prompt
            fb.drawString(@intCast(tx), @intCast(line_y), "zig> ", 110, 230, 110, 12, 14, 18);
            if (term_cmd_len > 0) {
                fb.drawString(@intCast(tx + 40), @intCast(line_y), term_cmd_buf[0..term_cmd_len], 255, 255, 255, 12, 14, 18);
            }
            if (win.focused) {
                fb.drawString(@intCast(tx + 40 + @as(i32, @intCast(term_cmd_len)) * 8), @intCast(line_y), "_", 240, 240, 240, 12, 14, 18);
            }
        },
        .calculator => {
            fb.fillRect(@intCast(win.x + 8), @intCast(body_y + 6), @intCast(win.w - 16), 24, 10, 12, 16);
            fb.drawRectBorder(@intCast(win.x + 8), @intCast(body_y + 6), @intCast(win.w - 16), 24, 1, 60, 80, 120);
            if (calc_len > 0) {
                fb.drawString(@intCast(win.x + 14), @intCast(body_y + 10), calc_display[0..calc_len], 240, 240, 140, 10, 12, 16);
            } else {
                fb.drawString(@intCast(win.x + 14), @intCast(body_y + 10), "0", 180, 180, 180, 10, 12, 16);
            }

            const btn_labels = [_][]const u8{
                "7", "8", "9", "/",
                "4", "5", "6", "*",
                "1", "2", "3", "-",
                "C", "0", "=", "+",
            };

            var row: usize = 0;
            while (row < 4) : (row += 1) {
                var col: usize = 0;
                while (col < 4) : (col += 1) {
                    const bx = win.x + 10 + @as(i32, @intCast(col * 38));
                    const by = body_y + 36 + @as(i32, @intCast(row * 28));
                    fb.fillRect(@intCast(bx), @intCast(by), 32, 22, 40, 48, 62);
                    fb.drawRectBorder(@intCast(bx), @intCast(by), 32, 22, 1, 70, 85, 110);
                    const idx = row * 4 + col;
                    fb.drawString(@intCast(bx + 12), @intCast(by + 3), btn_labels[idx], 240, 240, 240, 40, 48, 62);
                }
            }
        },
        .notepad => {
            fb.fillRect(@intCast(win.x + BORDER), @intCast(body_y), @intCast(win.w - 2 * BORDER), @intCast(body_h), 18, 22, 28);
            var i: usize = 0;
            while (i <= note_cur_line and i < NOTE_MAX_LINES) : (i += 1) {
                const ny = body_y + 6 + @as(i32, @intCast(i * 18));
                if (note_lens[i] > 0) {
                    fb.drawString(@intCast(tx), @intCast(ny), note_lines[i][0..note_lens[i]], 230, 230, 230, 18, 22, 28);
                }
                if (i == note_cur_line and win.focused) {
                    fb.drawString(@intCast(tx + @as(i32, @intCast(note_lens[i])) * 8), @intCast(ny), "|", 140, 200, 255, 18, 22, 28);
                }
            }
        },
        .launcher => {
            fb.drawString(@intCast(tx), @intCast(line_y), "FAT16 Programs (/mnt/disk):", 120, 200, 255, 26, 28, 35);
            line_y += 20;

            const progs = [_][]const u8{
                "1. /mnt/disk/hello.exe (Win32 PE)",
                "2. /mnt/disk/hello_linux (Linux ELF)",
                "3. /mnt/disk/busybox (Multi-call)",
            };
            for (progs) |p| {
                fb.drawString(@intCast(tx), @intCast(line_y), p, 200, 200, 200, 26, 28, 35);
                line_y += 18;
            }
            line_y += 6;
            fb.drawString(@intCast(tx), @intCast(line_y), "Open Terminal to run them!", 140, 220, 140, 26, 28, 35);
        },
        .about => {
            fb.drawString(@intCast(tx), @intCast(line_y), "Zirconium OS GUI v0.4.0", 100, 200, 255, 26, 28, 35);
            line_y += 22;
            fb.drawString(@intCast(tx), @intCast(line_y), "Click 'Apps' for menu.", 200, 200, 200, 26, 28, 35);
            line_y += 20;
            fb.drawString(@intCast(tx), @intCast(line_y), "Drag windows by titlebar.", 180, 180, 180, 26, 28, 35);
            line_y += 20;
            fb.drawString(@intCast(tx), @intCast(line_y), "Press Esc to exit GUI.", 220, 160, 120, 26, 28, 35);
        },
    }
}

fn drawWindow(win: *Window) void {
    if (!win.visible) return;
    const border_color: u32 = if (win.focused) 0x4080E0 else 0x404450;
    fb.drawRectBorder(@intCast(win.x), @intCast(win.y), @intCast(win.w), @intCast(win.h), @intCast(BORDER), @intCast((border_color >> 16) & 0xFF), @intCast((border_color >> 8) & 0xFF), @intCast(border_color & 0xFF));

    const bar_color: u32 = if (win.focused) 0x24488A else 0x303440;
    fb.fillRect(@intCast(win.x + BORDER), @intCast(win.y + BORDER), @intCast(win.w - 2 * BORDER), @intCast(TITLE_H - BORDER), @intCast((bar_color >> 16) & 0xFF), @intCast((bar_color >> 8) & 0xFF), @intCast(bar_color & 0xFF));
    const title_color: u32 = if (win.focused) 0xFFFFFF else 0xB0B0C0;
    fb.drawString(@intCast(win.x + 6), @intCast(win.y + BORDER + 2), win.title[0..win.title_len], @intCast((title_color >> 16) & 0xFF), @intCast((title_color >> 8) & 0xFF), @intCast(title_color & 0xFF), @intCast((bar_color >> 16) & 0xFF), @intCast((bar_color >> 8) & 0xFF), @intCast(bar_color & 0xFF));

    // Close button [X]
    const close_x = win.x + win.w - 18;
    const close_y = win.y + 2;
    fb.fillRect(@intCast(close_x), @intCast(close_y), 14, 14, 180, 50, 50);
    fb.drawString(@intCast(close_x + 3), @intCast(close_y - 1), "x", 255, 255, 255, 180, 50, 50);

    drawWindowBody(win);
}

fn drawStartMenu() void {
    if (!start_menu_open) return;
    const ty = @as(i32, @intCast(fb.fb_height)) - TASKBAR_H;
    const menu_h = @as(i32, @intCast(MENU_ITEMS_COUNT * MENU_ITEM_H + 28));
    const my = ty - menu_h - 2;

    fb.fillRect(START_BTN_X, @intCast(my), @as(u32, @intCast(MENU_W)), @as(u32, @intCast(menu_h)), 24, 28, 38);
    fb.drawRectBorder(START_BTN_X, @intCast(my), @as(u32, @intCast(MENU_W)), @as(u32, @intCast(menu_h)), 2, 70, 110, 180);

    // Menu Header
    fb.fillRect(START_BTN_X + 2, @intCast(my + 2), @as(u32, @intCast(MENU_W - 4)), 20, 36, 50, 80);
    fb.drawString(START_BTN_X + 8, @intCast(my + 4), "=== Applications ===", 100, 220, 255, 36, 50, 80);

    var i: usize = 0;
    while (i < MENU_ITEMS_COUNT) : (i += 1) {
        const item_y = my + 24 + @as(i32, @intCast(i * MENU_ITEM_H));
        const hovered = (mouse.mx >= START_BTN_X and mouse.mx < START_BTN_X + MENU_W and
            mouse.my >= item_y and mouse.my < item_y + MENU_ITEM_H);

        if (hovered) {
            fb.fillRect(START_BTN_X + 3, @intCast(item_y), @as(u32, @intCast(MENU_W - 6)), @as(u32, @intCast(MENU_ITEM_H - 2)), 50, 90, 160);
            fb.drawString(START_BTN_X + 8, @intCast(item_y + 2), menu_items[i], 255, 255, 255, 50, 90, 160);
        } else {
            fb.drawString(START_BTN_X + 8, @intCast(item_y + 2), menu_items[i], 200, 210, 230, 24, 28, 38);
        }
    }
}

fn drawTaskbar() void {
    const ty = @as(i32, @intCast(fb.fb_height)) - TASKBAR_H;
    fb.fillRect(0, @intCast(ty), fb.fb_width, @as(u32, @intCast(TASKBAR_H)), 18, 20, 28);
    fb.fillRect(0, @intCast(ty), fb.fb_width, 2, 60, 90, 150);

    // Start / Apps button
    const btn_bg: u32 = if (start_menu_open) 0x3068C0 else 0x253B60;
    fb.fillRect(START_BTN_X, @intCast(ty + 3), @as(u32, @intCast(START_BTN_W)), @as(u32, @intCast(START_BTN_H)), @intCast((btn_bg >> 16) & 0xFF), @intCast((btn_bg >> 8) & 0xFF), @intCast(btn_bg & 0xFF));
    fb.drawRectBorder(START_BTN_X, @intCast(ty + 3), @as(u32, @intCast(START_BTN_W)), @as(u32, @intCast(START_BTN_H)), 1, 80, 140, 230);
    fb.drawString(START_BTN_X + 8, @intCast(ty + 6), "[ Apps ]", 240, 240, 255, @intCast((btn_bg >> 16) & 0xFF), @intCast((btn_bg >> 8) & 0xFF), @intCast(btn_bg & 0xFF));

    // Taskbar app buttons
    var btn_x: i32 = START_BTN_X + START_BTN_W + 12;
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (!windows[i].visible) continue;
        const wbtn_bg: u32 = if (windows[i].focused) 0x304870 else 0x1E2430;
        fb.fillRect(@intCast(btn_x), @intCast(ty + 3), 84, @as(u32, @intCast(START_BTN_H)), @intCast((wbtn_bg >> 16) & 0xFF), @intCast((wbtn_bg >> 8) & 0xFF), @intCast(wbtn_bg & 0xFF));
        fb.drawRectBorder(@intCast(btn_x), @intCast(ty + 3), 84, @as(u32, @intCast(START_BTN_H)), 1, 60, 80, 110);
        const slen = @min(windows[i].title_len, 9);
        fb.drawString(@intCast(btn_x + 6), @intCast(ty + 6), windows[i].title[0..slen], 210, 220, 240, @intCast((wbtn_bg >> 16) & 0xFF), @intCast((wbtn_bg >> 8) & 0xFF), @intCast(wbtn_bg & 0xFF));
        btn_x += 92;
    }

    drawTaskbarClock();
    drawStartMenu();
}

fn drawTaskbarClock() void {
    const ty = @as(i32, @intCast(fb.fb_height)) - TASKBAR_H;
    var tbuf: [32]u8 = undefined;
    timer.formatTime(tbuf[0..9]);
    const time_width = 9 * 8;
    const xpos_time: i32 = @as(i32, @intCast(fb.fb_width)) - @as(i32, @intCast(time_width)) - 12;
    fb.fillRect(@intCast(xpos_time - 4), @intCast(ty + 4), @as(u32, @intCast(time_width + 8)), @as(u32, @intCast(TASKBAR_H - 8)), 18, 20, 28);
    fb.drawString(@intCast(xpos_time), @intCast(ty + 6), tbuf[0..8], 140, 220, 140, 18, 20, 28);
}

fn drawDesktopRect(px: i32, py: i32, pw: i32, ph: i32) void {
    const x0: i32 = if (px < 0) 0 else px;
    const y0: i32 = if (py < 0) 0 else py;
    const x1: i32 = @min(px + pw, @as(i32, @intCast(fb.fb_width)));
    const y1: i32 = @min(py + ph, @as(i32, @intCast(fb.fb_height)));
    const h = fb.fb_height;
    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        const t: u32 = @intCast(y);
        const r: u8 = @intCast(16 + @as(u32, (t * 2) / (h + 1)));
        const g: u8 = @intCast(22 + @as(u32, (t * 3) / (h + 1)));
        const b: u8 = @intCast(38 + @as(u32, (t * 6) / (h + 1)));
        if (x1 > x0) fb.fillRect(@intCast(x0), @intCast(y), @intCast(x1 - x0), 1, r, g, b);
    }
}

fn drawDesktop() void {
    drawDesktopRect(0, 0, @intCast(fb.fb_width), @intCast(fb.fb_height));
}

fn winIntersects(rx: i32, ry: i32, rw: i32, rh: i32, w: *const Window) bool {
    return w.x < rx + rw and rx < w.x + w.w and w.y < ry + rh and ry < w.y + w.h;
}

fn redrawRect(rx: i32, ry: i32, rw: i32, rh: i32) void {
    if (rw <= 0 or rh <= 0) return;
    drawDesktopRect(rx, ry, rw, rh);
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (!windows[i].visible) continue;
        if (windows[i].focused) continue;
        if (winIntersects(rx, ry, rw, rh, &windows[i])) drawWindow(&windows[i]);
    }
    i = 0;
    while (i < num_windows) : (i += 1) {
        if (!windows[i].visible) continue;
        if (!windows[i].focused) continue;
        if (winIntersects(rx, ry, rw, rh, &windows[i])) drawWindow(&windows[i]);
    }
    const taskbar_y = @as(i32, @intCast(fb.fb_height)) - TASKBAR_H;
    if (ry + rh > taskbar_y or start_menu_open) drawTaskbar();
}

fn redrawAll() void {
    restoreCursor();
    drawDesktop();
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (!windows[i].focused) drawWindow(&windows[i]);
    }
    i = 0;
    while (i < num_windows) : (i += 1) {
        if (windows[i].focused) drawWindow(&windows[i]);
    }
    drawTaskbar();
    fb.flush();
    drawCursor();
}

fn clockWindow() ?*Window {
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (windows[i].visible and windows[i].content == .clock) return &windows[i];
    }
    return null;
}

fn focusedWindow() ?*Window {
    var i: usize = 0;
    while (i < num_windows) : (i += 1) {
        if (windows[i].visible and windows[i].focused) return &windows[i];
    }
    return null;
}

// ----- Public Entry Point -----

pub fn run() void {
    if (!fb.active) {
        vga.setColor(.light_red, .black);
        vga.write("  GUI requires a framebuffer (no text mode).\n");
        vga.setColor(.white, .black);
        return;
    }

    num_windows = 0;
    drag_index = -1;
    prev_left = false;
    prev_right = false;
    drag_button = .none;
    cursor_drawn = false;
    start_menu_open = false;
    next_clock_tick = timer.ticks;

    // Initialize terminal
    term_line_count = 0;
    term_scroll_offset = 0;
    term_cmd_len = 0;
    term_hist_count = 0;
    term_hist_idx = -1;
    termAddLineWithColor("Zirconium OS Interactive Terminal", 0x80D0FF);
    termAddLine("Type 'help' to see all available commands.");

    calc_len = 0;
    calc_val1 = 0;
    calc_op = 0;
    calc_new_num = true;

    note_cur_line = 0;
    note_lens = [_]usize{0} ** NOTE_MAX_LINES;
    const note_init = "Zirconium Notes";
    @memcpy(note_lines[0][0..note_init.len], note_init);
    note_lens[0] = note_init.len;

    const sw = @as(i32, @intCast(fb.fb_width));
    const sh = @as(i32, @intCast(fb.fb_height));

    drawDesktop();

    createWindow(.about, @divTrunc(sw, 2) - 120, @divTrunc(sh, 4), 240, 140, "Welcome");
    createWindow(.terminal, 30, 40, 380, 240, "Terminal");
    createWindow(.clock, sw - 190, 40, 160, 110, "Clock");

    redrawAll();
    mouse.debug_log = true;

    while (true) {
        if (kb.pollKey()) |k| {
            if (k == 0x1B) break; // Esc quits GUI

            if (focusedWindow()) |fwin| {
                if (fwin.content == .terminal) {
                    if (k == '\n' or k == '\r') {
                        executeTermCmd();
                        redrawAll();
                    } else if (k == 0x08) { // Backspace
                        if (term_cmd_len > 0) {
                            term_cmd_len -= 1;
                            redrawAll();
                        }
                    } else if (k == kb.KEY_UP) {
                        if (term_hist_count > 0) {
                            if (term_hist_idx < 0) {
                                term_hist_idx = @intCast(term_hist_count - 1);
                            } else if (term_hist_idx > 0) {
                                term_hist_idx -= 1;
                            }
                            const hidx: usize = @intCast(term_hist_idx);
                            const hlen = term_hist_lens[hidx];
                            @memcpy(term_cmd_buf[0..hlen], term_history[hidx][0..hlen]);
                            term_cmd_len = hlen;
                            redrawAll();
                        }
                    } else if (k == kb.KEY_DOWN) {
                        if (term_hist_idx >= 0) {
                            if (@as(usize, @intCast(term_hist_idx)) < term_hist_count - 1) {
                                term_hist_idx += 1;
                                const hidx: usize = @intCast(term_hist_idx);
                                const hlen = term_hist_lens[hidx];
                                @memcpy(term_cmd_buf[0..hlen], term_history[hidx][0..hlen]);
                                term_cmd_len = hlen;
                            } else {
                                term_hist_idx = -1;
                                term_cmd_len = 0;
                            }
                            redrawAll();
                        }
                    } else if (k == kb.KEY_PAGE_UP) {
                        if (term_scroll_offset > 2) {
                            term_scroll_offset -= 2;
                        } else {
                            term_scroll_offset = 0;
                        }
                        redrawAll();
                    } else if (k == kb.KEY_PAGE_DOWN) {
                        if (term_scroll_offset + TERM_VISIBLE_LINES < term_line_count) {
                            term_scroll_offset += 2;
                        }
                        redrawAll();
                    } else if (k >= 0x20 and k < 0x7F and term_cmd_len < 60) {
                        term_cmd_buf[term_cmd_len] = k;
                        term_cmd_len += 1;
                        redrawAll();
                    }
                } else if (fwin.content == .notepad) {
                    if (k == '\n' or k == '\r') {
                        if (note_cur_line < NOTE_MAX_LINES - 1) {
                            note_cur_line += 1;
                            redrawAll();
                        }
                    } else if (k == 0x08) {
                        if (note_lens[note_cur_line] > 0) {
                            note_lens[note_cur_line] -= 1;
                            redrawAll();
                        } else if (note_cur_line > 0) {
                            note_cur_line -= 1;
                            redrawAll();
                        }
                    } else if (k >= 0x20 and k < 0x7F and note_lens[note_cur_line] < NOTE_LINE_LEN - 1) {
                        note_lines[note_cur_line][note_lens[note_cur_line]] = k;
                        note_lens[note_cur_line] += 1;
                        redrawAll();
                    }
                }
            }
        }

        const px = mouse.mx;
        const py = mouse.my;

        if (px != cursor_x or py != cursor_y) {
            if (drag_index >= 0 and @as(usize, @intCast(drag_index)) < num_windows) {
                const w = &windows[@intCast(drag_index)];
                const ox = w.x;
                const oy = w.y;
                w.x = px - drag_off_x;
                w.y = py - drag_off_y;
                if (w.x < 0) w.x = 0;
                if (w.y < 0) w.y = 0;
                if (w.x + w.w > sw) w.x = sw - w.w;
                if (w.y + w.h > sh - TASKBAR_H) w.y = sh - TASKBAR_H - w.h;
                if (w.x != ox or w.y != oy) {
                    redrawAll();
                }
            } else {
                restoreCursor();
                cursor_x = px;
                cursor_y = py;
                saveCursorBg(cursor_x, cursor_y);
                drawCursorShape();
                cursor_drawn = true;
            }
        }

        const left_pressed = mouse.left_button and !prev_left;
        const right_pressed = mouse.right_button and !prev_right;

        if (left_pressed or right_pressed) {
            const ty = sh - TASKBAR_H;

            // Check Start / Apps button click
            if (px >= START_BTN_X and px < START_BTN_X + START_BTN_W and py >= ty) {
                start_menu_open = !start_menu_open;
                redrawAll();
            } else if (start_menu_open) {
                const menu_h = @as(i32, @intCast(MENU_ITEMS_COUNT * MENU_ITEM_H + 28));
                const my = ty - menu_h - 2;

                if (px >= START_BTN_X and px < START_BTN_X + MENU_W and py >= my and py < ty) {
                    const item_idx = @as(usize, @intCast(@divTrunc(py - (my + 24), MENU_ITEM_H)));
                    start_menu_open = false;
                    switch (item_idx) {
                        0 => openOrCreateWindow(.terminal),
                        1 => openOrCreateWindow(.clock),
                        2 => openOrCreateWindow(.system),
                        3 => openOrCreateWindow(.calculator),
                        4 => openOrCreateWindow(.notepad),
                        5 => openOrCreateWindow(.launcher),
                        6 => openOrCreateWindow(.about),
                        7 => break, // Exit GUI
                        else => {},
                    }
                    redrawAll();
                } else {
                    start_menu_open = false;
                    redrawAll();
                }
            } else if (drag_index < 0) {
                const hit = topmostAt(px, py);
                if (hit >= 0) {
                    allFocused(@intCast(hit));
                    const w = &windows[@intCast(hit)];

                    // Check [X] close button click
                    const close_x = w.x + w.w - 18;
                    const close_y = w.y + 2;
                    if (px >= close_x and px < close_x + 14 and py >= close_y and py < close_y + 14) {
                        w.visible = false;
                        redrawAll();
                    } else if (py < w.y + TITLE_H) {
                        drag_index = hit;
                        drag_button = if (left_pressed) .left else .right;
                        drag_off_x = px - w.x;
                        drag_off_y = py - w.y;
                        redrawAll();
                    } else {
                        // Body interaction (e.g. calculator buttons)
                        if (w.content == .calculator) {
                            const body_y = w.y + TITLE_H + BORDER;
                            var row: usize = 0;
                            while (row < 4) : (row += 1) {
                                var col: usize = 0;
                                while (col < 4) : (col += 1) {
                                    const bx = w.x + 10 + @as(i32, @intCast(col * 38));
                                    const by = body_y + 36 + @as(i32, @intCast(row * 28));
                                    if (px >= bx and px < bx + 32 and py >= by and py < by + 22) {
                                        const bidx = row * 4 + col;
                                        handleCalcClick(bidx);
                                        redrawAll();
                                    }
                                }
                            }
                        }
                        redrawAll();
                    }
                }
            }
        } else if (drag_index >= 0) {
            const held = if (drag_button == .left) mouse.left_button else mouse.right_button;
            if (!held) drag_index = -1;
        }

        prev_left = mouse.left_button;
        prev_right = mouse.right_button;

        if (timer.ticks >= next_clock_tick) {
            next_clock_tick = timer.ticks + 100;
            restoreCursor();
            if (clockWindow()) |w| {
                redrawRect(w.x, w.y, w.w, w.h);
            }
            drawTaskbarClock();
            fb.flush();
            drawCursor();
        }

        asm volatile ("pause");
    }

    redrawAll();
    vga.clear();
}

fn handleCalcClick(bidx: usize) void {
    const chars = "789/456*123-C0=+";
    if (bidx >= chars.len) return;
    const ch = chars[bidx];

    if (ch >= '0' and ch <= '9') {
        if (calc_new_num or calc_len == 0) {
            calc_display[0] = ch;
            calc_len = 1;
            calc_new_num = false;
        } else if (calc_len < 10) {
            calc_display[calc_len] = ch;
            calc_len += 1;
        }
    } else if (ch == 'C') {
        calc_len = 0;
        calc_val1 = 0;
        calc_op = 0;
        calc_new_num = true;
    } else if (ch == '+' or ch == '-' or ch == '*' or ch == '/') {
        calc_val1 = parseCalc();
        calc_op = ch;
        calc_new_num = true;
    } else if (ch == '=') {
        const val2 = parseCalc();
        var res: i64 = val2;
        if (calc_op == '+') res = calc_val1 + val2;
        if (calc_op == '-') res = calc_val1 - val2;
        if (calc_op == '*') res = calc_val1 * val2;
        if (calc_op == '/' and val2 != 0) res = @divTrunc(calc_val1, val2);

        var buf: [32]u8 = undefined;
        const ures: u64 = if (res < 0) @intCast(-res) else @intCast(res);
        const sres = fmtDec(ures, buf[0..]);
        var off: usize = 0;
        if (res < 0) {
            calc_display[0] = '-';
            off = 1;
        }
        @memcpy(calc_display[off..][0..sres.len], sres);
        calc_len = off + sres.len;
        calc_new_num = true;
        calc_op = 0;
    }
}

fn parseCalc() i64 {
    if (calc_len == 0) return 0;
    var v: i64 = 0;
    for (calc_display[0..calc_len]) |c| {
        if (c >= '0' and c <= '9') {
            v = v * 10 + @as(i64, @intCast(c - '0'));
        }
    }
    return v;
}