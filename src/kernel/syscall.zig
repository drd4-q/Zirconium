const std = @import("std");
const root = @import("root");
const vga = root.vga;
const serial = @import("../system/serial.zig");
const port_io = @import("../arch/port.zig");
const isr_mod = @import("../arch/isr.zig");
const scheduler = @import("scheduler.zig");
const kb = @import("../drivers/keyboard.zig");
const timer = @import("../drivers/timer.zig");

pub const SyscallNumber = enum(u64) {
    SYS_WRITE = 1,
    SYS_READ = 2,
    SYS_OPEN = 3,
    SYS_CLOSE = 4,
    SYS_SLEEP = 10,
    SYS_TIME = 11,
    SYS_EXIT = 60,
    SYS_FORK = 57,
    SYS_EXEC = 59,
};

var kernel_rsp: u64 = 0;
extern fn sys_exit_return() callconv(.c) noreturn;

pub fn initKernelStack(rsp: u64) void {
    kernel_rsp = rsp;
}

pub export fn syscall_handler(frame: *isr_mod.InterruptFrame) callconv(.c) void {
    const num: SyscallNumber = @enumFromInt(frame.rax);

    switch (num) {
        .SYS_WRITE => {
            // rdi = fd, rsi = buf_ptr, rdx = len
            const fd = frame.rdi;
            const buf_ptr = frame.rsi;
            const len = frame.rdx;

            if (fd == 1 or fd == 2) { // stdout/stderr -> VGA
                const buf: [*]const u8 = @ptrFromInt(buf_ptr);
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    vga.putChar(buf[i]);
                }
                frame.rax = len;
            } else if (fd == 3) { // serial
                const buf: [*]const u8 = @ptrFromInt(buf_ptr);
                const slice = buf[0..len];
                serial.serialWrite(slice);
                frame.rax = len;
            } else {
                frame.rax = @bitCast(@as(isize, -9)); // EBADF
            }
        },
        .SYS_READ => {
            // rdi = fd, rsi = buf_ptr, rdx = max_len
            const fd = frame.rdi;
            const buf_ptr = frame.rsi;
            const max_len = frame.rdx;

            if (fd == 0) { // stdin -> keyboard
                const buf: [*]u8 = @ptrFromInt(buf_ptr);
                var count: usize = 0;
                while (count < max_len) {
                    if (kb.pollKey()) |ch| {
                        if (ch == '\n' or ch == '\r') {
                            buf[count] = '\n';
                            count += 1;
                            break;
                        } else if (ch == 0x08) { // backspace
                            if (count > 0) {
                                count -= 1;
                                vga.putChar(0x08);
                                vga.putChar(' ');
                                vga.putChar(0x08);
                            }
                        } else if (ch >= 0x20) {
                            buf[count] = ch;
                            count += 1;
                            vga.putChar(ch);
                        }
                    } else {
                        asm volatile ("hlt");
                    }
                }
                frame.rax = count;
            } else {
                frame.rax = @bitCast(@as(isize, -9)); // EBADF
            }
        },
        .SYS_SLEEP => {
            const ms = frame.rdi;
            timer.sleep(@intCast(ms));
            frame.rax = 0;
        },
        .SYS_TIME => {
            timer.updateTime();
            const total_seconds = @as(u64, timer.hours) * 3600 + @as(u64, timer.minutes) * 60 + @as(u64, timer.seconds);
            frame.rax = total_seconds;
        },
        .SYS_EXIT => {
            const exit_code = frame.rdi;
            // Mark current task as finished
            if (scheduler.current_task >= 0) {
                scheduler.tasks[@intCast(scheduler.current_task)].state = .finished;
            }
            vga.setColor(.yellow, .black);
            vga.write("\n[USER] Process exited with code ");
            vga.writeDec(exit_code);
            vga.write("\n");
            vga.setColor(.white, .black);

            // Switch back to kernel page table
            asm volatile ("movq %[cr3], %%cr3" : : [cr3] "r" (scheduler.kernel_cr3) : .{ .memory = true });

            // Restore kernel stack and return to runAll()
            sys_exit_return();
        },
        .SYS_FORK => {
            // Simplified fork - just return -1 (not implemented)
            frame.rax = @bitCast(@as(isize, -1));
        },
        .SYS_EXEC => {
            // Simplified exec - not implemented
            frame.rax = @bitCast(@as(isize, -1));
        },
        else => {
            serial.serialWrite("[SYSCALL] Unknown syscall: ");
            serial.serialWriteDec(frame.rax);
            serial.serialWrite("\n");
            frame.rax = @bitCast(@as(isize, -38)); // ENOSYS
        },
    }
}
