//! Linux x86-64 syscall ABI.
//!
//! Entered from `syscall_entry_64` (see arch/isr.S) for tasks whose personality
//! is `.linux`. Call numbers follow the Linux x86-64 table so unmodified static
//! binaries (musl, Zig's freestanding-linux output) run as-is.
//!
//! Argument registers: rdi, rsi, rdx, r10, r8, r9. Return value in rax, errors
//! as negative errno. Note r10 (not rcx) is the 4th argument: `syscall`
//! clobbers rcx with the return address.

const std = @import("std");
const root = @import("root");
const vga = root.vga;
const serial = @import("../system/serial.zig");
const isr = @import("../arch/isr.zig");
const msr = @import("../arch/msr.zig");
const scheduler = @import("scheduler.zig");
const task = @import("task.zig");
const fdtable = @import("fdtable.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const vfs = @import("../fs/vfs.zig");
const timer = @import("../drivers/timer.zig");
const uaccess = @import("uaccess.zig");

// Linux x86-64 call numbers (arch/x86/entry/syscalls/syscall_64.tbl)
const SYS_read: u64 = 0;
const SYS_write: u64 = 1;
const SYS_open: u64 = 2;
const SYS_close: u64 = 3;
const SYS_stat: u64 = 4;
const SYS_fstat: u64 = 5;
const SYS_lseek: u64 = 8;
const SYS_mmap: u64 = 9;
const SYS_mprotect: u64 = 10;
const SYS_munmap: u64 = 11;
const SYS_brk: u64 = 12;
const SYS_rt_sigaction: u64 = 13;
const SYS_rt_sigprocmask: u64 = 14;
const SYS_ioctl: u64 = 16;
const SYS_writev: u64 = 20;
const SYS_nanosleep: u64 = 35;
const SYS_getpid: u64 = 39;
const SYS_socket: u64 = 41;
const SYS_connect: u64 = 42;
const SYS_sendto: u64 = 44;
const SYS_recvfrom: u64 = 45;
const SYS_exit: u64 = 60;
const SYS_uname: u64 = 63;
const SYS_readlink: u64 = 89;
const SYS_getuid: u64 = 102;
const SYS_getgid: u64 = 104;
const SYS_geteuid: u64 = 107;
const SYS_getegid: u64 = 108;
const SYS_arch_prctl: u64 = 158;
const SYS_gettid: u64 = 186;
const SYS_futex: u64 = 202;
const SYS_set_tid_address: u64 = 218;
const SYS_clock_gettime: u64 = 228;
const SYS_exit_group: u64 = 231;
const SYS_openat: u64 = 257;
const SYS_newfstatat: u64 = 262;
const SYS_set_robust_list: u64 = 273;
const SYS_prlimit64: u64 = 302;
const SYS_getrandom: u64 = 318;
const SYS_rseq: u64 = 334;

// errno values we return
const ENOENT: isize = -2;
const EBADF: isize = -9;
const ENOMEM: isize = -12;
const EFAULT: isize = -14;
const EINVAL: isize = -22;
const ENOSYS: isize = -38;
const ENOTTY: isize = -25;
const ERANGE: isize = -34;

const AT_FDCWD: i64 = -100;

const ARCH_SET_FS: u64 = 0x1002;
const ARCH_GET_FS: u64 = 0x1003;

/// Returns true when the syscall was handled (including with an error).
pub fn dispatch(frame: *isr.InterruptFrame, t: *task.Task) void {
    const nr = frame.rax;
    const a1 = frame.rdi;
    const a2 = frame.rsi;
    const a3 = frame.rdx;
    const a4 = frame.r10;

    switch (nr) {
        SYS_read => {
            const buf = uaccess.userSlice(a2, a3) orelse return ret(frame, EFAULT);
            ret(frame, fdtable.read(t, @intCast(a1), buf));
        },
        SYS_write => {
            const buf = uaccess.userSliceConst(a2, a3) orelse return ret(frame, EFAULT);
            ret(frame, fdtable.write(t, @intCast(a1), buf));
        },
        SYS_writev => ret(frame, sysWritev(t, a1, a2, a3)),
        SYS_open => ret(frame, sysOpenat(t, AT_FDCWD, a1, a2)),
        SYS_openat => ret(frame, sysOpenat(t, @bitCast(a1), a2, a3)),
        SYS_close => {
            if (fdtable.close(t, @intCast(a1))) ret(frame, 0) else ret(frame, EBADF);
        },
        SYS_lseek => ret(frame, sysLseek(t, a1, a2, a3)),
        SYS_stat => ret(frame, sysStat(a1, a2)),
        SYS_newfstatat => ret(frame, sysStat(a2, a3)),
        SYS_fstat => ret(frame, sysFstat(t, a1, a2)),
        SYS_brk => ret(frame, sysBrk(t, a1)),
        SYS_mmap => ret(frame, sysMmap(t, a1, a2, a3)),
        SYS_munmap => ret(frame, 0), // memory is reclaimed on exit
        SYS_mprotect => ret(frame, 0), // all user pages are already RW
        SYS_ioctl => ret(frame, sysIoctl(t, a1, a2)),
        SYS_nanosleep => ret(frame, sysNanosleep(a1)),
        SYS_clock_gettime => ret(frame, sysClockGettime(a2)),
        SYS_arch_prctl => ret(frame, sysArchPrctl(t, a1, a2)),
        SYS_set_tid_address, SYS_set_robust_list, SYS_rseq => ret(frame, @intCast(t.id + 1)),
        SYS_rt_sigaction, SYS_rt_sigprocmask, SYS_prlimit64, SYS_futex => ret(frame, 0),
        SYS_getpid, SYS_gettid => ret(frame, @intCast(t.id + 1)),
        SYS_getuid, SYS_geteuid, SYS_getgid, SYS_getegid => ret(frame, 0),
        SYS_uname => ret(frame, sysUname(a1)),
        SYS_readlink => ret(frame, EINVAL),
        SYS_getrandom => ret(frame, sysGetrandom(a1, a2)),
        SYS_socket => ret(frame, sysSocket(t)),
        SYS_connect => ret(frame, sysConnect(t, a1, a2, a3)),
        SYS_sendto => {
            const buf = uaccess.userSliceConst(a2, a3) orelse return ret(frame, EFAULT);
            ret(frame, fdtable.write(t, @intCast(a1), buf));
        },
        SYS_recvfrom => {
            const buf = uaccess.userSlice(a2, a3) orelse return ret(frame, EFAULT);
            ret(frame, fdtable.read(t, @intCast(a1), buf));
        },
        SYS_exit, SYS_exit_group => {
            _ = a4;
            @import("process.zig").exitCurrent(@intCast(a1 & 0xFF));
        },
        else => {
            serial.serialWrite("[LINUX] Unimplemented syscall ");
            serial.serialWriteDec(nr);
            serial.serialWrite(" from RIP 0x");
            serial.serialWriteHex(frame.rip);
            serial.serialWrite("\n");
            ret(frame, ENOSYS);
        },
    }
}

fn ret(frame: *isr.InterruptFrame, value: isize) void {
    frame.rax = @bitCast(value);
}

fn sysWritev(t: *task.Task, fd: u64, iov_ptr: u64, iovcnt: u64) isize {
    // struct iovec { void *iov_base; size_t iov_len; }
    if (iovcnt > 1024) return EINVAL;
    var total: isize = 0;
    var i: u64 = 0;
    while (i < iovcnt) : (i += 1) {
        const entry = iov_ptr + i * 16;
        const base = uaccess.readU64(entry) orelse return EFAULT;
        const len = uaccess.readU64(entry + 8) orelse return EFAULT;
        if (len == 0) continue;
        const buf = uaccess.userSliceConst(base, len) orelse return EFAULT;
        const n = fdtable.write(t, @intCast(fd), buf);
        if (n < 0) return if (total > 0) total else n;
        total += n;
    }
    return total;
}

fn sysOpenat(t: *task.Task, dirfd: i64, path_ptr: u64, flags: u64) isize {
    _ = dirfd; // only AT_FDCWD-relative paths are supported
    var path_buf: [256]u8 = undefined;
    const path = uaccess.readCStr(path_ptr, &path_buf) orelse return EFAULT;
    if (path.len == 0) return ENOENT;

    const O_WRONLY: u64 = 0o1;
    const O_RDWR: u64 = 0o2;
    const O_CREAT: u64 = 0o100;
    const O_TRUNC: u64 = 0o1000;

    const want_write = (flags & O_WRONLY != 0) or (flags & O_RDWR != 0);
    const handle = vfs.open(path, .{
        .read = !want_write or (flags & O_RDWR != 0),
        .write = want_write,
        .create = flags & O_CREAT != 0,
        .truncate = flags & O_TRUNC != 0,
    }) orelse return ENOENT;

    const fd = fdtable.alloc(t, .{ .file = handle }) orelse {
        vfs.close(handle);
        return -24; // EMFILE
    };
    return @intCast(fd);
}

fn sysLseek(t: *task.Task, fd: u64, offset: u64, whence: u64) isize {
    const SEEK_SET: u64 = 0;
    const SEEK_CUR: u64 = 1;
    const target = switch (whence) {
        SEEK_SET => offset,
        SEEK_CUR => fdtable.tell(t, @intCast(fd)) + offset,
        else => return EINVAL,
    };
    if (!fdtable.seek(t, @intCast(fd), target)) return EBADF;
    return @intCast(target);
}

/// Minimal `struct stat` fill: musl only needs st_mode and st_size to decide
/// whether a path is a file/dir and how large it is.
fn writeStat(buf_ptr: u64, is_dir: bool, size: u64) isize {
    // Offsets in x86-64 struct stat: st_mode @24 (u32), st_size @48 (i64),
    // st_blksize @56, st_blocks @64.
    var i: usize = 0;
    while (i < 144) : (i += 8) {
        if (!uaccess.writeU64(buf_ptr + i, 0)) return EFAULT;
    }
    const S_IFREG: u32 = 0o100000;
    const S_IFDIR: u32 = 0o040000;
    const mode: u32 = (if (is_dir) S_IFDIR else S_IFREG) | 0o644;
    if (!uaccess.writeU32(buf_ptr + 24, mode)) return EFAULT;
    if (!uaccess.writeU64(buf_ptr + 48, size)) return EFAULT;
    if (!uaccess.writeU64(buf_ptr + 56, 4096)) return EFAULT;
    if (!uaccess.writeU64(buf_ptr + 64, (size + 511) / 512)) return EFAULT;
    return 0;
}

fn sysStat(path_ptr: u64, buf_ptr: u64) isize {
    var path_buf: [256]u8 = undefined;
    const path = uaccess.readCStr(path_ptr, &path_buf) orelse return EFAULT;
    const info = vfs.stat(path) orelse return ENOENT;
    return writeStat(buf_ptr, info.file_type == .directory, info.size);
}

fn sysFstat(t: *task.Task, fd: u64, buf_ptr: u64) isize {
    const desc = fdtable.get(t, @intCast(fd)) orelse return EBADF;
    return switch (desc) {
        .console, .serial => blk: {
            // A character device: st_mode S_IFCHR so libc uses unbuffered I/O.
            var i: usize = 0;
            while (i < 144) : (i += 8) {
                if (!uaccess.writeU64(buf_ptr + i, 0)) break :blk EFAULT;
            }
            const S_IFCHR: u32 = 0o020000;
            if (!uaccess.writeU32(buf_ptr + 24, S_IFCHR | 0o620)) break :blk EFAULT;
            if (!uaccess.writeU64(buf_ptr + 56, 1024)) break :blk EFAULT;
            break :blk 0;
        },
        else => writeStat(buf_ptr, false, 0),
    };
}

fn sysBrk(t: *task.Task, new_brk: u64) isize {
    const as = t.address_space orelse return ENOMEM;

    if (t.heap_brk == 0) {
        t.heap_brk = task.USER_HEAP_BASE;
        t.heap_mapped = task.USER_HEAP_BASE;
    }

    // Linux brk() returns the *current* break on failure or query, never an
    // errno — libc detects failure by comparing against what it asked for.
    if (new_brk == 0) return @bitCast(t.heap_brk);
    if (new_brk < task.USER_HEAP_BASE or new_brk >= task.USER_HEAP_LIMIT) {
        return @bitCast(t.heap_brk);
    }

    if (new_brk <= t.heap_brk) {
        t.heap_brk = new_brk;
        return @bitCast(new_brk);
    }

    const aligned_end = (new_brk + 0xFFF) & ~@as(u64, 0xFFF);
    if (aligned_end > t.heap_mapped) {
        if (!as.allocUserRange(t.heap_mapped, aligned_end - t.heap_mapped, vmm.PAGE_WRITE)) {
            return @bitCast(t.heap_brk);
        }
        t.heap_mapped = aligned_end;
    }
    t.heap_brk = new_brk;
    return @bitCast(new_brk);
}

fn sysMmap(t: *task.Task, addr: u64, length: u64, prot: u64) isize {
    _ = addr;
    _ = prot;
    if (length == 0) return EINVAL;
    const base = @import("process.zig").mmapAnon(t, length) orelse return ENOMEM;
    return @bitCast(base);
}

fn sysIoctl(t: *task.Task, fd: u64, request: u64) isize {
    const TCGETS: u64 = 0x5401;
    const TIOCGWINSZ: u64 = 0x5413;
    if (!fdtable.isTty(t, @intCast(fd))) return ENOTTY;
    // Claiming success without filling termios would make libc believe it has a
    // configured tty; returning ENOTTY for TCGETS just makes it treat the fd as
    // a pipe, which is correct enough here.
    return switch (request) {
        TCGETS, TIOCGWINSZ => ENOTTY,
        else => ENOTTY,
    };
}

fn sysNanosleep(req_ptr: u64) isize {
    const secs = uaccess.readU64(req_ptr) orelse return EFAULT;
    const nsecs = uaccess.readU64(req_ptr + 8) orelse return EFAULT;
    const ms = secs * 1000 + nsecs / 1_000_000;
    if (ms > 0) timer.sleep(@intCast(@min(ms, 60_000)));
    return 0;
}

fn sysClockGettime(ts_ptr: u64) isize {
    // The PIT tick is our only clock; expose it as a monotonic time base.
    const ticks = timer.ticks;
    const secs = ticks / 100;
    const nsecs = (ticks % 100) * 10_000_000;
    if (!uaccess.writeU64(ts_ptr, secs)) return EFAULT;
    if (!uaccess.writeU64(ts_ptr + 8, nsecs)) return EFAULT;
    return 0;
}

fn sysArchPrctl(t: *task.Task, code: u64, addr: u64) isize {
    switch (code) {
        ARCH_SET_FS => {
            t.fs_base = addr;
            msr.setFsBase(addr);
            return 0;
        },
        ARCH_GET_FS => {
            if (!uaccess.writeU64(addr, t.fs_base)) return EFAULT;
            return 0;
        },
        else => return EINVAL,
    }
}

fn sysUname(buf_ptr: u64) isize {
    // struct utsname: 6 fields of 65 bytes each.
    const fields = [_][]const u8{ "Linux", "zirconium", "6.0.0-zirconium", "#1 Zirconium", "x86_64", "(none)" };
    var off: u64 = 0;
    for (fields) |f| {
        var i: usize = 0;
        while (i < 65) : (i += 1) {
            const ch: u8 = if (i < f.len) f[i] else 0;
            if (!uaccess.writeU8(buf_ptr + off + i, ch)) return EFAULT;
        }
        off += 65;
    }
    return 0;
}

fn sysGetrandom(buf_ptr: u64, len: u64) isize {
    // Deterministic PRNG: no entropy source exists on this platform. Good
    // enough for libc's stack-guard/hashtable seeding, not for cryptography.
    var state: u64 = timer.ticks *% 6364136223846793005 +% 1442695040888963407;
    var i: u64 = 0;
    while (i < len) : (i += 1) {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        if (!uaccess.writeU8(buf_ptr + i, @intCast((state >> 33) & 0xFF))) return EFAULT;
    }
    return @intCast(len);
}

fn sysSocket(t: *task.Task) isize {
    const tcp = @import("../net/tcp.zig");
    const conn = tcp.allocConnection() orelse return ENOMEM;
    const fd = fdtable.alloc(t, .{ .socket = conn }) orelse {
        tcp.disconnect(conn);
        return -24; // EMFILE
    };
    return @intCast(fd);
}

fn sysConnect(t: *task.Task, fd: u64, addr_ptr: u64, addr_len: u64) isize {
    if (addr_len < 8) return EINVAL;
    const desc = fdtable.get(t, @intCast(fd)) orelse return EBADF;
    const conn = switch (desc) {
        .socket => |c| c,
        else => return -88, // ENOTSOCK
    };

    // struct sockaddr_in { u16 family; u16 port_be; u32 addr_be; ... }
    const port_be = uaccess.readU16(addr_ptr + 2) orelse return EFAULT;
    const port: u16 = (port_be >> 8) | (port_be << 8);
    var ip: [4]u8 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        ip[i] = uaccess.readU8(addr_ptr + 4 + i) orelse return EFAULT;
    }

    const tcp = @import("../net/tcp.zig");
    tcp.openConn(conn, ip, port);
    if (!tcp.waitEstablished(conn, 500)) return -111; // ECONNREFUSED
    return 0;
}
