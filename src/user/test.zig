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

fn socket() u64 {
    return syscall3(70, 0, 0, 0);
}

fn connect(sockfd: u64, ip: []const u8, port: u64) u64 {
    return syscall3(71, sockfd, @intFromPtr(ip.ptr), port);
}

fn send(sockfd: u64, msg: []const u8) u64 {
    return syscall3(72, sockfd, @intFromPtr(msg.ptr), msg.len);
}

fn recv(sockfd: u64, buf: []u8) u64 {
    return syscall3(73, sockfd, @intFromPtr(buf.ptr), buf.len);
}

pub export fn _start() callconv(.c) noreturn {
    write(1, "\n[USER] Hello from Ring 3 (user space)!\n");
    write(3, "[USER-SERIAL] Hello from Ring 3!\n");

    const sock = socket();
    if (sock < 8) {
        write(1, "[USER-NET] Created socket via sys_socket\n");
        const ip = [_]u8{ 10, 0, 2, 2 };
        _ = connect(sock, &ip, 80);
        write(1, "[USER-NET] Connected to 10.0.2.2:80 via sys_connect\n");
        _ = send(sock, "GET / HTTP/1.1\r\nHost: 10.0.2.2\r\n\r\n");
        write(1, "[USER-NET] Sent HTTP GET request via sys_send\n");
    }

    sleep(1000);
    write(1, "[USER] Goodbye from user-space!\n\n");
    exit(42);
}
