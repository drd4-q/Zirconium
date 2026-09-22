# Comprehensive Kernel Subsystems Audit & Stability Survey Report

**Explorer**: Explorer 1 (Core Subsystems Audit)  
**Date**: 2026-09-20  
**Target**: Zirconium x86_64 Bare-Metal Operating System Kernel  
**Status**: Read-Only Survey Complete  

---

## 1. Executive Summary

An exhaustive, line-by-line audit of the core kernel subsystems of the Zirconium x86_64 bare-metal kernel was conducted across six core subsystem domains:
1. **Memory Management**: Physical Memory Manager (`pmm.zig`), Virtual Memory Manager (`vmm.zig`), Kernel Heap (`kalloc.zig`), Address Space Manager (`address_space.zig`).
2. **Concurrency, SMP & Scheduling**: Scheduler (`scheduler.zig`), Task State (`task.zig`), SMP Bringup (`smp.zig`), ACPI Discovery (`acpi.zig`), APIC Driver (`apic.zig`), Timer Driver (`timer.zig`).
3. **Interrupts & Architecture**: IDT (`idt.zig`), ISR Dispatch (`isr.zig`, `isr.S`), PIC (`pic.zig`), GDT & TSS (`gdt.zig`), SYSCALL/SYSRET (`syscall64.zig`).
4. **Syscalls & Ring 3**: Native Syscall Dispatcher (`syscall.zig`), Process Setup (`process.zig`), User Test Binary (`test.zig`), User Heap Allocator (`heap.zig`).
5. **VFS & Filesystem**: VFS Layer (`vfs.zig`), RAMFS (`ramfs.zig`), FAT16 Driver (`fat16.zig`), Block Device Abstraction (`blockdev.zig`), Virtio-blk Driver (`virtio_blk.zig`).
6. **Networking & Drivers**: Network Stack Core (`mod.zig`), TCP/IP (`tcp.zig`, `ip.zig`), ARP (`arp.zig`), UDP/DHCP (`udp.zig`, `dhcp.zig`), Intel e1000 Driver (`e1000.zig`).

### Key Critical Findings Summary
- **Zero Kernel Synchronization Across SMP / Multi-Core**: Global data structures across PMM, VMM, Kernel Heap, Scheduler, VFS, and Network Driver possess zero mutexes, spinlocks, or atomic protections. AP cores or interrupts concurrently accessing memory allocators will immediately corrupt heap nodes, page allocation bitmaps, and network descriptor rings.
- **Critical Heap Corruption in `kalloc.expandHeap`**: Non-contiguous physical chunk expansion links disjoint memory blocks as adjacent; freeing adjacent blocks causes `mergeBlocks` to sum sizes without checking addresses, creating phantom blocks that bridge physical gaps and overwrite kernel memory.
- **Architectural Security Hole in `SYSCALL64`**: `IA32_FMASK` fails to mask IF (Interrupt Flag). An incoming interrupt taken immediately upon `syscall` instruction execution pushes an `InterruptFrame` onto the user-controlled `%rsp`, giving ring 3 arbitrary write control over kernel state or inducing triple faults.
- **User Segfault Induces Kernel Panic**: Non-COW page faults (or any unhandled exception) in Ring 3 directly invoke `kernelPanic()` and halt the CPU (`cli; hlt`), crashing the entire operating system rather than killing the faulty task.
- **Static Array Memory Free Corruption in VFS**: `vfs.open()` allocates a `FileHandle` on the heap inside `ramfsOpen()`, copies it into static array `open_files[i]`, and returns the static address. `vfs.close()` passes the static address to `ramfsClose()`, which calls `kfree()` on static BSS memory, destroying heap headers and corrupting BSS state.
- **Permanent TCP & FAT16 Connection / Handle Leaks**: TCP connection slots closed via RST, timeout, or normal teardown fail to reset `conn.id = -1`, permanently exhausting the 4 available sockets. Similarly, FAT16 `open_handles` slots and `file_cache` slots are never freed on close, permanently preventing file opens after 32 handles or 128 file accesses.
- **Hardcoded NIC Transmission**: Higher-level networking modules (`arp.zig`, `dhcp.zig`, `icmp.zig`, `tcp.zig`, `udp.zig`) invoke `e1000.transmit()` directly instead of dispatching through `net.sendFrame()` or a device abstraction, rendering RTL8169 and any future USB Wi-Fi / Ethernet adapters completely non-functional.

---

## 2. Detailed Subsystem Audit & Vulnerability Catalog

---

### Group 1: Memory Management

#### 1.1 `src/kernel/pmm.zig`
- **Location**: `src/kernel/pmm.zig:24-32, 158-175, 177-214, 216-248`
- **Issue**: **Complete Absence of Concurrency Control (Race Conditions)**
  - *Mechanism*: `bitmap`, `ref_counts`, `free_pages`, and `total_pages` are modified without atomic operations, spinlocks, or interrupt disabling.
  - *Failure Mode*: In an SMP environment or during interrupt handlers, concurrent calls to `allocPage()`, `freePage()`, `incRef()`, and `decRef()` will race. Two cores can allocate the exact same physical page simultaneously, ref counts will desynchronize, and `free_pages` counters will deviate from actual state.
  - *Remediation*: Implement a kernel spinlock (`var pmm_lock: Spinlock = .{};`) around all allocation, freeing, and ref-count mutation functions.
- **Location**: `src/kernel/pmm.zig:58-60`
  - *Mechanism*: In `mmap` parsing: `if (entry_size < 20) break;`. If a BIOS provides a slightly non-standard entry size or trailing attributes, breaking immediately terminates memory discovery rather than advancing or reporting an error.
  - *Remediation*: Check `if (entry_size < 20) { offset += 24; continue; }`.
- **Location**: `src/kernel/pmm.zig:219-222`
  - *Mechanism*: Saturated reference count at `ref_counts[page] < 255`. If a page is shared across >255 tasks, the count ceases incrementing. As tasks exit, `decRef` decrements until 0, prematurely freeing a page that still has active readers.
  - *Remediation*: If `ref_counts[page] == 255`, pin the page permanently or widen ref count storage.

#### 1.2 `src/kernel/vmm.zig`
- **Location**: `src/kernel/vmm.zig:26-28`
  - *Mechanism*: **Lack of SMP TLB Shootdown**
  - *Observation*: `invalidatePage(vaddr)` executes a local `invlpg (%[addr])`.
  - *Failure Mode*: On x86_64 SMP, modifying page tables or resolving COW faults only updates the TLB of the calling core. Other cores running tasks in the same address space retain stale TLB translations, reading outdated or freed memory.
  - *Remediation*: When modifying a shared page table, send an IPI (Inter-Processor Interrupt) to all online AP cores to execute `invlpg`.
- **Location**: `src/kernel/vmm.zig:93-103`
  - *Mechanism*: **Page Directory Permission Loss**
  - *Observation*: `nextPageTable` returns an existing table entry if present: `if (entry & PAGE_PRESENT != 0) return @ptrFromInt(entry & PAGE_ADDR_MASK);`.
  - *Failure Mode*: If an intermediate PDPT or PD was initially mapped without `PAGE_USER` (e.g. during kernel identity mapping), subsequent calls to `mapPage()` for a user address will find the intermediate table marked kernel-only and will NOT add `PAGE_USER` to the parent entry. The CPU then triggers a `#PF` with ring 3 protection violation on access.
  - *Remediation*: Update the existing entry flags: `table[index] |= (flags & (PAGE_USER | PAGE_WRITE));`.
- **Location**: `src/kernel/vmm.zig:128-163`
  - *Mechanism*: **Physical Page Table Leak on `unmapPage`**
  - *Failure Mode*: `unmapPage` clears the leaf PT entry but does NOT decrement the ref count or free the backing physical page, nor does it free empty PT or PD pages when all 512 entries are cleared.
  - *Remediation*: `unmapPage` should return or release the physical page and prune empty page tables.

#### 1.3 `src/kernel/kalloc.zig`
- **Location**: `src/kernel/kalloc.zig:193-232, 169-191`
- **Issue**: **Critical Heap Memory Corruption via Non-Contiguous `expandHeap` Merging**
  - *Mechanism*: When `kmalloc` exhausts the initial 128 KB heap, `expandHeap()` allocates `pages_needed` using `pmm.allocPages()`. If these pages are not physically contiguous with the existing heap, it appends `new_block` to the end of `free_list`:
    ```zig
    last.next = new_block;
    new_block.prev = last;
    ```
    Later, when blocks in `last` and `new_block` are both freed, `mergeBlocks()` executes:
    ```zig
    prev.size += @sizeOf(BlockHeader) + block.size;
    prev.next = block.next;
    ```
  - *Failure Mode*: `mergeBlocks` assumes all sequentially linked blocks are contiguous in virtual/physical address space! It adds the sizes together across an arbitrary physical memory gap. Any subsequent allocation taking advantage of this merged size will write across the unallocated memory gap, corrupting arbitrary kernel physical memory.
  - *Remediation*: `free_list` must strictly represent contiguous arenas, or each heap chunk must maintain an explicit base address and limit so blocks in disjoint arenas are NEVER coalesced.
- **Location**: `src/kernel/kalloc.zig:111-148`
  - *Mechanism*: `krealloc` absorbs a free `next` block without updating heap statistics (`used_size`, `total_allocated`), creating accounting drift in `printStats()`.

#### 1.4 `src/kernel/address_space.zig`
- **Location**: `src/kernel/address_space.zig:184-193, 211-220`
- **Issue**: **Corrupt Address Bitmasks & Sizing in `cloneUserSpace`**
  - *Observation*:
    ```zig
    if (pdpt_entry & vmm.PAGE_SIZE != 0) {
        const phys = pdpt_entry & 0x000FFFFFC0000000;
        const new_phys = pmm.allocPages(512) orelse ...;
        @memcpy(@as([*]u8, @ptrFromInt(new_phys))[0 .. 512 * 2048], ...);
        child_pdpt[pdpt_idx] = (new_phys & 0x000FFFFFC0000000) | ...;
    }
    ```
  - *Failure Mode*:
    1. A 1 GB huge page contains 262,144 pages, yet `allocPages(512)` allocates only 2 MB. `@memcpy` copies only `512 * 2048` (1 MB).
    2. `new_phys & 0x000FFFFFC0000000` requires 1 GB alignment. A 4 KB aligned page from `allocPages` will have bits 12..29 cleared to 0, completely altering the physical target address.
    3. For 2 MB huge pages (line 212): `pd_entry & 0x000FFFFFE0000000` has 5 'F's instead of 7 'F's (`0x000FFFFFFFE00000`), inadvertently masking out bits 21..28 (clearing 256 MB of address information).
    4. Furthermore, huge pages in PML4[0] are kernel identity-map pages and should NEVER be deep-copied by user process cloning; they must be shared read-only.
  - *Remediation*: Do not allocate and clone huge pages in `cloneUserSpace`. Share identity mappings directly without re-allocation.
- **Location**: `src/kernel/address_space.zig:359-378`
  - *Mechanism*: `isSharedKernelTable` uses `const current = vmm.getCurrentCr3();`. If `destroy()` is called on a task that is NOT the currently running task, it compares against the wrong PML4, failing to detect shared kernel page tables and freeing active kernel tables (`pmm.freePage(pd_phys)`).
  - *Remediation*: Pass the kernel's original boot CR3 / PML4 pointer to `isSharedKernelTable` rather than reading current volatile CR3.

---

### Group 2: Concurrency, SMP & Scheduling

#### 2.1 `src/kernel/scheduler.zig` & `src/kernel/task.zig`
- **Location**: `src/kernel/scheduler.zig:10-16, 226-250, 252-288`
- **Issue**: **Non-Preemptive Run-to-Completion Scheduler with Global Racy State**
  - *Observation*: Tasks run in `runAll()` or `runTask()` until completion or voluntary exit. Preemption is completely unconfigured despite `TIME_SLICE = 10` existing.
  - *Failure Mode*: If any user task enters an infinite loop (`while(true){}`), the entire OS hangs permanently. No timer tick ever preempts or context-switches a task.
  - *Remediation*: Hook `timer.zig` / LAPIC timer interrupt (Vector 32) into `scheduler.tick()` to save current task register context (`InterruptFrame`) and switch tasks when `time_slice` expires.
- **Location**: `src/kernel/task.zig:81, 106-108`
  - *Mechanism*: Fixed maximum tasks `MAX_TASKS = 16` and static kernel stacks `[KERNEL_STACK_SIZE]u8`. Reusable slots in `newUserTaskSlot()` reset state with `t.* = .{};`, but if tasks are repeatedly spawned without exit, the system returns `null` with no resource recovery.

#### 2.2 `src/arch/smp.zig`
- **Location**: `src/arch/smp.zig:101-120, 157-181`
- **Issue**: **Shared TSS & Stack Collision Across Multiple Cores**
  - *Observation*: `prepareAp` hands the AP core the exact same GDT and IDT as the BSP (`writeBytesCell(CELL_GDT_DESC, gdt_desc)`).
  - *Failure Mode*: In x86_64, when an interrupt or syscall occurs at CPL 3, the hardware loads `RSP0` from the active TSS. Because all cores share the exact same TSS (`gdt.tss.rsp0`), if multiple cores handle ring 3 transitions or interrupts concurrently, they will execute on the exact same stack pointer, instantly corrupting each other's registers and stack frames.
  - *Remediation*: Create per-CPU GDTs and per-CPU TSS instances with distinct `rsp0` stacks for each detected CPU.
- **Location**: `src/arch/smp.zig:173-180`
  - *Observation*: Secondary AP cores idle in an infinite busy-loop:
    ```zig
    while (true) {
        ticks +%= 1;
        asm volatile ("pause");
    }
    ```
  - *Failure Mode*: APs consume 100% host CPU and perform zero scheduling work because the scheduler only dispatches tasks on the BSP.

#### 2.3 `src/drivers/apic.zig` & `src/drivers/timer.zig`
- **Location**: `src/drivers/apic.zig:111-119` vs `AGENTS.md`
- **Issue**: **Discrepancy in LAPIC Timer Masking & Interrupt Double-Counting**
  - *Observation*: AGENTS.md explicitly states: "LAPIC timer is intentionally masked (src/drivers/apic.zig:83) — the PIT is the single 100 Hz tick source."
  - *Actual Code*: In `src/drivers/apic.zig:114-118`, the LAPIC timer is initialized in periodic mode (`writeReg(REG_LVT_TIMER, periodic_mode | timer_vector);`) and unmasked, while legacy PIT IRQ 0 is masked via `pic.mask(0);`.
  - *Status*: The LAPIC timer is actually unmasked and PIT IRQ0 is masked. If PIT IRQ0 is unmasked elsewhere, vector 32 fires twice per tick, causing sleep and timeout durations to halve.
- **Location**: `src/drivers/timer.zig:33-39`
  - *Observation*: `sleep(ms)` executes:
    ```zig
    asm volatile ("sti");
    while (ticks < target) {
        asm volatile ("hlt");
    }
    ```
  - *Failure Mode*: Unconditionally forces interrupts on (`sti`) even if the caller held a critical section with interrupts disabled. Furthermore, if `target` wraps around u64, the loop behaves unexpectedly.
  - *Remediation*: Save interrupt flags via `pushfq; popq` before halting, and restore original flags upon exit.

---

### Group 3: Interrupts & Architecture

#### 3.1 `src/arch/syscall64.zig` & `src/arch/isr.S`
- **Location**: `src/arch/syscall64.zig:29-33` and `src/arch/isr.S:229-234`
- **Issue**: **CRITICAL KERNEL VULNERABILITY: Unmasked IF in `IA32_FMASK` on `syscall` Entry**
  - *Observation*:
    ```zig
    // Mask DF (0x400), TF (0x100), NT (0x4000), AC (0x40000) on syscall entry while
    // keeping IF=1 so timer/interrupts continue to work for blocking syscalls.
    const fmask: u64 = (1 << 8) | (1 << 10) | (1 << 14) | (1 << 18); // TF, DF, NT, AC
    msr.write(msr.IA32_FMASK, fmask);
    ```
    Assembly entry in `isr.S`:
    ```asm
    syscall_entry_64:
        cld
        movq %rsp, syscall_user_rsp(%rip)
        movq syscall_kernel_rsp(%rip), %rsp
    ```
  - *Mechanism*: `IA32_FMASK` does NOT mask IF (bit 9, 0x200). When user space executes `syscall`, the CPU enters CPL 0 with `IF=1` (interrupts enabled).
  - *Catastrophic Failure Mode*: If an interrupt (timer, keyboard, NIC) occurs before or during `movq %rsp, syscall_user_rsp(%rip)`:
    1. The CPU is already in CPL 0.
    2. Because CPL is 0, the CPU does NOT look at TSS.RSP0! It pushes the hardware interrupt frame onto whatever `%rsp` currently holds.
    3. `%rsp` is still the USER STACK!
    4. The kernel interrupt handler executes using the user stack, allowing a malicious ring 3 program to corrupt kernel frames or trigger an unhandled double fault.
    5. Additionally, `syscall_user_rsp` is a single non-reentrant global variable. Nested interrupts will corrupt it.
  - *Remediation*:
    1. Mask IF in FMASK: `const fmask: u64 = (1 << 8) | (1 << 9) | (1 << 10) | (1 << 14) | (1 << 18);`.
    2. Switch to kernel stack immediately in `syscall_entry_64` before enabling interrupts with `sti`.

#### 3.2 `src/arch/isr.zig`
- **Location**: `src/arch/isr.zig:84-138`
- **Issue**: **Ring 3 Exception Induces Unconditional Kernel Panic & System Halt**
  - *Observation*:
    ```zig
    if (int_num < 32) {
        if (int_num == 14) {
            var fault_addr: u64 = 0;
            asm volatile ("movq %%cr2, %[addr]" : [addr] "=r" (fault_addr));
            if (@import("../kernel/vmm.zig").handlePageFault(fault_addr, frame.error_code)) {
                return;
            }
        }
        vga.write("\n=== KERNEL PANIC ===\n");
        ...
        while (true) asm volatile ("cli; hlt");
    }
    ```
  - *Failure Mode*: If a user space program dereferences `NULL`, triggers `#GP` (int 13), executes an invalid instruction (`#UD`, int 6), or performs division by zero (`#DE`, int 0), the kernel executes a kernel panic and halts the machine!
  - *Remediation*: Check `(frame.cs & 3) == 3`. If the fault originated in Ring 3, terminate the current user task (`process.exitCurrent(-11)`), reclaim its resources, and return to the scheduler instead of panicking.
- **Location**: `src/arch/isr.zig:140-148`
  - *Mechanism*: EOI is only sent if `int_num >= 32 and int_num < 48`. If any MSI/MSI-X interrupt or APIC vector >= 48 arrives (e.g. vector 255 spurious or future PCIe/USB interrupts), no EOI is sent to LAPIC, permanently blocking all subsequent interrupts.

#### 3.3 `src/arch/isr.S`
- **Location**: `src/arch/isr.S:318-320, 351-353, 368`
- **Issue**: **Global Scratch Register `scheduler_kernel_rsp` Prevents Multi-Task Preemption**
  - *Observation*: `scheduler_kernel_rsp: .quad 0` is a single global quadword.
  - *Failure Mode*: Context switching between multiple user tasks or nested syscalls overwrites this single variable, corrupting the return stack pointer.

---

### Group 4: Syscalls & Ring 3

#### 4.1 `src/kernel/syscall.zig`
- **Location**: `src/kernel/syscall.zig:108-119, 130-155, 515-517, 555-557, 588-593`
- **Issue**: **Unchecked User Pointers in Kernel Space (Arbitrary Kernel Read/Write)**
  - *Observation*:
    ```zig
    // SYS_WRITE:
    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    // Directly dereferenced in kernel mode!
    // SYS_READ:
    const buf: [*]u8 = @ptrFromInt(buf_ptr);
    buf[count] = ch; // Written in kernel mode!
    ```
  - *Failure Mode*: Ring 3 passes arbitrary pointers (e.g. `0x100000` kernel image or `0x8000` page tables). `SYS_READ` overwrites kernel data structures with keyboard input. `SYS_WRITE` dumps kernel memory to stdout. If the address is unmapped, it triggers a kernel page fault, crashing the OS.
  - *Remediation*: Implement `validateUserBuffer(addr: u64, len: usize, write: bool) bool`. Ensure `addr >= USER_BASE and addr + len <= USER_STACK_TOP`.
- **Location**: `src/kernel/syscall.zig:200-220`
  - *Issue*: **Heap Deallocation Leak in `SYS_BRK`**
  - *Observation*: When `new_brk <= old_brk`, `t.heap_brk = new_brk` is updated, but physical pages between `new_brk` and `t.heap_mapped` are NEVER freed or unmapped, and `t.heap_mapped` is not decreased. Subsequent expansions skip mapping, leading to memory corruption.
- **Location**: `src/kernel/syscall.zig:310-345`
  - *Issue*: **FD Table and Socket Table Wiped on `SYS_FORK`**
  - *Observation*: `child.* = .{};` wipes child task data to defaults. Open file descriptors (`fds`) and active network sockets (`sockets`) are never copied to the child process.
- **Location**: `src/kernel/syscall.zig:440-469`
  - *Issue*: **Non-Blocking `SYS_WAITPID` Breaks Standard Process Management**
  - *Observation*: `SYS_WAITPID` checks if child has already finished; if not, it immediately returns `ECHILD (-1)` without blocking. A parent waiting for a child process immediately errors out.
- **Location**: `src/kernel/syscall.zig:587-594`
  - *Issue*: **Silent Data Loss in `SYS_RECV`**
  - *Observation*:
    ```zig
    const copy_len = @min(conn.rx_len, max_len);
    @memcpy(user_buf[0..copy_len], conn.rx_buf[0..copy_len]);
    conn.rx_len = 0;
    conn.rx_ready = false;
    ```
  - *Failure Mode*: If 1000 bytes are received and user requests 100 bytes (`max_len = 100`), 100 bytes are copied and the remaining 900 bytes are permanently discarded! There is no sliding receive buffer or FIFO stream.

#### 4.2 `src/user/heap.zig`
- **Location**: `src/user/heap.zig:91-96`
- **Issue**: **Heap Fragmentation & Infinite Loops on Double Free**
  - *Observation*: `free()` prepends freed blocks to `free_head` without coalescing adjacent memory blocks.
  - *Failure Mode*: Frequent allocations cause severe fragmentation where adjacent free blocks cannot satisfy larger requests. Calling `free(ptr)` twice creates an immediate cycle in the singly-linked list, causing `malloc()` to loop infinitely.

---

### Group 5: VFS & Filesystem

#### 5.1 `src/fs/vfs.zig` & `src/fs/ramfs.zig`
- **Location**: `src/fs/vfs.zig:260-274, 277-288` vs `src/fs/ramfs.zig:136-143, 201-204`
- **Issue**: **CRITICAL BSS CORRUPTION: `kfree()` Called on Static Array in VFS File Close**
  - *Mechanism*:
    1. In `ramfsOpen`: `const handle = kalloc.kmalloc(@sizeOf(vfs.FileHandle)) orelse return null;`. Heap memory is allocated.
    2. In `vfs.open`:
       ```zig
       const handle = fs.openFn(fs, rel_path, flags) orelse return null;
       open_files[i] = handle.*; // Copied to static BSS array!
       file_used[i] = true;
       return &open_files[i];   // Returns pointer to STATIC array open_files[i]
       ```
       Notice that the heap pointer `handle` is never stored and never freed — it is LEAKED on every single file open!
    3. In `vfs.close`:
       ```zig
       handle.fs.closeFn(handle.fs, handle); // Passes &open_files[i] to closeFn!
       ```
    4. In `ramfsClose`:
       ```zig
       kalloc.kfree(@ptrFromInt(@intFromPtr(handle))); // Calls kfree(&open_files[i])!
       ```
  - *Catastrophic Failure Mode*: `kfree()` expects a heap pointer preceded by a `BlockHeader`. It reads `@intFromPtr(&open_files[i]) - 32`, assumes it is a `BlockHeader`, marks it free, and links it into `kalloc.free_list`! This immediately corrupts static BSS kernel memory and scrambles the kernel heap.
  - *Remediation*: Either have filesystems return a file handle struct by value or store the actual heap pointer in `vfs.open_files[i]`, and ensure `fs.closeFn` receives the correct pointer.
- **Location**: `src/fs/vfs.zig:124-146`
  - *Issue*: **Prefix Matching Flaw in `findMount`**
  - *Observation*: If `/mnt/disk` is mounted, a path `/mnt/disk2/file.txt` matches `/mnt/disk` because `path[0..mp.len]` matches, even though it is not a subdirectory.
  - *Remediation*: Require `path.len == mp.len or path[mp.len] == '/'`.
- **Location**: `src/fs/vfs.zig:148, 234`
  - *Observation*: Global mutable buffers `path_resolve_buf` and `rel_path_buf` are used for path manipulation without locks, making path resolution completely non-reentrant.

#### 5.2 `src/fs/fat16.zig`
- **Location**: `src/fs/fat16.zig:583-634`
- **Issue**: **Permanent Handle & Cache Leak in FAT16 Driver**
  - *Observation*:
    1. `fat16Open` sets `open_handle_used[h] = true;`.
    2. `fat16Close` is completely empty:
       ```zig
       fn fat16Close(fs: *vfs.FileSystem, handle: *vfs.FileHandle) void {
           _ = fs;
           _ = handle;
       }
       ```
    3. `open_handle_used[h]` is NEVER set back to false.
    4. Furthermore, each open appends a new entry to `file_cache[idx]` without checking if the file is already cached, and `file_count` is never decremented.
  - *Failure Mode*: After exactly 32 file opens, `fat16Open` fails forever with out-of-handles. After 128 file accesses, `file_cache` exhausts `MAX_FAT16_FILES`, permanently disabling all FAT16 filesystem operations until reboot.
  - *Remediation*: In `fat16Close`, find `handle` in `open_handles` and reset `open_handle_used[h] = false`. Maintain ref counts on cached inodes in `file_cache`.
- **Location**: `src/fs/fat16.zig:642-644`
  - *Issue*: **Integer Underflow in `fat16Read`**
  - *Observation*: `const remaining = fi.file_size - @as(u32, @intCast(handle.offset));`. If `handle.offset > fi.file_size`, integer underflow causes `remaining` to wrap to ~4 GB, triggering an out-of-bounds cluster read or panic in Debug mode.
- **Location**: `src/fs/fat16.zig:692-695`
  - *Issue*: **Hardcoded 4096 Cluster Buffer Limits Volume Support**
  - *Observation*: `var cbuf: [4096]u8 = undefined; if (cs > cbuf.len) return written;`. In FAT16, standard volumes formatted with 16, 32, or 64 sectors per cluster have cluster sizes of 8 KB, 16 KB, or 32 KB. On such disks, `fat16Write` silently aborts and writes 0 bytes.

#### 5.3 `src/drivers/virtio_blk.zig`
- **Location**: `src/drivers/virtio_blk.zig:127-224`
- **Issue**: **Descriptor Ring Desynchronization on I/O Timeout**
  - *Observation*: If polling the used ring exceeds 2,000,000 spins, `doIo` frees the descriptor chain (`freeDescChain(hdr_idx)`) and returns `false`.
  - *Failure Mode*: The device controller may still complete the transfer moments later and write status into `req_data` or advance the used ring index, causing desynchronization of the entire virtqueue and subsequent silent disk corruption.
  - *Remediation*: Issue a device reset on timeout or wait for completion before reclaiming descriptors.

---

### Group 6: Networking

#### 6.1 `src/net/tcp.zig`
- **Location**: `src/net/tcp.zig:56-68, 184, 216, 327, 362`
- **Issue**: **Permanent Socket Slot Exhaustion (Connection Leaks)**
  - *Observation*:
    ```zig
    pub fn allocConnection() ?*Connection {
        for (&connections, 0..) |*c, i| {
            if (c.state == .closed and c.id == -1) { ... return c; }
        }
        return null;
    }
    ```
    However, when a connection transitions to `.closed` via:
    - Normal peer close (line 184: `conn.state = .closed;`)
    - Peer reset (line 216: `conn.state = .closed;`)
    - Retransmission timeout (line 327: `c.state = .closed;`)
    - Route resolution failure (line 362: `conn.state = .closed;`)
    `c.id` is NEVER reset to `-1`! Only `disconnect()` resets `c.id = -1`.
  - *Failure Mode*: Any connection that is reset or timed out without explicit shell disconnect permanently stays with `c.id != -1`. Since `MAX_CONNECTIONS = 4`, after four failed or closed connections, the kernel can NEVER establish another TCP connection!
  - *Remediation*: Reset `conn.id = -1` upon entering `.closed` in all state machine branches.
- **Location**: `src/net/tcp.zig:259-304`
  - *Issue*: **Global Shared `tx_buf` in TCP Transmission**
  - *Observation*: `var tx_buf: [14 + 20 + 20 + MSS]u8 align(16) = undefined;` is a single global buffer. If an ACK packet is constructed during a re-entrant `net.poll()` or from another thread while `sendPacket()` is assembling a frame, the packet content is mangled.

#### 6.2 Hardcoded Driver Calls across Net Subsystems
- **Locations**:
  - `src/net/arp.zig:145, 172`: `e1000.transmit(arp_tx_buf[0..42]);`
  - `src/net/dhcp.zig:260, 283`: `e1000.transmit(dhcp_tx_buf[0..frame_len]);`
  - `src/net/icmp.zig:72, 124`: `e1000.transmit(reply_buf[0..frame_len]);`
  - `src/net/tcp.zig:289, 316`: `e1000.transmit(tx_buf[0..frame_len]);`
  - `src/net/udp.zig:97`: `e1000.transmit(udp_tx_buf[0..frame_len]);`
- **Issue**: **Architecture Violation Breaking Multi-NIC & USB Wi-Fi Support**
  - *Observation*: Despite `net/mod.zig` defining `pub const NicType = enum { none, e1000, rtl8169 };`, all packet-generating protocols bypass `net.sendFrame` and call `e1000.transmit` directly.
  - *Failure Mode*: If the system runs on hardware with an RTL8169 NIC, or when Milestone 4 introduces USB 2.4GHz Wi-Fi network adapters (RTL8188EU / RTL8192CU), none of ARP, DHCP, ICMP, TCP, or UDP can transmit.
  - *Remediation*: Unify all packet transmission through `net.sendFrame(dst_mac, eth_type, payload)` or a `NetDevice` interface.

#### 6.3 `src/drivers/e1000.zig`
- **Location**: `src/drivers/e1000.zig:288-290, 309-311`
- **Issue**: **Synchronous Spin-Wait in Packet Transmission**
  - *Observation*: `transmit()` spins up to 1,000,000 pauses waiting for descriptor status bit DD to be set.
  - *Failure Mode*: CPU cycles are wasted burning in a spin-wait for every single packet transmission instead of queueing descriptors and advancing `tx_cur` asynchronously.

---

## 3. Subsystem Interdependencies & Architectural Risks

```
+-------------------------------------------------------------------------+
|                              Ring 3 User Space                           |
|       (test.zig, heap.zig, shell programs, ELF binaries)                |
+-------------------------------------------------------------------------+
                                    |
                    INT 0x80 / SYSCALL (syscall.zig)
                      [CRITICAL: IF unmasked in FMASK]
                      [CRITICAL: Unchecked user ptrs]
                                    |
+-------------------------------------------------------------------------+
|                           Process & Task Core                           |
|         (scheduler.zig, task.zig, address_space.zig, process.zig)       |
|    - Single TSS across all SMP cores (smp.zig/gdt.zig)                   |
|    - Corrupt huge page cloning & leaking PTs in address_space.zig       |
+-------------------------------------------------------------------------+
             |                              |                |
             v                              v                v
+-----------------------+     +-------------------+   +-------------------+
|   Memory Management   |     |  VFS & Storage    |   |     Networking    |
| (pmm, vmm, kalloc)    |     | (vfs, ramfs, fat) |   | (tcp, ip, arp)    |
| - kalloc non-contig   |     | - vfs kfree on BSS|   | - Hardcoded e1000 |
|   merge corruption    |     | - FAT16 leak hndl |   | - TCP conn slot   |
| - Missing SMP locks   |     | - Buffer races    |   |   exhaustion      |
+-----------------------+     +-------------------+   +-------------------+
             |                              |                |
             +------------------------------+----------------+
                                    |
+-------------------------------------------------------------------------+
|                         Hardware Drivers & Arch                         |
|   (e1000, virtio_blk, pci, apic, timer, idt, isr, pic)                  |
|   - Early STI before PMM/VMM initialization                             |
|   - Ring 3 exceptions panic the kernel                                  |
|   - Missing unified Network Device interface                            |
+-------------------------------------------------------------------------+
```

### Critical Interdependency Chains
1. **Early STI $\rightarrow$ PMM/VMM Not Ready**:
   In `src/system/init.zig:39`, `sti` is executed BEFORE `pmm.init()`, `vmm.init()`, and `kalloc.init()`. Any early hardware interrupt or APIC timer tick attempting dynamic allocation will crash the system.
2. **VFS File Handle $\rightarrow$ Kernel Heap Corruption**:
   `vfs.close` calls `ramfsClose`, which calls `kalloc.kfree` on static BSS memory (`&open_files[i]`). This corrupts `kalloc`'s free-list headers, which subsequently corrupts `kmalloc` across the entire kernel.
3. **USB Subsystem Integration Risk**:
   Incoming USB host controllers (xHCI, EHCI, UHCI) and USB Wi-Fi adapters will rely heavily on:
   - DMA allocations from `pmm.allocPages()` (currently un-synchronized).
   - Interrupt/polling dispatch without clobbering network descriptor buffers.
   - Dynamic packet dispatch in `net/mod.zig` (currently hardcoded to `e1000.transmit`).

---

## 4. Actionable Remediation Strategies for Milestone 1

### Phase 1: Core Architecture & Interrupt Hardening
1. **Fix `IA32_FMASK` in `src/arch/syscall64.zig`**:
   Add bit 9 (IF) to `fmask`:
   ```zig
   const fmask: u64 = (1 << 8) | (1 << 9) | (1 << 10) | (1 << 14) | (1 << 18);
   ```
   Ensure `syscall_entry_64` switches to kernel stack before enabling interrupts with `sti`.
2. **Handle Ring 3 Exceptions Gracefully in `src/arch/isr.zig`**:
   In `isr_handler`, inspect `frame.cs & 3 == 3`:
   ```zig
   if ((frame.cs & 3) == 3) {
       serial.serialWrite("[USER] Process faulted with exception, killing task\n");
       scheduler.tasks[@intCast(scheduler.current_task)].state = .finished;
       scheduler.tasks[@intCast(scheduler.current_task)].exit_code = -11; // SIGSEGV
       // Clean up resources and return to scheduler via sys_exit_return()
   }
   ```
3. **Move `sti` in Boot Sequence**:
   Remove `asm volatile ("sti")` from `system/init.zig`. Enable interrupts in `main.zig` only AFTER `kalloc.init()` and `vfs.init()` have completed.
4. **Per-CPU TSS & GDT for SMP**:
   Allocate dedicated TSS entries in GDT for secondary AP cores so `rsp0` stacks never overlap.

### Phase 2: Memory Manager Hardening
1. **Fix `kalloc.expandHeap` Chunk Discontinuity**:
   Do not link disjoint physical chunks in the same coalescing list. Mark blocks with arena identifiers so `mergeBlocks` never merges across disjoint physical page runs.
2. **Fix `AddressSpace.cloneUserSpace`**:
   Do not deep copy or allocate huge pages in `cloneUserSpace`. Inherit kernel identity mappings by reference. Correct bitmask constants to `0x000FFFFFFFE00000`.
3. **Fix `AddressSpace.isSharedKernelTable`**:
   Compare against the constant boot PML4/PDPT addresses rather than `vmm.getCurrentCr3()`.

### Phase 3: VFS & FAT16 Stability Overhaul
1. **Fix File Handle Lifecycle**:
   Standardize `FileHandle` ownership. In `vfs.open()`, store the pointer returned by `fs.openFn` and do not call `kfree` on static arrays.
2. **Implement Handle Cleanup in `fat16Close`**:
   In `fat16Close`, set `open_handle_used[h] = false;` so handle slots can be reused.
3. **Prevent Slot Exhaustion in `fat16.file_cache`**:
   Check if file is already in `file_cache` before allocating a new slot. Implement reuse of free slots.

### Phase 4: Network Stack Unification
1. **Unify NIC Transmission in `net/mod.zig`**:
   Create `net.sendPacket(dst_mac, eth_type, payload)` and replace all direct calls to `e1000.transmit` in `arp.zig`, `dhcp.zig`, `icmp.zig`, `tcp.zig`, and `udp.zig`.
2. **Fix TCP Connection Slot Leaks in `tcp.zig`**:
   In all state transitions to `.closed` (RST, timeout, final ACK), set `c.id = -1` and `c.retx_active = false`.
3. **Prevent Buffer Overflow in `SYS_RECV`**:
   Implement a FIFO buffer or ring buffer in `Connection` so unread bytes are preserved for subsequent `sys_recv` calls.

---

## 5. Conclusion

The core kernel has established functional basics (boot, basic ring 3 context switch, basic TCP client, FAT16 reading), but contains critical stability hazards (BSS corruption on file close, arbitrary memory write in syscalls, unmasked IF on syscall entry, broken heap coalescence across disjoint chunks, and permanent TCP/FAT16 resource exhaustion). 

Addressing these defects in Milestone 1 will establish a robust, crash-resilient foundation necessary for the USB Host Controller (Milestone 2) and USB Wireless Peripheral (Milestones 3 & 4) implementations.
