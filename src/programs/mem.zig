const root = @import("root");
const vga = root.vga;

pub fn run() void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== Memory Info ===\n\n");

    vga.setColor(.white, .black);
    vga.write("  Region              Start       End         Size\n");
    vga.write("  ─────────────────────────────────────────────────\n");

    printRegion("Kernel code", @intFromPtr(&__kernel_start), @intFromPtr(&__kernel_end));
    printRegion("BSS (zeroed)", @intFromPtr(&__bss_start), @intFromPtr(&__bss_end));
    printRegion("Stack", @intFromPtr(&__stack_bottom), @intFromPtr(&__stack_top));
    printRegion("VGA buffer", 0xB8000, 0xB8000 + 4000);

    vga.write("\n  Physical Memory Manager:\n");
    vga.write("    Page size:    4 KB\n");
    vga.write("    Total pages:  ");
    vga.writeDec(root.pmm.total_pages);
    vga.write("\n");
    vga.write("    Free pages:   ");
    vga.writeDec(root.pmm.free_pages);
    vga.write("\n");
    vga.write("    Used pages:   ");
    vga.writeDec(root.pmm.total_pages - root.pmm.free_pages);
    vga.write("\n");
    vga.write("    Total RAM:    ");
    vga.writeDec(root.pmm.total_pages * 4 / 1024);
    vga.write(" MB\n");
    vga.write("    Free RAM:     ");
    vga.writeDec(root.pmm.free_pages * 4 / 1024);
    vga.write(" MB\n");
    vga.write("    Used RAM:     ");
    vga.writeDec((root.pmm.total_pages - root.pmm.free_pages) * 4 / 1024);
    vga.write(" MB\n\n");

    // Kernel heap stats
    vga.setColor(.yellow, .black);
    vga.write("  Kernel Heap:\n");
    vga.setColor(.white, .black);
    vga.write("    Heap size:    ");
    vga.writeDec(root.kalloc.heap_size);
    vga.write(" bytes (");
    vga.writeDec(root.kalloc.heap_size / 1024);
    vga.write(" KB)\n");
    vga.write("    Used:         ");
    vga.writeDec(root.kalloc.used_size);
    vga.write(" bytes\n");
    vga.write("    Free:         ");
    vga.writeDec(root.kalloc.heap_size - root.kalloc.used_size);
    vga.write(" bytes\n");
    vga.write("    Allocations:  ");
    vga.writeDec(root.kalloc.alloc_count);
    vga.write("\n");
    vga.write("    Frees:        ");
    vga.writeDec(root.kalloc.free_count);
    vga.write("\n");

    vga.setColor(.yellow, .black);
    vga.write("  Pointer sizes:\n");
    vga.setColor(.white, .black);
    vga.write("    *u8 = ");
    vga.writeHexShort(@sizeOf(*u8));
    vga.write(" bytes\n");
    vga.write("    *u16 = ");
    vga.writeHexShort(@sizeOf(*u16));
    vga.write(" bytes\n");
    vga.write("    *u32 = ");
    vga.writeHexShort(@sizeOf(*u32));
    vga.write(" bytes\n");
    vga.write("    *u64 = ");
    vga.writeHexShort(@sizeOf(*u64));
    vga.write(" bytes\n\n");
}

fn printRegion(name: []const u8, start: u64, end: u64) void {
    vga.write("  ");
    vga.write(name);
    var pad: usize = name.len;
    while (pad < 20) : (pad += 1) {
        vga.putChar(' ');
    }
    vga.putChar(' ');
    vga.writeHexShort(start);
    vga.write("  ");
    vga.writeHexShort(end);
    vga.write("  ");
    vga.writeHexShort(end - start);
    vga.write("\n");
}

extern const __kernel_start: u8;
extern const __kernel_end: u8;
extern const __bss_start: u8;
extern const __bss_end: u8;
extern const __stack_bottom: u8;
extern const __stack_top: u8;
