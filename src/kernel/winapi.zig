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
