const std = @import("std");
const root = @import("root");
const vga = root.vga;
const kb = @import("drivers/keyboard.zig");
const mouse = @import("drivers/mouse.zig");
const pci = @import("drivers/pci.zig");
const net = @import("net/mod.zig");
const vga_fb = @import("system/framebuffer.zig");
const gui = @import("system/gui.zig");

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
const nano_prog = @import("programs/nano.zig");
const vfs = @import("fs/vfs.zig");
const smp = @import("arch/smp.zig");
const acpi = @import("arch/acpi.zig");
const usb_prog = @import("programs/usb.zig");
const dillo_prog = @import("programs/dillo.zig");

const HISTORY_SIZE: usize = 16;
const CMD_MAX: usize = 128;
var history: [HISTORY_SIZE][CMD_MAX]u8 = undefined;
var history_len: [HISTORY_SIZE]usize = undefined;
var history_count: usize = 0;
var history_pos: i32 = -1;

const env = @import("system/env.zig");
const fat16 = @import("fs/fat16.zig");
const timer = @import("drivers/timer.zig");

/// A shell command: name plus a uniform handler that receives everything
/// typed after the name. This table is the single source of truth for both
/// dispatch and tab completion.
const CmdEntry = struct {
    name: []const u8,
    run: *const fn (args: []const u8) void,
};

const command_table = [_]CmdEntry{
    .{ .name = "help",       .run = printHelp },
    .{ .name = "info",       .run = runInfo },
    .{ .name = "sysinfo",    .run = runSysinfo },
    .{ .name = "mem",        .run = runMem },
    .{ .name = "ps",         .run = showPs },
    .{ .name = "clear",      .run = cmdClear },
    .{ .name = "cls",        .run = cmdClear },
    .{ .name = "halt",       .run = cmdHalt },
    .{ .name = "reboot",     .run = cmdReboot },
    .{ .name = "calc",       .run = runCalc },
    .{ .name = "color",      .run = runColor },
    .{ .name = "clock",      .run = runClock },
    .{ .name = "fib",        .run = runFib },
    .{ .name = "matrix",     .run = cmdMatrix },
    .{ .name = "lua",        .run = cmdLua },
    .{ .name = "user",       .run = cmdUser },
    .{ .name = "exec",       .run = cmdExec },
    .{ .name = "save",       .run = cmdSave },
    .{ .name = "ping",       .run = ping_mod.run },
    .{ .name = "net",        .run = runNet },
    .{ .name = "get",        .run = web.run },
    .{ .name = "wget",       .run = web.run },
    .{ .name = "dillo",      .run = dillo_prog.run },
    .{ .name = "echo",       .run = cmdEcho },
    .{ .name = "set",        .run = cmdSet },
    .{ .name = "unset",      .run = cmdUnset },
    .{ .name = "env",        .run = cmdEnv },
    .{ .name = "mouse",      .run = showMouse },
    .{ .name = "resolution", .run = cmdResolution },
    .{ .name = "gui",        .run = cmdGui },
    .{ .name = "dhcp",       .run = runDhcp },
    .{ .name = "arpcache",   .run = runArpcache },
    .{ .name = "nslookup",   .run = cmdNslookup },
    .{ .name = "smp",        .run = showSmp },
    .{ .name = "cpuinfo",    .run = showSmp },
    .{ .name = "usb",        .run = runUsb },
    .{ .name = "lsusb",      .run = runUsb },
    .{ .name = "acpi",       .run = showAcpi },
    .{ .name = "ls",         .run = files.cmdLs },
    .{ .name = "cat",        .run = files.cmdCat },
    .{ .name = "touch",      .run = files.cmdTouch },
    .{ .name = "mkdir",      .run = files.cmdMkdir },
    .{ .name = "rm",         .run = files.cmdRm },
    .{ .name = "write",      .run = files.cmdWrite },
    .{ .name = "cd",         .run = files.cmdCd },
    .{ .name = "cp",         .run = files.cmdCopy },
    .{ .name = "hexdump",    .run = files.cmdHexdump },
    .{ .name = "mkfs",       .run = runMkfs },
    .{ .name = "df",         .run = runDf },
    .{ .name = "uptime",     .run = runUptime },
    .{ .name = "mount",      .run = runMount },
    .{ .name = "nano",       .run = cmdNano },
};

var cmd_buf: [CMD_MAX]u8 = undefined;

pub fn run() void {
    root.serial.serialWrite("[SHELL] run: enter\n");
    kb.init();
    root.serial.serialWrite("[SHELL] run: keyboard ready\n");

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
        // Mirror the prompt over serial: it is the handshake marker for
        // headless automation driving the console through QEMU stdio.
        root.serial.serialWrite("\n[SERIAL] zirc> ");

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
    vga.write("\n  Zirconium v0.3.0 — Bare-metal x86_64\n");
    vga.write("  Type 'help' for commands.\n\n");
}

fn execute(cmd: []const u8) void {
    if (cmd.len == 0) return;

    // $KEY references are expanded once for the whole line, so both builtin
    // arguments and foreign program paths/args see environment values.
    const line = expandVars(cmd);

    var cmd_end: usize = line.len;
    var args_start: usize = line.len;
    for (line, 0..) |ch, i| {
        if (ch == ' ') {
            cmd_end = i;
            args_start = i + 1;
            break;
        }
    }

    const cmd_name = line[0..cmd_end];
    const args = if (args_start < line.len) line[args_start..] else "";

    for (command_table) |entry| {
        if (eql(entry.name, cmd_name)) {
            entry.run(args);
            return;
        }
    }

    // Not a builtin: try to execute it as a program from the filesystem.
    // The whole line is passed as the arg string so its first token stays
    // argv[0] for the spawned program.
    if (execFromPath(cmd_name, line)) return;

    vga.setColor(.light_red, .black);
    vga.write("  Unknown command: '");
    vga.write(cmd_name);
    vga.write("'\n");
    vga.setColor(.white, .black);
    vga.write("  Type 'help' for available commands.\n");
}

// Adapters for zero-argument program entry points.
fn runInfo(_: []const u8) void {
    info.run();
}
fn runSysinfo(_: []const u8) void {
    sysinfo.run();
}
fn runMem(_: []const u8) void {
    mem_mod.run();
}
fn runCalc(_: []const u8) void {
    calc.run();
}
fn runColor(_: []const u8) void {
    color.run();
}
fn runClock(_: []const u8) void {
    clock_mod.run();
}
fn runFib(_: []const u8) void {
    fib.run();
}
fn runNet(_: []const u8) void {
    netinfo.run();
}
fn runDhcp(_: []const u8) void {
    dhcp_mod.run();
}
fn runArpcache(_: []const u8) void {
    arp_cache.printCache();
}
fn runUsb(_: []const u8) void {
    usb_prog.run();
}
fn runMount(_: []const u8) void {
    vfs.printMounts();
}

/// mkfs — reformat /mnt/disk as a blank FAT16 volume (destroys contents).
fn runMkfs(_: []const u8) void {
    vga.write("  Formatting /mnt/disk as FAT16...\n");
    if (fat16.isMounted()) {
        vga.write("  Unmounting existing filesystem\n");
        _ = @import("fs/vfs.zig").unmount("/mnt/disk");
        fat16.resetMountState();
    }
    if (fat16.format()) {
        vga.write("  Done. Disk is mounted and empty.\n");
    } else {
        vga.setColor(.light_red, .black);
        vga.write("  mkfs failed\n");
        vga.setColor(.white, .black);
    }
}

/// df — disk usage summary for the FAT16 volume.
fn runDf(_: []const u8) void {
    fat16.printInfo();
}

/// uptime — time since kernel boot from PIT ticks.
fn runUptime(_: []const u8) void {
    const ticks = timer.ticks;
    const total_secs = ticks / 100;
    const days = total_secs / 86400;
    const hours = (total_secs % 86400) / 3600;
    const mins = (total_secs % 3600) / 60;
    const secs = total_secs % 60;

    vga.write("  up ");
    if (days > 0) {
        vga.writeDec(days);
        vga.write(" days, ");
    }
    if (hours < 10) vga.putChar('0');
    vga.writeDec(hours);
    vga.putChar(':');
    if (mins < 10) vga.putChar('0');
    vga.writeDec(mins);
    vga.putChar(':');
    if (secs < 10) vga.putChar('0');
    vga.writeDec(secs);
    vga.write("  (");
    vga.writeDec(ticks);
    vga.write(" ticks)\n");
}

// Programs that take over the screen and return to a fresh banner on exit.
fn cmdLua(_: []const u8) void {
    lua_prog.run();
    vga.clear();
    printBanner();
}
fn cmdMatrix(_: []const u8) void {
    matrix.run();
    vga.clear();
    printBanner();
}
fn cmdGui(_: []const u8) void {
    gui.run();
    vga.clear();
    printBanner();
}
fn cmdNano(args: []const u8) void {
    vga.clear();
    nano_prog.run(args);
    vga.clear();
    printBanner();
}

// System commands.
fn cmdClear(_: []const u8) void {
    vga.clear();
}

/// echo [-n] text... — print text; $KEY references are already expanded by
/// the time arguments reach this handler.
fn cmdEcho(args: []const u8) void {
    var rest = args;
    var newline = true;
    if (rest.len >= 2 and rest[0] == '-' and rest[1] == 'n') {
        newline = false;
        rest = rest[2..];
        while (rest.len > 0 and rest[0] == ' ') : (rest = rest[1..]) {}
    }
    vga.write(rest);
    if (newline) vga.putChar('\n');
}
fn cmdHalt(_: []const u8) void {
    vga.setColor(.light_red, .black);
    vga.write("\n  System halted.\n");
    root.serial.serialWrite("\n[BOOT] System halted by user.\n");
    while (true) {
        asm volatile ("cli; hlt");
    }
}
fn cmdReboot(_: []const u8) void {
    vga.setColor(.yellow, .black);
    vga.write("\n  Rebooting...\n");
    port_io.outb(0x92, 0x03);
    while (true) {
        asm volatile ("cli; hlt");
    }
}

/// Spawn the compiled-in ring 3 test ELF and run it to completion.
fn cmdUser(_: []const u8) void {
    const sched = root.scheduler;
    const user_test_bin = @import("user_test_bin");
    vga.write("[SHELL] Spawning user-space ELF task...\n");
    if (sched.spawnProgramImage(&user_test_bin.data, "user_test")) |task_id| {
        sched.runTask(task_id);
    } else |err| {
        vga.write("[SHELL] Error: failed to spawn user task: ");
        vga.write(@errorName(err));
        vga.write("\n");
    }
}

/// Resolve a raw path/name against the VFS search paths and run it.
/// Returns false if it could not be resolved or spawned.
fn execFromPath(raw_path: []const u8, args: []const u8) bool {
    const resolved_path = resolveExecutablePath(raw_path) orelse {
        vga.setColor(.light_red, .black);
        vga.write("[SHELL] Error: file not found: ");
        vga.write(raw_path);
        vga.write("\n");
        vga.setColor(.white, .black);
        root.serial.serialWrite("[SHELL] file not found: ");
        root.serial.serialWrite(raw_path);
        root.serial.serialWrite("\n");
        return false;
    };
    return spawnAndRun(resolved_path, args);
}

/// Print the "Executing ..." banner, spawn a program image and run it to
/// completion. Shared by the exec command and bare-name execution.
fn spawnAndRun(path: []const u8, args: []const u8) bool {
    vga.setColor(.light_cyan, .black);
    vga.write("[SHELL] Executing ");
    vga.write(path);
    vga.write("...\n");
    vga.setColor(.white, .black);

    const sched = root.scheduler;
    const task_id = sched.spawnProgram(path, args) catch |err| {
        vga.setColor(.light_red, .black);
        vga.write("[SHELL] Error: failed to spawn '");
        vga.write(path);
        vga.write("': ");
        vga.write(@errorName(err));
        vga.write("\n");
        vga.setColor(.white, .black);
        root.serial.serialWrite("[SHELL] spawn failed: ");
        root.serial.serialWrite(path);
        root.serial.serialWrite(": ");
        root.serial.serialWrite(@errorName(err));
        root.serial.serialWrite("\n");
        return false;
    };
    sched.runTask(task_id);
    return true;
}

fn showPs(_: []const u8) void {
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

fn showSmp(_: []const u8) void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== SMP / CPU ===\n\n");
    vga.setColor(.white, .black);
    vga.write("  CPUs (ACPI):   ");
    vga.writeDec(smp.cpuCount());
    vga.write("\n  BSP LAPIC ID:  ");
    vga.writeDec(smp.getLapicId());
    vga.write("\n  APs online:    ");
    vga.writeDec(smp.cpuOnline());
    vga.write("\n");

    var i: usize = 0;
    while (i < acpi.MAX_CPU) : (i += 1) {
        if (smp.online_flags[i]) {
            vga.write("  CPU #");
            vga.writeDec(i);
            vga.write(": ONLINE, idle ticks = ");
            vga.writeDec(smp.ap_ticks[i]);
            vga.write("\n");
        }
    }
    vga.write("\n");
}

fn pad(n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        vga.putChar(' ');
    }
}

fn showAcpi(_: []const u8) void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== ACPI ===\n\n");
    vga.setColor(.white, .black);
    if (acpi.rsdp_address == 0) {
        vga.write("  RSDP: not found\n");
    } else {
        vga.write("  RSDP: 0x");
        vga.writeHexShort(acpi.rsdp_address);
        vga.write("\n  LAPIC base: 0x");
        vga.writeHexShort(@intCast(acpi.lapic_base));
        vga.write("\n");
    }
    var i: usize = 0;
    while (i < acpi.cpu_count) : (i += 1) {
        vga.write("  CPU ");
        vga.writeDec(i);
        vga.write(" LAPIC ID: ");
        vga.writeDec(acpi.lapic_ids[i]);
        vga.write("\n");
    }
    vga.write("\n");
}

fn showMouse(_: []const u8) void {
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

var resolved_path_buf: [256]u8 = undefined;

fn resolveExecutablePath(raw: []const u8) ?[]const u8 {
    if (raw.len == 0 or raw.len >= 200) return null;

    // 1. Direct path as provided
    if (vfs.stat(raw)) |st| {
        if (st.file_type != .directory) return raw;
    }

    // 2. Absolute paths skip the search-path prefixes below, but still get
    //    the ".exe" fallback in step 5 (e.g. /mnt/disk/jq -> jq.exe).

    // 3. Try /bin/<raw>
    const bin_prefix = "/bin/";
    @memcpy(resolved_path_buf[0..bin_prefix.len], bin_prefix);
    @memcpy(resolved_path_buf[bin_prefix.len..][0..raw.len], raw);
    const bin_len = bin_prefix.len + raw.len;
    const bin_cand = resolved_path_buf[0..bin_len];
    if (vfs.stat(bin_cand)) |st| {
        if (st.file_type != .directory) return bin_cand;
    }

    // 4. Try /mnt/disk/<raw>
    const disk_prefix = "/mnt/disk/";
    @memcpy(resolved_path_buf[0..disk_prefix.len], disk_prefix);
    @memcpy(resolved_path_buf[disk_prefix.len..][0..raw.len], raw);
    const disk_len = disk_prefix.len + raw.len;
    const disk_cand = resolved_path_buf[0..disk_len];
    if (vfs.stat(disk_cand)) |st| {
        if (st.file_type != .directory) return disk_cand;
    }

    // 5. If no extension, try with .exe
    var has_ext = false;
    for (raw) |ch| {
        if (ch == '.') has_ext = true;
    }
    if (!has_ext and raw.len + 4 < 200) {
        // Try <raw>.exe
        @memcpy(resolved_path_buf[0..raw.len], raw);
        @memcpy(resolved_path_buf[raw.len..][0..4], ".exe");
        const exe_cand = resolved_path_buf[0 .. raw.len + 4];
        if (vfs.stat(exe_cand)) |st| {
            if (st.file_type != .directory) return exe_cand;
        }

        // Try /bin/<raw>.exe
        @memcpy(resolved_path_buf[0..bin_prefix.len], bin_prefix);
        @memcpy(resolved_path_buf[bin_prefix.len..][0..raw.len], raw);
        @memcpy(resolved_path_buf[bin_prefix.len + raw.len ..][0..4], ".exe");
        const bin_exe_cand = resolved_path_buf[0 .. bin_prefix.len + raw.len + 4];
        if (vfs.stat(bin_exe_cand)) |st| {
            if (st.file_type != .directory) return bin_exe_cand;
        }

        // Try /mnt/disk/<raw>.exe
        @memcpy(resolved_path_buf[0..disk_prefix.len], disk_prefix);
        @memcpy(resolved_path_buf[disk_prefix.len..][0..raw.len], raw);
        @memcpy(resolved_path_buf[disk_prefix.len + raw.len ..][0..4], ".exe");
        const disk_exe_cand = resolved_path_buf[0 .. disk_prefix.len + raw.len + 4];
        if (vfs.stat(disk_exe_cand)) |st| {
            if (st.file_type != .directory) return disk_exe_cand;
        }
    }

    return null;
}

fn cmdExec(args: []const u8) void {
    if (args.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: exec <path> [args...]\n");
        vga.setColor(.white, .black);
        return;
    }

    var path_end: usize = args.len;
    for (args, 0..) |ch, i| {
        if (ch == ' ') {
            path_end = i;
            break;
        }
    }
    _ = execFromPath(args[0..path_end], args);
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

fn printHelp(_: []const u8) void {
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
    vga.write("    reboot        Reboot\n");
    vga.write("    uptime        Time since boot\n\n");
    vga.write("  Environment:\n");
    vga.write("    set K=V       Set environment variable\n");
    vga.write("    unset K       Remove environment variable\n");
    vga.write("    env           List all variables\n");
    vga.write("    echo [-n] t   Print text ($KEY expands to its value)\n\n");
    vga.write("  Programs:\n");
    vga.write("    calc          Calculator (a+b, a-b, a*b, a/b)\n");
    vga.write("    color         VGA color palette demo\n");
    vga.write("    clock         Real-time clock\n");
    vga.write("    fib           Fibonacci sequence (F0-F40)\n");
    vga.write("    matrix        Matrix rain animation\n");
    vga.write("    lua           Lua 5.x REPL interpreter\n");
    vga.write("    user          Run compiled-in user ELF\n");
    vga.write("    save [path]   Save user binary to ramfs\n");
    vga.write("    exec <path>   Run ELF or PE/EXE binary\n\n");
    vga.write("  Network:\n");
    vga.write("    net           Network interface info\n");
    vga.write("    ping [ip]     Ping (default: gateway)\n");
    vga.write("    get <url>     Fetch URL (CLI web browser)\n");
    vga.write("    dillo [url]   Dillo web browser (GUI / text)\n");
    vga.write("    dhcp          Auto-configure IP via DHCP\n");
    vga.write("    arpcache      Show ARP cache table\n");
    vga.write("    nslookup <h>  DNS lookup\n\n");
    vga.write("  CPU / Hardware:\n");
    vga.write("    smp/cpuinfo   SMP & per-CPU status\n");
    vga.write("    acpi          ACPI tables (RSDP, MADT)\n");
    vga.write("    usb/lsusb     USB controllers & devices status\n\n");
    vga.write("  Filesystem:\n");
    vga.write("    ls [path]     List directory\n");
    vga.write("    cat <file>    Print file contents\n");
    vga.write("    touch <file>  Create empty file\n");
    vga.write("    mkdir <dir>   Create directory\n");
    vga.write("    rm <file>     Remove file\n");
    vga.write("    cp <s> <d>    Copy file\n");
    vga.write("    write <f> <t> Write text to file\n");
    vga.write("    hexdump <f>   Hex+ASCII file viewer\n");
    vga.write("    cd [path]     Change directory\n");
    vga.write("    nano <file>   Nano-style text editor\n");
    vga.write("    df            Disk usage (FAT16)\n");
    vga.write("    mkfs          Reformat /mnt/disk as blank FAT16\n");
    vga.write("    mount         List mounted filesystems\n\n");
    vga.write("  Input:\n");
    vga.write("    mouse         Show mouse info\n");
    vga.write("    gui           Window manager demo (framebuffer)\n");
    vga.write("    resolution    Change screen resolution (framebuffer)\n\n");
    vga.write("  Keys: Tab=complete, Up/Down=history, PgUp/PgDn=scroll\n\n");
}

fn cmdSet(args: []const u8) void {
    if (args.len == 0) {
        cmdEnv("");
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
    if (!env.set(key, val)) {
        vga.setColor(.light_red, .black);
        vga.write("  Environment full\n");
        vga.setColor(.white, .black);
    }
}

fn cmdUnset(args: []const u8) void {
    if (args.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: unset KEY\n");
        vga.setColor(.white, .black);
        return;
    }
    env.unset(args);
}

fn cmdEnv(_: []const u8) void {
    var found = false;
    var i: usize = 0;
    while (i < env.maxEntries()) : (i += 1) {
        if (env.getAt(i)) |entry| {
            vga.setColor(.light_cyan, .black);
            vga.write("  ");
            vga.write(entry.key);
            vga.setColor(.white, .black);
            vga.write("=");
            vga.setColor(.yellow, .black);
            vga.write(entry.value);
            vga.setColor(.white, .black);
            vga.putChar('\n');
            found = true;
        }
    }
    if (!found) {
        vga.write("  No environment variables set\n");
    }
}

var expand_buf: [256]u8 = undefined;

/// Expand $KEY references using the environment table. `$` followed by a
/// non-name character is literal; unset names expand to nothing (sh rules).
/// The result lives in a static buffer and is valid until the next call.
fn expandVars(input: []const u8) []const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len and out < expand_buf.len) {
        if (input[i] == '$' and i + 1 < input.len and isNameChar(input[i + 1])) {
            var j = i + 1;
            while (j < input.len and isNameChar(input[j])) : (j += 1) {}
            if (env.get(input[i + 1 .. j])) |value| {
                for (value) |ch| {
                    if (out >= expand_buf.len) break;
                    expand_buf[out] = ch;
                    out += 1;
                }
            }
            i = j;
        } else {
            expand_buf[out] = input[i];
            out += 1;
            i += 1;
        }
    }
    return expand_buf[0..out];
}

fn isNameChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '_';
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
    for (command_table) |entry| {
        const cmd = entry.name;
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
    for (command_table) |entry| {
        const cmd = entry.name;
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
    for (command_table) |entry| {
        const cmd = entry.name;
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
        // Keyboard first, serial console second: the latter lets tests and
        // remote users drive the shell through QEMU -serial stdio.
        const ch = kb.pollKey() orelse serialPollKey() orelse {
            asm volatile ("hlt");
            continue;
        };
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
    }
    return pos;
}

/// Serial counterpart of kb.pollKey(): translates CR to LF and DEL to
/// backspace so terminal clients behave like the PS/2 keyboard.
fn serialPollKey() ?u8 {
    const raw = @import("system/serial.zig").pollRead() orelse return null;
    return switch (raw) {
        '\r' => '\n',
        0x7F => 0x08,
        else => raw,
    };
}

const port_io = @import("arch/port.zig");
