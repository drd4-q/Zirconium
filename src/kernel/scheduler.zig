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

pub fn addElfUserTask(elf_data: []const u8) ?u32 {
    if (task_count >= task.MAX_TASKS) return null;

    const idx = task_count;
    const t = &tasks[idx];
    t.id = @intCast(idx);
    t.state = .ready;
    t.task_type = .user;
    t.time_slice = TIME_SLICE;

    // Create user address space
    if (address_space.AddressSpace.create()) |addr_space| {
        t.address_space = addr_space;

        // Load ELF binary
        const entry_vaddr = @import("elf.zig").loadElf(addr_space, elf_data) catch |err| {
            port.serialWrite("[SCHED] Failed to load ELF: ");
            port.serialWrite(@errorName(err));
            port.serialWrite("\n");
            addr_space.destroy();
            t.address_space = null;
            return null;
        };
        t.entry_point = entry_vaddr;

        // Allocate user stack
        const user_stack_phys = @import("pmm.zig").allocPages(task.USER_STACK_SIZE / 4096) orelse {
            port.serialWrite("[SCHED] Failed to allocate user stack\n");
            addr_space.destroy();
            t.address_space = null;
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

    port.serialWrite("[SCHED] User ELF task ");
    port.serialWriteDec(idx);
    port.serialWrite(" registered, entry=0x");
    port.serialWriteHex(t.entry_point);
    port.serialWrite("\n");

    return t.id;
}

pub fn addUserTaskFromPath(path: []const u8) ?u32 {
    if (task_count >= task.MAX_TASKS) return null;

    const idx = task_count;
    const t = &tasks[idx];
    t.id = @intCast(idx);
    t.state = .ready;
    t.task_type = .user;
    t.time_slice = TIME_SLICE;

    // Create user address space
    if (address_space.AddressSpace.create()) |addr_space_val| {
        t.address_space = addr_space_val;

        // Load ELF binary from VFS path
        const entry_vaddr = @import("elf.zig").loadElfFromPath(addr_space_val, path) catch |err| {
            port.serialWrite("[SCHED] Failed to load ELF from path: ");
            port.serialWrite(@errorName(err));
            port.serialWrite("\n");
            addr_space_val.destroy();
            t.address_space = null;
            return null;
        };
        t.entry_point = entry_vaddr;

        // Allocate user stack
        const user_stack_phys = @import("pmm.zig").allocPages(task.USER_STACK_SIZE / 4096) orelse {
            port.serialWrite("[SCHED] Failed to allocate user stack\n");
            addr_space_val.destroy();
            t.address_space = null;
            return null;
        };
        t.user_stack_phys = user_stack_phys;

        // Map user stack
        const user_stack_virt = address_space.USER_STACK_TOP - task.USER_STACK_SIZE;
        addr_space_val.mapUserRange(user_stack_virt, user_stack_phys, task.USER_STACK_SIZE, vmm.PAGE_WRITE);

        // Set up initial state for user task
        t.saved_state.rip = entry_vaddr;
        t.saved_state.rsp = address_space.USER_STACK_TOP - 8;
        t.saved_state.rflags = 0x200;
        t.saved_state.cs = gdt.USER_CODE_SEL;
        t.saved_state.ss = gdt.USER_DATA_SEL;
    } else {
        port.serialWrite("[SCHED] Failed to create address space\n");
        return null;
    }

    task_count += 1;

    port.serialWrite("[SCHED] User task ");
    port.serialWriteDec(idx);
    port.serialWrite(" from path, entry=0x");
    port.serialWriteHex(t.entry_point);
    port.serialWrite("\n");

    return t.id;
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

    // Set TSS RSP0 for ring 0 stack on syscalls/interrupts
    gdt.setRsp0(@intFromPtr(&t.kernel_stack) + task.KERNEL_STACK_SIZE);

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
    // Call net tick every 100 ticks (~1 second at 100Hz)
    if (tick_count % 100 == 0) {
        @import("../net/mod.zig").tick();
    }
}

pub fn taskCount() usize {
    return task_count;
}
