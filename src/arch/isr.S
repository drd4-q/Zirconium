.code64

.extern isr_handler
.extern syscall_handler
.extern win_thunk_handler

.macro ISR_NOERR num
.global isr\num
isr\num:
    pushq $0
    pushq $\num
    jmp isr_common
.endm

.macro ISR_ERR num
.global isr\num
isr\num:
    pushq $\num
    jmp isr_common
.endm

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_NOERR 21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_ERR   29
ISR_ERR   30
ISR_NOERR 31

.macro IRQ num, stub_num
.global irq\num
irq\num:
    pushq $0
    pushq $\stub_num
    jmp isr_common
.endm

IRQ 0,  32
IRQ 1,  33
IRQ 2,  34
IRQ 3,  35
IRQ 4,  36
IRQ 5,  37
IRQ 6,  38
IRQ 7,  39
IRQ 8,  40
IRQ 9,  41
IRQ 10, 42
IRQ 11, 43
IRQ 12, 44
IRQ 13, 45
IRQ 14, 46
IRQ 15, 47

isr_common:
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    movq %rsp, %rdi
    call isr_handler

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax

    addq $16, %rsp
    iretq

# Syscall entry point (INT 0x80)
# INT 0x80 is a normal IDT interrupt gate (DPL=3).
# When called from ring 3, the CPU automatically switches RSP to TSS.RSP0
# and pushes SS, RSP, RFLAGS, CS, RIP onto the kernel stack.
# We push a fake error_code=0 and int_num=0x80 to match InterruptFrame layout,
# then call syscall_handler exactly like isr_common calls isr_handler.
.global syscall_entry
syscall_entry:
    pushq $0          # error_code = 0
    pushq $0x80       # int_num = 0x80

    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    movq %rsp, %rdi
    call syscall_handler

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax

    addq $16, %rsp    # pop int_num + error_code
    iretq

# Win32 import thunk entry (INT 0x81, DPL=3).
# The PE import thunks execute `mov eax,<id>; int 0x81; ret`, so this reuses the
# exact frame layout of the syscall path and lets the handler read the Win64
# argument registers (rcx/rdx/r8/r9) plus stack arguments via frame.rsp.
.global win_thunk_entry
win_thunk_entry:
    pushq $0          # error_code = 0
    pushq $0x81       # int_num

    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    movq %rsp, %rdi
    call win_thunk_handler

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax

    addq $16, %rsp
    iretq

# Syscall entry point for the `syscall` instruction (Linux ABI binaries).
#
# Unlike INT 0x80, `syscall` does NOT switch stacks and pushes nothing:
#   RCX = return RIP, R11 = saved RFLAGS, CS/SS come from IA32_STAR.
# We switch to the task's kernel stack ourselves and synthesize the same frame
# layout isr_common/syscall_entry build, so syscall_handler is shared by both
# entry paths. We return with iretq rather than sysret because the handler may
# rewrite CS/SS/RSP/RIP wholesale (exec) or not return at all (exit).
#
# The scratch globals are safe without a per-CPU area because only the BSP runs
# user tasks and the scheduler is not preemptive (APs idle in ap_entry).
.global syscall_entry_64
syscall_entry_64:
    movq %rsp, syscall_user_rsp(%rip)
    movq syscall_kernel_rsp(%rip), %rsp

    # Build the iretq frame exactly as the CPU would for an interrupt.
    pushq $0x23                          # SS  = user data selector (0x20|3)
    pushq syscall_user_rsp(%rip)         # RSP = user stack
    pushq %r11                           # RFLAGS (saved by syscall)
    pushq $0x1B                          # CS  = user code selector (0x18|3)
    pushq %rcx                           # RIP (saved by syscall)

    pushq $0                             # error_code
    pushq $0x80                          # int_num: same tag as the INT 0x80 path

    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    movq %rsp, %rdi
    call syscall_handler

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax

    addq $16, %rsp                       # pop int_num + error_code
    iretq

.global load_gdt
load_gdt:
    lgdt (%rdi)
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss
    mov $0x40, %ax
    ltr %ax
    pushq $0x08
    leaq .reload_cs(%rip), %rax
    pushq %rax
    lretq
.reload_cs:
    ret

.global load_idt
load_idt:
    lidt (%rdi)
    ret

# switch_to_user(rdi=user_rsp, rsi=user_rip, rdx=user_cs, rcx=user_ss, r8=user_rflags)
.global switch_to_user
switch_to_user:
    # Save kernel callee-saved registers
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    # Save kernel stack pointer
    movq %rsp, scheduler_kernel_rsp(%rip)

    # Push iretq frame
    pushq %rcx  # SS
    pushq %rdi  # RSP
    pushq %r8   # RFLAGS
    pushq %rdx  # CS
    pushq %rsi  # RIP

    # Clear all GPRs to prevent information leak to user space
    xorq %rax, %rax
    xorq %rbx, %rbx
    xorq %rcx, %rcx
    xorq %rdx, %rdx
    xorq %rsi, %rsi
    xorq %rdi, %rdi
    xorq %rbp, %rbp
    xorq %r8,  %r8
    xorq %r9,  %r9
    xorq %r10, %r10
    xorq %r11, %r11
    xorq %r12, %r12
    xorq %r13, %r13
    xorq %r14, %r14
    xorq %r15, %r15

    iretq

# sys_exit_return()
.global sys_exit_return
sys_exit_return:
    # Switch back to kernel stack
    movq scheduler_kernel_rsp(%rip), %rsp

    # Restore kernel callee-saved registers
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx

    sti
    ret

.data
.global scheduler_kernel_rsp
scheduler_kernel_rsp:
    .quad 0

# Kernel RSP loaded by syscall_entry_64; kept in sync with TSS.RSP0.
.global syscall_kernel_rsp
syscall_kernel_rsp:
    .quad 0

# Scratch slot for the user RSP across the syscall stack switch.
.global syscall_user_rsp
syscall_user_rsp:
    .quad 0

