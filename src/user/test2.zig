//! Second ring-3 task, used to prove that the scheduler really preempts.
//!
//! It never blocks: it spins in *user* code printing a progress marker, so the
//! only way task 0 can finish is for the timer tick to switch away from it and
//! back. If preemption were not happening, "[USER2]" would never appear in the
//! log while task 0 was still running.

fn syscall3(num: u64, a1: u64, a2: u64, a3: u64) u64 {
    return asm volatile (
        "int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

fn write(fd: u64, msg: []const u8) void {
    _ = syscall3(1, fd, @intFromPtr(msg.ptr), msg.len);
}

fn exit(code: u64) noreturn {
    _ = syscall3(60, code, 0, 0);
    while (true) {}
}

pub export fn _start() callconv(.c) noreturn {
    write(3, "[USER2] started\n");

    // Busy user-mode work between syscalls. The loop body must be something
    // the optimizer cannot delete: an empty `while (i < N) {}` is removed
    // entirely in ReleaseFast, which made this task finish in ~10 ms and never
    // be a preemption candidate. `pause` with a memory clobber survives.
    var round: u64 = 0;
    while (round < 10) : (round += 1) {
        var spin: u64 = 0;
        while (spin < 2_000_000) : (spin += 1) {
            asm volatile ("pause" ::: .{ .memory = true });
        }
        write(3, "[USER2] round\n");
    }

    write(3, "[USER2] finished\n");
    exit(7);
}
