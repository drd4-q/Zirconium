const std = @import("std");
const root = @import("root");
const vga = root.vga;
const kb = @import("drivers/keyboard.zig");
const pci = @import("drivers/pci.zig");
const e1000 = @import("drivers/e1000.zig");
const net = @import("net/mod.zig");

const info = @import("programs/info.zig");
const calc = @import("programs/calc.zig");
const color = @import("programs/color.zig");
const clock_mod = @import("programs/clock.zig");
const ping_mod = @import("programs/ping.zig");
const web = @import("programs/web.zig");
const netinfo = @import("programs/netinfo.zig");
const sysinfo = @import("programs/sysinfo.zig");
const mem_mod = @import("programs/mem.zig");
const fib = @import("programs/fib.zig");
const matrix = @import("programs/matrix.zig");
const lua_prog = @import("programs/lua.zig");

const HISTORY_SIZE: usize = 16;
const CMD_MAX: usize = 128;
var history: [HISTORY_SIZE][CMD_MAX]u8 = undefined;
var history_len: [HISTORY_SIZE]usize = undefined;
var history_count: usize = 0;
var history_pos: i32 = -1;

const ENV_MAX: usize = 32;
const ENV_KEY_MAX: usize = 32;
const ENV_VAL_MAX: usize = 64;
const EnvEntry = struct {
    key: [ENV_KEY_MAX]u8 = undefined,
    key_len: usize = 0,
    value: [ENV_VAL_MAX]u8 = undefined,
    value_len: usize = 0,
    used: bool = false,
};
var env_store: [ENV_MAX]EnvEntry = undefined;

const commands = [_][]const u8{
    "help",  "info",    "sysinfo", "mem",  "ps",   "clear", "cls",
    "halt",  "reboot",  "calc",    "color","clock","fib",   "matrix",
    "lua",   "user",    "ping",    "net",  "get",  "wget",
    "set",   "unset",   "env",
};

var cmd_buf: [CMD_MAX]u8 = undefined;

pub fn run() void {
    kb.init();

    pci.scan();

    if (pci.findByClass(0x02, 0x00)) |dev| {
        _ = e1000.init(dev);
        net.init();
    }

    root.scheduler_ready = true;

    vga.clear();
    printBanner();

    vga.setColor(.light_gray, .black);
    vga.write("  IRQ-based: keyboard (IRQ1), timer 100Hz (IRQ0)\n");
    if (pci.findByClass(0x02, 0x00) != null) {
        vga.write("  Network: e1000, IP: 10.0.2.15, GW: 10.0.2.2\n");
    } else {
        vga.write("  Network: none\n");
    }
    vga.setColor(.white, .black);
    vga.write("\n");

    while (true) {
        vga.setColor(.light_green, .black);
        vga.write("zig> ");
        vga.setColor(.white, .black);

        const len = readLineEnhanced(&cmd_buf, CMD_MAX);
        if (len == 0) continue;

        historyPush(cmd_buf[0..len]);
        execute(cmd_buf[0..len]);
    }
}

fn printBanner() void {
    vga.setColor(.light_cyan, .black);
    vga.write("  ____          _\n");
    vga.write(" / ___|___   __| | ___  _ __ ___\n");
    vga.write("| |   / _ \\ / _` |/ _ \\| '__/ _ \\\n");
    vga.write("| |__| (_) | (_| |  __/| | | (_) |\n");
    vga.write(" \\____\\___/ \\__,_|\\___||_|  \\___/\n");
    vga.setColor(.white, .black);
    vga.write("\n  Bare-metal x86_64 kernel v0.2.0 — IRQ-based\n");
    vga.write("  Type 'help' for commands.\n\n");
}

fn execute(cmd: []const u8) void {
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

    if (eql(cmd_name, "help")) {
        printHelp();
    } else if (eql(cmd_name, "info")) {
        info.run();
    } else if (eql(cmd_name, "calc")) {
        calc.run();
    } else if (eql(cmd_name, "color")) {
        color.run();
    } else if (eql(cmd_name, "clock")) {
        clock_mod.run();
    } else if (eql(cmd_name, "ping")) {
        ping_mod.run(args);
    } else if (eql(cmd_name, "get") or eql(cmd_name, "wget")) {
        web.run(args);
    } else if (eql(cmd_name, "net")) {
        netinfo.run();
    } else if (eql(cmd_name, "sysinfo")) {
        sysinfo.run();
    } else if (eql(cmd_name, "mem")) {
        mem_mod.run();
    } else if (eql(cmd_name, "ps")) {
        showPs();
    } else if (eql(cmd_name, "fib")) {
        fib.run();
    } else if (eql(cmd_name, "lua")) {
        lua_prog.run();
        vga.clear();
        printBanner();
    } else if (eql(cmd_name, "user")) {
        const sched = root.scheduler;
        const user_test_bin = @import("user_test_bin");
        vga.write("[SHELL] Spawning user-space ELF task...\n");
        if (sched.addElfUserTask(&user_test_bin.data)) |task_id| {
            _ = task_id;
            sched.runAll();
        } else {
            vga.write("[SHELL] Error: failed to spawn user task\n");
        }
    } else if (eql(cmd_name, "matrix")) {

        matrix.run();
        vga.clear();
        printBanner();
    } else if (eql(cmd_name, "clear") or eql(cmd_name, "cls")) {
        vga.clear();
    } else if (eql(cmd_name, "halt")) {
        vga.setColor(.light_red, .black);
        vga.write("\n  System halted.\n");
        root.serial.serialWrite("\n[BOOT] System halted by user.\n");
        while (true) {
            asm volatile ("cli; hlt");
        }
    } else if (eql(cmd_name, "reboot")) {
        vga.setColor(.yellow, .black);
        vga.write("\n  Rebooting...\n");
        port_io.outb(0x92, 0x03);
        while (true) {
            asm volatile ("cli; hlt");
        }
    } else if (eql(cmd_name, "set")) {
        cmdSet(args);
    } else if (eql(cmd_name, "unset")) {
        cmdUnset(args);
    } else if (eql(cmd_name, "env")) {
        cmdEnv();
    } else {
        vga.setColor(.light_red, .black);
        vga.write("  Unknown command: '");
        vga.write(cmd_name);
        vga.write("'\n");
        vga.setColor(.white, .black);
        vga.write("  Type 'help' for available commands.\n");
    }
}

fn showPs() void {
    const sched = root.scheduler;
    vga.setColor(.cyan, .black);
    vga.write("\n=== Tasks ===\n\n");
    vga.setColor(.white, .black);
    vga.write("  PID  STATE      ENTRY       TIME_LEFT\n");
    vga.write("  ─────────────────────────────────────\n");

    if (sched.task_count == 0) {
        vga.write("  No tasks registered\n\n");
        return;
    }

    var i: usize = 0;
    while (i < sched.task_count) : (i += 1) {
        const t = &sched.tasks[i];
        vga.write("  ");
        vga.writeDec(t.id);
        pad(4);
        switch (t.state) {
            .ready => vga.write("READY    "),
            .running => vga.write("RUNNING  "),
            .blocked => vga.write("BLOCKED  "),
            .finished => vga.write("FINISHED "),
        }
        vga.writeHexShort(t.entry_point);
        vga.write("   ");
        vga.writeDec(t.time_slice);
        vga.putChar('\n');
    }
    vga.write("\n  Total: ");
    vga.writeDec(sched.task_count);
    vga.write(" tasks, current: ");
    if (sched.current_task >= 0) {
        vga.writeDec(@intCast(sched.current_task));
    } else {
        vga.write("none");
    }
    vga.write("\n\n");
}

fn pad(n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        vga.putChar(' ');
    }
}

fn printHelp() void {
    vga.setColor(.cyan, .black);
    vga.write("\n  === Commands ===\n\n");
    vga.setColor(.white, .black);
    vga.write("  System:\n");
    vga.write("    help          Show this help\n");
    vga.write("    info          Basic system info\n");
    vga.write("    sysinfo       Extended system info + PCI\n");
    vga.write("    mem           Memory map + PMM stats\n");
    vga.write("    ps            Process/task list\n");
    vga.write("    clear/cls     Clear screen\n");
    vga.write("    halt          Halt system\n");
    vga.write("    reboot        Reboot\n\n");
    vga.write("  Environment:\n");
    vga.write("    set K=V       Set environment variable\n");
    vga.write("    unset K       Remove environment variable\n");
    vga.write("    env           List all variables\n\n");
    vga.write("  Programs:\n");
    vga.write("    calc          Calculator (a+b, a-b, a*b, a/b)\n");
    vga.write("    color         VGA color palette demo\n");
    vga.write("    clock         Real-time clock\n");
    vga.write("    fib           Fibonacci sequence (F0-F40)\n");
    vga.write("    matrix        Matrix rain animation\n");
    vga.write("    lua           Lua 5.x REPL interpreter\n\n");
    vga.write("  Network:\n");
    vga.write("    net           Network interface info\n");
    vga.write("    ping [ip]     Ping (default: gateway)\n");
    vga.write("    get <url>     Fetch URL (CLI web browser)\n\n");
    vga.write("  Keys: Tab=complete, Up/Down=history\n\n");
}

fn cmdSet(args: []const u8) void {
    if (args.len == 0) {
        cmdEnv();
        return;
    }
    var eq_pos: ?usize = null;
    for (args, 0..) |ch, i| {
        if (ch == '=') {
            eq_pos = i;
            break;
        }
    }
    if (eq_pos == null) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: set KEY=VALUE\n");
        vga.setColor(.white, .black);
        return;
    }
    const ep = eq_pos.?;
    const key = args[0..ep];
    const val = args[ep + 1 ..];

    for (&env_store) |*entry| {
        if (entry.used and eql(entry.key[0..entry.key_len], key)) {
            const vlen = @min(val.len, ENV_VAL_MAX);
            @memcpy(entry.value[0..vlen], val[0..vlen]);
            entry.value_len = vlen;
            return;
        }
    }
    for (&env_store) |*entry| {
        if (!entry.used) {
            const klen = @min(key.len, ENV_KEY_MAX);
            const vlen = @min(val.len, ENV_VAL_MAX);
            @memcpy(entry.key[0..klen], key[0..klen]);
            entry.key_len = klen;
            @memcpy(entry.value[0..vlen], val[0..vlen]);
            entry.value_len = vlen;
            entry.used = true;
            return;
        }
    }
    vga.setColor(.light_red, .black);
    vga.write("  Environment full\n");
    vga.setColor(.white, .black);
}

fn cmdUnset(args: []const u8) void {
    if (args.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: unset KEY\n");
        vga.setColor(.white, .black);
        return;
    }
    for (&env_store) |*entry| {
        if (entry.used and eql(entry.key[0..entry.key_len], args)) {
            entry.used = false;
            return;
        }
    }
}

fn cmdEnv() void {
    var found = false;
    for (env_store) |entry| {
        if (entry.used) {
            vga.setColor(.light_cyan, .black);
            vga.write("  ");
            vga.write(entry.key[0..entry.key_len]);
            vga.setColor(.white, .black);
            vga.write("=");
            vga.setColor(.yellow, .black);
            vga.write(entry.value[0..entry.value_len]);
            vga.setColor(.white, .black);
            vga.putChar('\n');
            found = true;
        }
    }
    if (!found) {
        vga.write("  No environment variables set\n");
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn historyPush(cmd: []const u8) void {
    if (cmd.len == 0) return;
    const idx = history_count % HISTORY_SIZE;
    const copy_len = @min(cmd.len, CMD_MAX - 1);
    @memcpy(history[idx][0..copy_len], cmd[0..copy_len]);
    history_len[idx] = copy_len;
    history_count += 1;
    history_pos = -1;
}

fn historyGet(idx: i32) ?[]const u8 {
    if (history_count == 0) return null;
    const total: i32 = @intCast(history_count);
    const max: i32 = @intCast(@min(history_count, HISTORY_SIZE));
    if (idx < 0 or idx >= max) return null;
    const raw = total - 1 - idx;
    const real: usize = @intCast(@as(u64, @intCast(raw)) % HISTORY_SIZE);
    return history[real][0..history_len[real]];
}

fn clearLine(len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        vga.putChar(0x08);
        vga.putChar(' ');
        vga.putChar(0x08);
    }
}

fn printStr(s: []const u8) void {
    for (s) |ch| {
        vga.putChar(ch);
    }
}

fn tabComplete(buf: []u8, len: usize) usize {
    if (len == 0) return len;
    const prefix = buf[0..len];

    var match_count: usize = 0;
    var last_match: []const u8 = "";
    for (commands) |cmd| {
        if (cmd.len >= prefix.len and eql(cmd[0..prefix.len], prefix)) {
            match_count += 1;
            last_match = cmd;
        }
    }

    if (match_count == 0) return len;

    if (match_count == 1) {
        clearLine(len);
        const copy_len = @min(last_match.len, CMD_MAX - 1);
        @memcpy(buf[0..copy_len], last_match[0..copy_len]);
        printStr(last_match);
        return copy_len;
    }

    var common_len: usize = last_match.len;
    for (commands) |cmd| {
        if (cmd.len >= prefix.len and eql(cmd[0..prefix.len], prefix)) {
            var k: usize = prefix.len;
            while (k < common_len and k < cmd.len) : (k += 1) {
                if (cmd[k] != last_match[k]) {
                    common_len = k;
                    break;
                }
            }
            if (cmd.len < common_len) common_len = cmd.len;
            last_match = cmd;
        }
    }

    if (common_len > prefix.len) {
        clearLine(len);
        const copy_len = @min(common_len, CMD_MAX - 1);
        @memcpy(buf[0..copy_len], prefix[0..copy_len]);
        printStr(buf[0..copy_len]);
        return copy_len;
    }

    vga.putChar('\n');
    for (commands) |cmd| {
        if (cmd.len >= prefix.len and eql(cmd[0..prefix.len], prefix)) {
            vga.setColor(.light_cyan, .black);
            vga.write("  ");
            vga.write(cmd);
            vga.setColor(.white, .black);
            vga.write("  ");
        }
    }
    vga.putChar('\n');
    vga.setColor(.light_green, .black);
    vga.write("zig> ");
    vga.setColor(.white, .black);
    printStr(buf[0..len]);
    return len;
}

fn readLineEnhanced(buf: []u8, max_len: usize) usize {
    var pos: usize = 0;
    history_pos = -1;
    while (pos < max_len) {
        if (kb.pollKey()) |ch| {
            if (ch == '\n' or ch == '\r') {
                vga.putChar('\n');
                return pos;
            } else if (ch == 0x08) {
                if (pos > 0) {
                    pos -= 1;
                    vga.putChar(0x08);
                    vga.putChar(' ');
                    vga.putChar(0x08);
                }
            } else if (ch == kb.KEY_UP) {
                const max_hist: i32 = @intCast(@min(history_count, HISTORY_SIZE));
                if (history_pos < max_hist - 1) {
                    history_pos += 1;
                    const maybe_cmd = historyGet(history_pos);
                    if (maybe_cmd) |cmd| {
                        clearLine(pos);
                        const copy_len = @min(cmd.len, max_len - 1);
                        @memcpy(buf[0..copy_len], cmd[0..copy_len]);
                        printStr(buf[0..copy_len]);
                        pos = copy_len;
                    }
                }
            } else if (ch == kb.KEY_DOWN) {
                if (history_pos > 0) {
                    history_pos -= 1;
                    const maybe_cmd = historyGet(history_pos);
                    if (maybe_cmd) |cmd| {
                        clearLine(pos);
                        const copy_len = @min(cmd.len, max_len - 1);
                        @memcpy(buf[0..copy_len], cmd[0..copy_len]);
                        printStr(buf[0..copy_len]);
                        pos = copy_len;
                    }
                } else if (history_pos == 0) {
                    history_pos = -1;
                    clearLine(pos);
                    pos = 0;
                }
            } else if (ch == kb.KEY_TAB) {
                pos = tabComplete(buf, pos);
            } else if (ch >= 0x20 and ch < 0x7F) {
                buf[pos] = ch;
                pos += 1;
                vga.putChar(ch);
            }
        } else {
            asm volatile ("hlt");
        }
    }
    return pos;
}

const port_io = @import("arch/port.zig");
