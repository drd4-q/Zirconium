//! Seed pseudo-filesystem content that real Linux programs expect to find.
//!
//! At boot this writes small static snapshots into the ramfs: /etc/os-release,
//! /etc/hostname and the classic /proc files (cpuinfo, meminfo, uptime,
//! loadavg, version) plus a couple of /sys DMI entries. Values come from the
//! live kernel state at boot time (PMM totals, CPUID brand, tick count), so
//! tools like fastfetch print plausible output instead of erroring out.
//!
//! Everything is a regular file — there is no dynamic procfs behind it.

const root = @import("root");
const serial = root.serial;
const vfs = @import("../fs/vfs.zig");
const pmm = @import("pmm.zig");
const scheduler = @import("scheduler.zig");
const timer = @import("../drivers/timer.zig");

fn writeFile(path: []const u8, contents: []const u8) void {
    const handle = vfs.open(path, .{ .create = true, .truncate = true, .write = true }) orelse {
        serial.serialWrite("[SEED] cannot create ");
        serial.serialWrite(path);
        serial.serialWrite("\n");
        return;
    };
    defer vfs.close(handle);
    _ = vfs.write(handle, contents);
}

/// CPUID leaves 0x80000002..0x80000004 processor brand string; returns the
/// printable length (0 when unsupported).
fn cpuBrand(buf: *[48]u8) usize {
    var max_ext: u32 = 0;
    asm volatile ("cpuid"
        : [eax] "={eax}" (max_ext)
        : [leaf] "{eax}" (@as(u32, 0x80000000))
        : .{ .ebx = true, .ecx = true, .edx = true }
    );
    if (max_ext < 0x80000004) return 0;

    const words: [*]align(1) u32 = @ptrCast(buf);
    var leaf: u32 = 0x80000002;
    while (leaf <= 0x80000004) : (leaf += 1) {
        var eax: u32 = undefined;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        var edx: u32 = undefined;
        asm volatile ("cpuid"
            : [a] "={eax}" (eax),
              [b] "={ebx}" (ebx),
              [c] "={ecx}" (ecx),
              [d] "={edx}" (edx)
            : [leaf] "{eax}" (leaf)
        );
        words[(leaf - 0x80000002) * 4 + 0] = eax;
        words[(leaf - 0x80000002) * 4 + 1] = ebx;
        words[(leaf - 0x80000002) * 4 + 2] = ecx;
        words[(leaf - 0x80000002) * 4 + 3] = edx;
    }
    // The brand string is NUL/space padded; find its printable length.
    var len: usize = 48;
    while (len > 0 and (buf[len - 1] == 0 or buf[len - 1] == ' ')) : (len -= 1) {}
    return len;
}

const Builder = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,

    fn add(self: *Builder, s: []const u8) void {
        for (s) |ch| {
            if (self.len >= self.buf.len) return;
            self.buf[self.len] = ch;
            self.len += 1;
        }
    }

    fn addDec(self: *Builder, v: u64) void {
        var tmp: [20]u8 = undefined;
        var n: usize = 0;
        if (v == 0) {
            tmp[0] = '0';
            n = 1;
        } else {
            var x = v;
            while (x > 0) : (x /= 10) {
                tmp[n] = '0' + @as(u8, @intCast(x % 10));
                n += 1;
            }
        }
        while (n > 0) : (n -= 1) {
            self.add(tmp[n - 1 .. n]);
        }
    }
};

pub fn init() void {
    // Parent directories first: ramfs has no auto-mkdir.
    _ = vfs.mkdir("/proc");
    _ = vfs.mkdir("/sys");
    _ = vfs.mkdir("/sys/class");
    _ = vfs.mkdir("/sys/class/dmi");
    _ = vfs.mkdir("/sys/class/dmi/id");

    // ---- /etc -------------------------------------------------------------
    writeFile("/etc/os-release",
        \\NAME="Zirconium"
        \\PRETTY_NAME="Zirconium OS"
        \\ID=zirconium
        \\
    );
    writeFile("/etc/hostname", "zirconium\n");

    // ---- /proc ------------------------------------------------------------
    writeFile("/proc/version", "Zirconium Kernel version 1.0.0-zirconium #1 SMP\n");

    const total_kib = pmm.total_pages * 4;
    const free_kib = pmm.free_pages * 4;

    var b = Builder{};
    b.add("MemTotal:       ");
    b.addDec(total_kib);
    b.add(" kB\nMemFree:        ");
    b.addDec(free_kib);
    b.add(" kB\nMemAvailable:   ");
    b.addDec(free_kib);
    b.add(" kB\n");
    writeFile("/proc/meminfo", b.buf[0..b.len]);

    b = .{};
    b.addDec(timer.ticks / 100);
    b.add(".00 0.00\n");
    writeFile("/proc/uptime", b.buf[0..b.len]);

    b = .{};
    b.add("0.00 0.00 0.00 ");
    b.addDec(scheduler.taskCount());
    b.add("/");
    b.addDec(scheduler.taskCount());
    b.add("\n");
    writeFile("/proc/loadavg", b.buf[0..b.len]);

    var brand_buf: [48]u8 = undefined;
    const brand_len = cpuBrand(&brand_buf);
    b = .{};
    b.add("processor\t: 0\nmodel name\t: ");
    b.add(if (brand_len > 0) brand_buf[0..brand_len] else "x86_64-compatible CPU");
    b.add("\n\n");
    writeFile("/proc/cpuinfo", b.buf[0..b.len]);

    // ---- /sys (only what fastfetch-style tools peek at) --------------------
    writeFile("/sys/class/dmi/id/sys_vendor", "QEMU\n");
    writeFile("/sys/class/dmi/id/product_name", "Zirconium Virtual Machine\n");
    writeFile("/sys/class/dmi/id/board_name", "zirc-virt");

    serial.serialWrite("[SEED] procfs-lite files created in ramfs\n");
}
