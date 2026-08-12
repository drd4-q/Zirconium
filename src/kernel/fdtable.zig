//! Per-task file descriptor table shared by the Linux and Win32 personalities.

const std = @import("std");
const task = @import("task.zig");
const vfs = @import("../fs/vfs.zig");
const vga = @import("../system/vga.zig");
const serial = @import("../system/serial.zig");
const kb = @import("../drivers/keyboard.zig");

pub const STDIN: usize = 0;
pub const STDOUT: usize = 1;
pub const STDERR: usize = 2;

/// Install stdin/stdout/stderr. fd 3 is wired to the serial log, matching the
/// native ABI's convention so existing debug output keeps working.
pub fn initStdio(t: *task.Task) void {
    t.fds[STDIN] = .console;
    t.fds[STDOUT] = .console;
    t.fds[STDERR] = .console;
    if (task.MAX_FDS > 3) t.fds[3] = .serial;
}

pub fn alloc(t: *task.Task, desc: task.FileDesc) ?usize {
    var i: usize = 0;
    while (i < task.MAX_FDS) : (i += 1) {
        if (t.fds[i] == null) {
            t.fds[i] = desc;
            return i;
        }
    }
    return null;
}

pub fn get(t: *task.Task, fd: usize) ?task.FileDesc {
    if (fd >= task.MAX_FDS) return null;
    return t.fds[fd];
}

pub fn close(t: *task.Task, fd: usize) bool {
    const desc = get(t, fd) orelse return false;
    switch (desc) {
        .file => |h| vfs.close(h),
        .socket => |c| @import("../net/tcp.zig").disconnect(c),
        else => {},
    }
    t.fds[fd] = null;
    return true;
}

pub fn closeAll(t: *task.Task) void {
    var i: usize = 0;
    while (i < task.MAX_FDS) : (i += 1) {
        _ = close(t, i);
    }
}

/// Returns bytes written, or a negative errno.
pub fn write(t: *task.Task, fd: usize, buf: []const u8) isize {
    const desc = get(t, fd) orelse return -9; // EBADF
    switch (desc) {
        .console => {
            for (buf) |ch| vga.putChar(ch);
            // Mirror program output to the serial log: it is the only way to see
            // it in the headless test harness.
            serial.serialWrite(buf);
            return @intCast(buf.len);
        },
        .serial => {
            serial.serialWrite(buf);
            return @intCast(buf.len);
        },
        .file => |h| {
            const n = vfs.write(h, buf);
            return @intCast(n);
        },
        .socket => |c| {
            const tcp = @import("../net/tcp.zig");
            if (c.state != .established) return -107; // ENOTCONN
            tcp.send(c, buf);
            return @intCast(buf.len);
        },
    }
}

/// Returns bytes read, 0 on EOF, or a negative errno.
pub fn read(t: *task.Task, fd: usize, buf: []u8) isize {
    const desc = get(t, fd) orelse return -9; // EBADF
    switch (desc) {
        .console => {
            if (buf.len == 0) return 0;
            // Line-oriented like a tty in canonical mode: programs such as a
            // shell expect read() to return at the newline.
            var count: usize = 0;
            while (count < buf.len) {
                const ch = kb.pollKey() orelse {
                    asm volatile ("hlt");
                    continue;
                };
                if (ch == '\n' or ch == '\r') {
                    vga.putChar('\n');
                    buf[count] = '\n';
                    count += 1;
                    break;
                }
                if (ch == 0x08) {
                    if (count > 0) {
                        count -= 1;
                        vga.putChar(0x08);
                        vga.putChar(' ');
                        vga.putChar(0x08);
                    }
                    continue;
                }
                if (ch < 0x20 or ch >= 0x80) continue;
                buf[count] = ch;
                count += 1;
                vga.putChar(ch);
            }
            return @intCast(count);
        },
        .serial => return 0,
        .file => |h| {
            const n = vfs.read(h, buf);
            return @intCast(n);
        },
        .socket => |c| {
            const net = @import("../net/mod.zig");
            const timer = @import("../drivers/timer.zig");
            const deadline = timer.ticks +% 300;
            while (!c.rx_ready and c.state == .established and timer.ticks < deadline) {
                net.poll();
            }
            if (!c.rx_ready or c.rx_len == 0) return 0;
            const n = @min(c.rx_len, buf.len);
            @memcpy(buf[0..n], c.rx_buf[0..n]);
            c.rx_len = 0;
            c.rx_ready = false;
            return @intCast(n);
        },
    }
}

pub fn isTty(t: *task.Task, fd: usize) bool {
    const desc = get(t, fd) orelse return false;
    return switch (desc) {
        .console, .serial => true,
        else => false,
    };
}

pub fn seek(t: *task.Task, fd: usize, offset: u64) bool {
    const desc = get(t, fd) orelse return false;
    return switch (desc) {
        .file => |h| vfs.seek(h, offset),
        else => false,
    };
}

pub fn tell(t: *task.Task, fd: usize) u64 {
    const desc = get(t, fd) orelse return 0;
    return switch (desc) {
        .file => |h| h.offset,
        else => 0,
    };
}
