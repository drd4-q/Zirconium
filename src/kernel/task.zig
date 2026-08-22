const vfs = @import("../fs/vfs.zig");

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

/// Which syscall ABI a user task speaks. Set by the loader from the binary
/// format; the syscall dispatcher uses it to pick a call table.
pub const Personality = enum {
    /// Zirconium's own INT 0x80 ABI (`src/user/*`).
    native,
    /// Linux x86-64: `syscall` instruction, Linux call numbers.
    linux,
    /// Win64: imports resolved to kernel thunks (see kernel/winapi.zig).
    windows,
};

pub const MAX_TASKS: usize = 16;
pub const KERNEL_STACK_SIZE: usize = 16384;
pub const USER_STACK_SIZE: usize = 0x20000; // 128KB
pub const MAX_FDS: usize = 16;

pub const USER_HEAP_BASE: u64 = 0x04000000; // 64MB, above USER_BASE, below stack
pub const USER_HEAP_LIMIT: u64 = 0x0F000000; // stay clear of the mmap arena

/// Anonymous mapping arena (Linux mmap, Win32 VirtualAlloc/HeapAlloc).
pub const MMAP_BASE: u64 = 0x50000000;
pub const MMAP_LIMIT: u64 = 0x70000000;

/// Where the Win32 import thunks are mapped in a PE process.
pub const WIN_THUNK_BASE: u64 = 0x0F000000;

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

/// One entry of a task's file descriptor table.
pub const FileDesc = union(enum) {
    /// Console: keyboard on read, VGA on write.
    console,
    /// Serial debug port.
    serial,
    /// A file opened through the VFS.
    file: *vfs.FileHandle,
    /// A TCP connection created by socket().
    socket: *@import("../net/tcp.zig").Connection,
    /// An open directory, remembered by path so Linux getdents64 can list it
    /// (the VFS enumerates directories by path, not by open handle).
    dir: DirDesc,
};

/// State of an open directory descriptor.
pub const DirDesc = struct {
    path_buf: [160]u8 = undefined,
    path_len: usize = 0,
    /// Number of entries already returned by getdents64.
    cursor: usize = 0,
};

pub const Task = struct {
    id: u32 = 0,
    state: TaskState = .ready,
    task_type: TaskType = .kernel,
    personality: Personality = .native,
    kernel_stack: [KERNEL_STACK_SIZE]u8 align(16) = [_]u8{0} ** KERNEL_STACK_SIZE,
    user_stack_phys: u64 = 0,
    user_stack_pages: usize = 0,
    entry_point: u64 = 0,
    saved_state: SavedState = .{},
    time_slice: u64 = 0,
    address_space: ?@import("address_space.zig").AddressSpace = null,
    parent_id: i32 = -1,
    exit_code: i32 = 0,
    heap_brk: u64 = 0, // current user heap break (0 = not yet initialized)
    heap_mapped: u64 = 0, // top of user heap pages actually mapped
    /// Next free virtual address in the anonymous mapping arena.
    mmap_next: u64 = MMAP_BASE,
    /// Head of the in-arena free list used by HeapAlloc/malloc-style calls.
    heap_free_head: u64 = 0,
    /// Value of FS_BASE the task expects (Linux TLS via arch_prctl).
    fs_base: u64 = 0,
    /// Thread-local storage slots for Win32 TlsAlloc/TlsSetValue.
    tls_slots: [32]u64 = [_]u64{0} ** 32,
    tls_used: u32 = 0,
    /// Win32 GetLastError value.
    last_error: u32 = 0,
    /// User addresses of the ANSI/wide command line (Win32 GetCommandLine).
    cmdline_a: u64 = 0,
    cmdline_w: u64 = 0,
    fds: [MAX_FDS]?FileDesc = [_]?FileDesc{null} ** MAX_FDS,
    /// Legacy socket table kept for the native ABI's socket/connect/send/recv.
    sockets: [8]?*@import("../net/tcp.zig").Connection = [_]?*@import("../net/tcp.zig").Connection{null} ** 8,
};
