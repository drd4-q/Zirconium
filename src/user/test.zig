fn syscall3(num: u64, arg1: u64, arg2: u64, arg3: u64) u64 {
    return asm volatile (
        "int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

fn write(fd: u64, msg: []const u8) void {
    _ = syscall3(1, fd, @intFromPtr(msg.ptr), msg.len);
}

fn sleep(ms: u64) void {
    _ = syscall3(10, ms, 0, 0);
}

fn exit(code: u64) noreturn {
    _ = syscall3(60, code, 0, 0);
    while (true) {}
}

pub export fn _start() callconv(.c) noreturn {
    write(1, "\n[USER] Hello from Ring 3 (user space)!\n");
    write(3, "[USER-SERIAL] Hello from Ring 3!\n");
    sleep(1000);
    write(1, "[USER] Goodbye from user-space!\n\n");
    exit(42);
}
