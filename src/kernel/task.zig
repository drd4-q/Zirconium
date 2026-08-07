pub const TaskState = enum {
    ready,
    running,
    blocked,
    finished,
};

pub const TaskType = enum {
    kernel,
    user,
};

pub const MAX_TASKS: usize = 16;
pub const KERNEL_STACK_SIZE: usize = 4096;
pub const USER_STACK_SIZE: usize = 0x10000; // 64KB

pub const SavedState = extern struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    rbp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
    rsp: u64 = 0,
    rflags: u64 = 0x200, // IF=1
    cs: u64 = 0x08, // kernel code
    ss: u64 = 0x10, // kernel data
};

pub const Task = struct {
    id: u32 = 0,
    state: TaskState = .ready,
    task_type: TaskType = .kernel,
    kernel_stack: [KERNEL_STACK_SIZE]u8 align(16) = [_]u8{0} ** KERNEL_STACK_SIZE,
    user_stack_phys: u64 = 0,
    entry_point: u64 = 0,
    saved_state: SavedState = .{},
    time_slice: u64 = 0,
    address_space: ?@import("address_space.zig").AddressSpace = null,
    parent_id: i32 = -1,
    exit_code: i32 = 0,
};
