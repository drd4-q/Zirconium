/*
 * A guest kernel, written by hand.
 *
 * This is the smallest thing that is really a guest: it believes it is a PC,
 * it finds the hypervisor's device, and it talks to it.  It is written in
 * assembly on purpose - the interpreter has to implement a specific set of
 * instructions, and a hand-written guest is a list of exactly those.
 *
 * The entry is called with RDI pointing at the Multiboot information block.
 * The device (the ZVP) is mapped by the hypervisor at a fixed guest physical
 * address; a real guest would find it by scanning the PCI bus.
 *
 * It writes to the serial port, which is how its output reaches the
 * hypervisor's log.
 */

/* The magic is in the last 12 bytes of the 4 KB boot information block, so
 * it is at 4096 - 12 = 4084 from the block's start. */
.set MBINFO_MAGIC_OFFSET, 4084
.set MB_MAGIC,            0x2BADB002

.set COM1,                0x3F8

/* The PCI configuration ports. */
.set PCI_ADDRESS,         0x0CF8
.set PCI_DATA,            0x0CFC

/* Where the guest asks for the device to be mapped.  It is above the RAM and
 * below the window the hypervisor's own device starts in, the way a device
 * in the PCI memory window of a real PC is. */
.set ZVP_RELOCATE,        0xE0000000
.set REG_MAGIC,           0x000
.set REG_VERSION,         0x004
.set REG_CMD,             0x010
.set REG_STATUS,           0x014
.set REG_ARG0,            0x018
.set REG_ARG1,            0x01C
.set REG_RESULT0,         0x028
.set REG_RESULT1,         0x02C
.set REG_DOORBELL,        0x058
.set REG_SERVICED,        0x05C
.set ZVP_MAGIC,           0x5A565031
.set CMD_PING,            1
.set CMD_IDENTITY,        2
.set CMD_MACHINE,         7

    .section .text
    .code64
    .globl guest_entry
    .type guest_entry, @function

guest_entry:
    /* RDI is the boot information block.  Keep it: it is the only handle on
     * what the hypervisor told us. */
    movq %rdi, %r12

    call serial_init
    leaq msg_hello(%rip), %rsi
    call serial_write

    /* Check that the hypervisor really is Multiboot. */
    movl MBINFO_MAGIC_OFFSET(%r12), %eax
    cmpl $MB_MAGIC, %eax
    jne .Lnot_multiboot
    leaq msg_mb_ok(%rip), %rsi
    call serial_write
    jmp .Ldevice

.Lnot_multiboot:
    leaq msg_no_mb(%rip), %rsi
    call serial_write

.Ldevice:
    /* Find the hypervisor's device.  A real guest scans the PCI bus for it;
     * a hard-coded address would be a guest that believes it is the only
     * machine in the world. */
    call pci_find
    testq %rbx, %rbx
    jz .Lno_device
    leaq msg_dev_ok(%rip), %rsi
    call serial_write

    /* The version. */
    leaq msg_ver(%rip), %rsi
    call serial_write
    movl REG_VERSION(%rbx), %eax
    addb $0x30, %al
    movw $COM1, %dx
    outb %al, %dx
    leaq msg_space(%rip), %rsi
    call serial_write
    /* The same value, in hex. */
    movl REG_VERSION(%rbx), %eax
    movq %rax, %rdi
    call serial_hex
    leaq msg_nl(%rip), %rsi
    call serial_write

    /* Which machine did the hypervisor give us? */
    movl $CMD_MACHINE, REG_CMD(%rbx)
    movl $1, REG_ARG0(%rbx)
    call zvp_wait
    leaq msg_machine(%rip), %rsi
    call serial_write
    movl REG_RESULT0(%rbx), %eax
    addb $0x30, %al
    movw $COM1, %dx
    outb %al, %dx
    leaq msg_nl(%rip), %rsi
    call serial_write

    /* And can it still hear us? */
    movl $CMD_PING, REG_CMD(%rbx)
    movl $2, REG_ARG0(%rbx)
    call zvp_wait
    movl REG_RESULT0(%rbx), %eax
    cmpl $0x50494E47, %eax
    jne .Lno_pong
    leaq msg_pong(%rip), %rsi
    call serial_write
    jmp .Ldone

.Lno_pong:
    leaq msg_no_pong(%rip), %rsi
    call serial_write
    jmp .Ldone

.Lno_device:
    leaq msg_no_dev(%rip), %rsi
    call serial_write

.Ldone:
    leaq msg_done(%rip), %rsi
    call serial_write
    cli
    hlt
.Lhalt:
    jmp .Lhalt
.size guest_entry, . - guest_entry

/* Find the hypervisor's device on the PCI bus.
 *
 * This is the ordinary way a guest finds its hardware: write the
 * bus/slot/function/register triple to the configuration address port, then
 * read the configuration space through the data port.  The address of the
 * device comes out of its base address register, and the guest maps that
 * address itself.
 *
 * On success RBX holds the device's base address; on failure it is zero.
 */
    .type pci_find, @function
pci_find:
    movl $0, %r13d                   /* the slot */
.Lslot:
    cmpl $32, %r13d
    jae .Lnone
    movl $0, %r14d                   /* the function */
.Lfunc:
    cmpl $8, %r14d
    jae .Lnext_slot

    /* The address register: enable | slot << 11 | function << 8. */
    movl %r13d, %eax
    shll $11, %eax
    movl %r14d, %ecx
    shll $8, %ecx
    orl %ecx, %eax
    orl $0x80000000, %eax
    movw $PCI_ADDRESS, %dx
    outl %eax, %dx

    /* The vendor and device ID.  An absent function reads all ones, so the
     * *vendor* - the low half - is what tells them apart. */
    movw $PCI_DATA, %dx
    inl %dx, %eax
    andl $0xFFFF, %eax
    cmpl $0xFFFF, %eax
    je .Lnext_func
    movl %eax, %r15d                 /* the vendor and device ID */

    /* Base address register 0. */
    movl %r13d, %eax
    shll $11, %eax
    movl %r14d, %ecx
    shll $8, %ecx
    orl %ecx, %eax
    orl $0x80000000, %eax
    orl $0x10, %eax                  /* the register number of BAR0 */
    movw $PCI_ADDRESS, %dx
    outl %eax, %dx
    movw $PCI_DATA, %dx
    inl %dx, %eax
    movl %eax, %r15d                 /* the base address register */
    andl $0xFFFFFFF0, %eax
    testl %eax, %eax
    jz .Lnext_func

    /* Program the register where we want it.  A guest that reads a base
     * address register and then uses the address it read has to program it
     * first: the address is a place the *guest* chooses. */
    movl %r15d, %ecx
    andl $0x0F, %ecx                 /* the type bits, which are read-only */
    orl $ZVP_RELOCATE, %ecx
    movl %r13d, %eax
    shll $11, %eax
    movl %r14d, %edx
    shll $8, %edx
    orl %edx, %eax
    orl $0x80000000, %eax
    orl $0x10, %eax
    movw $PCI_ADDRESS, %dx
    outl %eax, %dx
    movl %ecx, %eax
    movw $PCI_DATA, %dx
    outl %eax, %dx

    /* And the device is there, at the address we asked for.  The low four
     * bits of the register are the type, not part of the address. */
    movl %ecx, %ebx
    andl $0xFFFFFFF0, %ebx
    movl REG_MAGIC(%rbx), %eax
    cmpl $ZVP_MAGIC, %eax
    jne .Lnext_func
    ret
.Lnext_func:
    incl %r14d
    jmp .Lfunc
.Lnext_slot:
    incl %r13d
    jmp .Lslot
.Lnone:
    xorl %ebx, %ebx
    ret
.size pci_find, . - pci_find

/* Wait for the hypervisor to answer the command in CMD. */
    .type zvp_wait, @function
zvp_wait:
    movl REG_SERVICED(%rbx), %r14d
    addl $1, %r14d
    movl %r14d, REG_DOORBELL(%rbx)
.Lwait:
    movl REG_SERVICED(%rbx), %eax
    cmpl %r14d, %eax
    jne .Lwait
    ret
.size zvp_wait, . - zvp_wait

/* Set up the serial port: 115200 8N1.
 *
 * The 8250's registers are at offsets from the base: 0 is the transmit
 * holding register, 1 the interrupt enable, 2 the FIFO control, 3 the line
 * control, 4 the modem control and 5 the line status.  The divisor latch
 * overlaps 0 and 1 and is selected by the line control's DLAB bit.
 */
    .type serial_init, @function
serial_init:
    movw $(COM1+1), %dx        /* the interrupt enable */
    movb $0x00, %al
    outb %al, %dx               /* the interrupts off */

    movw $(COM1+3), %dx        /* the line control */
    movb $0x80, %al
    outb %al, %dx               /* DLAB: the divisor latch is selected */

    movw $COM1, %dx            /* the divisor latch, low */
    movb $0x01, %al
    outb %al, %dx               /* 115200 baud */

    movw $(COM1+1), %dx        /* the divisor latch, high */
    movb $0x00, %al
    outb %al, %dx

    movw $(COM1+3), %dx        /* the line control */
    movb $0x03, %al
    outb %al, %dx               /* 8 bits, no parity, one stop */

    movw $(COM1+4), %dx        /* the modem control */
    movb $0x07, %al
    outb %al, %dx

    movw $(COM1+2), %dx        /* the FIFO control */
    movb $0x0B, %al
    outb %al, %dx               /* the FIFO on */
    ret
.size serial_init, . - serial_init

/* Write the NUL-terminated string in RSI to the serial port. */
    .type serial_write, @function
serial_write:
    movq %rsi, %rcx
.Lsw:
    movzbl (%rcx), %eax
    testl %eax, %eax
    je .Lsw_end
    /* Wait for the transmit holding register to be empty.  The check reads
     * the line status, and the check itself clobbers AL, so the character is
     * reloaded afterwards. */
    movw $(COM1+5), %dx
.Lwait_tx:
    inb %dx, %al
    andb $0x20, %al
    jz .Lwait_tx
    movzbl (%rcx), %eax
    movw $COM1, %dx
    outb %al, %dx
    incq %rcx
    jmp .Lsw
.Lsw_end:
    ret
.size serial_write, . - serial_write

/* Write the 64-bit value in RDI to the serial port as hex. */
    .type serial_hex, @function
serial_hex:
    movq %rdi, %rcx
    movl $16, %r8d
.Lsh:
    decl %r8d
    /* Sixteen nibbles, then stop. */
    jz .Lsh_end
    /* Rotate the value left by four bits: the top nibble comes round into
     * the bottom, which is the nibble to print next. */
    rolq $4, %rcx
    movq %rcx, %rax
    andl $0xF, %eax
    movq %rax, %r10            /* the digit index */
    leaq hex_digits(%rip), %r11
    movzbl (%r11,%r10), %edx
    movb %dl, %r9b             /* the digit, out of harm's way */
    /* Wait for the transmit holding register to be empty.  The check uses
     * DX and AL, so the index and the digit are kept elsewhere. */
    movw $(COM1+5), %dx
.Lwait_tx2:
    inb %dx, %al
    andb $0x20, %al
    jz .Lwait_tx2
    movb %r9b, %al
    movw $COM1, %dx
    outb %al, %dx
    jmp .Lsh
.Lsh_end:
    ret
.size serial_hex, . - serial_hex

    .section .rodata
hex_digits:
    .ascii "0123456789ABCDEF"

msg_hello:
    .asciz "\n[GUEST] ZVM guest: hello\n"
msg_mb_ok:
    .asciz "[GUEST] multiboot magic ok\n"
msg_no_mb:
    .asciz "[GUEST] not a multiboot boot\n"
msg_dev_ok:
    .asciz "[GUEST] found the ZVP device\n"
msg_no_dev:
    .asciz "[GUEST] no ZVP device\n"
msg_ver:
    .asciz "[GUEST] ZVP version "
msg_machine:
    .asciz "[GUEST] machine "
msg_pong:
    .asciz "[GUEST] the hypervisor answered\n"
msg_no_pong:
    .asciz "[GUEST] the hypervisor did not answer\n"
msg_done:
    .asciz "[GUEST] guest: done\n"
msg_nl:
    .asciz "\n"
msg_space:
    .asciz " "
