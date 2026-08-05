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

pub fn addUserTask(entry_vaddr: u64, _: u64, _: u64) ?u32 {
    if (task_count >= task.MAX_TASKS) return null;

    const idx = task_count;
    const t = &tasks[idx];
    t.id = @intCast(idx);
    t.state = .ready;
    t.task_type = .user;
    t.entry_point = entry_vaddr;
    t.time_slice = TIME_SLICE;

    // Create user address space
    if (address_space.AddressSpace.create()) |addr_space| {
        t.address_space = addr_space;

        // Map kernel into user address space (upper half)
        // The kernel page tables are already shared via AddressSpace.create()

        // Allocate user stack (in lower half, so PAGE_USER works)
        const user_stack_phys = @import("pmm.zig").allocPages(task.USER_STACK_SIZE / 4096) orelse {
            port.serialWrite("[SCHED] Failed to allocate user stack\n");
            return null;
        };
        t.user_stack_phys = user_stack_phys;

        // Map user stack: user_stack_virt -> user_stack_phys
        const user_stack_virt = address_space.USER_STACK_TOP - task.USER_STACK_SIZE;
        addr_space.mapUserRange(user_stack_virt, user_stack_phys, task.USER_STACK_SIZE, vmm.PAGE_WRITE);

        // Set up initial state for user task
        t.saved_state.rip = entry_vaddr;
        t.saved_state.rsp = address_space.USER_STACK_TOP - 8; // -8 for alignment
        t.saved_state.rflags = 0x200; // IF=1
        t.saved_state.cs = gdt.USER_CODE_SEL; // ring 3 code
        t.saved_state.ss = gdt.USER_DATA_SEL; // ring 3 data
    } else {
        port.serialWrite("[SCHED] Failed to create address space\n");
        return null;
    }

    task_count += 1;

    port.serialWrite("[SCHED] User task ");
    port.serialWriteDec(idx);
    port.serialWrite(" registered, entry=0x");
    port.serialWriteHex(entry_vaddr);
    port.serialWrite("\n");

    return t.id;
}

pub fn runAll() void {
    vga.setColor(.yellow, .black);
    vga.write("[SCHED] Running all tasks...\n");
    port.serialWrite("[SCHED] Running all tasks...\n");

    var i: usize = 0;
    while (i < task_count) : (i += 1) {
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

fn jumpToUser(t: *task.Task) void {
    // Switch to user address space
    if (t.address_space) |addr_space| {
        addr_space.switchTo();
    }

    // Set TSS RSP0 for ring 0 stack on syscalls/interrupts
    gdt.setRsp0(@intFromPtr(&t.kernel_stack) + task.KERNEL_STACK_SIZE);

    // Build iretq frame and jump to ring 3
    const rsp = t.saved_state.rsp;
    const rip = t.saved_state.rip;
    const cs = t.saved_state.cs;
    const ss = t.saved_state.ss;
    const rflags = t.saved_state.rflags;

    asm volatile (
        \\movq %[ss_val], %%rax
        \\pushq %%rax
        \\movq %[rsp_val], %%rax
        \\pushq %%rax
        \\movq %[rflags_val], %%rax
        \\pushq %%rax
        \\movq %[cs_val], %%rax
        \\pushq %%rax
        \\movq %[rip_val], %%rax
        \\pushq %%rax
        \\xorq %%rax, %%rax
        \\xorq %%rbx, %%rbx
        \\xorq %%rcx, %%rcx
        \\xorq %%rdx, %%rdx
        \\xorq %%rsi, %%rsi
        \\xorq %%rdi, %%rdi
        \\xorq %%rbp, %%rbp
        \\xorq %%r8, %%r8
        \\xorq %%r9, %%r9
        \\xorq %%r10, %%r10
        \\xorq %%r11, %%r11
        \\xorq %%r12, %%r12
        \\xorq %%r13, %%r13
        \\xorq %%r14, %%r14
        \\xorq %%r15, %%r15
        \\iretq
        :
        : [ss_val] "m" (ss),
          [rsp_val] "m" (rsp),
          [rflags_val] "m" (rflags),
          [cs_val] "m" (cs),
          [rip_val] "m" (rip),
        : .{ .rax = true, .rbx = true, .rcx = true, .rdx = true, .rsi = true, .rdi = true, .rbp = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .r12 = true, .r13 = true, .r14 = true, .r15 = true, .memory = true }
    );
}

pub fn scheduleTick() void {
    tick_count += 1;
}

pub fn taskCount() usize {
    return task_count;
}
