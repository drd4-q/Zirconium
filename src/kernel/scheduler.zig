const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;
const task = @import("task.zig");
const gdt = @import("../arch/gdt.zig");
const isr = @import("../arch/isr.zig");
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
    return addElfUserTaskMapped(elf_data, &.{});
}

/// An extra page mapping for a user task: a piece of hardware the task is
/// allowed to touch.  This is how a guest driver reaches a device's
/// registers.
pub const ExtraMapping = struct {
    /// Where in the task's virtual address space the page appears.
    vaddr: u64,
    /// The physical page it is backed by.
    paddr: u64,
    /// How many bytes.
    size: u64,
};

/// Load an ELF into a new user task and map any extra pages into it.
///
/// The mappings are the guest's view of the hardware: a device's register
/// block and its shared window.  The task can read and write them exactly
/// as it would a device mapped into its own page tables.
pub fn addElfUserTaskMapped(elf_data: []const u8, extra: []const ExtraMapping) ?u32 {
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

        // The hardware the task is allowed to touch.
        for (extra) |m| {
            addr_space.mapUserRange(m.vaddr, m.paddr, m.size, vmm.PAGE_WRITE);
        }

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
        // Blocking-capable housekeeping runs here, between tasks: the tick
        // handler must stay non-blocking.
        pollDeferred();

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
    vga.write("[SCHED] All tasks completed (preemptions=");
    vga.writeDec(preemptions);
    vga.write(")\n");
    port.serialWrite("[SCHED] preemptions=");
    port.serialWriteDec(preemptions);
    port.serialWrite(" tick_count=");
    port.serialWriteDec(tick_count);
    port.serialWrite("\n");
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

// ───────────────────────── preemption (user <-> user) ─────────────────────────
//
// The scheduler switches ring-3 tasks by rewriting the *current* InterruptFrame
// in place.  The ISR's normal `iretq` then lands in the next task, so there is
// no nested context switch and no need for a separate kernel stack yet.
//
// Deliberately restricted to user<->user transitions: kernel-mode execution is
// non-preemptible (like Linux without PREEMPT) and a top-level task still
// returns to its C caller through `sys_exit_return`.  That keeps every existing
// path intact while making fork() children actually run.

/// Copy the architecture-visible part of a task's saved state into an interrupt
/// frame, so the frame's `iretq` resumes exactly that task.
pub fn loadStateIntoFrame(frame: *isr.InterruptFrame, t: *task.Task) void {
    const s = &t.saved_state;
    frame.rax = s.rax;
    frame.rbx = s.rbx;
    frame.rcx = s.rcx;
    frame.rdx = s.rdx;
    frame.rsi = s.rsi;
    frame.rdi = s.rdi;
    frame.rbp = s.rbp;
    frame.r8 = s.r8;
    frame.r9 = s.r9;
    frame.r10 = s.r10;
    frame.r11 = s.r11;
    frame.r12 = s.r12;
    frame.r13 = s.r13;
    frame.r14 = s.r14;
    frame.r15 = s.r15;
    frame.rip = s.rip;
    frame.rsp = s.rsp;
    frame.rflags = s.rflags | 0x200; // IF=1: a task never resumes with IRQs off
    frame.cs = s.cs;
    frame.ss = s.ss;
}

/// Inverse of loadStateIntoFrame: bank the interrupted registers.
pub fn saveFrameToState(frame: *isr.InterruptFrame, t: *task.Task) void {
    const s = &t.saved_state;
    s.rax = frame.rax;
    s.rbx = frame.rbx;
    s.rcx = frame.rcx;
    s.rdx = frame.rdx;
    s.rsi = frame.rsi;
    s.rdi = frame.rdi;
    s.rbp = frame.rbp;
    s.r8 = frame.r8;
    s.r9 = frame.r9;
    s.r10 = frame.r10;
    s.r11 = frame.r11;
    s.r12 = frame.r12;
    s.r13 = frame.r13;
    s.r14 = frame.r14;
    s.r15 = frame.r15;
    s.rip = frame.rip;
    s.rsp = frame.rsp;
    s.rflags = frame.rflags;
    s.cs = frame.cs;
    s.ss = frame.ss;
}

/// Install everything a task needs to be *the* current one: page tables, the
/// ring-0 stack interrupts will land on, and its TLS bases.
pub fn activateTask(t: *task.Task) void {
    if (t.address_space) |as| as.switchTo() else vmm.loadCr3(kernel_cr3);

    const kstack_top = @intFromPtr(&t.kernel_stack) + task.KERNEL_STACK_SIZE;
    gdt.setRsp0(kstack_top);
    @import("../arch/syscall64.zig").setKernelStack(kstack_top);

    if (t.personality == .linux and t.fs_base != 0) {
        @import("../arch/msr.zig").setFsBase(t.fs_base);
    }
    if (t.personality == .windows and t.gs_base != 0) {
        @import("../arch/msr.zig").setGsBase(t.gs_base);
    }
}

/// First ready user task that is not `skip`, round-robin from the current one.
fn pickNextUserTask(skip: usize) ?usize {
    var i: usize = 0;
    while (i < task_count) : (i += 1) {
        const idx = (skip + 1 + i) % task_count;
        const t = &tasks[idx];
        if (t.task_type == .user and t.state == .ready and t.address_space != null) return idx;
    }
    return null;
}

/// The task a C caller (runTask/runAll -> jumpToUser) is still blocked in.
/// Only this one may return through `sys_exit_return`; a pre-empted task that
/// exits has to be routed to a live task instead, or control would land back in
/// the middle of a C frame belonging to someone else.
pub var preempted_from: i32 = -1;

/// Resume `next` through `frame`, switching away from whatever is running now.
/// Called from interrupt context; it does not return to the old task.
pub fn switchToTaskInFrame(frame: *isr.InterruptFrame, next: usize) void {
    const cur_signed = current_task;
    if (cur_signed >= 0 and @as(usize, @intCast(cur_signed)) != next) {
        const cur: usize = @intCast(cur_signed);
        // Only a task that is still mid-flight becomes the resume target for
        // whatever it pre-empts out of.
        if (cur < task_count and tasks[cur].state == .running) preempted_from = cur_signed;
    }
    const t = &tasks[next];
    t.state = .running;
    current_task = @intCast(next);
    slice_used = 0;
    activateTask(t);
    loadStateIntoFrame(frame, t);
}

/// Where a task that is exiting should hand the CPU. Prefers the parent (so
/// waitpid-style loops resume), then the task we were pre-empted out of, then
/// -1 meaning "return to the C caller".
///
/// `exiting` is excluded from every candidate: a preempted task is recorded in
/// `preempted_from`, and without this check a pre-empted task with no parent
/// would redirect to *itself*, resurrecting a task that already returned from
/// exit() - which loops forever instead of completing.
pub fn redirectTargetFor(t: *task.Task, exiting: usize) i32 {
    if (t.parent_id >= 0 and @as(usize, @intCast(t.parent_id)) < task_count and
        @as(usize, @intCast(t.parent_id)) != exiting and
        scheduler_taskAlive(@intCast(t.parent_id))) return t.parent_id;
    if (preempted_from >= 0 and @as(usize, @intCast(preempted_from)) < task_count and
        @as(usize, @intCast(preempted_from)) != exiting and
        tasks[@intCast(preempted_from)].state == .running) return preempted_from;
    return -1;
}

fn scheduler_taskAlive(idx: i32) bool {
    if (idx < 0) return false;
    const i: usize = @intCast(idx);
    if (i >= task_count) return false;
    return tasks[i].state == .ready or tasks[i].state == .running;
}

/// Tick hook. Returns true when the caller must let the ISR's `iretq` perform
/// the switch, i.e. the frame now describes a different task.
pub fn onTick(frame: *isr.InterruptFrame) bool {
    const cur_signed = current_task;
    if (cur_signed < 0) return false;
    const cur: usize = @intCast(cur_signed);
    if (cur >= task_count) return false;

    const preemptible = tasks[cur].state == .running and tasks[cur].task_type == .user and
        tasks[cur].address_space != null;
    if (!preemptible) return false;
    // Only switch away from ring 3: a kernel-mode context has no iretq frame
    // to rewrite and must run to its next blocking point.
    if ((frame.cs & 3) != 3) return false;

    const next = pickNextUserTask(cur) orelse return false;

    saveFrameToState(frame, &tasks[cur]);
    tasks[cur].state = .ready;

    switchToTaskInFrame(frame, next);
    preemptions += 1;
    return true;
}

/// Ticks the current task has consumed in its current slice.
pub var slice_used: u64 = 0;
pub var preemptions: u64 = 0;
/// Set by process.exitCurrent when a task with a parent exits. The interrupt
/// handler consumes it as its last action: rewrite the frame for that parent so
/// the pending `iretq` resumes it, and drop whatever the dying task was about to
/// return.
pub var exit_redirect: i32 = -1;

/// Perform a pending exit redirect, if any. Returns true when the frame has been
/// repurposed and the caller must return immediately without touching it again.
pub fn applyExitRedirect(frame: *isr.InterruptFrame) bool {
    const target = exit_redirect;
    if (target < 0) return false;
    exit_redirect = -1;
    const idx: usize = @intCast(target);
    if (idx >= task_count or tasks[idx].state == .finished) return false;
    switchToTaskInFrame(frame, idx);
    return true;
}
/// Mark that a task gave up the CPU without exiting (end of its slice).
pub fn yieldCurrent() void {
    const cur_signed = current_task;
    if (cur_signed < 0) return;
    const cur: usize = @intCast(cur_signed);
    if (cur < task_count and tasks[cur].state == .running) tasks[cur].state = .ready;
}

/// Interrupt-context work. Deliberately does *only* the preemption decision,
/// which is bounded and cannot block.
///
/// USB/HID/net polling used to live here and had to move out: a poll that
/// spins on a hardware status bit inside an ISR deadlocks the machine, because
/// the very tick that would release it cannot arrive while IF is clear.
pub fn scheduleTick(frame: ?*isr.InterruptFrame) void {
    tick_count += 1;

    // The hypervisor's own devices are serviced from the tick: a guest
    // spinning in a wait loop needs an answer from the hypervisor, and the
    // tick is the only thing that runs while the guest has the CPU.  The
    // service is bounded and never blocks.
    if (@import("config").features.kvm) {
        @import("../vm/mod.zig").serviceDevices();
    }

    if (frame) |f| {
        const cur_signed = current_task;
        if (cur_signed >= 0) {
            const cur: usize = @intCast(cur_signed);
            if (cur < task_count and tasks[cur].state == .running) {
                slice_used += 1;
                if (slice_used >= tasks[cur].time_slice) {
                    _ = onTick(f);
                }
            }
        }
    }
}

/// Polling that may block, so it must run from a context that can wait (the
/// shell loop and between scheduled tasks) - never from the tick handler.
pub fn pollDeferred() void {
    @import("../drivers/usb.zig").poll();
    @import("../drivers/usb.zig").pollHid();
    // The guests run here rather than in the tick handler: emulating a guest
    // is not a bounded operation, and the tick handler must never block.
    if (@import("config").features.kvm) {
        @import("../vm/mod.zig").poll();
    }
    if (tick_count % 100 == 0) {
        @import("../net/mod.zig").tick();
    }
}

pub fn taskCount() usize {
    return task_count;
}
