pub fn outb(port_addr: u16, val: u8) void {
    asm volatile ("outb %%al, %%dx"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port_addr),
    );
}

pub fn inb(port_addr: u16) u8 {
    return asm volatile ("inb %%dx, %%al"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port_addr),
    );
}

pub fn outw(port_addr: u16, val: u16) void {
    asm volatile ("outw %%ax, %%dx"
        :
        : [val] "{ax}" (val),
          [port] "{dx}" (port_addr),
    );
}

pub fn inw(port_addr: u16) u16 {
    return asm volatile ("inw %%dx, %%ax"
        : [result] "={ax}" (-> u16),
        : [port] "{dx}" (port_addr),
    );
}

pub fn ioWait() void {
    outb(0x80, 0);
}
