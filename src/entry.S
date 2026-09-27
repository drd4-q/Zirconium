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
// PTE bit 63 is NX.  A 64-bit page-table entry is written here as two 32-bit
// halves, so in the high dword NX is bit 31.
.set PAGE_NX_HI,   1 << 31

// The kernel is linked at 1M (see linker.ld) and is a few MB.  NX applies to
// ring 0 as well, so this many 2MB pages at the bottom of the identity map are
// kept executable: 3 pages = 6MB, which covers the image, its page tables and
// the low memory the loaders use.
.set EXEC_PD_ENTRIES, 3

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
    .skip 4096 * 64  // 64 Page Directories = 64 GB identity map

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

    // Zero out entire .bss section (critical on bare metal where RAM is uninitialized).
    // Round the byte count up: a size that is not a multiple of 4 would otherwise
    // leave the trailing 1-3 bytes stale.
    movl $__bss_start, %edi
    movl $__bss_end, %ecx
    subl %edi, %ecx
    addl $3, %ecx
    shrl $2, %ecx
    xorl %eax, %eax
    rep stosl

    // Set up PML4 table (entry 0 -> pdpt_table)
    leal pdpt_table, %eax
    orl $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl %eax, pml4_table
    movl $0, pml4_table + 4

    // Set up PDPT table (64 entries -> 64 PD tables, covering 0 to 64 GB)
    leal pd_table_0, %eax
    leal pdpt_table, %edi
    movl $64, %ecx
.setup_pdpt:
    orl $(PAGE_PRESENT | PAGE_WRITE), %eax
    movl %eax, (%edi)
    movl $0, 4(%edi)
    addl $8, %edi
    addl $4096, %eax
    decl %ecx
    jnz .setup_pdpt

    // Fill the 64 Page Directories with 2MB huge pages (512 * 64 = 32768 entries = 64 GB).
    // The high dword carries NX: with EFER.NXE enabled this makes the whole
    // identity map - kernel image, RAM, page tables - non-executable, so a
    // ring-3 task cannot jump into kernel code even though it can still read
    // the address range.  User pages are mapped separately by the ELF/PE loaders
    // and are left executable.
    movl $(PAGE_PRESENT | PAGE_WRITE | PAGE_SIZE), %eax
    movl $PAGE_NX_HI, %edx
    movl $(512 * 64), %ecx
    leal pd_table_0, %edi
.fill_pds:
    movl %eax, (%edi)
    movl %edx, 4(%edi)
    addl $8, %edi
    addl $0x200000, %eax
    adcl $0, %edx
    decl %ecx
    jnz .fill_pds

    // NX is *not* privilege-dependent: an instruction fetch from an NX page
    // faults in ring 0 too.  The kernel image is linked at 1M and lives in the
    // identity map, so the first EXEC_MB megabytes must stay executable; only
    // everything above that is marked non-executable.  User programs are mapped
    // explicitly by the loaders and are unaffected either way.
    //
    // Loop the first EXEC_PD_ENTRIES 2MB entries of PD0 and clear NX there.
    movl $EXEC_PD_ENTRIES, %ecx
    leal pd_table_0, %edi
    xorl %edx, %edx                 // edx = 0 -> clears bit 63 (NX)
.clear_exec_nx:
    movl (%edi), %eax               // keep the physical address, drop NX
    movl %eax, (%edi)
    movl %edx, 4(%edi)
    addl $8, %edi
    decl %ecx
    jnz .clear_exec_nx

    leal pml4_table, %eax
    movl %eax, %cr3

    movl %cr4, %eax
    orl $((1 << 5) | (1 << 9) | (1 << 10)), %eax
    movl %eax, %cr4

    // EFER: LME (bit 8) enables long mode, NXE (bit 11) makes PTE bit 63
    // meaningful.  Without NXE the NX bits in the identity map are ignored and
    // every page stays executable.
    movl $0xC0000080, %ecx
    rdmsr
    orl $((1 << 8) | (1 << 11)), %eax
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

