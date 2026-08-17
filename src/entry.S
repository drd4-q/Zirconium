.code32

.set MBALIGN, 1 << 0
.set MEMINFO, 1 << 1
.set VIDEO,   1 << 2
.set FLAGS,    MBALIGN | MEMINFO | VIDEO 
.set MAGIC,    0x1BADB002
.set CHECKSUM, -(MAGIC + FLAGS)

.set PAGE_PRESENT, 1 << 0
.set PAGE_WRITE,   1 << 1
.set PAGE_SIZE,    1 << 7

.section .multiboot, "a", @progbits
    .align 4
    .long MAGIC
    .long FLAGS
    .long CHECKSUM
    // video request: mode_type (0 = linear), width, height, depth
    .long 0
    .long 1024
    .long 768
    .long 32
.section .data, "aw", @progbits
    .align 4
mb_magic_saved: .long 0
mb_info_saved:  .long 0

    .align 4
gdt64:
    .quad 0
    .quad (1 << 41) | (1 << 43) | (1 << 44) | (1 << 47) | (1 << 53)
    .quad (1 << 41) | (1 << 44) | (1 << 47)
gdt64_pointer:
    .word . - gdt64 - 1
    .long gdt64

.bss
    .align 16
stack_bottom:
    .skip 32768
stack_top:

    .align 4096
pml4_table:
    .skip 4096
pdpt_table:
    .skip 4096
pd_table_0:
    .skip 4096
pd_table_1:
    .skip 4096
pd_table_2:
    .skip 4096
pd_table_3:
    .skip 4096

.section .text, "ax", @progbits
.global _start
.extern kernel_entry

_start:
    movl %eax, mb_magic_saved
    movl %ebx, mb_info_saved

    cld
    movl $stack_top, %esp

    leal pml4_table, %edi
    movl $(4096 * 6 / 4), %ecx
    xorl %eax, %eax
    rep stosl

    leal pdpt_table, %eax
    orl $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl %eax, pml4_table

    leal pd_table_0, %eax
    orl $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl %eax, pdpt_table

    leal pd_table_1, %eax
    orl $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl %eax, pdpt_table + 8

    leal pd_table_2, %eax
    orl $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl %eax, pdpt_table + 16

    leal pd_table_3, %eax
    orl $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl %eax, pdpt_table + 24

    movl $(PAGE_PRESENT | PAGE_WRITE | PAGE_SIZE), %eax
    movl $2048, %ecx
    leal pd_table_0, %edi
.fill_pds:
    movl %eax, (%edi)
    addl $8, %edi
    addl $0x200000, %eax
    decl %ecx
    jnz .fill_pds

    leal pml4_table, %eax
    movl %eax, %cr3

    movl %cr4, %eax
    orl $((1 << 5) | (1 << 9) | (1 << 10)), %eax
    movl %eax, %cr4

    movl $0xC0000080, %ecx
    rdmsr
    orl $(1 << 8), %eax
    wrmsr

    movl %cr0, %eax
    andl $0xFFFFFFFB, %eax
    orl $((1 << 1) | (1 << 31) | (1 << 0)), %eax
    movl %eax, %cr0

    lgdt gdt64_pointer
    ljmp $0x08, $_start64

.code64
_start64:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss

    movq $stack_top, %rsp

    movl mb_magic_saved, %edi
    movl mb_info_saved, %esi

    call kernel_entry

.hang:
    cli
    hlt
    jmp .hang
