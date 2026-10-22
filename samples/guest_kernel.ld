/* The layout of the sample guest kernel.
 *
 * A Multiboot guest is a single image with two halves: a 32-bit entry stub
 * at the very start, which the loader calls, and the 64-bit code after it,
 * which the stub jumps to once it has turned on long mode.
 *
 * The stub has to come first and the 64-bit code has to be 64-bit, so the
 * two are placed explicitly rather than by the linker's own order.
 */

ENTRY(_start)

SECTIONS
{
    . = 0x100000;

    .stub : {
        *(.stub)
    }

    .text : {
        *(.text.entry)
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
