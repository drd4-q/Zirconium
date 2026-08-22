const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;
const task = @import("task.zig");
const gdt = @import("../arch/gdt.zig");
const address_space = @import("address_space.zig");
const vmm = @import("vmm.zig");

pub var tasks: [task.MAX_TASKS]task.Task = undefined;
pub var task_count: usize = 0;
pub var current_task: i32 = -1;
pub var tick_count: u64 = 0;
pub var scheduler_ready: bool = false;
pub var kernel_rsp: u64 = 0;
pub var kernel_cr3: u64 = 0;

const TIME_SLICE: u64 = 10; // 10 ticks = 100ms

pub fn init() void {
    task_count = 0;
    current_task = -1;
    scheduler_ready = false;
    vga.setColor(.cyan, .black);
    vga.write("[SCHED] Scheduler initialized\n");
    port.serialWrite("[SCHED] Scheduler initialized\n");
}

pub fn addKernelTask(entry: *const fn () void) ?u32 {
    if (task_count >= task.MAX_TASKS) return null;

    const idx = task_count;
    const t = &tasks[idx];
    t.id = @intCast(idx);
    t.state = .ready;
    t.task_type = .kernel;
    t.entry_point = @intFromPtr(entry);
    t.time_slice = TIME_SLICE;

    // Set up initial kernel stack for context switch
    const stack_base = @intFromPtr(&t.kernel_stack);
    const stack_top_addr = stack_base + task.KERNEL_STACK_SIZE;

    // Initial stack frame for first context switch (simulated)
    t.saved_state.rsp = stack_top_addr;
    t.saved_state.rip = @intFromPtr(entry);
    t.saved_state.rflags = 0x200; // IF=1
    t.saved_state.cs = 0x08; // kernel code
    t.saved_state.ss = 0x10; // kernel data

    task_count += 1;

    port.serialWrite("[SCHED] Kernel task ");
    port.serialWriteDec(idx);
    port.serialWrite(" registered, entry=0x");
    port.serialWriteHex(@intFromPtr(entry));
    port.serialWrite("\n");

    return t.id;
}

// Allocate the user stack and set the ring-3 initial register state.
// Requires t.address_space to already be set.
fn prepareUserStack(t: *task.Task, entry_vaddr: u64) bool {
    const addr_space = t.address_space orelse return false;

    const pages = task.USER_STACK_SIZE / 4096;
    const user_stack_phys = @import("pmm.zig").allocPages(pages) orelse {
        port.serialWrite("[SCHED] Failed to allocate user stack\n");
        return false;
    };
    t.user_stack_phys = user_stack_phys;
    t.user_stack_pages = pages;

    const user_stack_virt = address_space.USER_STACK_TOP - task.USER_STACK_SIZE;
    addr_space.mapUserRange(user_stack_virt, user_stack_phys, task.USER_STACK_SIZE, vmm.PAGE_WRITE);

    t.saved_state = .{};
    t.saved_state.rip = entry_vaddr;
    t.saved_state.rsp = address_space.USER_STACK_TOP - 8; // -8 for alignment
    t.saved_state.rflags = 0x200; // IF=1
    t.saved_state.cs = gdt.USER_CODE_SEL; // ring 3 code
    t.saved_state.ss = gdt.USER_DATA_SEL; // ring 3 data
    return true;
}

// Allocate a task slot and initialize its common user-task fields. Finished
// slots are reused so repeated `user`/`exec` runs don't exhaust MAX_TASKS
// (their resources are already reclaimed in SYS_EXIT teardown).
fn newUserTaskSlot() ?*task.Task {
    var slot: usize = 0;
    while (slot < task_count) : (slot += 1) {
        if (tasks[slot].state == .finished) {
            const t = &tasks[slot];
            t.* = .{};
            t.id = @intCast(slot);
            t.state = .ready;
            t.task_type = .user;
            t.time_slice = TIME_SLICE;
            return t;
        }
    }
    if (task_count >= task.MAX_TASKS) return null;
    const t = &tasks[task_count];
    t.* = .{};
    t.id = @intCast(task_count);
    t.state = .ready;
    t.task_type = .user;
    t.time_slice = TIME_SLICE;
    task_count += 1;
    return t;
}

fn registerUser(t: *task.Task, entry_vaddr: u64, label: []const u8) ?u32 {
    if (t.address_space == null) {
        t.address_space = address_space.AddressSpace.create();
    }
    const addr_space = t.address_space orelse {
        port.serialWrite("[SCHED] Failed to create address space\n");
        return null;
    };
    if (!prepareUserStack(t, entry_vaddr)) {
        addr_space.destroy();
        t.address_space = null;
        return null;
    }

    port.serialWrite("[SCHED] ");
    port.serialWrite(label);
    port.serialWrite(" task ");
    port.serialWriteDec(t.id);
    port.serialWrite(" registered, entry=0x");
    port.serialWriteHex(entry_vaddr);
    port.serialWrite("\n");
    return t.id;
}

pub fn addUserTask(entry_vaddr: u64, _: u64, _: u64) ?u32 {
    const t = newUserTaskSlot() orelse return null;
    t.entry_point = entry_vaddr;
    return registerUser(t, entry_vaddr, "User");
}

pub fn addElfUserTask(elf_data: []const u8) ?u32 {
    const t = newUserTaskSlot() orelse return null;

    if (address_space.AddressSpace.create()) |addr_space| {
        t.address_space = addr_space;

        const entry_vaddr = @import("elf.zig").loadElf(addr_space, elf_data) catch |err| {
            port.serialWrite("[SCHED] Failed to load ELF: ");
            port.serialWrite(@errorName(err));
            port.serialWrite("\n");
            addr_space.destroy();
            t.address_space = null;
            return null;
        };
        t.entry_point = entry_vaddr;
        return registerUser(t, entry_vaddr, "User ELF");
    } else {
        port.serialWrite("[SCHED] Failed to create address space\n");
        return null;
    }
}

pub fn addUserTaskFromPath(path: []const u8) ?u32 {
    const t = newUserTaskSlot() orelse return null;

    if (address_space.AddressSpace.create()) |addr_space| {
        t.address_space = addr_space;

        const entry_vaddr = @import("elf.zig").loadElfFromPath(addr_space, path) catch |err| {
            port.serialWrite("[SCHED] Failed to load ELF from path: ");
            port.serialWrite(@errorName(err));
            port.serialWrite("\n");
            addr_space.destroy();
            t.address_space = null;
            return null;
        };
        t.entry_point = entry_vaddr;
        return registerUser(t, entry_vaddr, "User from path");
    } else {
        port.serialWrite("[SCHED] Failed to create address space\n");
        return null;
    }
}

/// Spawn a program from a file, auto-detecting its binary format (ELF or PE) and
/// setting up the ABI its personality requires. `argline` is the full command
/// line, program name first.
pub fn spawnProgram(path: []const u8, argline: []const u8) !u32 {
    const t = newUserTaskSlot() orelse return error.TooManyTasks;
    errdefer t.state = .finished;

    @import("process.zig").setupFromPath(t, path, argline) catch |err| {
        port.serialWrite("[SCHED] spawn failed: ");
        port.serialWrite(@errorName(err));
        port.serialWrite("\n");
        return err;
    };

    port.serialWrite("[SCHED] Program task ");
    port.serialWriteDec(t.id);
    port.serialWrite(" registered, entry=0x");
    port.serialWriteHex(t.entry_point);
    port.serialWrite("\n");
    return t.id;
}

/// Spawn a program from an in-memory image (used for the embedded test binary).
pub fn spawnProgramImage(data: []const u8, argline: []const u8) !u32 {
    const t = newUserTaskSlot() orelse return error.TooManyTasks;
    errdefer t.state = .finished;

    try @import("process.zig").setup(t, data, argline);

    port.serialWrite("[SCHED] Program task ");
    port.serialWriteDec(t.id);
    port.serialWrite(" registered, entry=0x");
    port.serialWriteHex(t.entry_point);
    port.serialWrite("\n");
    return t.id;
}

/// Run a single task to completion (used by the shell to launch one program).
pub fn runTask(id: u32) void {
    if (id >= task_count) return;
    const t = &tasks[id];
    if (t.state != .ready) return;

    t.state = .running;
    current_task = @intCast(id);

    if (t.task_type == .kernel) {
        const entry_fn: *const fn () void = @ptrFromInt(t.entry_point);
        entry_fn();
    } else {
        jumpToUser(t);
    }

    t.state = .finished;
    current_task = -1;
}

/// Exit code of a finished task, or null if it is still running / not a task.
pub fn exitCodeOf(id: u32) ?i32 {
    if (id >= task_count) return null;
    if (tasks[id].state != .finished) return null;
    return tasks[id].exit_code;
}

pub fn runAll() void {
    vga.setColor(.yellow, .black);
    vga.write("[SCHED] Running all tasks...\n");
    port.serialWrite("[SCHED] Running all tasks...\n");

    var i: usize = 0;
    while (i < task_count) : (i += 1) {
        if (tasks[i].state != .ready) continue;
        tasks[i].state = .running;
        current_task = @intCast(i);

        vga.setColor(.light_cyan, .black);
        vga.write("[SCHED] Task ");
        vga.writeDec(tasks[i].id);
        vga.write(" executing...\n");

        // For kernel tasks, call directly (no context switch needed)
        if (tasks[i].task_type == .kernel) {
            const entry_fn: *const fn () void = @ptrFromInt(tasks[i].entry_point);
            entry_fn();
        } else {
            // For user tasks, we need to jump to ring 3
            // This will be handled by context switch
            jumpToUser(&tasks[i]);
        }

        tasks[i].state = .finished;
        vga.setColor(.light_cyan, .black);
        vga.write("[SCHED] Task ");
        vga.writeDec(tasks[i].id);
        vga.write(" finished\n");
    }

    current_task = -1;
    vga.setColor(.yellow, .black);
    vga.write("[SCHED] All tasks completed\n");
}

extern fn switch_to_user(user_rsp: u64, user_rip: u64, user_cs: u64, user_ss: u64, user_rflags: u64) void;

fn jumpToUser(t: *task.Task) void {
    // Save kernel CR3
    kernel_cr3 = vmm.getCurrentCr3();

    // Switch to user address space
    if (t.address_space) |addr_space| {
        addr_space.switchTo();
    }

    // Ring 0 stack for syscalls/interrupts taken from ring 3. Both entry paths
    // need it: the CPU loads TSS.RSP0 for INT 0x80, while `syscall` does not
    // switch stacks at all and the stub reads syscall_kernel_rsp instead.
    const kstack_top = @intFromPtr(&t.kernel_stack) + task.KERNEL_STACK_SIZE;
    gdt.setRsp0(kstack_top);
    @import("../arch/syscall64.zig").setKernelStack(kstack_top);

    // A Linux task expects the FS_BASE it set through arch_prctl; restore it
    // here so a task resumed after another task ran still finds its TLS.
    if (t.personality == .linux and t.fs_base != 0) {
        @import("../arch/msr.zig").setFsBase(t.fs_base);
    }
    // Windows tasks get their fake TEB through GS.
    if (t.personality == .windows and t.gs_base != 0) {
        @import("../arch/msr.zig").setGsBase(t.gs_base);
    }

    switch_to_user(
        t.saved_state.rsp,
        t.saved_state.rip,
        t.saved_state.cs,
        t.saved_state.ss,
        t.saved_state.rflags,
    );
}

pub fn scheduleTick() void {
    tick_count += 1;
    // Poll USB HID devices (keyboards/tablets) at the tick rate.
    @import("../drivers/usb.zig").pollHid();
    // Call net tick every 100 ticks (~1 second at 100Hz)
    if (tick_count % 100 == 0) {
        @import("../net/mod.zig").tick();
    }
}

pub fn taskCount() usize {
    return task_count;
}
