//! User-space heap: malloc/free backed by the SYS_BRK syscall.
//! Simple first-fit allocator over a contiguous brk-grown region.

const SYS_BRK: u64 = 12;

/// Header layout is derived from Block itself instead of a hand-kept constant,
/// so adding a field cannot silently desync the offsets used by free().
const Block = struct {
    size: usize, // total block size, header included
    next: ?*Block,
    used: bool, // guards against double free and bogus pointers
};

const block_header_size: usize = @sizeOf(Block);
const align_mask: usize = 15;

/// Refuse absurd requests outright.  Rounding a huge `size` up would wrap and
/// hand back a block far smaller than the caller believes it got, which is a
/// silent heap overflow rather than a clean malloc failure.
const max_request: usize = @as(usize, 1) << 62;

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

var free_head: ?*Block = null;
var heap_base: usize = 0;
var heap_top: usize = 0; // 0 = not initialized yet

fn ensureInit() bool {
    if (heap_top != 0) return true;
    const base = brkSys(0); // query current break; kernel returns the heap base
    if (base == 0) return false;
    heap_base = @intCast(base);
    heap_top = heap_base;
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
    if (size > max_request) return null;
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
                tail.* = .{ .size = b.size - block_needed, .next = next, .used = false };
                b.size = block_needed;
                if (prev) |p| {
                    p.next = tail;
                } else {
                    free_head = tail;
                }
            }
            b.used = true;
            return @ptrFromInt(@intFromPtr(b) + block_header_size);
        }
        prev = cur;
        cur = next;
    }

    // No fit: extend the heap via brk
    const base = growHeap(block_needed) orelse return null;
    const b: *Block = @ptrFromInt(base);
    b.* = .{ .size = block_needed, .next = null, .used = true };
    return @ptrFromInt(base + block_header_size);
}

pub fn free(ptr: ?*anyopaque) void {
    const p = ptr orelse return;
    if (!ensureInit()) return;
    const addr = @intFromPtr(p);
    // Reject anything that is not a live block of our own heap before touching
    // the header.  A bogus pointer here would otherwise corrupt the free list,
    // and a self-referential list makes the first-fit scan in malloc() loop
    // forever - which hangs the whole machine, because the scheduler is
    // cooperative and never preempts a runaway ring-3 task.
    if (addr < heap_base + block_header_size or addr > heap_top) return;
    const b: *Block = @ptrFromInt(addr - block_header_size);
    if (@intFromPtr(b) < heap_base or @intFromPtr(b) + b.size > heap_top) return;
    if (!b.used) return;
    b.used = false;
    b.next = free_head;
    free_head = b;
}