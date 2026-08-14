pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ mov $1, %%rax          # sys_write
        \\ mov $1, %%rdi          # stdout
        \\ lea msg(%%rip), %%rsi  # buf
        \\ mov $50, %%rdx         # len
        \\ syscall
        \\ mov $60, %%rax         # sys_exit
        \\ mov $0, %%rdi          # status
        \\ syscall
        \\ msg:
        \\ .ascii "Hello from Linux ELF binary running in Zirconium!\n"
    );
}
