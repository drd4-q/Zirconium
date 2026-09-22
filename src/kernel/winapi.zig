//! Win32 API emulation for PE executables.
//!
//! A PE image's imports cannot be satisfied by real DLLs, so each imported
//! function is bound to a small thunk mapped into the process. Every thunk is
//! `mov eax, <id>; int 0x81; ret`, i.e. it re-enters the kernel through a
//! dedicated vector where `dispatch` below implements the call using the Win64
//! calling convention already set up by the caller (args in rcx/rdx/r8/r9, the
//! rest on the stack above the 32-byte shadow space).
//!
//! Implemented surface is deliberately small: console I/O, process exit, heap,
//! virtual memory, command line, TLS slots, tick counts and file I/O mapped onto
//! the VFS. Everything else resolves to a stub that names the missing function
//! and terminates the process, which is far easier to diagnose than a jump to a
//! zero-filled IAT slot.

const std = @import("std");
const serial = @import("../system/serial.zig");
const vga = @import("../system/vga.zig");
const task = @import("task.zig");
const scheduler = @import("scheduler.zig");
const address_space = @import("address_space.zig");
const isr = @import("../arch/isr.zig");
const fdtable = @import("fdtable.zig");
const uaccess = @import("uaccess.zig");
const process = @import("process.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const timer = @import("../drivers/timer.zig");
const vfs = @import("../fs/vfs.zig");
const env = @import("../system/env.zig");

/// Vector used by the thunks. Distinct from 0x80 so the Win32 entry path never
/// competes with the native/Linux syscall numbering.
pub const WIN_VECTOR: u8 = 0x81;

/// Every emulated function, in thunk-id order.
pub const Func = enum(u32) {
    unimplemented = 0,
    ExitProcess,
    GetStdHandle,
    WriteFile,
    ReadFile,
    CloseHandle,
    GetCommandLineA,
    GetCommandLineW,
    GetLastError,
    SetLastError,
    GetProcessHeap,
    HeapAlloc,
    HeapFree,
    HeapReAlloc,
    HeapSize,
    HeapCreate,
    HeapDestroy,
    VirtualAlloc,
    VirtualFree,
    GetModuleHandleA,
    GetModuleHandleW,
    GetProcAddress,
    GetTickCount,
    GetTickCount64,
    QueryPerformanceCounter,
    QueryPerformanceFrequency,
    GetSystemTimeAsFileTime,
    Sleep,
    GetCurrentProcess,
    GetCurrentProcessId,
    GetCurrentThreadId,
    TlsAlloc,
    TlsGetValue,
    TlsSetValue,
    TlsFree,
    CreateFileA,
    CreateFileW,
    SetFilePointerEx,
    GetFileSizeEx,
    FlushFileBuffers,
    GetConsoleMode,
    SetConsoleMode,
    WriteConsoleA,
    WriteConsoleW,
    IsProcessorFeaturePresent,
    InitializeSListHead,
    RtlCaptureContext,
    SetUnhandledExceptionFilter,
    UnhandledExceptionFilter,
    TerminateProcess,
    GetSystemInfo,
    GetEnvironmentVariableA,
    GetEnvironmentStringsW,
    FreeEnvironmentStringsW,
    GetACP,
    MultiByteToWideChar,
    WideCharToMultiByte,
    GetFileType,
    SetHandleCount,
    GetStartupInfoA,
    GetStartupInfoW,
    EnterCriticalSection,
    LeaveCriticalSection,
    InitializeCriticalSection,
    InitializeCriticalSectionEx,
    DeleteCriticalSection,
    GetVersion,
    GetVersionExA,
    IsDebuggerPresent,
    OutputDebugStringA,
    RaiseException,
    LoadLibraryA,
    FreeLibrary,

    // ---- CRT basics (msvcrt/kernel32 exports every real binary pulls in) ----
    memcpy,
    memmove,
    memset,
    memcmp,
    strlen,
    strcpy,
    strcat,
    strcmp,
    strncmp,
    strchr,
    strrchr,
    strstr,
    toupper,
    tolower,
    malloc,
    calloc,
    realloc,
    free,
    abort,
    exit,
    _exit,
    atexit,
    puts,
    putchar,
    printf,
    _snprintf,
    snprintf,
    sprintf,

    // ---- WinSock 2 (ws2_32.dll) -------------------------------------------
    WSAStartup,
    WSACleanup,
    WSAGetLastError,
    WSASetLastError,
    socket,
    closesocket,
    connect,
    send,
    recv,
    shutdown,
    htons,
    htonl,
    ntohs,
    ntohl,
    inet_addr,
    setsockopt,
    getsockopt,
    ioctlsocket,
    select,

    // ---- UCRT startup & runtime (jq/rg/curl class binaries) ----------------
    _initterm,
    _initterm_e,
    _configure_narrow_argv,
    _configure_wide_argv,
    _initialize_narrow_environment,
    _initialize_wide_environment,
    _set_app_type,
    _set_new_mode,
    _set_invalid_parameter_handler,
    __setusermatherr,
    _configthreadlocale,
    _crt_atexit,
    _cexit,
    _lock_file,
    _unlock_file,
    raise,
    _assert,
    _wassert,
    perror,
    TryEnterCriticalSection,
    __p___argc,
    __p___wargv,
    __p__environ,
    __p__wenviron,
    __p__commode,
    __p__fmode,
    _errno,
    __daylight,
    __timezone,
    __tzname,
    __acrt_iob_func,
    GetCurrentThread,
    fwrite,
    fread,
    fputs,
    fputc,
    getc,
    fgets,
    fclose,
    feof,
    ferror,
    fflush,
    setvbuf,
    _fileno,
    _get_osfhandle,
    _isatty,
    _open,
    _close,
    _read,
    _write,
    _setmode,
    _fdopen,
    _wfopen,
    memchr,
    strnlen,
    strspn,
    _strdup,
    _strnicmp,
    isalnum,
    isalpha,
    isspace,
    isdigit,
    isupper,
    islower,
    wcslen,
    wcsnlen,
    atoi,
    strtol,
    __stdio_common_vfprintf,
    __stdio_common_vsprintf,
    _time64,
    _gmtime64,
    _localtime64_s,
    _mktime64,
    _mkgmtime64,
    _tzset,
    rand_s,
};

const FUNC_COUNT: u32 = @typeInfo(Func).@"enum".fields.len;

/// Each thunk is: mov eax, imm32 (5) + int 0x81 (2) + ret (1) = 8 bytes.
const THUNK_SIZE: u64 = 8;

pub fn thunkAddr(f: Func) u64 {
    return task.WIN_THUNK_BASE + @intFromEnum(f) * THUNK_SIZE;
}

pub fn exitThunkAddr() u64 {
    return thunkAddr(.ExitProcess);
}

pub fn unimplementedThunk() u64 {
    return thunkAddr(.unimplemented);
}

/// Map and fill the thunk page(s) in the target address space.
pub fn installThunks(as: address_space.AddressSpace) !void {
    const bytes_needed = FUNC_COUNT * THUNK_SIZE;
    if (!as.allocUserRange(task.WIN_THUNK_BASE, bytes_needed, vmm.PAGE_WRITE)) {
        return error.OutOfMemory;
    }

    var id: u32 = 0;
    while (id < FUNC_COUNT) : (id += 1) {
        const vaddr = task.WIN_THUNK_BASE + id * THUNK_SIZE;
        const phys = as.translate(vaddr & ~@as(u64, 0xFFF)) orelse return error.OutOfMemory;
        const p: [*]u8 = @ptrFromInt(phys + (vaddr & 0xFFF));
        p[0] = 0xB8; // mov eax, imm32
        p[1] = @intCast(id & 0xFF);
        p[2] = @intCast((id >> 8) & 0xFF);
        p[3] = @intCast((id >> 16) & 0xFF);
        p[4] = @intCast((id >> 24) & 0xFF);
        p[5] = 0xCD; // int imm8
        p[6] = WIN_VECTOR;
        p[7] = 0xC3; // ret
    }

    serial.serialWrite("[WIN32] Installed ");
    serial.serialWriteDec(FUNC_COUNT);
    serial.serialWrite(" import thunks at 0x");
    serial.serialWriteHex(task.WIN_THUNK_BASE);
    serial.serialWrite("\n");
}

pub fn setCommandLine(t: *task.Task, ansi: u64, wide: u64) void {
    t.cmdline_a = ansi;
    t.cmdline_w = wide;
}

/// Resolve an import to a thunk address. `dll` is only used for diagnostics:
/// names are unique enough across the DLLs we emulate.
pub fn resolve(dll: []const u8, name: []const u8, ordinal: u16) ?u64 {
    _ = dll;
    if (name.len == 0) {
        // Ordinal-only imports are not supported: mapping ordinals requires the
        // real DLL's export table.
        _ = ordinal;
        return null;
    }
    const f = lookupName(name) orelse return null;
    return thunkAddr(f);
}

fn lookupName(name: []const u8) ?Func {
    inline for (@typeInfo(Func).@"enum".fields) |field| {
        if (field.value != 0 and std.mem.eql(u8, name, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

fn funcName(f: Func) []const u8 {
    inline for (@typeInfo(Func).@"enum".fields) |field| {
        if (field.value == @intFromEnum(f)) return field.name;
    }
    return "?";
}

// ---------------------------------------------------------------------------
// Win64 calling convention helpers
// ---------------------------------------------------------------------------

/// Stack arguments start above the return address and the callee's 32-byte
/// shadow space: [rsp] is the return address pushed by `int`, so the 5th
/// argument of the *thunked* function sits at the caller's rsp + 0x28.
/// Because we entered through an interrupt, frame.rsp is the value rsp had at
/// the `int` instruction, i.e. it points at the thunk's own return address.
fn stackArg(frame: *isr.InterruptFrame, index: usize) u64 {
    // index 4 => 5th argument
    const addr = frame.rsp + 8 + 0x20 + (index - 4) * 8;
    return uaccess.readU64(addr) orelse 0;
}

fn ret64(frame: *isr.InterruptFrame, value: u64) void {
    frame.rax = value;
}

fn retBool(frame: *isr.InterruptFrame, ok: bool) void {
    frame.rax = if (ok) 1 else 0;
}

// Pseudo-handles distinct from any heap pointer.
const HANDLE_STDIN: u64 = 0xF0000001;
const HANDLE_STDOUT: u64 = 0xF0000002;
const HANDLE_STDERR: u64 = 0xF0000003;
const HANDLE_PROCESS: u64 = 0xF0000010;
const HANDLE_PROCESS_HEAP: u64 = 0xF0000020;
const HANDLE_MODULE: u64 = 0xF0000030;
const INVALID_HANDLE: u64 = 0xFFFFFFFFFFFFFFFF;

/// Files get handles that encode their fd, so CloseHandle/WriteFile can map back.
const HANDLE_FILE_BASE: u64 = 0xF0001000;
const HANDLE_SOCKET_BASE: u64 = 0xF0002000;
/// Pseudo FILE* handles handed out by __acrt_iob_func: base + raw fd number.
const STREAM_BASE: u64 = 0xF1000000;

/// Map a UCRT FILE* back to its fd (only stdin/stdout/stderr exist).
fn streamToFd(stream: u64) ?usize {
    if (stream >= STREAM_BASE and stream < STREAM_BASE + 3) {
        return @intCast(stream - STREAM_BASE);
    }
    return null;
}
const INVALID_SOCKET: u64 = 0xFFFFFFFFFFFFFFFF;
const INADDR_NONE: u32 = 0xFFFFFFFF;

// WinSock error codes (winsock2.h).
const WSA_NOT_ENOUGH_MEMORY: u32 = 14;
const WSAEFAULT: u32 = 10014;
const WSAENOTSOCK: u32 = 10038;
const WSAECONNABORTED: u32 = 10053;
const WSAECONNREFUSED: u32 = 10061;

fn socketToFd(t: *task.Task, handle: u64) ?usize {
    if (handle < HANDLE_SOCKET_BASE or handle >= HANDLE_SOCKET_BASE + task.MAX_FDS) return null;
    const fd: usize = @intCast(handle - HANDLE_SOCKET_BASE);
    const desc = fdtable.get(t, fd) orelse return null;
    return switch (desc) {
        .socket => fd,
        else => null,
    };
}

/// Walks Win64 varargs: slot 1 = rdx, 2 = r8, 3 = r9, then the stack above
/// the shadow space. `next` is the index of the first variadic slot.
const ArgIter = struct {
    frame: *isr.InterruptFrame,
    next: usize,

    fn arg(self: *ArgIter) u64 {
        const v = switch (self.next) {
            1 => self.frame.rdx,
            2 => self.frame.r8,
            3 => self.frame.r9,
            else => stackArg(self.frame, self.next),
        };
        self.next += 1;
        return v;
    }
};

/// Walks an MSVC va_list: {u32 gp_offset, u32 fp_offset, void* overflow_area,
/// void* reg_save_area}. Register args come from reg_save_area until
/// gp_offset reaches 0x28, then from the overflow area.
const VaListIter = struct {
    gp_offset: u32,
    fp_offset: u32,
    overflow: u64,
    reg_save: u64,

    fn init(list_ptr: u64) ?VaListIter {
        if (uaccess.readU32(list_ptr)) |gp| {
            const fp = uaccess.readU32(list_ptr + 4) orelse return null;
            const ovf = uaccess.readU64(list_ptr + 8) orelse return null;
            const rsa = uaccess.readU64(list_ptr + 16) orelse return null;
            return .{ .gp_offset = gp, .fp_offset = fp, .overflow = ovf, .reg_save = rsa };
        }
        return null;
    }

    fn arg(self: *VaListIter) u64 {
        var v: u64 = 0;
        if (self.gp_offset < 0x28) {
            v = uaccess.readU64(self.reg_save + self.gp_offset) orelse 0;
            self.gp_offset += 8;
        } else {
            v = uaccess.readU64(self.overflow) orelse 0;
            self.overflow += 8;
        }
        return v;
    }
};

fn u64ToDigits(buf: []u8, value_in: u64, base: u8, upper: bool) []const u8 {
    if (value_in == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    const digits = "0123456789abcdef";
    const DIGITS = "0123456789ABCDEF";
    var tmp: [24]u8 = undefined;
    var n: usize = 0;
    var v = value_in;
    while (v > 0) : (v /= base) {
        tmp[n] = if (upper) DIGITS[@intCast(v % base)] else digits[@intCast(v % base)];
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = tmp[n - 1 - i];
    return buf[0..n];
}

/// Minimal C printf engine: %s %c %d/%i %u %x/%X %p %% with width/precision,
/// '-' left-align and '0' zero-pad. Length modifiers are consumed and ignored
/// (Win64 argument slots are 64-bit regardless). Returns bytes written.
fn cFormat(out: []u8, fmt: []const u8, iter: anytype) usize {
    var n: usize = 0;
    var i: usize = 0;
    var sbuf: [1024]u8 = undefined; // storage for a %s argument

    const putChar = struct {
        fn f(o: []u8, len: *usize, ch: u8) void {
            if (len.* < o.len) {
                o[len.*] = ch;
                len.* += 1;
            }
        }
    }.f;
    const putStr = struct {
        fn f(o: []u8, len: *usize, s: []const u8) void {
            for (s) |ch| putChar(o, len, ch);
        }
    }.f;

    while (i < fmt.len) {
        if (fmt[i] != '%') {
            putChar(out, &n, fmt[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= fmt.len) break;
        if (fmt[i] == '%') {
            putChar(out, &n, '%');
            i += 1;
            continue;
        }

        // Flags.
        var zero_pad = false;
        var left_align = false;
        while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '0' => zero_pad = true,
                '-' => left_align = true,
                '+', ' ' => {},
                else => break,
            }
        }
        // Width.
        var width: usize = 0;
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
            width = width * 10 + (fmt[i] - '0');
        }
        if (i < fmt.len and fmt[i] == '*') {
            const w: i64 = @bitCast(iter.arg());
            if (w < 0) left_align = true else width = @intCast(w);
            if (width > 1024) width = 1024;
            i += 1;
        }
        // Precision.
        var prec: usize = std.math.maxInt(usize);
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            prec = 0;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                prec = prec * 10 + (fmt[i] - '0');
            }
            if (i < fmt.len and fmt[i] == '*') {
                prec = @intCast(@as(u64, @bitCast(iter.arg())));
                i += 1;
            }
        }
        // Length modifiers: irrelevant on Win64, consume them.
        while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                'h', 'l', 'z', 'j', 't' => {},
                else => break,
            }
        }
        if (i >= fmt.len) break;
        const spec = fmt[i];
        i += 1;

        var num_buf: [40]u8 = undefined;
        var piece: []const u8 = "";
        var is_num = false;

        switch (spec) {
            's' => {
                const s = uaccess.readCStr(iter.arg(), &sbuf) orelse "(null)";
                piece = s[0..@min(s.len, prec)];
            },
            'c' => {
                num_buf[0] = @truncate(iter.arg());
                piece = num_buf[0..1];
            },
            'd', 'i' => {
                const sv: i64 = @bitCast(iter.arg());
                if (sv < 0) {
                    num_buf[0] = '-';
                    const d = u64ToDigits(num_buf[1..], ~@as(u64, @bitCast(sv)) +% 1, 10, false);
                    piece = num_buf[0 .. d.len + 1];
                } else {
                    piece = u64ToDigits(&num_buf, @as(u64, @bitCast(sv)), 10, false);
                }
                is_num = true;
            },
            'u' => {
                piece = u64ToDigits(&num_buf, iter.arg(), 10, false);
                is_num = true;
            },
            'x', 'X' => {
                piece = u64ToDigits(&num_buf, iter.arg(), 16, spec == 'X');
                is_num = true;
            },
            'p' => {
                const v = iter.arg();
                if (v == 0) {
                    piece = "(nil)";
                } else {
                    const d = u64ToDigits(num_buf[2..], v, 16, false);
                    num_buf[0] = '0';
                    num_buf[1] = 'x';
                    piece = num_buf[0 .. d.len + 2];
                }
                is_num = true;
            },
            else => {}, // unknown conversion: emit nothing
        }

        // Padding for numbers honors '0'; strings pad with spaces only.
        const pad_ch: u8 = if (zero_pad and is_num and !left_align) '0' else ' ';
        if (!left_align) {
            var done: usize = 0;
            while (done + piece.len < width and n < out.len) : (done += 1) {
                putChar(out, &n, pad_ch);
            }
        }
        putStr(out, &n, piece);
        if (left_align) {
            while (piece.len < width and n < out.len) {
                putChar(out, &n, ' ');
            }
        }
    }
    return n;
}

fn handleToFd(t: *task.Task, handle: u64) ?usize {
    return switch (handle) {
        HANDLE_STDIN => fdtable.STDIN,
        HANDLE_STDOUT => fdtable.STDOUT,
        HANDLE_STDERR => fdtable.STDERR,
        else => blk: {
            if (handle >= HANDLE_FILE_BASE and handle < HANDLE_FILE_BASE + task.MAX_FDS) {
                const fd: usize = @intCast(handle - HANDLE_FILE_BASE);
                if (fdtable.get(t, fd) != null) break :blk fd;
            }
            break :blk null;
        },
    };
}

const ERROR_INVALID_HANDLE: u32 = 6;
const ERROR_FILE_NOT_FOUND: u32 = 2;
const ERROR_NOT_ENOUGH_MEMORY: u32 = 8;
const ERROR_CALL_NOT_IMPLEMENTED: u32 = 120;

/// Handler for INT 0x81, exported for the assembly stub in arch/isr.S.
pub export fn win_thunk_handler(frame: *isr.InterruptFrame) callconv(.c) void {
    dispatch(frame);
}

/// Handler for INT 0x81. Called from `win_thunk_handler`.
pub fn dispatch(frame: *isr.InterruptFrame) void {
    const idx = scheduler.current_task;
    if (idx < 0) {
        serial.serialWrite("[WIN32] Thunk called with no current task\n");
        return;
    }
    const t = &scheduler.tasks[@intCast(idx)];

    const id: u32 = @intCast(frame.rax & 0xFFFFFFFF);
    if (id >= FUNC_COUNT) {
        serial.serialWrite("[WIN32] Bad thunk id\n");
        process.exitCurrent(-1);
    }
    const f: Func = @enumFromInt(id);

    const a1 = frame.rcx;
    const a2 = frame.rdx;
    const a3 = frame.r8;
    const a4 = frame.r9;

    switch (f) {
        .unimplemented => {
            vga.setColor(.light_red, .black);
            vga.write("\n[WIN32] Program called an unimplemented Windows API\n");
            vga.setColor(.white, .black);
            serial.serialWrite("[WIN32] Unimplemented import called from RIP 0x");
            serial.serialWriteHex(frame.rip);
            serial.serialWrite(": ");
            serial.serialWrite(funcName(f));
            serial.serialWrite("\n");
            process.exitCurrent(-1);
        },
        .ExitProcess, .TerminateProcess => {
            const code = if (f == .ExitProcess) a1 else a2;
            process.exitCurrent(@intCast(@as(u32, @truncate(code))));
        },
        .GetStdHandle => {
            // STD_INPUT_HANDLE = -10, OUTPUT = -11, ERROR = -12
            const which: i32 = @bitCast(@as(u32, @truncate(a1)));
            ret64(frame, switch (which) {
                -10 => HANDLE_STDIN,
                -11 => HANDLE_STDOUT,
                -12 => HANDLE_STDERR,
                else => INVALID_HANDLE,
            });
        },
        .WriteFile, .WriteConsoleA => {
            const fd = handleToFd(t, a1) orelse {
                t.last_error = ERROR_INVALID_HANDLE;
                return retBool(frame, false);
            };
            const len: u64 = @as(u32, @truncate(a3));
            const buf = uaccess.userSliceConst(a2, len) orelse {
                t.last_error = ERROR_INVALID_HANDLE;
                return retBool(frame, false);
            };
            const n = fdtable.write(t, fd, buf);
            if (n < 0) return retBool(frame, false);
            // lpNumberOfBytesWritten (4th arg) is optional.
            if (a4 != 0) _ = uaccess.writeU32(a4, @intCast(n));
            retBool(frame, true);
        },
        .WriteConsoleW => {
            // Wide console output: transliterate the low byte of each unit.
            const count: u64 = @as(u32, @truncate(a3));
            var i: u64 = 0;
            var buf: [256]u8 = undefined;
            var n: usize = 0;
            while (i < count) : (i += 1) {
                const unit = uaccess.readU16(a2 + i * 2) orelse break;
                buf[n] = if (unit < 0x80) @intCast(unit) else '?';
                n += 1;
                if (n == buf.len) {
                    _ = fdtable.write(t, fdtable.STDOUT, buf[0..n]);
                    n = 0;
                }
            }
            if (n > 0) _ = fdtable.write(t, fdtable.STDOUT, buf[0..n]);
            if (a4 != 0) _ = uaccess.writeU32(a4, @intCast(count));
            retBool(frame, true);
        },
        .ReadFile => {
            const fd = handleToFd(t, a1) orelse {
                t.last_error = ERROR_INVALID_HANDLE;
                return retBool(frame, false);
            };
            const len: u64 = @as(u32, @truncate(a3));
            const buf = uaccess.userSlice(a2, len) orelse return retBool(frame, false);
            const n = fdtable.read(t, fd, buf);
            if (n < 0) return retBool(frame, false);
            if (a4 != 0) _ = uaccess.writeU32(a4, @intCast(n));
            retBool(frame, true);
        },
        .CloseHandle => {
            if (handleToFd(t, a1)) |fd| {
                // Never close the standard streams out from under the program.
                if (fd > 3) _ = fdtable.close(t, fd);
                return retBool(frame, true);
            }
            retBool(frame, true); // pseudo-handles: nothing to do
        },
        .FlushFileBuffers => retBool(frame, true),
        .GetCommandLineA => ret64(frame, t.cmdline_a),
        .GetCommandLineW => ret64(frame, t.cmdline_w),
        .GetLastError => ret64(frame, t.last_error),
        .SetLastError => {
            t.last_error = @truncate(a1);
            ret64(frame, 0);
        },
        .GetProcessHeap => ret64(frame, HANDLE_PROCESS_HEAP),
        .HeapCreate => ret64(frame, HANDLE_PROCESS_HEAP),
        .HeapDestroy => retBool(frame, true),
        .HeapAlloc => {
            const HEAP_ZERO_MEMORY: u64 = 0x08;
            const size = a3;
            const ptr = heapAlloc(t, size, a2 & HEAP_ZERO_MEMORY != 0) orelse {
                t.last_error = ERROR_NOT_ENOUGH_MEMORY;
                return ret64(frame, 0);
            };
            ret64(frame, ptr);
        },
        .HeapReAlloc => {
            const ptr = heapRealloc(t, a3, stackArg(frame, 4)) orelse {
                t.last_error = ERROR_NOT_ENOUGH_MEMORY;
                return ret64(frame, 0);
            };
            ret64(frame, ptr);
        },
        .HeapFree => {
            heapFree(t, a3);
            retBool(frame, true);
        },
        .HeapSize => ret64(frame, heapSize(a3)),
        .VirtualAlloc => {
            const size = a2;
            const base = process.mmapAnon(t, size) orelse {
                t.last_error = ERROR_NOT_ENOUGH_MEMORY;
                return ret64(frame, 0);
            };
            ret64(frame, base);
        },
        .VirtualFree => retBool(frame, true), // reclaimed on exit
        .GetModuleHandleA, .GetModuleHandleW, .LoadLibraryA => ret64(frame, HANDLE_MODULE),
        .FreeLibrary => retBool(frame, true),
        // ---- CRT: memory ---------------------------------------------------
        .memcpy, .memmove => {
            const n: u64 = a3;
            const src = uaccess.userSliceConst(a2, n) orelse return ret64(frame, 0);
            const dst = uaccess.userSlice(a1, n) orelse return ret64(frame, 0);
            if (a1 <= a2 or a1 >= a2 + n) {
                @memcpy(dst[0..src.len], src);
            } else {
                var i: usize = n; // overlapping backwards copy
                while (i > 0) : (i -= 1) dst[i - 1] = src[i - 1];
            }
            ret64(frame, a1);
        },
        .memset => {
            const n: u64 = a3;
            const dst = uaccess.userSlice(a1, n) orelse return ret64(frame, 0);
            @memset(dst, @truncate(a2));
            ret64(frame, a1);
        },
        .memcmp => {
            const n: u64 = a3;
            const s1 = uaccess.userSliceConst(a1, n) orelse return ret64(frame, 0);
            const s2 = uaccess.userSliceConst(a2, n) orelse return ret64(frame, 0);
            for (s1, s2) |x, y| {
                if (x != y) return ret64(frame, if (x < y) @as(u64, @bitCast(@as(i64, -1))) else 1);
            }
            ret64(frame, 0);
        },
        // ---- CRT: strings (C strings live in user memory) --------------------
        .strlen => {
            var buf: [4096]u8 = undefined;
            const s = uaccess.readCStr(a1, &buf) orelse return ret64(frame, 0);
            ret64(frame, s.len);
        },
        .strcpy, .strcat => {
            var src_buf: [4096]u8 = undefined;
            var dst_buf: [4096]u8 = undefined;
            const src = uaccess.readCStr(a2, &src_buf) orelse return ret64(frame, a1);
            var dst_len: usize = 0;
            if (f == .strcat) {
                const cur = uaccess.readCStr(a1, &dst_buf) orelse return ret64(frame, a1);
                dst_len = cur.len;
            }
            _ = uaccess.writeBytes(a1 + dst_len, src);
            _ = uaccess.writeU8(a1 + dst_len + src.len, 0);
            ret64(frame, a1);
        },
        .strcmp, .strncmp => {
            var b1: [1024]u8 = undefined;
            var b2: [1024]u8 = undefined;
            const s1 = uaccess.readCStr(a1, &b1) orelse return ret64(frame, 0);
            const s2 = uaccess.readCStr(a2, &b2) orelse return ret64(frame, 0);
            const max: usize = if (f == .strncmp) @intCast(@min(a3, s1.len + 1)) else s1.len + 1;
            var i: usize = 0;
            while (i < max) : (i += 1) {
                const c1: u8 = if (i < s1.len) s1[i] else 0;
                const c2: u8 = if (i < s2.len) s2[i] else 0;
                if (c1 != c2) return ret64(frame, if (c1 < c2) @as(u64, @bitCast(@as(i64, -1))) else 1);
                if (c1 == 0) break;
            }
            ret64(frame, 0);
        },
        .strchr, .strrchr => {
            var buf: [4096]u8 = undefined;
            const s = uaccess.readCStr(a1, &buf) orelse return ret64(frame, 0);
            const needle: u8 = @truncate(a2);
            if (needle == 0) return ret64(frame, a1 + s.len);
            if (f == .strchr) {
                for (s, 0..) |ch, i| {
                    if (ch == needle) return ret64(frame, a1 + i);
                }
            } else {
                var i: usize = s.len;
                while (i > 0) : (i -= 1) {
                    if (s[i - 1] == needle) return ret64(frame, a1 + i - 1);
                }
            }
            ret64(frame, 0);
        },
        .strstr => {
            var b1: [4096]u8 = undefined;
            var b2: [1024]u8 = undefined;
            const hay = uaccess.readCStr(a1, &b1) orelse return ret64(frame, 0);
            const needle = uaccess.readCStr(a2, &b2) orelse return ret64(frame, 0);
            if (std.mem.indexOf(u8, hay, needle)) |pos| return ret64(frame, a1 + pos);
            ret64(frame, 0);
        },
        .toupper, .tolower => {
            const ch: u8 = @truncate(a2);
            ret64(frame, if (f == .toupper) std.ascii.toUpper(ch) else std.ascii.toLower(ch));
        },
        // ---- CRT: heap over the per-task arena -------------------------------
        .malloc => {
            const ptr = heapAlloc(t, a1, false) orelse {
                t.last_error = ERROR_NOT_ENOUGH_MEMORY;
                return ret64(frame, 0);
            };
            ret64(frame, ptr);
        },
        .calloc => {
            const total = a1 *| a2;
            const ptr = heapAlloc(t, total, true) orelse return ret64(frame, 0);
            ret64(frame, ptr);
        },
        .realloc => {
            const ptr = heapRealloc(t, a1, a2) orelse return ret64(frame, 0);
            ret64(frame, ptr);
        },
        .free => {
            // CRT free() may be handed pointers from either the Win32 heap or
            // VirtualAlloc; our heapFree only understands its own blocks.
            heapFree(t, a1);
            ret64(frame, 0);
        },
        .abort, .exit, ._exit => process.exitCurrent(if (f == .abort) -1 else @intCast(@as(u32, @truncate(a1)))),
        .atexit => ret64(frame, 0),
        // ---- CRT: console output ---------------------------------------------
        .puts => {
            var buf: [4096]u8 = undefined;
            const s = uaccess.readCStr(a1, &buf) orelse return ret64(frame, @as(u64, @bitCast(@as(i64, -1))));
            _ = fdtable.write(t, fdtable.STDOUT, s);
            _ = fdtable.write(t, fdtable.STDOUT, "\n");
            ret64(frame, 1);
        },
        .putchar => {
            const ch: u8 = @truncate(a1);
            _ = fdtable.write(t, fdtable.STDOUT, &[1]u8{ch});
            ret64(frame, @as(u8, ch));
        },
        .printf => {
            var buf: [4096]u8 = undefined;
            var fb: [1024]u8 = undefined;
            const fmt = uaccess.readCStr(a1, &fb) orelse return ret64(frame, @as(u64, @bitCast(@as(i64, -1))));
            var iter = ArgIter{ .frame = frame, .next = 1 };
            const n = cFormat(&buf, fmt, &iter);
            _ = fdtable.write(t, fdtable.STDOUT, buf[0..n]);
            ret64(frame, n);
        },
        .sprintf, ._snprintf, .snprintf => {
            const dst = a1;
            const cap: u64 = if (f == .sprintf) 4096 else a2;
            var fb: [1024]u8 = undefined;
            const fmt = uaccess.readCStr(if (f == .sprintf) a2 else a3, &fb) orelse return ret64(frame, 0);
            var out: [4096]u8 = undefined;
            var iter = ArgIter{
                .frame = frame,
                .next = if (f == .sprintf) 2 else 3,
            };
            const n = cFormat(&out, fmt, &iter);
            const copy = @min(n, @min(cap -| 1, out.len));
            _ = uaccess.writeBytes(dst, out[0..copy]);
            _ = uaccess.writeU8(dst + copy, 0);
            ret64(frame, n);
        },
        // ---- WinSock 2 -------------------------------------------------------
        .WSAStartup => {
            // Fill the WSADATA fields programs actually read: version pair and
            // the description string. Everything else stays zero.
            if (a2 != 0) {
                _ = uaccess.writeU16(a2, 0x0202); // wVersion 2.2
                _ = uaccess.writeU16(a2 + 2, 0x0202); // wHighVersion
                _ = uaccess.writeBytes(a2 + 4, "Zirconium WinSock 2.2");
                _ = uaccess.writeU8(a2 + 4 + 21, 0);
            }
            ret64(frame, 0);
        },
        .WSACleanup => ret64(frame, 0),
        .WSAGetLastError => ret64(frame, t.last_error),
        .WSASetLastError => {
            t.last_error = @truncate(a1);
            ret64(frame, 0);
        },
        .socket => {
            const tcp = @import("../net/tcp.zig");
            const conn = tcp.allocConnection() orelse {
                t.last_error = WSA_NOT_ENOUGH_MEMORY;
                return ret64(frame, INVALID_SOCKET);
            };
            const fd = fdtable.alloc(t, .{ .socket = conn }) orelse {
                tcp.disconnect(conn);
                t.last_error = WSA_NOT_ENOUGH_MEMORY;
                return ret64(frame, INVALID_SOCKET);
            };
            ret64(frame, HANDLE_SOCKET_BASE + fd);
        },
        .closesocket => {
            const fd = socketToFd(t, a1) orelse {
                t.last_error = WSAENOTSOCK;
                return ret64(frame, INVALID_SOCKET);
            };
            _ = fdtable.close(t, fd);
            ret64(frame, 0);
        },
        .shutdown => ret64(frame, 0),
        .connect => {
            const fd = socketToFd(t, a1) orelse {
                t.last_error = WSAENOTSOCK;
                return ret64(frame, INVALID_SOCKET);
            };
            const desc = fdtable.get(t, fd) orelse return ret64(frame, INVALID_SOCKET);
            const conn = switch (desc) {
                .socket => |c| c,
                else => return ret64(frame, INVALID_SOCKET),
            };
            // struct sockaddr_in { u16 family; u16 port_be; u32 addr_be; }
            const port_be = uaccess.readU16(a2 + 2) orelse {
                t.last_error = WSAEFAULT;
                return ret64(frame, INVALID_SOCKET);
            };
            const port: u16 = @byteSwap(port_be);
            var ip: [4]u8 = undefined;
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                ip[i] = uaccess.readU8(a2 + 4 + i) orelse {
                    t.last_error = WSAEFAULT;
                    return ret64(frame, INVALID_SOCKET);
                };
            }
            const tcp = @import("../net/tcp.zig");
            tcp.openConn(conn, ip, port);
            if (!tcp.waitEstablished(conn, 500)) {
                t.last_error = WSAECONNREFUSED;
                return ret64(frame, INVALID_SOCKET);
            }
            ret64(frame, 0);
        },
        .send => {
            const fd = socketToFd(t, a1) orelse {
                t.last_error = WSAENOTSOCK;
                return ret64(frame, INVALID_SOCKET);
            };
            const len: u64 = a3;
            const buf = uaccess.userSliceConst(a2, len) orelse {
                t.last_error = WSAEFAULT;
                return ret64(frame, INVALID_SOCKET);
            };
            const n = fdtable.write(t, fd, buf);
            if (n < 0) {
                t.last_error = WSAECONNABORTED;
                return ret64(frame, INVALID_SOCKET);
            }
            ret64(frame, @intCast(n));
        },
        .recv => {
            const fd = socketToFd(t, a1) orelse {
                t.last_error = WSAENOTSOCK;
                return ret64(frame, INVALID_SOCKET);
            };
            const len: u64 = a3;
            const buf = uaccess.userSlice(a2, len) orelse {
                t.last_error = WSAEFAULT;
                return ret64(frame, INVALID_SOCKET);
            };
            const n = fdtable.read(t, fd, buf);
            if (n < 0) {
                t.last_error = WSAECONNABORTED;
                return ret64(frame, INVALID_SOCKET);
            }
            ret64(frame, @intCast(n));
        },
        .htons => ret64(frame, @as(u16, @byteSwap(@as(u16, @truncate(a1))))),
        .htonl => ret64(frame, @as(u32, @byteSwap(@as(u32, @truncate(a1))))),
        .ntohs => ret64(frame, @as(u16, @byteSwap(@as(u16, @truncate(a1))))),
        .ntohl => ret64(frame, @as(u32, @byteSwap(@as(u32, @truncate(a1))))),
        .inet_addr => {
            var buf: [64]u8 = undefined;
            const s = uaccess.readCStr(a1, &buf) orelse return ret64(frame, INADDR_NONE);
            var ip: [4]u8 = undefined;
            var part: u32 = 0;
            var count: usize = 0;
            var any_digit = false;
            for (s) |ch| {
                if (ch >= '0' and ch <= '9') {
                    part = part * 10 + (ch - '0');
                    if (part > 255) return ret64(frame, INADDR_NONE);
                    any_digit = true;
                } else if (ch == '.') {
                    if (!any_digit or count >= 4) return ret64(frame, INADDR_NONE);
                    ip[count] = @intCast(part);
                    count += 1;
                    part = 0;
                    any_digit = false;
                } else return ret64(frame, INADDR_NONE);
            }
            if (!any_digit or count != 3) return ret64(frame, INADDR_NONE);
            ip[3] = @intCast(part);
            const packed_ip: u32 = (@as(u32, ip[0]) << 24) | (@as(u32, ip[1]) << 16) |
                (@as(u32, ip[2]) << 8) | ip[3];
            ret64(frame, packed_ip); // network byte order
        },
        .setsockopt, .ioctlsocket => ret64(frame, 0),
        .getsockopt => ret64(frame, 0),
        // Every descriptor is reported ready: our blocking reads poll anyway.
        .select => ret64(frame, a1),

        // ---- UCRT startup: table walkers and config setters are no-ops ----
        ._initterm, ._initterm_e, ._configure_narrow_argv, ._configure_wide_argv,
        ._initialize_narrow_environment, ._initialize_wide_environment,
        ._set_app_type, .__setusermatherr, ._configthreadlocale,
        ._lock_file, ._unlock_file, .raise, .setvbuf, .fflush, .fclose,
        .feof, .ferror, ._tzset, ._cexit => ret64(frame, 0),
        ._crt_atexit, ._set_invalid_parameter_handler, ._set_new_mode => {
            // "previous handler/mode" — none existed.
            ret64(frame, 0);
        },

        // ---- CRT data globals: pointers into the task's user block ----------
        .__p___argc => ret64(frame, t.crt_block),
        .__p___wargv => ret64(frame, t.crt_block + 8),
        .__p__environ => ret64(frame, t.crt_block + 16),
        .__p__wenviron => ret64(frame, t.crt_block + 24),
        .__p__commode => ret64(frame, t.crt_block + 32),
        .__p__fmode => ret64(frame, t.crt_block + 40),
        .__daylight => ret64(frame, t.crt_block + 48),
        .__timezone => ret64(frame, t.crt_block + 56),
        .__tzname => ret64(frame, t.crt_block + 64),
        ._errno => {
            if (t.crt_block != 0) _ = uaccess.writeU64(t.crt_block + 72, 0);
            ret64(frame, t.crt_block + 72);
        },

        .__acrt_iob_func => ret64(frame, STREAM_BASE + @min(a1, 2)),
        .GetCurrentThread => ret64(frame, HANDLE_PROCESS),
        .TryEnterCriticalSection => retBool(frame, true),

        ._assert, ._wassert => {
            var mb: [256]u8 = undefined;
            const msg: []const u8 = if (f == ._assert)
                (uaccess.readCStr(a1, &mb) orelse "assert")
            else
                "wide assertion";
            serial.serialWrite("[CRT] assertion failed: ");
            serial.serialWrite(msg);
            serial.serialWrite("\n");
            process.exitCurrent(-1);
        },
        .perror => {
            var mb: [256]u8 = undefined;
            const msg = uaccess.readCStr(a1, &mb) orelse "";
            _ = fdtable.write(t, fdtable.STDERR, msg);
            _ = fdtable.write(t, fdtable.STDERR, ": error\n");
            ret64(frame, 0);
        },

        // ---- stdio over pseudo FILE* and raw fds ----------------------------
        .fwrite => {
            const total = a2 *| a3;
            const fd = streamToFd(a4) orelse return ret64(frame, 0);
            const buf = uaccess.userSliceConst(a1, total) orelse return ret64(frame, 0);
            const n = fdtable.write(t, fd, buf);
            if (n <= 0) return ret64(frame, 0);
            ret64(frame, @as(u64, @intCast(n)) / @max(a2, 1));
        },
        .fread => {
            const total = a2 *| a3;
            const buf = uaccess.userSlice(a1, total) orelse return ret64(frame, 0);
            const fd = streamToFd(a4) orelse return ret64(frame, 0);
            const n = fdtable.read(t, fd, buf[0..@intCast(total)]);
            if (n <= 0) return ret64(frame, 0);
            ret64(frame, @as(u64, @intCast(n)) / @max(a2, 1));
        },
        .fputs => {
            var b: [4096]u8 = undefined;
            const s = uaccess.readCStr(a1, &b) orelse return ret64(frame, @bitCast(@as(i64, -1)));
            const fd = streamToFd(a2) orelse return ret64(frame, @bitCast(@as(i64, -1)));
            _ = fdtable.write(t, fd, s);
            ret64(frame, 1);
        },
        .fputc => {
            const fd = streamToFd(a2) orelse return ret64(frame, @bitCast(@as(i64, -1)));
            _ = fdtable.write(t, fd, &[1]u8{@truncate(a1)});
            ret64(frame, a1 & 0xFF);
        },
        .getc => {
            const fd = streamToFd(a1) orelse return ret64(frame, @bitCast(@as(i64, -1)));
            var one: [1]u8 = undefined;
            const n = fdtable.read(t, fd, &one);
            ret64(frame, if (n <= 0) @as(u64, @bitCast(@as(i64, -1))) else one[0]);
        },
        .fgets => {
            const fd = streamToFd(a3) orelse return ret64(frame, 0);
            const cap: usize = @intCast(@min(a2, 4096));
            var ln: usize = 0;
            while (ln + 1 < cap) : (ln += 1) {
                var one: [1]u8 = undefined;
                const n = fdtable.read(t, fd, &one);
                if (n <= 0) break;
                _ = uaccess.writeU8(a1 + ln, one[0]);
                if (one[0] == '\n') {
                    ln += 1;
                    break;
                }
            }
            if (ln == 0) return ret64(frame, 0);
            _ = uaccess.writeU8(a1 + ln, 0);
            ret64(frame, a1);
        },
        ._fileno => {
            if (streamToFd(a1)) |fd| return ret64(frame, fd);
            if (handleToFd(t, a1)) |fd| return ret64(frame, fd);
            ret64(frame, @bitCast(@as(i64, -1)));
        },
        ._get_osfhandle => {
            const fd: usize = @intCast(@min(a1, task.MAX_FDS - 1));
            if (t.fds[fd] != null) return ret64(frame, HANDLE_FILE_BASE + fd);
            ret64(frame, INVALID_HANDLE);
        },
        ._isatty => ret64(frame, if (a1 <= 2) 1 else 0),
        ._open => {
            // MSVC flags: _O_WRONLY=1 _O_RDWR=2 _O_CREAT=0x100 _O_TRUNC=0x200.
            var pb: [256]u8 = undefined;
            const path = uaccess.readCStr(a1, &pb) orelse return ret64(frame, @bitCast(@as(i64, -1)));
            const want_write = (a2 & 3) != 0;
            const handle = vfs.open(path, .{
                .read = !want_write or (a2 & 2) != 0,
                .write = want_write,
                .create = (a2 & 0x100) != 0,
                .truncate = (a2 & 0x200) != 0,
            }) orelse return ret64(frame, @bitCast(@as(i64, -1)));
            const fd = fdtable.alloc(t, .{ .file = handle }) orelse {
                vfs.close(handle);
                return ret64(frame, @bitCast(@as(i64, -1)));
            };
            ret64(frame, fd);
        },
        ._close => {
            const fd: usize = @intCast(@min(a1, task.MAX_FDS - 1));
            if (t.fds[fd] == null) return ret64(frame, @bitCast(@as(i64, -1)));
            _ = fdtable.close(t, fd);
            ret64(frame, 0);
        },
        ._read => {
            const fd: usize = @intCast(@min(a1, task.MAX_FDS - 1));
            const cnt: u64 = @truncate(a3);
            const buf = uaccess.userSlice(a2, cnt) orelse return ret64(frame, @bitCast(@as(i64, -1)));
            const n = fdtable.read(t, fd, buf);
            ret64(frame, @bitCast(n));
        },
        ._write => {
            const fd: usize = @intCast(@min(a1, task.MAX_FDS - 1));
            const cnt: u64 = @truncate(a3);
            const buf = uaccess.userSliceConst(a2, cnt) orelse return ret64(frame, @bitCast(@as(i64, -1)));
            const n = fdtable.write(t, fd, buf);
            ret64(frame, @bitCast(n));
        },
        ._setmode => ret64(frame, 0x8000), // prev mode O_BINARY
        ._fdopen, ._wfopen => ret64(frame, 0), // FILE streams for files unsupported

        // ---- string extras ---------------------------------------------------
        .memchr => {
            const n: u64 = a3;
            const s = uaccess.userSliceConst(a1, n) orelse return ret64(frame, 0);
            for (s, 0..) |ch, i| {
                if (ch == @as(u8, @truncate(a2))) return ret64(frame, a1 + i);
            }
            ret64(frame, 0);
        },
        .strnlen => {
            var b: [4096]u8 = undefined;
            const full = uaccess.readCStr(a1, &b) orelse return ret64(frame, 0);
            ret64(frame, @min(full.len, a2));
        },
        .strspn => {
            var sb: [256]u8 = undefined;
            var ab: [128]u8 = undefined;
            const s = uaccess.readCStr(a1, &sb) orelse return ret64(frame, 0);
            const acc = uaccess.readCStr(a2, &ab) orelse return ret64(frame, 0);
            var k: usize = 0;
            while (k < s.len) : (k += 1) {
                var hit = false;
                for (acc) |c| {
                    if (c == s[k]) {
                        hit = true;
                        break;
                    }
                }
                if (!hit) break;
            }
            ret64(frame, k);
        },
        ._strdup => {
            var b: [1024]u8 = undefined;
            const s = uaccess.readCStr(a1, &b) orelse return ret64(frame, 0);
            const p = heapAlloc(t, s.len + 1, false) orelse return ret64(frame, 0);
            _ = uaccess.writeBytes(p, s);
            _ = uaccess.writeU8(p + s.len, 0);
            ret64(frame, p);
        },
        ._strnicmp => {
            var b1: [512]u8 = undefined;
            var b2: [512]u8 = undefined;
            const s1 = uaccess.readCStr(a1, &b1) orelse return ret64(frame, 0);
            const s2 = uaccess.readCStr(a2, &b2) orelse return ret64(frame, 0);
            const max: usize = @intCast(@min(a3, @max(s1.len, s2.len)));
            var i: usize = 0;
            while (i < max) : (i += 1) {
                const c1: u8 = std.ascii.toUpper(if (i < s1.len) s1[i] else 0);
                const c2: u8 = std.ascii.toUpper(if (i < s2.len) s2[i] else 0);
                if (c1 != c2) return ret64(frame, if (c1 < c2) @as(u64, @bitCast(@as(i64, -1))) else 1);
                if (c1 == 0) break;
            }
            ret64(frame, 0);
        },
        .isalnum, .isalpha, .isdigit, .isspace, .isupper, .islower => {
            const ch: u8 = @truncate(a1);
            const r = switch (f) {
                .isalnum => std.ascii.isAlphanumeric(ch),
                .isalpha => std.ascii.isAlphabetic(ch),
                .isdigit => std.ascii.isDigit(ch),
                .isspace => std.ascii.isWhitespace(ch),
                .isupper => std.ascii.isUpper(ch),
                .islower => std.ascii.isLower(ch),
                else => false,
            };
            ret64(frame, @intFromBool(r));
        },
        .wcslen => {
            var k: u64 = 0;
            while (k < 8192) : (k += 1) {
                const unit = uaccess.readU16(a1 + k * 2) orelse break;
                if (unit == 0) break;
            }
            ret64(frame, k);
        },
        .wcsnlen => {
            var k: u64 = 0;
            while (k < a2) : (k += 1) {
                const unit = uaccess.readU16(a1 + k * 2) orelse break;
                if (unit == 0) break;
            }
            ret64(frame, k);
        },

        .atoi, .strtol => {
            var b: [128]u8 = undefined;
            const s = uaccess.readCStr(a1, &b) orelse return ret64(frame, 0);
            var i: usize = 0;
            while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
            var neg = false;
            if (i < s.len and (s[i] == '-' or s[i] == '+')) {
                neg = s[i] == '-';
                i += 1;
            }
            var base: u64 = if (f == .atoi) 10 else a3;
            if (base == 0) {
                if (i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
                    base = 16;
                    i += 2;
                } else base = 10;
            } else if (base == 16 and i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
                i += 2;
            }
            var v: i64 = 0;
            while (i < s.len) : (i += 1) {
                const d: u8 = switch (s[i]) {
                    '0'...'9' => s[i] - '0',
                    'a'...'f' => s[i] - 'a' + 10,
                    'A'...'F' => s[i] - 'A' + 10,
                    else => 255,
                };
                if (d >= base) break;
                v = v *% @as(i64, @intCast(base)) +% d;
            }
            if (neg) v = -v;
            if (f == .strtol and a2 != 0) _ = uaccess.writeU64(a2, a1 + i);
            ret64(frame, @bitCast(v));
        },

        // ---- UCRT printf core -----------------------------------------------
        .__stdio_common_vfprintf => {
            // (options, stream, format, locale, va_list)
            var fb: [1024]u8 = undefined;
            const fmtv = uaccess.readCStr(a3, &fb) orelse return ret64(frame, @bitCast(@as(i64, -1)));
            var it = VaListIter.init(stackArg(frame, 4)) orelse return ret64(frame, @bitCast(@as(i64, -1)));
            var out: [4096]u8 = undefined;
            const n = cFormat(&out, fmtv, &it);
            const fd = streamToFd(a2) orelse fdtable.STDOUT;
            _ = fdtable.write(t, fd, out[0..n]);
            ret64(frame, n);
        },
        .__stdio_common_vsprintf => {
            // (options, buffer, count, format, locale, va_list)
            const dst = a2;
            const cap: u64 = a3;
            var fb: [1024]u8 = undefined;
            const fmtv = uaccess.readCStr(a4, &fb) orelse return ret64(frame, @bitCast(@as(i64, -1)));
            var it = VaListIter.init(stackArg(frame, 5)) orelse return ret64(frame, @bitCast(@as(i64, -1)));
            var out: [4096]u8 = undefined;
            const n = cFormat(&out, fmtv, &it);
            const copy = @min(n, cap -| 1);
            _ = uaccess.writeBytes(dst, out[0..copy]);
            _ = uaccess.writeU8(dst + copy, 0);
            ret64(frame, n);
        },

        // ---- time: monotonic since boot mapped onto a 2026 epoch ------------
        ._time64 => {
            const v: u64 = 1787385600 + timer.ticks / 100;
            if (a1 != 0) _ = uaccess.writeU64(a1, v);
            ret64(frame, v);
        },
        ._gmtime64 => {
            // Return pointer to a zeroed tm inside the CRT block.
            if (t.crt_block != 0) {
                var k: u64 = 0;
                while (k < 56) : (k += 8) _ = uaccess.writeU64(t.crt_block + 128 + k, 0);
                ret64(frame, t.crt_block + 128);
            } else ret64(frame, 0);
        },
        ._localtime64_s => {
            if (a1 != 0) _ = uaccess.writeU32(a1, 0); // errno_t success
            ret64(frame, 0);
        },
        ._mktime64, ._mkgmtime64 => ret64(frame, 1787385600 + timer.ticks / 100),
        .rand_s => {
            const v: u32 = @truncate(timer.ticks *% 2654435761 ^ a1);
            if (a1 != 0) _ = uaccess.writeU32(a1, v);
            ret64(frame, 0);
        },
        .GetProcAddress => {
            // Resolve by name against the same table the loader uses.
            var name_buf: [128]u8 = undefined;
            const name = uaccess.readCStr(a2, &name_buf) orelse return ret64(frame, 0);
            const target = lookupName(name) orelse {
                serial.serialWrite("[WIN32] GetProcAddress miss: ");
                serial.serialWrite(name);
                serial.serialWrite("\n");
                return ret64(frame, 0);
            };
            ret64(frame, thunkAddr(target));
        },
        .GetTickCount => ret64(frame, (timer.ticks * 10) & 0xFFFFFFFF),
        .GetTickCount64 => ret64(frame, timer.ticks * 10),
        .QueryPerformanceCounter => {
            _ = uaccess.writeU64(a1, timer.ticks);
            retBool(frame, true);
        },
        .QueryPerformanceFrequency => {
            _ = uaccess.writeU64(a1, 100); // PIT tick rate
            retBool(frame, true);
        },
        .GetSystemTimeAsFileTime => {
            // 100ns units since 1601; we only guarantee monotonicity.
            const value: u64 = 116444736000000000 + timer.ticks * 100_000;
            _ = uaccess.writeU64(a1, value);
            ret64(frame, 0);
        },
        .Sleep => {
            if (a1 > 0) timer.sleep(@intCast(@min(a1, 60_000)));
            ret64(frame, 0);
        },
        .GetCurrentProcess => ret64(frame, HANDLE_PROCESS),
        .GetCurrentProcessId, .GetCurrentThreadId => ret64(frame, t.id + 1),
        .TlsAlloc => {
            if (t.tls_used >= t.tls_slots.len) return ret64(frame, 0xFFFFFFFF);
            const slot = t.tls_used;
            t.tls_used += 1;
            t.tls_slots[slot] = 0;
            ret64(frame, slot);
        },
        .TlsGetValue => {
            if (a1 >= t.tls_slots.len) return ret64(frame, 0);
            ret64(frame, t.tls_slots[@intCast(a1)]);
        },
        .TlsSetValue => {
            if (a1 >= t.tls_slots.len) return retBool(frame, false);
            t.tls_slots[@intCast(a1)] = a2;
            retBool(frame, true);
        },
        .TlsFree => retBool(frame, true),
        .CreateFileA, .CreateFileW => {
            const handle = createFile(t, f == .CreateFileW, a1, a2, stackArg(frame, 4)) orelse {
                t.last_error = ERROR_FILE_NOT_FOUND;
                return ret64(frame, INVALID_HANDLE);
            };
            ret64(frame, handle);
        },
        .SetFilePointerEx => {
            const fd = handleToFd(t, a1) orelse return retBool(frame, false);
            const FILE_CURRENT: u64 = 1;
            const target = if (a4 == FILE_CURRENT) fdtable.tell(t, fd) + a2 else a2;
            if (!fdtable.seek(t, fd, target)) return retBool(frame, false);
            if (a3 != 0) _ = uaccess.writeU64(a3, target);
            retBool(frame, true);
        },
        .GetFileSizeEx => {
            // Only files opened by name have a known size; report 0 otherwise.
            _ = uaccess.writeU64(a2, 0);
            retBool(frame, true);
        },
        .GetFileType => {
            const FILE_TYPE_CHAR: u64 = 0x0002;
            const FILE_TYPE_DISK: u64 = 0x0001;
            const fd = handleToFd(t, a1) orelse return ret64(frame, 0);
            ret64(frame, if (fdtable.isTty(t, fd)) FILE_TYPE_CHAR else FILE_TYPE_DISK);
        },
        .GetConsoleMode => {
            const fd = handleToFd(t, a1) orelse return retBool(frame, false);
            if (!fdtable.isTty(t, fd)) return retBool(frame, false);
            _ = uaccess.writeU32(a2, 0x0003); // ENABLE_PROCESSED_INPUT|LINE_INPUT
            retBool(frame, true);
        },
        .SetConsoleMode => retBool(frame, true),
        .IsProcessorFeaturePresent => retBool(frame, false),
        .InitializeSListHead => {
            _ = uaccess.writeU64(a1, 0);
            ret64(frame, 0);
        },
        .RtlCaptureContext => ret64(frame, 0),
        .SetUnhandledExceptionFilter => ret64(frame, 0),
        .UnhandledExceptionFilter => ret64(frame, 1), // EXCEPTION_EXECUTE_HANDLER
        .RaiseException => {
            serial.serialWrite("[WIN32] RaiseException code=0x");
            serial.serialWriteHex(a1);
            serial.serialWrite("\n");
            process.exitCurrent(-1);
        },
        .GetSystemInfo => {
            // SYSTEM_INFO: page size @4, active processor mask @32, count @32+8.
            _ = uaccess.writeU32(a1 + 4, 4096);
            _ = uaccess.writeU32(a1 + 32, 1);
            retBool(frame, true);
        },
        .GetEnvironmentVariableA => {
            // DWORD GetEnvironmentVariableA(name, buffer, size): copies the
            // value plus NUL into the caller's buffer. Returns the number of
            // characters copied (excluding NUL); when the buffer is too small
            // or NULL it returns the required size including NUL and sets
            // ERROR_INSUFFICIENT_BUFFER, matching Win32 semantics.
            var name_buf: [env.KEY_MAX + 1]u8 = undefined;
            const value: ?[]const u8 = if (uaccess.readCStr(a1, &name_buf)) |name|
                env.get(name)
            else
                null;
            if (value) |val| {
                const nsize: usize = @intCast(a3);
                if (a2 == 0 or val.len + 1 > nsize) {
                    t.last_error = 122; // ERROR_INSUFFICIENT_BUFFER
                    ret64(frame, val.len + 1);
                } else {
                    _ = uaccess.writeBytes(a2, val);
                    _ = uaccess.writeU8(a2 + val.len, 0);
                    ret64(frame, val.len);
                }
            } else {
                if (a2 != 0 and a3 > 0) _ = uaccess.writeU8(a2, 0);
                t.last_error = 203; // ERROR_ENVVAR_NOT_FOUND
                ret64(frame, 0);
            }
        },
        .GetEnvironmentStringsW => {
            // Build a "KEY=VALUE\0" UTF-16 block, double-NUL terminated, in
            // fresh anonymous user memory. The program owns it until exit
            // (FreeEnvironmentStringsW is a no-op, like VirtualFree).
            var needed: usize = 4; // final double NUL
            var i: usize = 0;
            while (i < env.maxEntries()) : (i += 1) {
                if (env.getAt(i)) |e| needed += (e.key.len + e.value.len + 2) * 2;
            }
            const base = process.mmapAnon(t, needed) orelse {
                t.last_error = ERROR_NOT_ENOUGH_MEMORY;
                return ret64(frame, 0);
            };
            var wpos: u64 = base;
            var line_buf: [env.KEY_MAX + env.VAL_MAX + 2]u8 = undefined;
            i = 0;
            while (i < env.maxEntries()) : (i += 1) {
                const e = env.getAt(i) orelse continue;
                @memcpy(line_buf[0..e.key.len], e.key);
                line_buf[e.key.len] = '=';
                @memcpy(line_buf[e.key.len + 1 ..][0..e.value.len], e.value);
                const total = e.key.len + 1 + e.value.len;
                const chars = uaccess.writeUtf16(wpos, line_buf[0..total], (needed / 2) - 1) orelse 0;
                wpos += chars * 2;
                _ = uaccess.writeU16(wpos, 0);
                wpos += 2;
            }
            _ = uaccess.writeU16(wpos, 0); // block terminator
            ret64(frame, base);
        },
        .FreeEnvironmentStringsW => retBool(frame, true),
        .GetACP => ret64(frame, 65001), // UTF-8
        .MultiByteToWideChar => {
            const src_len: i64 = @bitCast(a4);
            const dst_ptr = stackArg(frame, 4);
            const dst_chars = stackArg(frame, 5);
            ret64(frame, mbToWide(a3, src_len, dst_ptr, dst_chars));
        },
        .WideCharToMultiByte => {
            const src_len: i64 = @bitCast(a4);
            const dst_ptr = stackArg(frame, 4);
            const dst_bytes = stackArg(frame, 5);
            ret64(frame, wideToMb(a3, src_len, dst_ptr, dst_bytes));
        },
        .SetHandleCount => ret64(frame, a1),
        .GetStartupInfoA, .GetStartupInfoW => {
            // Zero the STARTUPINFO and set cb; nothing else is meaningful here.
            var off: u64 = 0;
            while (off < 104) : (off += 8) _ = uaccess.writeU64(a1 + off, 0);
            _ = uaccess.writeU32(a1, 104);
            ret64(frame, 0);
        },
        .EnterCriticalSection, .LeaveCriticalSection, .InitializeCriticalSection, .DeleteCriticalSection => {
            // Single-threaded: locks are no-ops.
            ret64(frame, 0);
        },
        .InitializeCriticalSectionEx => retBool(frame, true),
        .GetVersion => ret64(frame, 0x0A00), // Windows 10-ish
        .GetVersionExA => retBool(frame, true),
        .IsDebuggerPresent => retBool(frame, false),
        .OutputDebugStringA => {
            var buf: [256]u8 = undefined;
            if (uaccess.readCStr(a1, &buf)) |s| {
                serial.serialWrite("[WIN32-DBG] ");
                serial.serialWrite(s);
                serial.serialWrite("\n");
            }
            ret64(frame, 0);
        },
    }
}

// ---------------------------------------------------------------------------
// Process heap: a bump/free-list allocator inside the task's mmap arena.
// Layout per block: [u64 size][payload]
// ---------------------------------------------------------------------------

const HEAP_HDR: u64 = 16; // keeps payloads 16-byte aligned

fn heapAlloc(t: *task.Task, size: u64, zero: bool) ?u64 {
    const need = (size + 15) & ~@as(u64, 15);
    const total = need + HEAP_HDR;

    // First fit over the free list.
    var prev: u64 = 0;
    var cur = t.heap_free_head;
    while (cur != 0) {
        const block_size = uaccess.readU64(cur) orelse break;
        const next = uaccess.readU64(cur + 8) orelse break;
        if (block_size >= total) {
            if (prev == 0) {
                t.heap_free_head = next;
            } else {
                _ = uaccess.writeU64(prev + 8, next);
            }
            if (zero) zeroUser(cur + HEAP_HDR, block_size - HEAP_HDR);
            return cur + HEAP_HDR;
        }
        prev = cur;
        cur = next;
    }

    const base = process.mmapAnon(t, total) orelse return null;
    _ = uaccess.writeU64(base, total);
    // mmapAnon hands back zeroed pages, so `zero` needs nothing extra here.
    return base + HEAP_HDR;
}

fn heapFree(t: *task.Task, ptr: u64) void {
    if (ptr == 0) return;
    const block = ptr - HEAP_HDR;
    _ = uaccess.writeU64(block + 8, t.heap_free_head);
    t.heap_free_head = block;
}

fn heapSize(ptr: u64) u64 {
    if (ptr == 0) return 0;
    const total = uaccess.readU64(ptr - HEAP_HDR) orelse return 0;
    return total - HEAP_HDR;
}

fn heapRealloc(t: *task.Task, ptr: u64, size: u64) ?u64 {
    if (ptr == 0) return heapAlloc(t, size, false);
    const old_size = heapSize(ptr);
    if (old_size >= size) return ptr;
    const new_ptr = heapAlloc(t, size, false) orelse return null;
    const src = uaccess.userSliceConst(ptr, old_size) orelse return null;
    const dst = uaccess.userSlice(new_ptr, old_size) orelse return null;
    @memcpy(dst, src);
    heapFree(t, ptr);
    return new_ptr;
}

fn zeroUser(addr: u64, len: u64) void {
    if (uaccess.userSlice(addr, len)) |slice| @memset(slice, 0);
}

fn createFile(t: *task.Task, wide: bool, name_ptr: u64, access: u64, creation: u64) ?u64 {
    var path_buf: [256]u8 = undefined;
    var path: []const u8 = undefined;
    if (wide) {
        var i: usize = 0;
        while (i < path_buf.len - 1) : (i += 1) {
            const unit = uaccess.readU16(name_ptr + i * 2) orelse return null;
            if (unit == 0) break;
            path_buf[i] = if (unit < 0x80) @intCast(unit) else '?';
        }
        path = path_buf[0..i];
    } else {
        path = uaccess.readCStr(name_ptr, &path_buf) orelse return null;
    }
    if (path.len == 0) return null;

    const GENERIC_WRITE: u64 = 0x40000000;
    const CREATE_ALWAYS: u64 = 2;
    const CREATE_NEW: u64 = 1;
    const want_write = access & GENERIC_WRITE != 0;

    const handle = vfs.open(path, .{
        .read = !want_write,
        .write = want_write,
        .create = creation == CREATE_ALWAYS or creation == CREATE_NEW,
        .truncate = creation == CREATE_ALWAYS,
    }) orelse return null;

    const fd = fdtable.alloc(t, .{ .file = handle }) orelse {
        vfs.close(handle);
        return null;
    };
    return HANDLE_FILE_BASE + fd;
}

fn mbToWide(src: u64, src_len: i64, dst: u64, dst_chars: u64) u64 {
    var count: u64 = 0;
    var i: u64 = 0;
    while (true) : (i += 1) {
        if (src_len >= 0 and i >= @as(u64, @intCast(src_len))) break;
        const ch = uaccess.readU8(src + i) orelse break;
        if (dst != 0) {
            if (count >= dst_chars) return 0;
            _ = uaccess.writeU16(dst + count * 2, ch);
        }
        count += 1;
        if (src_len < 0 and ch == 0) break;
    }
    return count;
}

fn wideToMb(src: u64, src_len: i64, dst: u64, dst_bytes: u64) u64 {
    var count: u64 = 0;
    var i: u64 = 0;
    while (true) : (i += 1) {
        if (src_len >= 0 and i >= @as(u64, @intCast(src_len))) break;
        const unit = uaccess.readU16(src + i * 2) orelse break;
        const ch: u8 = if (unit < 0x80) @intCast(unit) else '?';
        if (dst != 0) {
            if (count >= dst_bytes) return 0;
            _ = uaccess.writeU8(dst + count, ch);
        }
        count += 1;
        if (src_len < 0 and unit == 0) break;
    }
    return count;
}
