const std = @import("std");
const root = @import("root");
const vga = root.vga;
const serial = @import("../system/serial.zig");
const pmm = @import("pmm.zig");

// Block header: stored before each allocation
const BlockHeader = struct {
    size: usize, // usable size (excluding header)
    free: bool,
    prev: ?*BlockHeader,
    next: ?*BlockHeader,
};

const HEAP_INITIAL_PAGES: usize = 32; // 128 KB initial heap
const MIN_BLOCK_SIZE: usize = 16; // minimum allocation (header size rounded up)

var heap_start: ?[*]u8 = null;
var heap_end: ?[*]u8 = null;
var heap_pages: usize = 0;

// Free list head
var free_list: ?*BlockHeader = null;

// Stats
pub var total_allocated: usize = 0;
pub var total_freed: usize = 0;
pub var alloc_count: usize = 0;
pub var free_count: usize = 0;
pub var heap_size: usize = 0;
pub var used_size: usize = 0;

pub fn init() void {
    const pages = pmm.allocPages(HEAP_INITIAL_PAGES) orelse {
        serial.serialWrite("[KHEAP] Failed to allocate initial heap pages\n");
        return;
    };

    heap_start = @ptrFromInt(pages);
    heap_end = @ptrFromInt(pages + HEAP_INITIAL_PAGES * 4096);
    heap_pages = HEAP_INITIAL_PAGES;
    heap_size = HEAP_INITIAL_PAGES * 4096;

    // Create initial free block spanning the entire heap
    const first_block: *BlockHeader = @ptrFromInt(pages);
    first_block.size = heap_size - @sizeOf(BlockHeader);
    first_block.free = true;
    first_block.prev = null;
    first_block.next = null;
    free_list = first_block;

    serial.serialWrite("[KHEAP] Initialized at 0x");
    serial.serialWriteHex(pages);
    serial.serialWrite(" size=");
    serial.serialWriteDec(heap_size);
    serial.serialWrite(" bytes\n");
}

pub fn kmalloc(size: usize) ?[*]u8 {
    if (size == 0) return null;

    const aligned_size = (size + 15) & ~@as(usize, 15); // 16-byte align

    // Search free list for first-fit
    var block = free_list;
    while (block) |b| {
        if (b.free and b.size >= aligned_size) {
            splitBlock(b, aligned_size);
            b.free = false;
            total_allocated += b.size;
            alloc_count += 1;
            used_size += b.size + @sizeOf(BlockHeader);

            const ptr: [*]u8 = @ptrFromInt(@intFromPtr(b) + @sizeOf(BlockHeader));
            return ptr;
        }
        block = b.next;
    }

    // No suitable block found — try to expand heap
    if (expandHeap(aligned_size + @sizeOf(BlockHeader))) {
        return kmalloc(size); // retry
    }

    serial.serialWrite("[KHEAP] OOM: failed to allocate ");
    serial.serialWriteDec(size);
    serial.serialWrite(" bytes\n");
    return null;
}

pub fn kfree(ptr: [*]u8) void {
    const addr = @intFromPtr(ptr);
    const block: *BlockHeader = @ptrFromInt(addr - @sizeOf(BlockHeader));

    if (block.free) {
        serial.serialWrite("[KHEAP] Double free detected at 0x");
        serial.serialWriteHex(addr);
        serial.serialWrite("\n");
        return;
    }

    block.free = true;
    total_freed += block.size;
    free_count += 1;
    used_size -= block.size + @sizeOf(BlockHeader);

    // Merge with adjacent free blocks
    mergeBlocks(block);

    // Add to free list if not already there
    addToFreeList(block);
}

pub fn krealloc(ptr: [*]u8, new_size: usize) ?[*]u8 {
    const addr = @intFromPtr(ptr);
    const block: *BlockHeader = @ptrFromInt(addr - @sizeOf(BlockHeader));

    const aligned_new = (new_size + 15) & ~@as(usize, 15);

    // If current block is large enough, just return it
    if (block.size >= aligned_new) {
        splitBlock(block, aligned_new);
        return ptr;
    }

    // Try to merge with next block
    if (block.next) |next| {
        if (next.free) {
            const total = block.size + @sizeOf(BlockHeader) + next.size;
            if (total >= aligned_new) {
                // Remove next from free list
                removeBlock(next);
                block.size = total - @sizeOf(BlockHeader);
                splitBlock(block, aligned_new);
                return ptr;
            }
        }
    }

    // Allocate new block and copy
    const new_ptr = kmalloc(new_size) orelse return null;
    const copy_len = @min(block.size, new_size);
    var i: usize = 0;
    while (i < copy_len) : (i += 1) {
        new_ptr[i] = ptr[i];
    }
    kfree(ptr);
    return new_ptr;
}

fn splitBlock(block: *BlockHeader, needed: usize) void {
    if (block.size < needed + @sizeOf(BlockHeader) + MIN_BLOCK_SIZE) return;

    const new_block_addr = @intFromPtr(block) + @sizeOf(BlockHeader) + needed;
    const new_block: *BlockHeader = @ptrFromInt(new_block_addr);

    new_block.size = block.size - needed - @sizeOf(BlockHeader);
    new_block.free = true;
    new_block.prev = block;
    new_block.next = block.next;

    if (block.next) |next| {
        next.prev = new_block;
    }

    block.next = new_block;
    block.size = needed;
}

/// Insert into the free list ordered by ADDRESS. mergeBlocks assumes that
/// list neighbours are memory-adjacent, so an unordered (LIFO) insert here
/// used to create fake "merged" blocks spanning unrelated memory — any large
/// allocation then overlapped live data and corrupted it.
fn addToFreeList(block: *BlockHeader) void {
    const addr = @intFromPtr(block);

    if (free_list == null or addr < @intFromPtr(free_list.?)) {
        block.next = free_list;
        block.prev = null;
        if (free_list) |head| head.prev = block;
        free_list = block;
        return;
    }

    var cur = free_list.?;
    while (cur.next) |n| {
        if (@intFromPtr(n) > addr) break;
        cur = n;
    }
    block.next = cur.next;
    block.prev = cur;
    if (cur.next) |n| n.prev = block;
    cur.next = block;
}

fn mergeBlocks(block: *BlockHeader) void {
    // Merge with the NEXT block only when it is physically adjacent.
    if (block.next) |next| {
        if (next.free) {
            const end = @intFromPtr(block) + @sizeOf(BlockHeader) + block.size;
            if (@intFromPtr(next) == end) {
                block.size += @sizeOf(BlockHeader) + next.size;
                block.next = next.next;
                if (next.next) |nn| {
                    nn.prev = block;
                }
            }
        }
    }

    // Merge with the PREVIOUS block only when this one directly follows it.
    if (block.prev) |prev| {
        if (prev.free) {
            const prev_end = @intFromPtr(prev) + @sizeOf(BlockHeader) + prev.size;
            if (prev_end == @intFromPtr(block)) {
                prev.size += @sizeOf(BlockHeader) + block.size;
                prev.next = block.next;
                if (block.next) |nn| {
                    nn.prev = prev;
                }
            }
        }
    }
}

fn removeBlock(block: *BlockHeader) void {
    if (block.prev) |prev| {
        prev.next = block.next;
    } else {
        free_list = block.next;
    }
    if (block.next) |next| {
        next.prev = block.prev;
    }
}

fn expandHeap(min_needed: usize) bool {
    const pages_needed = (min_needed + 4095) / 4096;
    const new_pages = pmm.allocPages(pages_needed) orelse return false;

    const new_size = pages_needed * 4096;

    heap_end = @ptrFromInt(new_pages + new_size);
    heap_pages += pages_needed;
    heap_size += new_size;

    // Create a free block in the new region and insert it address-sorted;
    // mergeBlocks then fuses it with a physically adjacent neighbour.
    const new_block: *BlockHeader = @ptrFromInt(new_pages);
    new_block.size = new_size - @sizeOf(BlockHeader);
    new_block.free = true;

    addToFreeList(new_block);
    mergeBlocks(new_block);
    return true;
}

pub fn printStats() void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== Kernel Heap ===\n\n");
    vga.setColor(.white, .black);

    vga.write("  Heap size:   ");
    vga.writeDec(heap_size);
    vga.write(" bytes (");
    vga.writeDec(heap_size / 1024);
    vga.write(" KB)\n");

    vga.write("  Heap pages:  ");
    vga.writeDec(heap_pages);
    vga.write("\n");

    vga.write("  Used:        ");
    vga.writeDec(used_size);
    vga.write(" bytes\n");

    vga.write("  Free:        ");
    vga.writeDec(heap_size - used_size);
    vga.write(" bytes\n");

    vga.write("  Allocations: ");
    vga.writeDec(alloc_count);
    vga.write("\n");

    vga.write("  Frees:       ");
    vga.writeDec(free_count);
    vga.write("\n");

    vga.write("  Total alloc: ");
    vga.writeDec(total_allocated);
    vga.write(" bytes\n");

    vga.write("  Total freed: ");
    vga.writeDec(total_freed);
    vga.write(" bytes\n\n");

    // Count free blocks
    var free_blocks: usize = 0;
    var free_bytes: usize = 0;
    var block = free_list;
    while (block) |b| {
        if (b.free) {
            free_blocks += 1;
            free_bytes += b.size;
        }
        block = b.next;
    }

    vga.write("  Free blocks: ");
    vga.writeDec(free_blocks);
    vga.write(" (");
    vga.writeDec(free_bytes);
    vga.write(" bytes)\n");

    vga.setColor(.light_green, .black);
    vga.write("\n  PMM: ");
    vga.writeDec(pmm.free_pages);
    vga.write(" / ");
    vga.writeDec(pmm.total_pages);
    vga.write(" pages free\n");
    vga.setColor(.white, .black);
}
