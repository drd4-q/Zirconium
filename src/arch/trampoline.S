/* AP trampoline — copied by smp.zig to physical 0x8000 before SIPI.
 * QEMU starts secondary CPUs here in 16-bit real mode (vector 8).
 * The blob is assembled and linked standalone at base 0x8000 (see build.zig):
 * all internal label addresses are 0x8000-relative, which matches the
 * physical copy target.
 *
 * Kernel-provided parameters live at FIXED offsets inside the blob and are
 * written by smp.zig after the copy:
 *   0x600 10-byte kernel GDT pseudo-descriptor (limit u16 + base u64)
 *   0x610 10-byte kernel IDT pseudo-descriptor
 *   0x700 u64 kernel PML4 (phys)
 *   0x708 u64 per-AP stack top
 *   0x710 u64 per-AP cpu index
 *   0x718 u64 ap_entry()
 */
    .code16
    .section .text, "ax", @progbits

    .global trampoline_start
    .global _start
trampoline_start:
_start:
    cli
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss

    # Load the trampoline's own flat 32-bit GDT
    lgdtl trampoline_gdtdesc

    # Protected mode: PE=1
    movl %cr0, %eax
    orl  $1, %eax
    movl %eax, %cr0
    ljmpl $0x08, $trampoline_pm32

    .code32
trampoline_pm32:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss

    # Enable PAE + PGE, mirroring entry.S
    movl %cr4, %eax
    orl  $((1 << 5) | (1 << 7) | (1 << 9) | (1 << 10)), %eax
    movl %eax, %cr4

    # CR3 = kernel PML4 (read from kernel-provided cell; low 32 bits suffice)
    movl $(trampoline_pml4_cell), %eax
    movl (%eax), %eax
    movl %eax, %cr3

    # LME = 1 (long mode enable)
    movl $0xC0000080, %ecx
    rdmsr
    orl  $(1 << 8), %eax
    wrmsr

    # Enable paging: PG=1 | PE=1
    movl %cr0, %eax
    orl  $0x80000001, %eax
    movl %eax, %cr0

    # Long mode via the local 64-bit code selector 0x18
    ljmpl $0x18, $trampoline64

    .code64
trampoline64:
    # Kernel GDT + far-jump CS to the kernel 0x08 selector.
    lgdt trampoline_gdt_cell(%rip)
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    leaq trampoline_early_stack(%rip), %rsp
    pushq $0x08
    leaq 1f(%rip), %rax
    pushq %rax
    lretq
1:
    # Kernel IDT
    lidt trampoline_idt_cell(%rip)

    # Per-AP kernel stack (from boot param)
    movq trampoline_stack_cell(%rip), %rsp
    andq $-16, %rsp
    subq $8, %rsp

    # Kernel page tables
    movq trampoline_pml4_cell(%rip), %rax
    movq %rax, %cr3

    xorq %rbp, %rbp
    xorq %rbx, %rbx
    xorq %r8, %r8
    xorq %r9, %r9
    xorq %r10, %r10
    xorq %r11, %r11
    xorq %r12, %r12
    xorq %r13, %r13
    xorq %r14, %r14
    xorq %r15, %r15

    # Call kernel ap_entry(cpu_index)
    movq trampoline_index_cell(%rip), %rdi
    movq trampoline_entry_cell(%rip), %rax
    callq *%rax

.Lhang:
    cli
    hlt
    jmp .Lhang

    .align 8
trampoline_gdt:
    .quad 0                                                 # null
    .byte 0xFF, 0xFF, 0, 0, 0, 0x9A, 0xCF, 0                # 0x08 code32
    .byte 0xFF, 0xFF, 0, 0, 0, 0x92, 0xCF, 0                # 0x10 data32
    .byte 0xFF, 0xFF, 0, 0, 0, 0x9A, 0xAF, 0                # 0x18 code64
trampoline_gdt_end:
trampoline_gdtdesc:
    .word trampoline_gdt_end - trampoline_gdt - 1
    .long trampoline_gdt

    .org 0x600
trampoline_gdt_cell:    .quad 0
                        .space 8
trampoline_idt_cell:    .quad 0
                        .space 8

    .org 0x700
trampoline_pml4_cell:   .quad 0

    .org 0x708
trampoline_stack_cell:  .quad 0

    .org 0x710
trampoline_index_cell:  .quad 0

    .org 0x718
trampoline_entry_cell:  .quad 0

    .org 0x780
trampoline_early_stack: .space 512

    .org 0x1000
trampoline_end: