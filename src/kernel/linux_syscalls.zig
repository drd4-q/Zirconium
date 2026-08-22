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
const SYS_lstat: u64 = 6;
const SYS_poll: u64 = 7;
const SYS_lseek: u64 = 8;
const SYS_mmap: u64 = 9;
const SYS_mprotect: u64 = 10;
const SYS_munmap: u64 = 11;
const SYS_brk: u64 = 12;
const SYS_rt_sigaction: u64 = 13;
const SYS_rt_sigprocmask: u64 = 14;
const SYS_ioctl: u64 = 16;
const SYS_writev: u64 = 20;
const SYS_access: u64 = 21;
const SYS_pipe: u64 = 22;
const SYS_select: u64 = 23;
const SYS_dup: u64 = 32;
const SYS_dup2: u64 = 33;
const SYS_nanosleep: u64 = 35;
const SYS_getpid: u64 = 39;
const SYS_socket: u64 = 41;
const SYS_connect: u64 = 42;
const SYS_sendto: u64 = 44;
const SYS_recvfrom: u64 = 45;
const SYS_execve: u64 = 59;
const SYS_exit: u64 = 60;
const SYS_uname: u64 = 63;
const SYS_fcntl: u64 = 72;
const SYS_getdents: u64 = 78;
const SYS_getcwd: u64 = 79;
const SYS_chdir: u64 = 80;
const SYS_readlink: u64 = 89;
const SYS_gettimeofday: u64 = 96;
const SYS_sysinfo: u64 = 99;
const SYS_getuid: u64 = 102;
const SYS_getgid: u64 = 104;
const SYS_geteuid: u64 = 107;
const SYS_getegid: u64 = 108;
const SYS_setpgid: u64 = 109;
const SYS_getppid: u64 = 110;
const SYS_getpgrp: u64 = 111;
const SYS_getpgid: u64 = 121;
const SYS_sigaltstack: u64 = 131;
const SYS_arch_prctl: u64 = 158;
const SYS_gettid: u64 = 186;
const SYS_futex: u64 = 202;
const SYS_getdents64: u64 = 217;
const SYS_set_tid_address: u64 = 218;
const SYS_clock_gettime: u64 = 228;
const SYS_exit_group: u64 = 231;
const SYS_openat: u64 = 257;
const SYS_newfstatat: u64 = 262;
const SYS_faccessat: u64 = 269;
const SYS_pselect6: u64 = 270;
const SYS_ppoll: u64 = 271;
const SYS_set_robust_list: u64 = 273;
const SYS_dup3: u64 = 292;
const SYS_pipe2: u64 = 293;
const SYS_prlimit64: u64 = 302;
const SYS_getrandom: u64 = 318;
const SYS_rseq: u64 = 334;
const SYS_faccessat2: u64 = 439;

// Native Zirconium syscall numbers for backwards compatibility
const SYS_native_socket: u64 = 70;
const SYS_native_connect: u64 = 71;
const SYS_native_send: u64 = 72;
const SYS_native_recv: u64 = 73;

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
        SYS_stat, SYS_lstat => ret(frame, sysStat(a1, a2)),
        SYS_newfstatat => ret(frame, sysStat(a2, a3)),
        SYS_fstat => ret(frame, sysFstat(t, a1, a2)),
        SYS_access, SYS_faccessat, SYS_faccessat2 => ret(frame, sysAccess(if (nr == SYS_access) a1 else a2)),
        SYS_brk => ret(frame, sysBrk(t, a1)),
        SYS_mmap => ret(frame, sysMmap(t, a1, a2, a3)),
        SYS_munmap => ret(frame, 0), // memory is reclaimed on exit
        SYS_mprotect => ret(frame, 0), // all user pages are already RW
        SYS_ioctl => ret(frame, sysIoctl(t, a1, a2, a3)),
        SYS_fcntl => ret(frame, sysFcntl(t, a1, a2, a3)),
        SYS_dup => ret(frame, sysDup(t, a1)),
        SYS_dup2, SYS_dup3 => ret(frame, sysDup2(t, a1, a2)),
        // Pipes have no kernel implementation; failing honestly beats handing
        // out fd numbers the caller then reads from/writes to.
        SYS_pipe, SYS_pipe2 => ret(frame, ENOSYS),
        SYS_poll, SYS_ppoll, SYS_select, SYS_pselect6 => ret(frame, 1),
        SYS_getcwd => ret(frame, sysGetcwd(a1, a2)),
        SYS_chdir => ret(frame, sysChdir(a1)),
        SYS_gettimeofday => ret(frame, sysGettimeofday(a1, a2)),
        SYS_sysinfo => ret(frame, sysSysinfo(a1)),
        SYS_nanosleep => ret(frame, sysNanosleep(a1)),
        SYS_clock_gettime => ret(frame, sysClockGettime(a2)),
        SYS_arch_prctl => ret(frame, sysArchPrctl(t, a1, a2)),
        SYS_set_tid_address, SYS_set_robust_list, SYS_rseq, SYS_sigaltstack => ret(frame, @intCast(t.id + 1)),
        SYS_rt_sigaction, SYS_rt_sigprocmask, SYS_prlimit64, SYS_futex => ret(frame, 0),
        SYS_getpid, SYS_gettid, SYS_getppid, SYS_getpgrp, SYS_getpgid => ret(frame, @intCast(t.id + 1)),
        SYS_setpgid => ret(frame, 0),
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
        SYS_getdents64 => ret(frame, sysGetdents64(t, a1, a2, a3)),
        SYS_execve => ret(frame, sysExecve(frame, t, a1, a2, a3)),
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

    // Directories never go through vfs.open: the VFS enumerates them by path
    // via readdir, so remember the path in a directory descriptor instead.
    if (!want_write) {
        if (vfs.stat(path)) |st| {
            if (st.file_type == .directory) {
                var d = task.DirDesc{};
                const n = @min(path.len, d.path_buf.len);
                @memcpy(d.path_buf[0..n], path[0..n]);
                d.path_len = n;
                const fd = fdtable.alloc(t, .{ .dir = d }) orelse return -24; // EMFILE
                return @intCast(fd);
            }
        }
    }

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

/// struct linux_dirent64 { u64 d_ino; i64 d_off; u16 d_reclen; u8 d_type;
///                          char d_name[]; } entries packed into the buffer.
fn sysGetdents64(t: *task.Task, fd: u64, buf_ptr: u64, buf_len: u64) isize {
    // The read cursor lives in the descriptor itself, so mutate it in place
    // through the fd table slot.
    if (fd >= task.MAX_FDS) return EBADF;
    const slot = &t.fds[@intCast(fd)];
    const desc = &(slot.* orelse return EBADF);
    if (desc.* != .dir) return -20; // ENOTDIR
    const dir = &desc.dir;

    var entries: [32]vfs.DirEntry = undefined;
    const count = vfs.readdir(dir.path_buf[0..dir.path_len], &entries);
    if (dir.cursor >= count) {
        dir.cursor = 0; // rewind so reopening-by-seek semantics stay sane
        return 0; // EOF
    }

    const DT_REG: u8 = 8;
    const DT_DIR: u8 = 4;

    var written: usize = 0;
    var i = dir.cursor;
    while (i < count) : (i += 1) {
        const e = &entries[i];
        // 19 fixed bytes + name + NUL, padded to 8.
        const reclen = (@as(usize, 19) + e.name_len + 1 + 7) & ~@as(usize, 7);
        if (written + reclen > buf_len) break;

        _ = uaccess.writeU64(buf_ptr + written, i + 1); // d_ino
        _ = uaccess.writeU64(buf_ptr + written + 8, i + 1); // d_off
        _ = uaccess.writeU16(buf_ptr + written + 16, @intCast(reclen));
        _ = uaccess.writeU8(buf_ptr + written + 18, if (e.file_type == .directory) DT_DIR else DT_REG);
        var k: usize = 0;
        while (k < e.name_len) : (k += 1) {
            _ = uaccess.writeU8(buf_ptr + written + 19 + k, e.name[k]);
        }
        var p = 19 + e.name_len;
        while (p < reclen) : (p += 1) {
            _ = uaccess.writeU8(buf_ptr + written + p, 0); // NUL + padding
        }
        written += reclen;
    }

    if (written == 0 and count > dir.cursor) return EINVAL; // buffer too small
    dir.cursor = i;
    return @intCast(written);
}

fn sysChdir(path_ptr: u64) isize {
    var path_buf: [256]u8 = undefined;
    const path = uaccess.readCStr(path_ptr, &path_buf) orelse return EFAULT;
    const info = vfs.stat(path) orelse return ENOENT;
    if (info.file_type != .directory) return -20; // ENOTDIR
    vfs.setCwd(path);
    return 0;
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

fn sysAccess(path_ptr: u64) isize {
    var path_buf: [256]u8 = undefined;
    const path = uaccess.readCStr(path_ptr, &path_buf) orelse return EFAULT;
    if (vfs.stat(path) != null) return 0;
    return ENOENT;
}

fn sysFcntl(t: *task.Task, fd: u64, cmd: u64, arg: u64) isize {
    const F_DUPFD: u64 = 0;
    const F_GETFD: u64 = 1;
    const F_SETFD: u64 = 2;
    const F_GETFL: u64 = 3;
    const F_SETFL: u64 = 4;
    return switch (cmd) {
        F_DUPFD => blk: {
            // Duplicate onto the lowest free fd >= arg.
            const desc = fdtable.get(t, @intCast(fd)) orelse break :blk EBADF;
            var cand: usize = @intCast(@min(arg, task.MAX_FDS));
            while (cand < task.MAX_FDS) : (cand += 1) {
                if (t.fds[cand] == null) {
                    t.fds[cand] = desc;
                    break :blk @intCast(cand);
                }
            }
            break :blk -24; // EMFILE
        },
        F_GETFD => 0,
        F_SETFD => 0,
        F_GETFL => 0o2, // O_RDWR
        F_SETFL => 0,
        else => 0,
    };
}

fn sysDup(t: *task.Task, oldfd: u64) isize {
    const desc = fdtable.get(t, @intCast(oldfd)) orelse return EBADF;
    const newfd = fdtable.alloc(t, desc) orelse return -24; // EMFILE
    return @intCast(newfd);
}

fn sysDup2(t: *task.Task, oldfd: u64, newfd: u64) isize {
    if (oldfd >= task.MAX_FDS or newfd >= task.MAX_FDS) return EBADF;
    const desc = fdtable.get(t, @intCast(oldfd)) orelse return EBADF;
    _ = fdtable.close(t, @intCast(newfd));
    t.fds[@intCast(newfd)] = desc;
    return @intCast(newfd);
}

fn sysGetcwd(buf_ptr: u64, size: u64) isize {
    const cwd = vfs.getCwd();
    if (size < cwd.len + 1) return ERANGE;
    for (cwd, 0..) |ch, i| {
        if (!uaccess.writeU8(buf_ptr + i, ch)) return EFAULT;
    }
    if (!uaccess.writeU8(buf_ptr + cwd.len, 0)) return EFAULT;
    return @intCast(cwd.len + 1);
}

/// struct sysinfo: fill in the fields libc actually reads (memory totals,
/// process count) and zero the rest.
fn sysSysinfo(info_ptr: u64) isize {
    if (info_ptr == 0) return EFAULT;
    var off: u64 = 0;
    while (off < 112) : (off += 8) {
        _ = uaccess.writeU64(info_ptr + off, 0);
    }
    const ticks = timer.ticks;
    _ = uaccess.writeU64(info_ptr + 0, ticks / 100); // uptime
    _ = uaccess.writeU64(info_ptr + 32, pmm.total_pages * 4096); // totalram
    _ = uaccess.writeU64(info_ptr + 40, pmm.free_pages * 4096); // freeram
    const sched = @import("scheduler.zig");
    _ = uaccess.writeU16(info_ptr + 80, @intCast(sched.task_count + 1)); // procs
    _ = uaccess.writeU32(info_ptr + 104, 1); // mem_unit
    return 0;
}

fn sysGettimeofday(tv_ptr: u64, tz_ptr: u64) isize {
    _ = tz_ptr;
    if (tv_ptr == 0) return 0;
    const ticks = timer.ticks;
    const secs = ticks / 100;
    const usecs = (ticks % 100) * 10_000;
    if (!uaccess.writeU64(tv_ptr, secs)) return EFAULT;
    if (!uaccess.writeU64(tv_ptr + 8, usecs)) return EFAULT;
    return 0;
}

fn sysIoctl(t: *task.Task, fd: u64, request: u64, arg_ptr: u64) isize {
    const TCGETS: u64 = 0x5401;
    const TIOCGWINSZ: u64 = 0x5413;
    if (!fdtable.isTty(t, @intCast(fd))) return ENOTTY;
    switch (request) {
        TIOCGWINSZ => {
            // struct winsize { u16 ws_row, ws_col, ws_xpixel, ws_ypixel }
            if (arg_ptr != 0) {
                if (!uaccess.writeU16(arg_ptr, 25)) return EFAULT;
                if (!uaccess.writeU16(arg_ptr + 2, 80)) return EFAULT;
                if (!uaccess.writeU16(arg_ptr + 4, 0)) return EFAULT;
                if (!uaccess.writeU16(arg_ptr + 6, 0)) return EFAULT;
                return 0;
            }
            return EINVAL;
        },
        TCGETS => {
            // struct termios: 60 bytes
            if (arg_ptr != 0) {
                var k: u64 = 0;
                while (k < 60) : (k += 1) {
                    _ = uaccess.writeU8(arg_ptr + k, 0);
                }
                _ = uaccess.writeU32(arg_ptr + 12, 0o0000010); // c_lflag = ECHO/ICANON
                return 0;
            }
            return EINVAL;
        },
        else => return ENOTTY,
    }
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

fn sysNativeConnect(t: *task.Task, fd: u64, ip_ptr: u64, port: u64) isize {
    const desc = fdtable.get(t, @intCast(fd)) orelse return EBADF;
    const conn = switch (desc) {
        .socket => |c| c,
        else => return -88, // ENOTSOCK
    };
    var ip: [4]u8 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        ip[i] = uaccess.readU8(ip_ptr + i) orelse return EFAULT;
    }
    const tcp = @import("../net/tcp.zig");
    tcp.openConn(conn, ip, @intCast(port));
    if (!tcp.waitEstablished(conn, 500)) return -111; // ECONNREFUSED
    return 0;
}

fn sysExecve(frame: *isr.InterruptFrame, t: *task.Task, path_ptr: u64, argv_ptr: u64, envp_ptr: u64) isize {
    _ = envp_ptr;
    var path_buf: [256]u8 = undefined;
    const path = uaccess.readCStr(path_ptr, &path_buf) orelse return EFAULT;
    if (path.len == 0) return ENOENT;

    var argline_buf: [512]u8 = undefined;
    var argline_len: usize = 0;

    if (argv_ptr != 0) {
        var arg_idx: usize = 0;
        while (arg_idx < 16) : (arg_idx += 1) {
            const ptr = uaccess.readU64(argv_ptr + arg_idx * 8) orelse break;
            if (ptr == 0) break;
            var str_buf: [128]u8 = undefined;
            const str = uaccess.readCStr(ptr, &str_buf) orelse break;
            if (argline_len > 0 and argline_len < argline_buf.len) {
                argline_buf[argline_len] = ' ';
                argline_len += 1;
            }
            const copy_n = @min(str.len, argline_buf.len - argline_len);
            @memcpy(argline_buf[argline_len..][0..copy_n], str[0..copy_n]);
            argline_len += copy_n;
        }
    }

    const argline = if (argline_len > 0) argline_buf[0..argline_len] else path;

    const binfmt = @import("binfmt.zig");
    const process = @import("process.zig");

    const file = binfmt.readFile(path) catch return ENOENT;
    defer binfmt.freeFile(file);

    const old_as = t.address_space;
    const old_stack_phys = t.user_stack_phys;
    const old_stack_pages = t.user_stack_pages;

    t.address_space = null;
    t.user_stack_phys = 0;
    t.user_stack_pages = 0;

    process.setup(t, file, argline) catch |err| {
        t.address_space = old_as;
        t.user_stack_phys = old_stack_phys;
        t.user_stack_pages = old_stack_pages;
        return switch (err) {
            error.OutOfMemory => ENOMEM,
            error.UnknownFormat, error.UnsupportedMachine, error.UnsupportedElfType, error.InvalidElfHeader => -8, // ENOEXEC
            else => -8,
        };
    };

    if (old_stack_phys != 0) {
        pmm.freePages(old_stack_phys, if (old_stack_pages != 0) old_stack_pages else task.USER_STACK_SIZE / 4096);
    }
    if (old_as) |as| {
        as.destroy();
    }

    if (t.address_space) |new_as| {
        new_as.switchTo();
    }

    frame.rip = t.saved_state.rip;
    frame.rsp = t.saved_state.rsp;
    frame.rflags = t.saved_state.rflags;
    frame.cs = t.saved_state.cs;
    frame.ss = t.saved_state.ss;
    frame.rax = 0;

    if (t.personality == .linux and t.fs_base != 0) {
        msr.setFsBase(t.fs_base);
    }

    return 0;
}
