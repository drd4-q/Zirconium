//! Process construction and teardown shared by all personalities.
//!
//! Owns the parts that differ per binary format: the initial user stack layout
//! (SysV argc/argv/envp/auxv for Linux, a return-to-exit trampoline for PE) and
//! the anonymous mapping arena used by mmap/VirtualAlloc.

const std = @import("std");
const serial = @import("../system/serial.zig");
const vga = @import("../system/vga.zig");
const task = @import("task.zig");
const scheduler = @import("scheduler.zig");
const address_space = @import("address_space.zig");
const binfmt = @import("binfmt.zig");
const winapi = @import("winapi.zig");
const fdtable = @import("fdtable.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const msr = @import("../arch/msr.zig");

pub const USER_STACK_TOP: u64 = address_space.USER_STACK_TOP;

/// ELF auxiliary vector tags we provide.
const AT_NULL: u64 = 0;
const AT_PHDR: u64 = 3;
const AT_PHENT: u64 = 4;
const AT_PHNUM: u64 = 5;
const AT_PAGESZ: u64 = 6;
const AT_BASE: u64 = 7;
const AT_FLAGS: u64 = 8;
const AT_ENTRY: u64 = 9;
const AT_UID: u64 = 11;
const AT_EUID: u64 = 12;
const AT_GID: u64 = 13;
const AT_EGID: u64 = 14;
const AT_SECURE: u64 = 23;
const AT_RANDOM: u64 = 25;

pub const SetupError = error{
    OutOfMemory,
    ArgsTooLong,
};

/// Load `data` into a fresh address space owned by `t` and prepare its initial
/// register/stack state. `argline` is the raw command line (program name first),
/// used for argv and GetCommandLine.
pub fn setup(t: *task.Task, data: []const u8, argline: []const u8) !void {
    const as = address_space.AddressSpace.create() orelse return error.OutOfMemory;
    t.address_space = as;
    errdefer {
        as.destroy();
        t.address_space = null;
    }

    const image = try binfmt.load(as, data);

    t.entry_point = image.entry;
    t.personality = switch (image.personality()) {
        .native => .native,
        .linux => .linux,
        .windows => .windows,
    };

    // The program break starts just past the image so a Linux binary's brk()
    // heap can never overlap its own data segment.
    const image_top = (image.image_end + 0xFFF) & ~@as(u64, 0xFFF);
    t.heap_brk = @max(task.USER_HEAP_BASE, image_top);
    t.heap_mapped = t.heap_brk;
    t.mmap_next = task.MMAP_BASE;
    t.heap_free_head = 0;

    // User stack
    const pages = task.USER_STACK_SIZE / 4096;
    const stack_phys = pmm.allocPages(pages) orelse return error.OutOfMemory;
    @memset(@as([*]u8, @ptrFromInt(stack_phys))[0..task.USER_STACK_SIZE], 0);
    t.user_stack_phys = stack_phys;
    t.user_stack_pages = pages;
    const stack_bottom = USER_STACK_TOP - task.USER_STACK_SIZE;
    as.mapUserRange(stack_bottom, stack_phys, task.USER_STACK_SIZE, vmm.PAGE_WRITE);

    fdtable.initStdio(t);

    const rsp = switch (t.personality) {
        .windows => try setupWindowsStack(t, as, stack_phys, argline),
        else => try setupSysVStack(as, stack_phys, image, argline),
    };

    t.saved_state = .{};
    t.saved_state.rip = image.entry;
    t.saved_state.rsp = rsp;
    t.saved_state.rflags = 0x200; // IF=1
    t.saved_state.cs = @import("../arch/gdt.zig").USER_CODE_SEL;
    t.saved_state.ss = @import("../arch/gdt.zig").USER_DATA_SEL;

    serial.serialWrite("[PROC] ");
    serial.serialWrite(image.format.name());
    serial.serialWrite(" image ready: entry=0x");
    serial.serialWriteHex(image.entry);
    serial.serialWrite(" rsp=0x");
    serial.serialWriteHex(rsp);
    serial.serialWrite("\n");
}

pub fn setupFromPath(t: *task.Task, path: []const u8, argline: []const u8) !void {
    const file = try binfmt.readFile(path);
    defer binfmt.freeFile(file);
    try setup(t, file, argline);
}

/// A writer into the not-yet-active user stack. Because the target address space
/// is not the current CR3 we address the stack through its physical pages, which
/// are contiguous (allocPages), so a single offset translation is enough.
const StackBuilder = struct {
    phys_base: u64,
    /// Current virtual stack pointer, moving down.
    sp: u64,

    fn physOf(self: StackBuilder, vaddr: u64) u64 {
        const stack_bottom = USER_STACK_TOP - task.USER_STACK_SIZE;
        return self.phys_base + (vaddr - stack_bottom);
    }

    fn pushBytes(self: *StackBuilder, bytes: []const u8) u64 {
        self.sp -= bytes.len;
        const dst: [*]u8 = @ptrFromInt(self.physOf(self.sp));
        @memcpy(dst[0..bytes.len], bytes);
        return self.sp;
    }

    fn pushCStr(self: *StackBuilder, s: []const u8) u64 {
        self.sp -= 1;
        const nul: [*]u8 = @ptrFromInt(self.physOf(self.sp));
        nul[0] = 0;
        return self.pushBytes(s);
    }

    fn alignDown(self: *StackBuilder, alignment: u64) void {
        self.sp &= ~(alignment - 1);
    }

    fn pushU64(self: *StackBuilder, value: u64) void {
        self.sp -= 8;
        const dst: *u64 = @ptrFromInt(self.physOf(self.sp));
        dst.* = value;
    }

    fn writeU64At(self: StackBuilder, vaddr: u64, value: u64) void {
        const dst: *u64 = @ptrFromInt(self.physOf(vaddr));
        dst.* = value;
    }
};

const MAX_ARGS: usize = 16;

/// Split `line` on spaces into at most MAX_ARGS slices.
fn splitArgs(line: []const u8, out: *[MAX_ARGS][]const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < line.len and count < MAX_ARGS) {
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        if (i >= line.len) break;
        const start = i;
        while (i < line.len and line[i] != ' ') : (i += 1) {}
        out[count] = line[start..i];
        count += 1;
    }
    return count;
}

/// Build the System V AMD64 initial process stack that ELF entry code expects:
///
///   rsp -> argc
///          argv[0] .. argv[argc-1], NULL
///          envp[0] .. NULL
///          auxv pairs .., AT_NULL
///   (strings and the AT_RANDOM block live higher up)
fn setupSysVStack(
    as: address_space.AddressSpace,
    stack_phys: u64,
    image: binfmt.LoadedImage,
    argline: []const u8,
) !u64 {
    _ = as;
    var b = StackBuilder{ .phys_base = stack_phys, .sp = USER_STACK_TOP };

    // Leave a little headroom at the very top; some code reads past argv.
    b.sp -= 64;

    var argv_slices: [MAX_ARGS][]const u8 = undefined;
    var argc = splitArgs(argline, &argv_slices);
    if (argc == 0) {
        argv_slices[0] = "program";
        argc = 1;
    }

    // Strings first (they must stay above the vectors we build below).
    var argv_addrs: [MAX_ARGS]u64 = undefined;
    var i: usize = argc;
    while (i > 0) {
        i -= 1;
        argv_addrs[i] = b.pushCStr(argv_slices[i]);
    }

    const env_paths = "PATH=/bin:/mnt/disk";
    const env_term = "TERM=zirconium";
    const env_addr_term = b.pushCStr(env_term);
    const env_addr_path = b.pushCStr(env_paths);

    // AT_RANDOM: 16 bytes libc uses to seed its stack guard.
    const random_bytes = [_]u8{
        0x5A, 0x69, 0x72, 0x63, 0x6F, 0x6E, 0x69, 0x75,
        0x6D, 0x21, 0x13, 0x37, 0xC0, 0xDE, 0xBE, 0xEF,
    };
    const random_addr = b.pushBytes(&random_bytes);

    b.alignDown(16);

    // The ABI requires the final rsp (which points at argc) to be 16-byte
    // aligned, so count every word we are about to push and pad if it is odd.
    const aux_pairs: usize = 13; // see the pushAux calls below
    const aux_words = (aux_pairs + 1) * 2; // + the AT_NULL terminator pair
    const words = 1 + (argc + 1) + 3 + aux_words;
    if ((words % 2) != 0) b.sp -= 8;

    // Push from the top down: auxv last-to-first, then envp, argv, argc.
    b.pushU64(AT_NULL);
    b.pushU64(AT_NULL);
    pushAux(&b, AT_SECURE, 0);
    pushAux(&b, AT_EGID, 0);
    pushAux(&b, AT_GID, 0);
    pushAux(&b, AT_EUID, 0);
    pushAux(&b, AT_UID, 0);
    pushAux(&b, AT_RANDOM, random_addr);
    pushAux(&b, AT_FLAGS, 0);
    pushAux(&b, AT_BASE, 0);
    pushAux(&b, AT_ENTRY, image.entry);
    pushAux(&b, AT_PAGESZ, 4096);
    pushAux(&b, AT_PHNUM, image.phnum);
    pushAux(&b, AT_PHENT, image.phentsize);
    pushAux(&b, AT_PHDR, image.phdr_vaddr);

    b.pushU64(0); // envp terminator
    b.pushU64(env_addr_term);
    b.pushU64(env_addr_path);

    b.pushU64(0); // argv terminator
    i = argc;
    while (i > 0) {
        i -= 1;
        b.pushU64(argv_addrs[i]);
    }
    b.pushU64(argc);

    return b.sp;
}

fn pushAux(b: *StackBuilder, key: u64, value: u64) void {
    b.pushU64(value);
    b.pushU64(key);
}

/// A PE entry point is called like a normal Win64 function: 32 bytes of shadow
/// space above a return address, 16-byte aligned so that rsp+8 is aligned at
/// entry. The return address points at the ExitProcess thunk, so a program whose
/// entry simply returns terminates cleanly instead of jumping to garbage.
fn setupWindowsStack(
    t: *task.Task,
    as: address_space.AddressSpace,
    stack_phys: u64,
    argline: []const u8,
) !u64 {
    var b = StackBuilder{ .phys_base = stack_phys, .sp = USER_STACK_TOP - 64 };

    // Command line strings live at the top of the stack; GetCommandLineA/W
    // return pointers into them.
    const cmdline_a = b.pushCStr(argline);
    b.alignDown(2);
    var wide: [256]u8 = undefined;
    var wlen: usize = 0;
    while (wlen < argline.len and wlen < 255) : (wlen += 1) {
        wide[wlen * 2] = argline[wlen];
        wide[wlen * 2 + 1] = 0;
    }
    wide[wlen * 2] = 0;
    wide[wlen * 2 + 1] = 0;
    const cmdline_w = b.pushBytes(wide[0 .. wlen * 2 + 2]);

    try winapi.installThunks(as);
    winapi.setCommandLine(t, cmdline_a, cmdline_w);

    b.alignDown(16);
    // 32 bytes of shadow space for the callee, then the return address.
    b.sp -= 32;
    b.pushU64(winapi.exitThunkAddr());
    return b.sp;
}

/// Reserve `length` bytes of zeroed anonymous memory in the task's mmap arena.
pub fn mmapAnon(t: *task.Task, length: u64) ?u64 {
    const as = t.address_space orelse return null;
    const size = (length + 0xFFF) & ~@as(u64, 0xFFF);
    if (t.mmap_next + size > task.MMAP_LIMIT) {
        serial.serialWrite("[PROC] mmap arena exhausted\n");
        return null;
    }
    const base = t.mmap_next;
    if (!as.allocUserRange(base, size, vmm.PAGE_WRITE)) return null;
    t.mmap_next = base + size;
    return base;
}

/// Terminate the current task and return to the scheduler. Never returns.
pub fn exitCurrent(code: i32) noreturn {
    const idx_signed = scheduler.current_task;
    if (idx_signed >= 0) {
        const idx: usize = @intCast(idx_signed);
        const t = &scheduler.tasks[idx];
        t.state = .finished;
        t.exit_code = code;

        const parent_id = t.parent_id;
        if (parent_id >= 0) {
            const parent: usize = @intCast(parent_id);
            if (scheduler.tasks[parent].state == .blocked) {
                scheduler.tasks[parent].state = .ready;
            }
        }
    }

    vga.setColor(.yellow, .black);
    vga.write("\n[PROC] Process exited with code ");
    vga.writeDec(@as(u64, @intCast(@as(u32, @bitCast(code)))));
    vga.write("\n");
    vga.setColor(.white, .black);

    serial.serialWrite("\n[PROC] Process exited with code ");
    serial.serialWriteDec(@as(u64, @intCast(@as(u32, @bitCast(code)))));
    serial.serialWrite("\n");

    // Back to the kernel page tables before touching the PMM: destroying the
    // address space unmaps the very pages we are running on otherwise.
    vmm.loadCr3(scheduler.kernel_cr3);

    if (idx_signed >= 0) {
        const idx: usize = @intCast(idx_signed);
        const t = &scheduler.tasks[idx];
        fdtable.closeAll(t);
        if (t.user_stack_phys != 0) {
            const pages = if (t.user_stack_pages != 0) t.user_stack_pages else task.USER_STACK_SIZE / 4096;
            pmm.freePages(t.user_stack_phys, pages);
            t.user_stack_phys = 0;
            t.user_stack_pages = 0;
        }
        if (t.address_space) |as| {
            as.destroy();
            t.address_space = null;
        }
    }

    // A Linux task may have installed its own FS_BASE; the kernel does not use
    // one, but leaving a user pointer there would confuse the next task.
    msr.setFsBase(0);

    sys_exit_return();
}

extern fn sys_exit_return() callconv(.c) noreturn;
