# Handoff Report — Core Kernel Subsystems Audit & Stability Survey

**Agent**: Explorer 1 (`explorer_survey_1`)  
**Date**: 2026-09-20  
**Status**: Hard Handoff (Task Complete)  
**Report Artifact**: `/home/dr4d/Zirconium/.agents/explorer_survey_1/survey_report.md`  

---

## 1. Observation

Direct observations from codebase inspection and execution of the test runner (`python3 tools/test_runner.py`):

1. **Unmasked IF on SYSCALL Entry**:
   - File: `src/arch/syscall64.zig:31-32`
     ```zig
     const fmask: u64 = (1 << 8) | (1 << 10) | (1 << 14) | (1 << 18); // TF, DF, NT, AC
     msr.write(msr.IA32_FMASK, fmask);
     ```
   - File: `src/arch/isr.S:230-234`
     ```asm
     syscall_entry_64:
         cld
         movq %rsp, syscall_user_rsp(%rip)
         movq syscall_kernel_rsp(%rip), %rsp
     ```
   Bit 9 (IF, 0x200) is omitted from `FMASK`. The CPU enters CPL 0 with interrupts enabled while `%rsp` is still the user stack.

2. **Heap Corruption across Disjoint Expansion**:
   - File: `src/kernel/kalloc.zig:219-227`
     ```zig
     last.next = new_block;
     new_block.prev = last;
     ```
   - File: `src/kernel/kalloc.zig:173-174, 184-185`
     ```zig
     block.size += @sizeOf(BlockHeader) + next.size;
     block.next = next.next;
     ```
     `new_block` from non-contiguous `pmm.allocPages` is linked to `last`. When merged, sizes are added without validating address continuity.

3. **Static Memory Freed in VFS**:
   - File: `src/fs/ramfs.zig:136, 203`
     ```zig
     const handle = kalloc.kmalloc(@sizeOf(vfs.FileHandle)) orelse return null;
     ...
     fn ramfsClose(fs: *vfs.FileSystem, handle: *vfs.FileHandle) void {
         kalloc.kfree(@ptrFromInt(@intFromPtr(handle)));
     }
     ```
   - File: `src/fs/vfs.zig:266-268, 278`
     ```zig
     open_files[i] = handle.*;
     file_used[i] = true;
     return &open_files[i];
     ...
     handle.fs.closeFn(handle.fs, handle);
     ```
     `open_files[i]` is a static global array in BSS. `vfs.close()` passes `&open_files[i]` to `ramfsClose()`, which calls `kfree()` on a static BSS address.

4. **Ring 3 Exceptions Halt Kernel**:
   - File: `src/arch/isr.zig:84-137`
     For any exception < 32 (other than handled COW in int 14):
     ```zig
     vga.write("\n=== KERNEL PANIC ===\n");
     ...
     while (true) asm volatile ("cli; hlt");
     ```
     `frame.cs` privilege level is not checked. A user-space segfault or divide-by-zero halts the kernel.

5. **Shared TSS across SMP Cores**:
   - File: `src/arch/smp.zig:108-111`
     ```zig
     fillDescBytes(&gdt_desc, gdt.gdtLimit(), @intFromPtr(gdt.gdtAddr()));
     writeBytesCell(CELL_GDT_DESC, gdt_desc);
     ```
   - File: `src/arch/gdt.zig:50, 96`
     ```zig
     pub var tss: Tss align(16) = undefined;
     tss.rsp0 = stack_top;
     ```
     All AP cores load the same GDT descriptor pointing to the same single `tss` instance.

6. **Permanent Resource Exhaustion in TCP & FAT16**:
   - File: `src/net/tcp.zig:58, 184, 216, 327, 362`
     `allocConnection()` requires `c.state == .closed and c.id == -1`. State transitions to `.closed` on RST, timeout, or peer close do not set `c.id = -1`, leaking the slot permanently.
   - File: `src/fs/fat16.zig:586-634`
     `fat16Close()` is a no-op; `open_handle_used[h]` is never cleared, and `file_cache` slots are never reused, exhausting all 32 open handles and 128 cache slots.

7. **Direct Driver Calls Bypassing NIC Abstraction**:
   - File: `src/net/arp.zig:145, 172`
   - File: `src/net/dhcp.zig:260, 283`
   - File: `src/net/icmp.zig:72, 124`
   - File: `src/net/tcp.zig:289, 316`
   - File: `src/net/udp.zig:97`
     All call `e1000.transmit()` directly.

8. **Current Build & Test Suite Verification**:
   - Tool execution: `python3 tools/test_runner.py`
   - Result: 10/10 markers passed (code 0).
   - Tool execution: `zig build` (Debug)
   - Result: Clean build (code 0).

---

## 2. Logic Chain

1. **SYSCALL Vulnerability**:
   - From Observation 1: `fmask` lacks bit 9 (`IF`). Therefore, `syscall` maintains interrupts enabled upon entering Ring 0.
   - Observation 1 also shows `syscall_entry_64` runs several instructions before `%rsp` is switched to the kernel stack.
   - An interrupt firing in this window forces the CPU (already in CPL 0) to push an `InterruptFrame` onto the existing user `%rsp`.
   - Inferences: Ring 3 can manipulate `%rsp` to corrupt kernel memory or trigger unrecoverable double faults.

2. **Heap Memory Corruption**:
   - From Observation 2: `kalloc.expandHeap` appends non-contiguous physical pages to `free_list`.
   - From Observation 2: `mergeBlocks` merges adjacent items in `free_list` simply by adding sizes: `block.size += @sizeOf(BlockHeader) + next.size`.
   - Inferences: If chunk A (e.g. at 0x1000000) and chunk B (e.g. at 0x2000000) are merged, the merged block claims to span the gap between them. Allocations inside this block will write to unmapped or unrelated physical memory.

3. **VFS Crash via BSS Corruption**:
   - From Observation 3: `vfs.open()` receives a heap-allocated pointer from `ramfsOpen()`, copies it into static `open_files[i]`, and returns `&open_files[i]`.
   - From Observation 3: `vfs.close()` passes `&open_files[i]` to `ramfsClose()`, which executes `kalloc.kfree(&open_files[i])`.
   - Inferences: `kfree` assumes any address passed to it is preceded by a 32-byte `BlockHeader`. It decrements 32 bytes in BSS, alters bytes in adjacent global variables, and corrupts the free list.

4. **Multi-Core Stack Corruption**:
   - From Observation 5: All AP cores share the single GDT and single `Tss` descriptor.
   - On x86_64, interrupts and syscalls from Ring 3 load `RSP0` from the active TSS.
   - Inferences: Multiple cores handling interrupts or Ring 3 syscalls concurrently will write to the same kernel stack simultaneously.

5. **Multi-NIC & Wireless Blockage**:
   - From Observation 7: Higher-level network layers call `e1000.transmit()` directly.
   - Inferences: Any other network controller (such as the existing RTL8169 or upcoming USB 2.4GHz Wi-Fi adapters) cannot transmit packets without refactoring these modules to use `net.sendFrame()`.

---

## 3. Caveats

- **Network Slirp Behavior**: In the current automated test, `connect()` receives an RST because nothing is listening on host port 80 in QEMU slirp; the test passes only because `test.zig` ignores the return value of `connect()`.
- **Preemption**: The scheduler is verified to be purely cooperative/run-to-completion. Implementing true preemptive multitasking requires careful interrupt stack management.
- **Hardware vs QEMU**: Physical hardware may exhibit different timing and PCI BAR allocations than QEMU.
- No source code was modified during this survey, per read-only explorer instructions.

---

## 4. Conclusion

The core kernel subsystems require a systematic stability overhaul in Milestone 1 before the USB and wireless networking layers can be integrated safely:
1. **Critical Security & Crash Fixes**: Mask IF in `IA32_FMASK`, isolate user-space exceptions so they terminate the task instead of panicking the kernel, and eliminate `kfree` on static BSS in VFS.
2. **Memory Hardening**: Prevent coalescing across disjoint heap expansion chunks in `kalloc`, and validate user pointers in `syscall.zig`.
3. **Resource Leak Cleanup**: Fix connection recycling in `tcp.zig` and handle/cache reclamation in `fat16.zig`.
4. **Network Device Abstraction**: Reroute all protocol transmissions through `net.sendFrame` to prepare for USB Wi-Fi adapter support.

---

## 5. Verification Method

To independently verify the observations and baseline:
1. **Run Automated Integration Suite**:
   ```bash
   python3 tools/test_runner.py
   ```
   Assert 10/10 test markers pass.
2. **Compile Debug Kernel**:
   ```bash
   zig build
   ```
   Assert clean compilation without errors.
3. **Compile ReleaseFast Kernel**:
   ```bash
   zig build -Drelease
   ```
   Assert clean compilation.
4. **Codebase Inspection**:
   - Inspect `src/arch/syscall64.zig:31` to verify unmasked IF in FMASK.
   - Inspect `src/fs/vfs.zig:266, 278` and `src/fs/ramfs.zig:203` to verify `kfree` on static `open_files`.
   - Inspect `src/kernel/kalloc.zig:219-227` to verify disjoint chunk linking.
   - Inspect `src/net/tcp.zig:184, 216, 327` to verify `conn.id` is not reset on close.
