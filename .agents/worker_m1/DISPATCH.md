# Dispatch: Milestone 1 — Core Kernel Stability Overhaul & Network Device Abstraction

## 2026-09-20T06:08:00Z

You are Worker 1 (`worker_m1`) for Milestone 1 of the Zirconium project.
Your working directory is `/home/dr4d/Zirconium/.agents/worker_m1`.
The project root is `/home/dr4d/Zirconium`.

CRITICAL INSTRUCTIONS:
1. You MUST read `/home/dr4d/Zirconium/.agents/ORIGINAL_REQUEST.md` before doing anything else.
2. Read `/home/dr4d/Zirconium/.agents/PROJECT.md`, `/home/dr4d/Zirconium/AGENTS.md`, `/home/dr4d/Zirconium/.agents/explorer_survey_1/survey_report.md`, and `/home/dr4d/Zirconium/.agents/explorer_survey_1/handoff.md`.

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

EXCLUSIVE WRITE OWNERSHIP:
You have exclusive write ownership of the following files:
- `src/arch/syscall64.zig`
- `src/kernel/kalloc.zig`
- `src/fs/vfs.zig`
- `src/fs/ramfs.zig`
- `src/arch/isr.zig`
- `src/arch/smp.zig`
- `src/arch/gdt.zig`
- `src/net/tcp.zig`
- `src/fs/fat16.zig`
- `src/net/mod.zig`
- `src/net/arp.zig`
- `src/net/dhcp.zig`
- `src/net/icmp.zig`
- `src/net/udp.zig`

OBJECTIVE & REQUIRED FIXES:
Implement the core stability and correctness fixes identified during the comprehensive audit:
1. **SYSCALL IF Masking (`src/arch/syscall64.zig`)**: In `init()`, mask IF (bit 9, 0x200) in `fmask` MSR `IA32_FMASK` so interrupts are disabled on entry before the stack is switched to kernel `rsp`.
2. **Kernel Heap Expansion Safety (`src/kernel/kalloc.zig`)**: In `expandHeap()` and `mergeBlocks()`, ensure that non-contiguous physical pages allocated by `pmm.allocPages()` are NOT coalesced across address gaps. Track address continuity explicitly.
3. **VFS BSS Deallocation Fix (`src/fs/vfs.zig` & `src/fs/ramfs.zig`)**: In `vfs.close()`, ensure that `ramfsClose()` does not attempt to `kfree()` the static global BSS array `open_files[i]`. Only free dynamic heap-allocated file handle structures.
4. **Ring 3 Fault Isolation (`src/arch/isr.zig`)**: In `isr_handler`, check the privilege level in `frame.cs & 3`. If a fault/exception (< 32, such as #GP, #PF, #DE) originates from user space (CPL == 3), do NOT call `kernelPanic()`; instead, log the fault, terminate the task (e.g. via `scheduler.exitTask()` or marking it finished), and restore execution to the scheduler.
5. **Per-CPU SMP TSS Setup (`src/arch/smp.zig` & `src/arch/gdt.zig`)**: Provide per-CPU TSS instances and per-CPU `RSP0` stacks so AP cores do not share a single TSS or collide on kernel stack pointers during ring 3 transitions.
6. **TCP Connection Recycling (`src/net/tcp.zig`)**: Ensure that when a TCP connection is closed, resets, or times out, its slot is properly recycled by setting `c.id = -1` and freeing buffers so slots are not permanently leaked.
7. **FAT16 Handle Recycling (`src/fs/fat16.zig`)**: Ensure `fat16Close()` clears `open_handle_used[h]` and frees/recycles directory cache entries.
8. **Network Device Abstraction (`src/net/mod.zig` and protocol files)**: Implement `net.sendFrame(packet: []const u8)` and route protocol packet transmissions from `arp.zig`, `dhcp.zig`, `icmp.zig`, `tcp.zig`, and `udp.zig` through `net.sendFrame()` instead of calling `e1000.transmit()` directly.

VERIFICATION REQUIREMENTS:
After implementing all fixes:
1. Run `zig build` (Debug mode). Ensure it compiles cleanly with 0 errors.
2. Run `zig build -Drelease` (ReleaseFast mode). Ensure it compiles cleanly with 0 errors.
3. Run `python3 tools/test_runner.py`. Ensure 100% of the 10 test markers pass.
4. Document all changes and verification outputs in `/home/dr4d/Zirconium/.agents/worker_m1/handoff.md`.
5. Send a completion message via `send_message` to your parent.
