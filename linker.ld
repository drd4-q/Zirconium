ENTRY(_start)

SECTIONS
{
    . = 1M;

    .multiboot : ALIGN(4)
    {
        *(.multiboot)
    }

    .text : ALIGN(4K)
    {
        *(.text)
    }

    .rodata : ALIGN(4K)
    {
        *(.rodata)
    }

    .data : ALIGN(4K)
    {
        *(.data)
    }

    .bss : ALIGN(4K)
    {
        __bss_start = .;
        *(COMMON)
        *(.bss)
        __bss_end = .;
    }

    __kernel_start = ADDR(.multiboot);
    __kernel_end = ADDR(.bss);

    .stack (NOLOAD) : ALIGN(16)
    {
        __stack_bottom = .;
        . += 16384;
        __stack_top = .;
    }

    /DISCARD/ :
    {
        *(.eh_frame)
        *(.comment)
        *(.note*)
        *(.note.GNU-stack)
    }
}
