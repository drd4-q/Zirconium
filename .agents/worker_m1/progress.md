# Progress — Milestone 1

Last visited: 2026-09-20T06:17:20Z

## Status
- [x] Initialized workspace and briefing
- [x] 1. SYSCALL IF Masking (`src/arch/syscall64.zig`)
- [x] 2. Heap expansion safety (`src/kernel/kalloc.zig`)
- [x] 3. VFS BSS handle fix (`src/fs/vfs.zig` and `src/fs/ramfs.zig`)
- [x] 4. Ring 3 fault isolation (`src/arch/isr.zig`)
- [x] 5. Per-CPU SMP TSS and kernel stack RSP0 (`src/arch/smp.zig` and `src/arch/gdt.zig`)
- [x] 6. TCP connection slot recycling (`src/net/tcp.zig`)
- [x] 7. FAT16 handle and cache recycling (`src/fs/fat16.zig`)
- [x] 8. Net device abstraction (`src/net/mod.zig`, `arp.zig`, `dhcp.zig`, `icmp.zig`, `tcp.zig`, `udp.zig`)
- [x] Verification (`zig build`, `zig build -Drelease`, `python3 tools/test_runner.py`) — 10/10 markers passed (100% SUCCESS)
- [x] Handoff report & notification
