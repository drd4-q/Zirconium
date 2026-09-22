## 2026-09-20T05:59:46Z

You are Explorer 1 for the Survey phase of the Zirconium project.
Your working directory is `/home/dr4d/Zirconium/.agents/explorer_survey_1`.
The project root is `/home/dr4d/Zirconium`.

CRITICAL INSTRUCTIONS:
1. You MUST read `/home/dr4d/Zirconium/.agents/ORIGINAL_REQUEST.md` before doing anything else.
2. Read `/home/dr4d/Zirconium/AGENTS.md` and `/home/dr4d/Zirconium/TODO.md`.
3. Investigate the core kernel subsystems for correctness, stability, memory leaks, synchronization, and edge cases:
   - Memory Management: `src/kernel/pmm.zig`, `src/kernel/vmm.zig`, `src/kernel/kalloc.zig`, `src/kernel/address_space.zig`
   - Concurrency, SMP & Scheduling: `src/kernel/scheduler.zig`, `src/kernel/task.zig`, `src/arch/smp.zig`, `src/arch/acpi.zig`, `src/drivers/apic.zig`, `src/drivers/timer.zig`
   - Interrupts & Architecture: `src/arch/idt.zig`, `src/arch/isr.zig`, `src/arch/isr.S`, `src/arch/pic.zig`, `src/arch/gdt.zig`
   - Syscalls & Ring 3: `src/kernel/syscall.zig`, `src/user/test.zig`, `src/user/heap.zig`
   - VFS & Filesystem: `src/fs/vfs.zig`, `src/fs/ramfs.zig`, `src/fs/fat16.zig`, `src/fs/blockdev.zig`, `src/drivers/virtio_blk.zig`
   - Networking: `src/net/mod.zig`, `src/net/tcp.zig`, `src/net/ip.zig`, `src/net/arp.zig`, `src/net/udp.zig`, `src/net/dhcp.zig`, `src/drivers/e1000.zig`
4. Catalog all identified bugs, edge cases, potential panics, race conditions, and unhandled errors.
5. Provide actionable remediation strategies and identify subsystem interdependencies.
6. Write your comprehensive report to `/home/dr4d/Zirconium/.agents/explorer_survey_1/survey_report.md`.
7. Write your handoff report to `/home/dr4d/Zirconium/.agents/explorer_survey_1/handoff.md`.
8. Send a message to your parent using `send_message` with a summary of findings and the path to your handoff report.
Remember: You are read-only. Do not modify kernel source code.
