const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;
const kb = @import("drivers/keyboard.zig");
const timer = @import("drivers/timer.zig");
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
// const lua_prog = @import("programs/lua.zig");

var cmd_buf: [128]u8 = undefined;

pub fn run() void {
    kb.init();
    timer.init();

    port.serialWrite("[SHELL] Timer and keyboard IRQ registered\n");

    pci.scan();
    port.serialWrite("[SHELL] PCI scanned, ");
    port.serialWriteDec(pci.device_count);
    port.serialWrite(" devices\n");

    if (pci.findByClass(0x02, 0x00)) |dev| {
        port.serialWrite("[SHELL] Found network device\n");
        _ = e1000.init(dev);
        net.init();
    }

    root.scheduler_ready = true;
    port.serialWrite("[SHELL] Scheduler enabled\n");

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

        const len = kb.readLine(&cmd_buf, 128);
        if (len == 0) continue;

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
    } else if (eql(cmd_name, "matrix")) {
        matrix.run();
        vga.clear();
        printBanner();
    } else if (eql(cmd_name, "clear") or eql(cmd_name, "cls")) {
        vga.clear();
    } else if (eql(cmd_name, "halt")) {
        vga.setColor(.light_red, .black);
        vga.write("\n  System halted.\n");
        port.serialWrite("\n[BOOT] System halted by user.\n");
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
    vga.write("  Programs:\n");
    vga.write("    calc          Calculator (a+b, a-b, a*b, a/b)\n");
    vga.write("    color         VGA color palette demo\n");
    vga.write("    clock         Real-time clock\n");
    vga.write("    fib           Fibonacci sequence (F0-F40)\n");
    vga.write("    matrix        Matrix rain animation\n\n");
    vga.write("  Network:\n");
    vga.write("    net           Network interface info\n");
    vga.write("    ping [ip]     Ping (default: gateway)\n");
    vga.write("    get <url>     Fetch URL (CLI web browser)\n\n");
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

const port_io = @import("arch/port.zig");
