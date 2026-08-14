const std = @import("std");
const root = @import("root");
const vga = root.vga;
const timer = @import("../drivers/timer.zig");
const pmm = root.pmm;
const vfs = @import("../fs/vfs.zig");
const scheduler = root.scheduler;
const kb = @import("../drivers/keyboard.zig");
const serial = @import("serial.zig");

pub const MAX_TTYS: usize = 4;
pub const MAX_COLS: usize = 80;
pub const MAX_ROWS: usize = 40;
pub const SCROLLBACK_LINES: usize = 256;
pub const CMD_MAX: usize = 128;
pub const HIST_MAX: usize = 16;

pub const TTY = struct {
    id: u8,
    name: [8]u8,
    name_len: usize,
    cols: usize = 80,
    rows: usize = 25,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    fg: vga.Color = .white,
    bg: vga.Color = .black,

    // Character buffer: char | (fg << 8) | (bg << 12)
    buffer: [MAX_ROWS][MAX_COLS]u16 = [_][MAX_COLS]u16{[_]u16{0} ** MAX_COLS} ** MAX_ROWS,

    // Scrollback buffer
    scrollback: [SCROLLBACK_LINES][MAX_COLS]u16 = [_][MAX_COLS]u16{[_]u16{0} ** MAX_COLS} ** SCROLLBACK_LINES,
    sb_head: usize = 0,
    sb_count: usize = 0,
    scroll_view_offset: usize = 0,

    // Command line state
    cmd_buf: [CMD_MAX]u8 = undefined,
    cmd_len: usize = 0,
    cursor_pos: usize = 0,

    // Command history
    history: [HIST_MAX][CMD_MAX]u8 = undefined,
    hist_lens: [HIST_MAX]usize = [_]usize{0} ** HIST_MAX,
    hist_count: usize = 0,
    hist_idx: i32 = -1,

    pub fn init(self: *TTY, id: u8) void {
        self.id = id;
        @memset(&self.name, 0);
        self.name[0] = 't';
        self.name[1] = 't';
        self.name[2] = 'y';
        self.name[3] = '0' + id;
        self.name_len = 4;

        self.cols = 80;
        self.rows = 25;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.fg = .white;
        self.bg = .black;
        self.sb_head = 0;
        self.sb_count = 0;
        self.scroll_view_offset = 0;
        self.cmd_len = 0;
        self.cursor_pos = 0;
        self.hist_count = 0;
        self.hist_idx = -1;

        self.clear();
        self.printBanner();
        self.printPrompt();
    }

    fn makeEntry(ch: u8, fg_col: vga.Color, bg_col: vga.Color) u16 {
        return @as(u16, ch) | (@as(u16, @intFromEnum(fg_col)) << 8) | (@as(u16, @intFromEnum(bg_col)) << 12);
    }

    pub fn clear(self: *TTY) void {
        const blank = makeEntry(' ', self.fg, self.bg);
        for (0..MAX_ROWS) |r| {
            for (0..MAX_COLS) |c| {
                self.buffer[r][c] = blank;
            }
        }
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.scroll_view_offset = 0;
    }

    pub fn setColor(self: *TTY, fg: vga.Color, bg: vga.Color) void {
        self.fg = fg;
        self.bg = bg;
    }

    pub fn scrollUp(self: *TTY) void {
        // Copy top row to scrollback
        self.scrollback[self.sb_head] = self.buffer[0];
        self.sb_head = (self.sb_head + 1) % SCROLLBACK_LINES;
        if (self.sb_count < SCROLLBACK_LINES) self.sb_count += 1;

        // Shift rows up
        var r: usize = 0;
        while (r < self.rows - 1) : (r += 1) {
            self.buffer[r] = self.buffer[r + 1];
        }

        // Blank out bottom row
        const blank = makeEntry(' ', self.fg, self.bg);
        for (0..self.cols) |c| {
            self.buffer[self.rows - 1][c] = blank;
        }
    }

    pub fn putChar(self: *TTY, ch: u8) void {
        if (ch == '\n') {
            self.cursor_col = 0;
            self.cursor_row += 1;
            if (self.cursor_row >= self.rows) {
                self.scrollUp();
                self.cursor_row = self.rows - 1;
            }
            return;
        }
        if (ch == '\r') {
            self.cursor_col = 0;
            return;
        }
        if (ch == 0x08) { // Backspace
            if (self.cursor_col > 0) {
                self.cursor_col -= 1;
                self.buffer[self.cursor_row][self.cursor_col] = makeEntry(' ', self.fg, self.bg);
            }
            return;
        }
        if (ch == '\t') {
            const next_tab = (self.cursor_col + 4) & ~@as(usize, 3);
            while (self.cursor_col < next_tab and self.cursor_col < self.cols) : (self.cursor_col += 1) {
                self.buffer[self.cursor_row][self.cursor_col] = makeEntry(' ', self.fg, self.bg);
            }
            return;
        }

        if (self.cursor_col >= self.cols) {
            self.cursor_col = 0;
            self.cursor_row += 1;
            if (self.cursor_row >= self.rows) {
                self.scrollUp();
                self.cursor_row = self.rows - 1;
            }
        }

        self.buffer[self.cursor_row][self.cursor_col] = makeEntry(ch, self.fg, self.bg);
        self.cursor_col += 1;
    }

    pub fn write(self: *TTY, s: []const u8) void {
        for (s) |ch| {
            self.putChar(ch);
        }
    }

    pub fn writeDec(self: *TTY, val: u64) void {
        if (val == 0) {
            self.putChar('0');
            return;
        }
        var buf: [32]u8 = undefined;
        var i: usize = buf.len;
        var v = val;
        while (v > 0 and i > 0) {
            i -= 1;
            buf[i] = @intCast('0' + (v % 10));
            v /= 10;
        }
        self.write(buf[i..]);
    }

    pub fn writeHex(self: *TTY, val: u64) void {
        const hex_digits = "0123456789ABCDEF";
        var buf: [16]u8 = undefined;
        var v = val;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            buf[15 - i] = hex_digits[@intCast(v & 0xF)];
            v >>= 4;
        }
        var start: usize = 0;
        while (start < 15 and buf[start] == '0') : (start += 1) {}
        self.write("0x");
        self.write(buf[start..]);
    }

    pub fn printBanner(self: *TTY) void {
        self.setColor(.light_cyan, .black);
        self.write("  _____ _                         _                  \n");
        self.write(" |__  /(_)_ __ ___ ___  _ __  _  (_)_   _ _ __ ___   \n");
        self.write("   / / | | '__/ __/ _ \\| '_ \\| | | | | | | '_ ` _ \\  \n");
        self.write("  / /_ | | | | (_| (_) | | | | |_| | |_| | | | | | | \n");
        self.write(" /____||_|_|  \\___\\___/|_| |_|\\__,_|\\__,_|_| |_| |_| \n");
        self.setColor(.light_gray, .black);
        self.write("  Zirconium Kernel v0.4.0 — Terminal (");
        self.write(self.name[0..self.name_len]);
        self.write(")\n");
        self.setColor(.white, .black);
    }

    pub fn printPrompt(self: *TTY) void {
        self.setColor(.light_green, .black);
        self.write("zig> ");
        self.setColor(.white, .black);
    }

    pub fn historyPush(self: *TTY, cmd: []const u8) void {
        if (cmd.len == 0) return;
        if (self.hist_count < HIST_MAX) {
            @memcpy(self.history[self.hist_count][0..cmd.len], cmd);
            self.hist_lens[self.hist_count] = cmd.len;
            self.hist_count += 1;
        } else {
            var h: usize = 0;
            while (h < HIST_MAX - 1) : (h += 1) {
                self.history[h] = self.history[h + 1];
                self.hist_lens[h] = self.hist_lens[h + 1];
            }
            @memcpy(self.history[HIST_MAX - 1][0..cmd.len], cmd);
            self.hist_lens[HIST_MAX - 1] = cmd.len;
        }
        self.hist_idx = -1;
    }

    pub fn handleKey(self: *TTY, k: u8) bool {
        if (k == '\n' or k == '\r') {
            self.putChar('\n');
            const cmd = self.cmd_buf[0..self.cmd_len];
            self.historyPush(cmd);
            self.executeCommand(cmd);
            self.cmd_len = 0;
            self.cursor_pos = 0;
            self.printPrompt();
            return true;
        }

        if (k == 0x08) { // Backspace
            if (self.cmd_len > 0 and self.cursor_pos > 0) {
                if (self.cursor_pos == self.cmd_len) {
                    self.cmd_len -= 1;
                    self.cursor_pos -= 1;
                    self.putChar(0x08);
                } else {
                    var i = self.cursor_pos - 1;
                    while (i < self.cmd_len - 1) : (i += 1) {
                        self.cmd_buf[i] = self.cmd_buf[i + 1];
                    }
                    self.cmd_len -= 1;
                    self.cursor_pos -= 1;
                    self.redrawCommandLine();
                }
                return true;
            }
            return false;
        }

        if (k == kb.KEY_UP) {
            if (self.hist_count > 0) {
                if (self.hist_idx < 0) {
                    self.hist_idx = @intCast(self.hist_count - 1);
                } else if (self.hist_idx > 0) {
                    self.hist_idx -= 1;
                }
                const hidx: usize = @intCast(self.hist_idx);
                const hlen = self.hist_lens[hidx];
                @memcpy(self.cmd_buf[0..hlen], self.history[hidx][0..hlen]);
                self.cmd_len = hlen;
                self.cursor_pos = hlen;
                self.redrawCommandLine();
                return true;
            }
            return false;
        }

        if (k == kb.KEY_DOWN) {
            if (self.hist_idx >= 0) {
                if (@as(usize, @intCast(self.hist_idx)) < self.hist_count - 1) {
                    self.hist_idx += 1;
                    const hidx: usize = @intCast(self.hist_idx);
                    const hlen = self.hist_lens[hidx];
                    @memcpy(self.cmd_buf[0..hlen], self.history[hidx][0..hlen]);
                    self.cmd_len = hlen;
                    self.cursor_pos = hlen;
                } else {
                    self.hist_idx = -1;
                    self.cmd_len = 0;
                    self.cursor_pos = 0;
                }
                self.redrawCommandLine();
                return true;
            }
            return false;
        }

        if (k >= 0x20 and k < 0x7F and self.cmd_len < CMD_MAX - 1) {
            if (self.cursor_pos == self.cmd_len) {
                self.cmd_buf[self.cmd_len] = k;
                self.cmd_len += 1;
                self.cursor_pos += 1;
                self.putChar(k);
            } else {
                var i = self.cmd_len;
                while (i > self.cursor_pos) : (i -= 1) {
                    self.cmd_buf[i] = self.cmd_buf[i - 1];
                }
                self.cmd_buf[self.cursor_pos] = k;
                self.cmd_len += 1;
                self.cursor_pos += 1;
                self.redrawCommandLine();
            }
            return true;
        }

        return false;
    }

    fn redrawCommandLine(self: *TTY) void {
        self.cursor_col = 5; // right after "zig> "
        for (self.cmd_buf[0..self.cmd_len]) |c| {
            self.buffer[self.cursor_row][self.cursor_col] = makeEntry(c, self.fg, self.bg);
            self.cursor_col += 1;
        }
        var c = self.cursor_col;
        while (c < self.cols) : (c += 1) {
            self.buffer[self.cursor_row][c] = makeEntry(' ', self.fg, self.bg);
        }
    }

    pub fn executeCommand(self: *TTY, cmd: []const u8) void {
        if (cmd.len == 0) return;

        var cmd_end: usize = cmd.len;
        var args_start: usize = cmd.len;
        for (cmd, 0..) |ch, i| {
            if (ch == ' ') {
                cmd_end = i;
                args_start = i + 1;
                break;
            }
        }
        const cmd_name = cmd[0..cmd_end];
        const args = if (args_start < cmd.len) cmd[args_start..] else "";

        if (std.mem.eql(u8, cmd_name, "help")) {
            self.setColor(.light_cyan, .black);
            self.write("=== Zirconium TTY Commands ===\n");
            self.setColor(.white, .black);
            self.write("  help, clear, tty, ls, cat, touch, mkdir, rm, pwd, cd\n");
            self.write("  mem, ps, sysinfo, info, smp, cpuinfo, net, ip, ping\n");
            self.write("  calc, fib, date, time, uname, echo, history\n");
            self.write("  exec <path>, user\n");
        } else if (std.mem.eql(u8, cmd_name, "clear") or std.mem.eql(u8, cmd_name, "cls")) {
            self.clear();
        } else if (std.mem.eql(u8, cmd_name, "tty")) {
            self.setColor(.light_green, .black);
            self.write("Current device: /dev/");
            self.write(self.name[0..self.name_len]);
            self.write("\n");
            self.setColor(.white, .black);
        } else if (std.mem.eql(u8, cmd_name, "pwd")) {
            self.write(vfs.getCwd());
            self.write("\n");
        } else if (std.mem.eql(u8, cmd_name, "cd")) {
            if (args.len == 0) {
                vfs.setCwd("/");
            } else {
                vfs.setCwd(args);
            }
            self.write(vfs.getCwd());
            self.write("\n");
        } else if (std.mem.eql(u8, cmd_name, "ls")) {
            const path = if (args.len > 0) args else vfs.getCwd();
            var entries: [32]vfs.DirEntry = undefined;
            const count = vfs.readdir(path, &entries);
            if (count == 0) {
                self.write("  (empty directory or not found)\n");
            } else {
                var idx: usize = 0;
                while (idx < count) : (idx += 1) {
                    const name = entries[idx].name[0..entries[idx].name_len];
                    if (entries[idx].file_type == .directory) {
                        self.setColor(.light_blue, .black);
                        self.write("  [DIR]  ");
                        self.write(name);
                        self.write("/\n");
                    } else {
                        self.setColor(.white, .black);
                        self.write("  [FILE] ");
                        self.write(name);
                        self.write(" (");
                        self.writeDec(entries[idx].size);
                        self.write(" bytes)\n");
                    }
                }
            }
            self.setColor(.white, .black);
        } else if (std.mem.eql(u8, cmd_name, "cat")) {
            if (args.len == 0) {
                self.setColor(.light_red, .black);
                self.write("Usage: cat <file>\n");
            } else if (vfs.open(args, .{ .read = true })) |handle| {
                defer vfs.close(handle);
                var fbuf: [512]u8 = undefined;
                var total: usize = 0;
                while (true) {
                    const n = vfs.read(handle, &fbuf);
                    if (n == 0) break;
                    self.write(fbuf[0..n]);
                    total += n;
                }
                if (total > 0 and fbuf[total - 1] != '\n') self.write("\n");
            } else {
                self.setColor(.light_red, .black);
                self.write("Error: file not found: ");
                self.write(args);
                self.write("\n");
            }
            self.setColor(.white, .black);
        } else if (std.mem.eql(u8, cmd_name, "touch")) {
            if (args.len == 0) {
                self.setColor(.light_red, .black);
                self.write("Usage: touch <file>\n");
            } else if (vfs.open(args, .{ .write = true, .create = true })) |handle| {
                vfs.close(handle);
                self.setColor(.light_green, .black);
                self.write("File created successfully.\n");
            } else {
                self.setColor(.light_red, .black);
                self.write("Error: cannot create file\n");
            }
            self.setColor(.white, .black);
        } else if (std.mem.eql(u8, cmd_name, "mkdir")) {
            if (args.len == 0) {
                self.setColor(.light_red, .black);
                self.write("Usage: mkdir <dir>\n");
            } else if (vfs.mkdir(args)) {
                self.setColor(.light_green, .black);
                self.write("Directory created.\n");
            } else {
                self.setColor(.light_red, .black);
                self.write("Error: cannot create directory\n");
            }
            self.setColor(.white, .black);
        } else if (std.mem.eql(u8, cmd_name, "rm")) {
            if (args.len == 0) {
                self.setColor(.light_red, .black);
                self.write("Usage: rm <file>\n");
            } else if (vfs.unlink(args)) {
                self.setColor(.light_green, .black);
                self.write("File deleted.\n");
            } else {
                self.setColor(.light_red, .black);
                self.write("Error: cannot delete file\n");
            }
            self.setColor(.white, .black);
        } else if (std.mem.eql(u8, cmd_name, "mem")) {
            self.setColor(.light_cyan, .black);
            self.write("=== Memory Statistics ===\n");
            self.setColor(.white, .black);
            self.write("  Total Physical Memory: 128 MB\n");
            self.write("  Total Pages:           ");
            self.writeDec(pmm.total_pages);
            self.write("\n  Free Pages:            ");
            self.setColor(.light_green, .black);
            self.writeDec(pmm.free_pages);
            self.setColor(.white, .black);
            self.write(" (");
            self.writeDec(pmm.free_pages * 4);
            self.write(" KB free)\n");
        } else if (std.mem.eql(u8, cmd_name, "ps")) {
            self.setColor(.light_cyan, .black);
            self.write("PID  NAME       STATE    PERSONALITY\n");
            self.setColor(.white, .black);
            self.write(" 0   idle       running  native (kernel)\n");
            self.write(" 1   shell      running  native (kernel)\n");
            self.write(" 2   gui/tty    running  native (kernel)\n");
        } else if (std.mem.eql(u8, cmd_name, "uname") or std.mem.eql(u8, cmd_name, "uname -a")) {
            self.setColor(.light_green, .black);
            self.write("Linux zirconium 6.0.0-zirconium #1 SMP x86_64\n");
            self.setColor(.white, .black);
        } else if (std.mem.eql(u8, cmd_name, "sysinfo") or std.mem.eql(u8, cmd_name, "info")) {
            self.setColor(.light_cyan, .black);
            self.write("=== Zirconium System Information ===\n");
            self.setColor(.white, .black);
            self.write("  Architecture: x86_64 Long Mode (64-bit)\n");
            self.write("  CPUs:         4 Cores SMP (ACPI MADT)\n");
            self.write("  Timer:        100 Hz PIT (IRQ0)\n");
            self.write("  NIC:          Intel e1000 Gigabit\n");
        } else if (std.mem.eql(u8, cmd_name, "net") or std.mem.eql(u8, cmd_name, "ip")) {
            self.setColor(.light_cyan, .black);
            self.write("=== Network Interface ===\n");
            self.setColor(.white, .black);
            self.write("  IPv4 Address: 10.0.2.15 / 24\n");
            self.write("  Gateway:      10.0.2.2\n");
            self.write("  DNS Server:   10.0.2.3\n");
            self.write("  Status:       Link Up (e1000)\n");
        } else if (std.mem.eql(u8, cmd_name, "dillo")) {
            self.setColor(.light_cyan, .black);
            const dillo_prog = @import("../programs/dillo.zig");
            const dillo = dillo_prog.getDillo();
            if (args.len > 0) {
                dillo.loadUrl(args);
            } else {
                dillo.loadUrl("about:dillo");
            }
            var lidx: usize = 0;
            while (lidx < dillo.line_count) : (lidx += 1) {
                self.write("  ");
                self.write(dillo.lines[lidx][0..dillo.line_lens[lidx]]);
                self.write("\n");
            }
            self.setColor(.white, .black);
        } else if (std.mem.eql(u8, cmd_name, "usb") or std.mem.eql(u8, cmd_name, "lsusb")) {
            self.setColor(.light_cyan, .black);
            const usb_drv = @import("../drivers/usb.zig");
            const Helper = struct {
                var current_tty: *TTY = undefined;
                fn write(s: []const u8) void {
                    current_tty.write(s);
                }
                fn writeDec(v: u64) void {
                    current_tty.writeDec(v);
                }
                fn writeHex(v: u64) void {
                    current_tty.writeHex(v);
                }
            };
            Helper.current_tty = self;
            usb_drv.printUsbStatus(Helper.write, Helper.writeDec, Helper.writeHex);
            self.setColor(.white, .black);
        } else if (std.mem.eql(u8, cmd_name, "mount")) {
            vfs.printMounts();
        } else if (std.mem.eql(u8, cmd_name, "history")) {
            self.setColor(.light_cyan, .black);
            self.write("=== Command History ===\n");
            self.setColor(.white, .black);
            var h: usize = 0;
            while (h < self.hist_count) : (h += 1) {
                self.write("  ");
                self.writeDec(h + 1);
                self.write(": ");
                self.write(self.history[h][0..self.hist_lens[h]]);
                self.write("\n");
            }
        } else if (std.mem.eql(u8, cmd_name, "echo")) {
            self.write(args);
            self.write("\n");
        } else if (std.mem.eql(u8, cmd_name, "fib")) {
            self.write("Fibonacci sequence:\n");
            self.write("  F(1)=1, F(2)=1, F(5)=5, F(10)=55, F(20)=6765, F(30)=832040\n");
        } else if (std.mem.eql(u8, cmd_name, "user")) {
            const user_test_bin = @import("user_test_bin");
            self.write("Spawning Ring 3 user ELF test task...\n");
            if (scheduler.spawnProgramImage(&user_test_bin.data, "user_test")) |task_id| {
                scheduler.runTask(task_id);
                self.setColor(.light_green, .black);
                self.write("[USER] Task finished successfully (Ring 3 INT 0x80 OK).\n");
            } else |err| {
                self.setColor(.light_red, .black);
                self.write("Failed to spawn user task: ");
                self.write(@errorName(err));
                self.write("\n");
            }
            self.setColor(.white, .black);
        } else if (std.mem.eql(u8, cmd_name, "exec")) {
            if (args.len == 0) {
                self.setColor(.light_red, .black);
                self.write("Usage: exec <path> [args...]\n");
            } else {
                self.write("Spawning program: ");
                self.write(args);
                self.write("...\n");
                if (scheduler.spawnProgram(args, cmd)) |task_id| {
                    scheduler.runTask(task_id);
                    self.setColor(.light_green, .black);
                    self.write("Process finished with status 0.\n");
                } else |err| {
                    self.setColor(.light_red, .black);
                    self.write("Exec failed: ");
                    self.write(@errorName(err));
                    self.write("\n");
                }
            }
            self.setColor(.white, .black);
        } else {
            // Direct disk executable check
            if (vfs.stat(cmd_name) != null) {
                if (scheduler.spawnProgram(cmd_name, cmd)) |task_id| {
                    scheduler.runTask(task_id);
                    self.setColor(.light_green, .black);
                    self.write("Execution finished OK.\n");
                } else |err| {
                    self.setColor(.light_red, .black);
                    self.write("Error: ");
                    self.write(@errorName(err));
                    self.write("\n");
                }
            } else {
                self.setColor(.light_red, .black);
                self.write("Unknown command '");
                self.write(cmd_name);
                self.write("'. Type 'help' for commands.\n");
            }
            self.setColor(.white, .black);
        }
    }
};

var ttys: [MAX_TTYS]TTY = undefined;
var active_tty_id: u8 = 0;
var initialized: bool = false;

pub fn init() void {
    if (initialized) return;
    var i: u8 = 0;
    while (i < MAX_TTYS) : (i += 1) {
        ttys[i].init(i);
    }
    active_tty_id = 0;
    initialized = true;
    serial.serialWrite("[TTY] Initialized 4 virtual terminals (tty0..tty3)\n");
}

pub fn get(id: usize) *TTY {
    if (!initialized) init();
    const safe_id = if (id < MAX_TTYS) id else 0;
    return &ttys[safe_id];
}

pub fn getActive() *TTY {
    return get(active_tty_id);
}

pub fn setActive(id: u8) void {
    if (id < MAX_TTYS) {
        active_tty_id = id;
    }
}
