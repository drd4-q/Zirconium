const std = @import("std");
const root = @import("root");
const vga = root.vga;
const serial = @import("../system/serial.zig");
const port_io = @import("../arch/port.zig");
const isr_mod = @import("../arch/isr.zig");
const scheduler = @import("scheduler.zig");
const task = @import("task.zig");
const address_space = @import("address_space.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const kb = @import("../drivers/keyboard.zig");
const timer = @import("../drivers/timer.zig");

pub const SyscallNumber = enum(u64) {
    SYS_WRITE = 1,
    SYS_READ = 2,
    SYS_OPEN = 3,
    SYS_CLOSE = 4,
    SYS_SLEEP = 10,
    SYS_TIME = 11,
    SYS_BRK = 12,
    SYS_FORK = 57,
    SYS_EXEC = 59,
    SYS_EXIT = 60,
    SYS_WAITPID = 61,
    SYS_SOCKET = 70,
    SYS_CONNECT = 71,
    SYS_SEND = 72,
    SYS_RECV = 73,
};

var kernel_rsp: u64 = 0;
extern fn sys_exit_return() callconv(.c) noreturn;

pub fn initKernelStack(rsp: u64) void {
    kernel_rsp = rsp;
}

fn readUserStr(ptr: u64, max_len: usize) ?[256]u8 {
    var buf: [256]u8 = undefined;
    const user_ptr: [*]const u8 = @ptrFromInt(ptr);
    var i: usize = 0;
    while (i < @min(max_len, 255)) : (i += 1) {
        const ch = user_ptr[i];
        if (ch == 0) {
            buf[i] = 0;
            return buf;
        }
        buf[i] = ch;
    }
    buf[255] = 0;
    return buf;
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
        .SYS_BRK => {
            // rdi = new break (0 = query current). Maps user heap pages on demand.
            const current_idx = scheduler.current_task;
            if (current_idx < 0) {
                frame.rax = @bitCast(@as(isize, -1));
                return;
            }
            const t = &scheduler.tasks[@intCast(current_idx)];
            const as = t.address_space orelse {
                frame.rax = @bitCast(@as(isize, -1));
                return;
            };

            // First use initializes the task's heap region
            if (t.heap_brk == 0) {
                t.heap_brk = task.USER_HEAP_BASE;
                t.heap_mapped = task.USER_HEAP_BASE;
            }

            const old_brk = t.heap_brk;
            const new_brk = frame.rdi;
            if (new_brk == 0) {
                frame.rax = old_brk;
                return;
            }
            if (new_brk >= task.USER_HEAP_LIMIT) {
                frame.rax = old_brk;
                return;
            }

            if (new_brk <= old_brk) {
                t.heap_brk = new_brk;
                frame.rax = new_brk;
                return;
            }

            const aligned_end = (new_brk + 0xFFF) & ~@as(u64, 0xFFF);
            var addr = t.heap_mapped;
            while (addr < aligned_end) : (addr += 0x1000) {
                const phys = pmm.allocPage() orelse {
                    t.heap_brk = old_brk;
                    frame.rax = 0;
                    return;
                };
                as.mapUserRange(addr, phys, 0x1000, vmm.PAGE_WRITE);
            }

            t.heap_mapped = aligned_end;
            t.heap_brk = new_brk;
            frame.rax = new_brk;
        },
        .SYS_EXIT => {
            const exit_code = frame.rdi;
            // Mark current task as finished and store exit code
            if (scheduler.current_task >= 0) {
                const idx: usize = @intCast(scheduler.current_task);
                scheduler.tasks[idx].state = .finished;
                scheduler.tasks[idx].exit_code = @intCast(exit_code);

                // Wake up parent if it's waiting via waitpid
                const parent_id = scheduler.tasks[idx].parent_id;
                if (parent_id >= 0) {
                    const parent: usize = @intCast(parent_id);
                    if (scheduler.tasks[parent].state == .blocked) {
                        scheduler.tasks[parent].state = .ready;
                    }
                }
            }
            vga.setColor(.yellow, .black);
            vga.write("\n[USER] Process exited with code ");
            vga.writeDec(exit_code);
            vga.write("\n");
            vga.setColor(.white, .black);

            serial.serialWrite("\n[USER] Process exited with code ");
            serial.serialWriteDec(exit_code);
            serial.serialWrite("\n");

            // Switch back to kernel address space and return to scheduler
            vmm.loadCr3(scheduler.kernel_cr3);

            // Reclaim the process's user-space resources now that we are back
            // on the kernel page tables. Without this, every `user`/`exec` run
            // leaked the address space, stack and PMM pages forever and filled
            // MAX_TASKS after ~13 invocations.
            if (scheduler.current_task >= 0) {
                const idx: usize = @intCast(scheduler.current_task);
                const t = &scheduler.tasks[idx];
                if (t.user_stack_phys != 0) {
                    pmm.freePages(t.user_stack_phys, task.USER_STACK_SIZE / 4096);
                    t.user_stack_phys = 0;
                }
                if (t.address_space) |as| {
                    as.destroy();
                    t.address_space = null;
                }
            }

            sys_exit_return();
        },
        .SYS_FORK => {
            const current_idx = scheduler.current_task;
            if (current_idx < 0) {
                frame.rax = @bitCast(@as(isize, -1));
                return;
            }
            const parent = &scheduler.tasks[@intCast(current_idx)];

            if (scheduler.task_count >= task.MAX_TASKS) {
                frame.rax = @bitCast(@as(isize, -11)); // EAGAIN
                return;
            }

            // Clone address space
            const parent_as = parent.address_space orelse {
                frame.rax = @bitCast(@as(isize, -1));
                return;
            };
            const child_as = parent_as.cloneUserSpace() orelse {
                frame.rax = @bitCast(@as(isize, -12)); // ENOMEM
                return;
            };

            // Allocate child user stack
            const child_stack_phys = pmm.allocPages(task.USER_STACK_SIZE / 4096) orelse {
                child_as.destroy();
                frame.rax = @bitCast(@as(isize, -12));
                return;
            };

            // Map child user stack
            const user_stack_virt = address_space.USER_STACK_TOP - task.USER_STACK_SIZE;
            child_as.mapUserRange(user_stack_virt, child_stack_phys, task.USER_STACK_SIZE, vmm.PAGE_WRITE | vmm.PAGE_USER);

            // Copy parent stack contents to child via physical addresses
            const parent_stack_phys = parent.user_stack_phys;
            const parent_stack_ptr: [*]const u8 = @ptrFromInt(parent_stack_phys);
            const child_stack_ptr: [*]u8 = @ptrFromInt(child_stack_phys);
            @memcpy(child_stack_ptr[0..task.USER_STACK_SIZE], parent_stack_ptr[0..task.USER_STACK_SIZE]);

            // Create child task
            const child_idx = scheduler.task_count;
            const child = &scheduler.tasks[child_idx];
            child.* = .{};
            child.id = @intCast(child_idx);
            child.state = .ready;
            child.task_type = .user;
            child.entry_point = parent.entry_point;
            child.time_slice = 10;
            child.address_space = child_as;
            child.user_stack_phys = child_stack_phys;
            child.parent_id = @intCast(parent.id);

            // Copy parent register state
            child.saved_state.rax = 0; // child gets 0
            child.saved_state.rbx = frame.rbx;
            child.saved_state.rcx = frame.rcx;
            child.saved_state.rdx = frame.rdx;
            child.saved_state.rsi = frame.rsi;
            child.saved_state.rdi = frame.rdi;
            child.saved_state.rbp = frame.rbp;
            child.saved_state.r8 = frame.r8;
            child.saved_state.r9 = frame.r9;
            child.saved_state.r10 = frame.r10;
            child.saved_state.r11 = frame.r11;
            child.saved_state.r12 = frame.r12;
            child.saved_state.r13 = frame.r13;
            child.saved_state.r14 = frame.r14;
            child.saved_state.r15 = frame.r15;
            child.saved_state.rip = frame.rip;
            child.saved_state.rsp = frame.rsp;
            child.saved_state.rflags = frame.rflags;
            child.saved_state.cs = frame.cs;
            child.saved_state.ss = frame.ss;

            scheduler.task_count += 1;

            serial.serialWrite("[SYSCALL] fork: child pid=");
            serial.serialWriteDec(child.id);
            serial.serialWrite("\n");

            // Parent gets child PID
            frame.rax = child.id;
        },
        .SYS_EXEC => {
            const path_ptr = frame.rdi;
            const maybe_path = readUserStr(path_ptr, 255);
            if (maybe_path == null) {
                frame.rax = @bitCast(@as(isize, -14)); // EFAULT
                return;
            }
            const path = maybe_path.?;

            // Find path length
            var path_len: usize = 0;
            while (path[path_len] != 0 and path_len < 255) : (path_len += 1) {}

            serial.serialWrite("[SYSCALL] exec: ");
            serial.serialWrite(path[0..path_len]);
            serial.serialWrite("\n");

            const task_idx = scheduler.current_task;
            if (task_idx < 0) {
                frame.rax = @bitCast(@as(isize, -1));
                return;
            }
            const t = &scheduler.tasks[@intCast(task_idx)];

            // Free old user stack
            if (t.user_stack_phys != 0) {
                pmm.freePages(t.user_stack_phys, task.USER_STACK_SIZE / 4096);
                t.user_stack_phys = 0;
            }

            // Destroy old address space (frees user pages + page tables)
            if (t.address_space) |old_as| {
                old_as.destroy();
                t.address_space = null;
            }

            // Create new address space
            const new_as = address_space.AddressSpace.create() orelse {
                serial.serialWrite("[SYSCALL] exec: failed to create address space\n");
                frame.rax = @bitCast(@as(isize, -12)); // ENOMEM
                return;
            };
            t.address_space = new_as;

            // Load ELF from VFS
            const entry_vaddr = @import("elf.zig").loadElfFromPath(new_as, path[0..path_len]) catch |err| {
                serial.serialWrite("[SYSCALL] exec: failed to load ELF: ");
                serial.serialWrite(@errorName(err));
                serial.serialWrite("\n");
                new_as.destroy();
                t.address_space = null;
                frame.rax = @bitCast(@as(isize, -8)); // ENOEXEC
                return;
            };

            // Allocate new user stack
            const user_stack_phys = pmm.allocPages(task.USER_STACK_SIZE / 4096) orelse {
                serial.serialWrite("[SYSCALL] exec: failed to allocate stack\n");
                new_as.destroy();
                t.address_space = null;
                frame.rax = @bitCast(@as(isize, -12));
                return;
            };
            t.user_stack_phys = user_stack_phys;

            // Map user stack
            const user_stack_virt = address_space.USER_STACK_TOP - task.USER_STACK_SIZE;
            new_as.mapUserRange(user_stack_virt, user_stack_phys, task.USER_STACK_SIZE, vmm.PAGE_WRITE);

            // Update task state
            t.entry_point = entry_vaddr;
            t.state = .ready;

            // Update the interrupt frame to return to the new program
            frame.rip = entry_vaddr;
            frame.rsp = address_space.USER_STACK_TOP - 8;
            frame.cs = @import("../arch/gdt.zig").USER_CODE_SEL;
            frame.ss = @import("../arch/gdt.zig").USER_DATA_SEL;
            frame.rflags = 0x200; // IF=1

            // Switch to new address space before returning
            new_as.switchTo();

            // Return 0 to the new program (rax in frame will be the return value)
            frame.rax = 0;

            serial.serialWrite("[SYSCALL] exec: jumping to 0x");
            serial.serialWriteHex(entry_vaddr);
            serial.serialWrite("\n");
        },
        .SYS_WAITPID => {
            // rdi = pid to wait for (-1 = any child)
            const wait_pid: i32 = @intCast(@as(i64, @bitCast(frame.rdi)));
            const current_idx = scheduler.current_task;
            if (current_idx < 0) {
                frame.rax = @bitCast(@as(isize, -1));
                return;
            }
            const parent_id = scheduler.tasks[@intCast(current_idx)].id;

            // Search for a finished child
            var found: i32 = -1;
            var i: usize = 0;
            while (i < scheduler.task_count) : (i += 1) {
                const t = &scheduler.tasks[i];
                if (t.parent_id != @as(i32, @intCast(parent_id))) continue;
                if (t.state != .finished) continue;
                if (wait_pid != -1 and t.id != @as(u32, @intCast(wait_pid))) continue;
                found = @intCast(i);
                break;
            }

            if (found >= 0) {
                // Return child PID; exit_code stored in rax of the child's exit
                frame.rax = scheduler.tasks[@intCast(found)].id;
            } else {
                // No finished child found
                frame.rax = @bitCast(@as(isize, -1)); // ECHILD
            }
        },
        .SYS_SOCKET => {
            const current_idx = scheduler.current_task;
            if (current_idx < 0) {
                frame.rax = @bitCast(@as(isize, -1));
                return;
            }
            const t = &scheduler.tasks[@intCast(current_idx)];

            var slot_idx: ?usize = null;
            for (t.sockets, 0..) |s, idx| {
                if (s == null) {
                    slot_idx = idx;
                    break;
                }
            }

            if (slot_idx) |idx| {
                const conn = @import("../net/tcp.zig").allocConnection();
                if (conn) |c| {
                    t.sockets[idx] = c;
                    frame.rax = idx;
                } else {
                    frame.rax = @bitCast(@as(isize, -12)); // ENOMEM / no free connection slots
                }
            } else {
                frame.rax = @bitCast(@as(isize, -24)); // EMFILE
            }
        },
        .SYS_CONNECT => {
            // rdi = sockfd, rsi = ip_ptr, rdx = port
            const sockfd = frame.rdi;
            const ip_ptr = frame.rsi;
            const port = frame.rdx;

            const current_idx = scheduler.current_task;
            if (current_idx < 0 or sockfd >= 8) {
                frame.rax = @bitCast(@as(isize, -9)); // EBADF
                return;
            }
            const t = &scheduler.tasks[@intCast(current_idx)];
            const conn = t.sockets[sockfd] orelse {
                frame.rax = @bitCast(@as(isize, -9));
                return;
            };

            const user_ip: [*]const u8 = @ptrFromInt(ip_ptr);
            const dst_ip = [4]u8{ user_ip[0], user_ip[1], user_ip[2], user_ip[3] };

            _ = @import("../net/tcp.zig").connect(dst_ip, @intCast(port));
            _ = conn;
            frame.rax = 0;
        },
        .SYS_SEND => {
            // rdi = sockfd, rsi = buf_ptr, rdx = len
            const sockfd = frame.rdi;
            const buf_ptr = frame.rsi;
            const len = frame.rdx;

            const current_idx = scheduler.current_task;
            if (current_idx < 0 or sockfd >= 8) {
                frame.rax = @bitCast(@as(isize, -9));
                return;
            }
            const t = &scheduler.tasks[@intCast(current_idx)];
            const conn = t.sockets[sockfd] orelse {
                frame.rax = @bitCast(@as(isize, -9));
                return;
            };

            const user_buf: [*]const u8 = @ptrFromInt(buf_ptr);
            @import("../net/tcp.zig").send(conn, user_buf[0..len]);
            frame.rax = len;
        },
        .SYS_RECV => {
            // rdi = sockfd, rsi = buf_ptr, rdx = max_len
            const sockfd = frame.rdi;
            const buf_ptr = frame.rsi;
            const max_len = frame.rdx;

            const current_idx = scheduler.current_task;
            if (current_idx < 0 or sockfd >= 8) {
                frame.rax = @bitCast(@as(isize, -9));
                return;
            }
            const t = &scheduler.tasks[@intCast(current_idx)];
            const conn = t.sockets[sockfd] orelse {
                frame.rax = @bitCast(@as(isize, -9));
                return;
            };

            @import("../net/mod.zig").poll();

            if (conn.rx_ready and conn.rx_len > 0) {
                const user_buf: [*]u8 = @ptrFromInt(buf_ptr);
                const copy_len = @min(conn.rx_len, max_len);
                @memcpy(user_buf[0..copy_len], conn.rx_buf[0..copy_len]);
                conn.rx_len = 0;
                conn.rx_ready = false;
                frame.rax = copy_len;
            } else {
                frame.rax = 0;
            }
        },
        else => {
            serial.serialWrite("[SYSCALL] Unknown syscall: ");
            serial.serialWriteDec(frame.rax);
            serial.serialWrite("\n");
            frame.rax = @bitCast(@as(isize, -38)); // ENOSYS
        },
    }
}
