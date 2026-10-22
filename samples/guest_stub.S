/*
 * The 32-bit Multiboot entry of the sample guest kernel.
 *
 * Multiboot calls the guest in 32-bit protected mode with a flat 4 GB code
 * segment, EAX = 0x2BADB002 and EBX pointing at the boot information block.
 * This stub does the three things every Multiboot kernel has to do before it
 * can run 64-bit code:
 *
 *   1. check that the loader really is Multiboot,
 *   2. build page tables that map the first 2 GB identically, with PAE on,
 *   3. turn on long mode and jump to the 64-bit entry point.
 *
 * The 64-bit half lives in guest_kernel.zig, which is linked in at
 * guest64_entry.
 */

.set MB_MAGIC,    0x2BADB002

.set PML4_ADDR,   0x1000        /* the stub's own scratch, below 1 MB */
.set PDPT_ADDR,   0x2000
.set PD_ADDR,     0x3000
.set PT_ADDR,     0x4000
.set STACK_TOP,   0x80000       /* the stack, in the low megabyte */

.section .stub, "ax", @progbits
.code32
.global _start
.type _start, @function
_start:
    /* EBX is the address of the boot information block.  It is the only way
     * back to it, so save it before anything else touches a register. */
    movl %ebx, %ebp

    /* 1. Is this really Multiboot? */
    cmpl $MB_MAGIC, %eax
    jne .Lno_multiboot

    /* The stack.  Multiboot gives us a stack, but the guest kernel wants one
     * it can rely on, and the loader's may be anywhere. */
    movl $STACK_TOP, %esp

    /* 2. Page tables: identity map the first 2 GB with 2 MB pages.
     *
     *    PML4[0]  -> PDPT
     *    PDPT[0]  -> PD
     *    PD[0..3] -> four page tables, 512 entries each, 2 MB per entry
     */
    movl $PML4_ADDR, %edi
    movl $PDPT_ADDR, %eax
    orl $(1 << 0) | (1 << 1), %eax          /* present | writable */
    movl %eax, (%edi)
    movl $0, 4(%edi)

    movl $PDPT_ADDR, %edi
    movl $PD_ADDR, %eax
    orl $(1 << 0) | (1 << 1), %eax
    movl %eax, (%edi)
    movl $0, 4(%edi)

    /* The four page directories: 4 x 512 x 2 MB = 4 GB, of which the first
     * 2 GB is what the 64-bit code needs. */
    movl $PD_ADDR, %edi
    movl $PT_ADDR, %eax
    xorl %edx, %edx
    movl $4, %ecx
.Lpd_loop:
    movl %eax, (%edi)
    movl %edx, 4(%edi)
    addl $0x1000, %eax
    addl $8, %edi
    incl %ecx
    jnz .Lpd_loop

    /* The four page tables: 2 MB pages, identity mapped. */
    movl $PT_ADDR, %edi
    xorl %eax, %eax
    movl $2048, %ecx
.Lpt_loop:
    movl %eax, (%edi)
    movl $0, 4(%edi)
    addl $0x200000, %eax
    addl $8, %edi
    decl %ecx
    jnz .Lpt_loop

    /* Load the page tables. */
    movl %cr3, %eax
    movl $PML4_ADDR, %eax
    movl %eax, %cr3

    /* 3. Turn on PAE (CR4.PSE) and long mode (EFER.LME). */
    movl %cr4, %eax
    orl $(1 << 5), %eax                    /* PAE */
    movl %eax, %cr4

    movl $0xC0000080, %ecx                /* EFER */
    rdmsr
    orl $(1 << 8) | (1 << 11), %eax       /* LME | NXE */
    wrmsr

    /* Enable paging and protected mode. */
    movl %cr0, %eax
    orl $(1 << 31) | (1 << 0), %eax       /* PG | PE */
    movl %eax, %cr0

    /* The 64-bit code needs the boot information's address. */
    movl %ebp, %ebx

    /* Far jump into 64-bit code: the segment selector has to have the L bit
     * set, and the offset is the 64-bit entry point. */
    ljmp $0x08, $guest64_entry

.Lno_multiboot:
    /* Not Multiboot.  There is nowhere to report it - the console is the
     * loader's, not ours - so just stop. */
    cli
    hlt
.Lhang:
    jmp .Lhang
.size _start, . - _start
