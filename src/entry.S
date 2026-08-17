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
    // 5 unused aout-kludge address fields (required by multiboot 1 header offset layout when VIDEO bit is set)
    .long 0   // header_addr
    .long 0   // load_addr
    .long 0   // load_end_addr
    .long 0   // bss_end_addr
    .long 0   // entry_addr
    // video request: mode_type (0 = linear graphics), width, height, depth
    .long 0   // mode_type: 0 = linear graphics
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
    .skip 4096 * 8   // 8 Page Directories = 8 GB identity map

.section .text, "ax", @progbits
.global _start
.extern kernel_entry
.extern __bss_start
.extern __bss_end

_start:
    movl %eax, mb_magic_saved
    movl %ebx, mb_info_saved

    cld
    movl $stack_top, %esp

    // Zero out entire .bss section (critical on bare metal where RAM is uninitialized)
    movl $__bss_start, %edi
    movl $__bss_end, %ecx
    subl %edi, %ecx
    shrl $2, %ecx
    xorl %eax, %eax
    rep stosl

    // Set up PML4 table (entry 0 -> pdpt_table)
    leal pdpt_table, %eax
    orl $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl %eax, pml4_table
    movl $0, pml4_table + 4

    // Set up PDPT table (8 entries -> 8 PD tables, covering 0 to 8 GB)
    leal pd_table_0, %eax
    leal pdpt_table, %edi
    movl $8, %ecx
.setup_pdpt:
    orl $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl %eax, (%edi)
    movl $0, 4(%edi)
    addl $8, %edi
    addl $4096, %eax
    decl %ecx
    jnz .setup_pdpt

    // Fill the 8 Page Directories with 2MB huge pages (512 * 8 = 4096 entries = 8 GB)
    movl $(PAGE_PRESENT | PAGE_WRITE | PAGE_SIZE), %eax
    movl $(512 * 8), %ecx
    leal pd_table_0, %edi
.fill_pds:
    movl %eax, (%edi)
    movl $0, 4(%edi)
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

