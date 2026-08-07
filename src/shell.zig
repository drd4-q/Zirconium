const std = @import("std");
const root = @import("root");
const vga = root.vga;
const kb = @import("drivers/keyboard.zig");
const mouse = @import("drivers/mouse.zig");
const pci = @import("drivers/pci.zig");
const e1000 = @import("drivers/e1000.zig");
const net = @import("net/mod.zig");
const vga_fb = @import("system/framebuffer.zig");

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
const arp_cache = @import("net/arp_cache.zig");
const dhcp_mod = @import("net/dhcp.zig");
const dns_mod = @import("net/dns.zig");
const files = @import("programs/files.zig");
const vfs = @import("fs/vfs.zig");

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
    "lua",   "user",    "exec",    "save", "ping", "net",  "get",  "wget",
    "set",   "unset",   "env",     "mouse","resolution",
    "dhcp",  "arpcache","nslookup",
    "ls",    "cat",     "touch",   "mkdir","rm",  "write", "cd",
    "mount",
};

var cmd_buf: [CMD_MAX]u8 = undefined;

pub fn run() void {
    kb.init();

    pci.scan();

    if (pci.findByClass(0x02, 0x00)) |dev| {
        _ = e1000.init(dev);
        net.init();
    }

    // Try to init virtio-blk disk
    @import("drivers/virtio_blk.zig").init();

    // Auto-mount FAT16 if block device available
    @import("fs/fat16.zig").init();

    mouse.init();

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
    vga.write("  ____                _                   \n");
    vga.write(" |  _ \\  ___  ___ ___| |_ _  _ _ __ ___  \n");
    vga.write(" | | | |/ _ \\/ __/ _ \\  _| || | '_ ` _ \\ \n");
    vga.write(" | |_| |  __/ (_|  __/ | | || | | | | | |\n");
    vga.write(" |____/ \\___|\\___\\___|\\__|\\_,_|_| |_| |_|\n");
    vga.setColor(.white, .black);
    vga.write("\n  Zirconium v0.2.0 — Bare-metal x86_64\n");
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
    } else if (eql(cmd_name, "exec")) {
        cmdExec(args);
    } else if (eql(cmd_name, "save")) {
        cmdSave(args);
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
    } else if (eql(cmd_name, "mouse")) {
        showMouse();
    } else if (eql(cmd_name, "resolution")) {
        cmdResolution(args);
    } else if (eql(cmd_name, "dhcp")) {
        dhcp_mod.run();
    } else if (eql(cmd_name, "arpcache")) {
        arp_cache.printCache();
    } else if (eql(cmd_name, "nslookup")) {
        cmdNslookup(args);
    } else if (eql(cmd_name, "ls")) {
        files.cmdLs(args);
    } else if (eql(cmd_name, "cat")) {
        files.cmdCat(args);
    } else if (eql(cmd_name, "touch")) {
        files.cmdTouch(args);
    } else if (eql(cmd_name, "mkdir")) {
        files.cmdMkdir(args);
    } else if (eql(cmd_name, "rm")) {
        files.cmdRm(args);
    } else if (eql(cmd_name, "write")) {
        files.cmdWrite(args);
    } else if (eql(cmd_name, "cd")) {
        files.cmdCd(args);
    } else if (eql(cmd_name, "mount")) {
        vfs.printMounts();
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

fn showMouse() void {
    vga.setColor(.cyan, .black);
    vga.write("\n  === Mouse Info ===\n\n");
    vga.setColor(.white, .black);

    if (!mouse.ready) {
        vga.write("  Mouse not initialized\n\n");
        return;
    }

    vga.write("  Position: (");
    if (mouse.mx < 0) {
        vga.putChar('-');
        vga.writeDec(@as(u64, @intCast(-mouse.mx)));
    } else {
        vga.writeDec(@as(u64, @intCast(mouse.mx)));
    }
    vga.write(", ");
    if (mouse.my < 0) {
        vga.putChar('-');
        vga.writeDec(@as(u64, @intCast(-mouse.my)));
    } else {
        vga.writeDec(@as(u64, @intCast(mouse.my)));
    }
    vga.write(")\n");

    vga.write("  Buttons: L=");
    vga.write(if (mouse.left_button) "ON" else "off");
    vga.write("  R=");
    vga.write(if (mouse.right_button) "ON" else "off");
    vga.write("  M=");
    vga.write(if (mouse.middle_button) "ON" else "off");
    vga.write("\n");

    vga.write("  Delta: dx=");
    if (mouse.dx < 0) {
        vga.putChar('-');
        vga.writeDec(@as(u64, @intCast(-mouse.dx)));
    } else {
        vga.writeDec(@as(u64, @intCast(mouse.dx)));
    }
    vga.write(" dy=");
    if (mouse.dy < 0) {
        vga.putChar('-');
        vga.writeDec(@as(u64, @intCast(-mouse.dy)));
    } else {
        vga.writeDec(@as(u64, @intCast(mouse.dy)));
    }
    vga.write("\n\n");
}

fn cmdResolution(args: []const u8) void {
    if (!vga.isFbActive()) {
        vga.setColor(.light_red, .black);
        vga.write("  Framebuffer not available. Only VGA text mode.\n");
        vga.setColor(.white, .black);
        return;
    }

    if (args.len == 0) {
        vga.setColor(.cyan, .black);
        vga.write("\n  === Resolution ===\n\n");
        vga.setColor(.white, .black);
        vga.write("  Current: ");
        vga.writeDec(vga_fb.fb_width);
        vga.write("x");
        vga.writeDec(vga_fb.fb_height);
        vga.write(" (");
        vga.writeDec(vga_fb.cols);
        vga.write("x");
        vga.writeDec(vga_fb.rows);
        vga.write(" chars)\n\n");
        vga.write("  Usage: resolution <width>x<height>\n");
        vga.write("  Examples:\n");
        vga.write("    resolution 640x480\n");
        vga.write("    resolution 800x600\n");
        vga.write("    resolution 1024x768\n");
        vga.write("    resolution 1280x720\n\n");
        return;
    }

    // Parse WxH
    var w: u32 = 0;
    var h: u32 = 0;
    var found_x = false;
    for (args) |ch| {
        if (ch == 'x' or ch == 'X') {
            found_x = true;
        } else if (ch >= '0' and ch <= '9') {
            if (!found_x) {
                w = w * 10 + @as(u32, ch - '0');
            } else {
                h = h * 10 + @as(u32, ch - '0');
            }
        }
    }

    if (w == 0 or h == 0 or !found_x) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: resolution <width>x<height>\n");
        vga.setColor(.white, .black);
        return;
    }

    vga.setResolution(w, h);
    vga.clear();
    vga.setColor(.light_green, .black);
    vga.write("  Resolution: ");
    vga.writeDec(w);
    vga.write("x");
    vga.writeDec(h);
    vga.write(" (");
    vga.writeDec(vga_fb.cols);
    vga.write("x");
    vga.writeDec(vga_fb.rows);
    vga.write(" chars)\n");
    vga.setColor(.white, .black);
}

fn cmdNslookup(args: []const u8) void {
    if (args.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: nslookup <hostname>\n");
        vga.setColor(.white, .black);
        return;
    }

    if (dns_mod.resolve(args)) |ip| {
        vga.setColor(.light_green, .black);
        vga.write("  ");
        vga.write(args);
        vga.write(" -> ");
        net.printIp(ip);
        vga.write("\n");
        vga.setColor(.white, .black);
    } else {
        vga.setColor(.light_red, .black);
        vga.write("  Failed to resolve ");
        vga.write(args);
        vga.write("\n");
        vga.setColor(.white, .black);
    }
}

fn cmdExec(args: []const u8) void {
    if (args.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: exec <path>\n");
        vga.setColor(.white, .black);
        return;
    }

    const sched = root.scheduler;
    vga.setColor(.light_cyan, .black);
    vga.write("[SHELL] exec: loading ");
    vga.write(args);
    vga.write("\n");
    vga.setColor(.white, .black);

    // Create a user task that loads from the ramfs path
    if (sched.addUserTaskFromPath(args)) |task_id| {
        _ = task_id;
        sched.runAll();
    } else {
        vga.write("[SHELL] Error: failed to exec ");
        vga.write(args);
        vga.write("\n");
    }
}

fn cmdSave(args: []const u8) void {
    const path = if (args.len == 0) "/bin/user_test" else args;

    const user_test_bin = @import("user_test_bin");

    vga.setColor(.light_cyan, .black);
    vga.write("[SHELL] Saving user binary to ");
    vga.write(path);
    vga.write("...\n");
    vga.setColor(.white, .black);

    // Ensure parent directory exists
    var dir_end: usize = path.len;
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') {
            dir_end = i - 1;
            break;
        }
    }
    if (dir_end > 0) {
        _ = vfs.mkdir(path[0..dir_end]);
    }

    const handle = vfs.open(path, .{ .create = true, .truncate = true, .write = true }) orelse {
        vga.write("[SHELL] Error: failed to create file\n");
        return;
    };
    defer vfs.close(handle);

    const written = vfs.write(handle, &user_test_bin.data);
    vga.setColor(.green, .black);
    vga.write("[SHELL] Saved ");
    vga.writeDec(written);
    vga.write(" bytes\n");
    vga.setColor(.white, .black);
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
    vga.write("    lua           Lua 5.x REPL interpreter\n");
    vga.write("    user          Run compiled-in user ELF\n");
    vga.write("    save [path]   Save user binary to ramfs\n");
    vga.write("    exec <path>   Run ELF from ramfs path\n\n");
    vga.write("  Network:\n");
    vga.write("    net           Network interface info\n");
    vga.write("    ping [ip]     Ping (default: gateway)\n");
    vga.write("    get <url>     Fetch URL (CLI web browser)\n");
    vga.write("    dhcp          Auto-configure IP via DHCP\n");
    vga.write("    arpcache      Show ARP cache table\n");
    vga.write("    nslookup <h>  DNS lookup\n\n");
    vga.write("  Filesystem:\n");
    vga.write("    ls [path]     List directory\n");
    vga.write("    cat <file>    Print file contents\n");
    vga.write("    touch <file>  Create empty file\n");
    vga.write("    mkdir <dir>   Create directory\n");
    vga.write("    rm <file>     Remove file\n");
    vga.write("    write <f> <t> Write text to file\n");
    vga.write("    cd [path]     Change directory\n");
    vga.write("    mount         List mounted filesystems\n\n");
    vga.write("  Input:\n");
    vga.write("    mouse         Show mouse info\n");
    vga.write("    resolution    Change screen resolution (framebuffer)\n\n");
    vga.write("  Keys: Tab=complete, Up/Down=history, PgUp/PgDn=scroll\n\n");
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
            } else if (ch == kb.KEY_PAGE_UP) {
                if (vga_fb.active) {
                    vga_fb.scrollBack(vga_fb.rows - 1);
                } else {
                    vga.scrollBackText(vga.getRows() - 1);
                }
            } else if (ch == kb.KEY_PAGE_DOWN) {
                if (vga_fb.active) {
                    vga_fb.scrollForward(vga_fb.rows - 1);
                } else {
                    vga.scrollForwardText(vga.getRows() - 1);
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
