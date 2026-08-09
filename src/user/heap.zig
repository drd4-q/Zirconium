//! User-space heap: malloc/free backed by the SYS_BRK syscall.
//! Simple first-fit allocator over a contiguous brk-grown region.

const SYS_BRK: u64 = 12;

const block_header_size: usize = 16;
const align_mask: usize = 15;

fn syscall3(num: u64, a1: u64, a2: u64, a3: u64) u64 {
    return asm volatile (
        "int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

fn brkSys(new_break: u64) u64 {
    return syscall3(SYS_BRK, new_break, 0, 0);
}

const Block = struct {
    size: usize,
    next: ?*Block,
};

var free_head: ?*Block = null;
var heap_top: usize = 0; // 0 = not initialized yet

fn ensureInit() bool {
    if (heap_top != 0) return true;
    const base = brkSys(0); // query current break; kernel returns the heap base
    if (base == 0) return false;
    heap_top = @intCast(base);
    return true;
}

fn growHeap(amount: usize) ?usize {
    if (!ensureInit()) return null;
    const old = heap_top;
    const new = old + amount;
    if (new < old) return null; // overflow
    if (brkSys(new) != new) return null;
    heap_top = new;
    return old;
}

pub fn malloc(size: usize) ?*anyopaque {
    const payload_needed = (size + align_mask) & ~align_mask;
    const block_needed = payload_needed + block_header_size;

    // First-fit scan of the free list
    var prev: ?*Block = null;
    var cur = free_head;
    while (cur) |b| {
        const next = b.next;
        if (b.size >= block_needed) {
            // Remove b from the free list
            if (prev) |p| {
                p.next = next;
            } else {
                free_head = next;
            }
            // Split if there is leftover room for another block
            if (b.size - block_needed >= block_header_size + 16) {
                const tail: *Block = @ptrFromInt(@intFromPtr(b) + block_needed);
                tail.* = .{ .size = b.size - block_needed, .next = next };
                b.size = block_needed;
                if (prev) |p| {
                    p.next = tail;
                } else {
                    free_head = tail;
                }
            }
            return @ptrFromInt(@intFromPtr(b) + block_header_size);
        }
        prev = cur;
        cur = next;
    }

    // No fit: extend the heap via brk
    const base = growHeap(block_needed) orelse return null;
    const b: *Block = @ptrFromInt(base);
    b.* = .{ .size = block_needed, .next = null };
    return @ptrFromInt(base + block_header_size);
}

pub fn free(ptr: ?*anyopaque) void {
    if (ptr == null) return;
    const b: *Block = @ptrFromInt(@intFromPtr(ptr.?) - block_header_size);
    b.next = free_head;
    free_head = b;
}