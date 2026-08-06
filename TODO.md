# TODO — Zig Kernel

## Current state
- Kernel boots via Multiboot/GRUB, identity-mapped 2MB pages
- VGA + serial output, keyboard driver (IRQ1), timer (PIT 100Hz), PCI, e1000 NIC
- PMM (bitmap page allocator) + VMM (page tables) + kernel heap (kmalloc/kfree/krealloc)
- TCP/IP stack (ARP, IP, ICMP, TCP, HTTP), DNS resolver, UDP, DHCP, ARP cache
- VFS layer + ramfs (ls, cat, touch, mkdir, rm, write, cd, mount)
- Shell with commands: help, clear, calc, clock, ping, get, net, ps, mem, reboot, matrix, fib, lua, user, mouse, set/unset/env, dhcp, arpcache, nslookup, resolution, ls, cat, touch, mkdir, rm, write, cd, mount
- GDT with ring 0+3 segments, IDT (256 entries + INT 0x80 DPL3), PIC, TSS
- Syscall interface (INT 0x80): write, read, sleep, time, exit (fork/exec stubs)
- ELF loader, ring 3 context switch via iretq, address spaces per process
- Lua interpreter (lexer, parser, AST, VM, API) — compiled and working
- Keyboard flush support for clean input between programs
- PS/2 mouse driver with IRQ12
- Framebuffer support (Multiboot FBFLAG, CP437 bitmap font)
- Scrollback buffer (512 lines, VGA text mode + framebuffer)
- Environment variables (set/unset/env)

## What needs to be done

### Critical — boot stability
- [x] Verify kernel boots past GDT init (latest fix: TssEntry alignment)
- [x] Solve SSE #UD mystery (movups/xorps cause #UD despite CR4.OSFXSR=1)
- [x] Fix sys_exit_return IF flag (sti before ret — keyboard was dead after user exit)
- [x] Fix panic.zig missing CLI before halt
- [x] Fix VMM/address_space nextPageTable OOM (was returning undefined)
- [x] Fix keyboard init command byte (0x47→0x45, was disabling keyboard scan)
- [x] Fix syscall exit code display for values >= 100
- [x] Fix matrix command (init arrays, add timer.sleep between frames, u16 bounds)
- [ ] Test all shell commands after stable boot

### Lua integration
- [x] Uncomment lua import in shell.zig
- [x] Add `lua` command back to shell dispatcher
- [x] Fix compilation issues with Lua code on Zig 0.16
- [x] Fix FixedBufferAllocator use-after-free (was on stack of initLua)
- [x] Fix Lua exit command (keyboard ring buffer flush)
- [x] Fix Lua prompt display after each command
- [ ] Test Lua REPL in kernel — user testing in progress

### User-space (ring 3)
- [x] ELF loader — load user binaries into address space
- [x] Test ring 3 context switch (jumpToUser with iretq)
- [x] Test syscalls from user-space (INT 0x80) — write, sleep, exit confirmed working
- [ ] Run Lua as a user-space process (ring 3)

### Filesystem / storage
- [x] Virtual filesystem (VFS) layer
- [x] RAM filesystem (ramfs) with directories /dev, /tmp, /etc
- [x] Shell commands: ls, cat, touch, mkdir, rm, write, cd, mount
- [ ] Disk driver (ATA/AHCI or virtio-blk)
- [ ] Persistent filesystem (FAT16/ext2)
- [ ] Load programs from disk instead of compiled-in

### Networking
- [x] DNS resolver (UDP to 10.0.2.3)
- [x] UDP support (basic send/receive for DNS)
- [x] DHCP client (discover/offer/request/ack, auto-configures IP/gateway/DNS)
- [x] ARP cache (32-entry table with TTL, auto-eviction)
- [ ] Socket API for user-space programs
- [ ] TCP improvements (retransmission, window scaling, congestion control)
- [ ] ICMP RTT measurement
- [ ] UDP socket abstraction

### Memory management
- [x] Physical page allocator (PMM bitmap, 4KB pages)
- [x] Virtual memory manager (VMM, page tables, mapPage/unmapPage)
- [x] Kernel heap allocator (kmalloc/kfree/krealloc, free-list with coalescing)
- [ ] User-space heap allocator (malloc/free via syscall)
- [ ] Shared memory between processes
- [ ] Copy-on-write fork

### Process management
- [x] Scheduler with kernel + user tasks
- [x] ELF loader
- [x] Address spaces per process
- [ ] exec syscall (load and run ELF binary)
- [ ] waitpid / exit with status
- [ ] Signals (SIGTERM, SIGKILL, etc.)
- [ ] Process groups / sessions

### Driver improvements
- [x] PS/2 mouse driver
- [ ] AHCI/virtio-blk disk driver
- [ ] Virtio-net driver (better than e1000 for QEMU)
- [ ] PCI enumeration improvements

### Shell improvements
- [x] Tab completion (auto-complete from known commands, show matches on ambiguous)
- [x] Command history (up/down arrows, 16 entries circular buffer)
- [x] Environment variables (set KEY=V, unset K, env)
- [x] Scrollback buffer (PageUp/PageDown, 512 lines)
- [x] Resolution command (framebuffer, change resolution at runtime)
- [ ] Pipes (cmd1 | cmd2)
- [ ] I/O redirection (cmd > file, cmd < file)

### Build / tooling
- [ ] Automated test suite
- [ ] CI pipeline
- [ ] Debug symbols / stack traces on panic
- [ ] GDB stub for QEMU debugging

### Nice to have
- [ ] SMP (multi-core) support
- [ ] APIC timer (replace PIT)
- [ ] ACPI support
- [ ] USB driver
- [ ] GUI / window manager (framebuffer console with mouse cursor)
