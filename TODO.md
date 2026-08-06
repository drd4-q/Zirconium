# TODO — Zig Kernel

## Current state
- Kernel boots via Multiboot/GRUB, identity-mapped 2MB pages
- VGA + serial output, keyboard driver (IRQ1), timer (PIT 100Hz), PCI, e1000 NIC
- PMM + VMM (OOM handling fixed), scheduler with kernel + user tasks
- TCP/IP stack (ARP, IP, ICMP, TCP, HTTP), web server on port 8080→80
- Shell with commands: help, clear, calc, clock, ping, get, net, ps, mem, reboot, matrix, fib, lua, user
- GDT with ring 0+3 segments, IDT (256 entries + INT 0x80 DPL3), PIC, TSS
- Syscall interface (INT 0x80): write, read, sleep, time, exit (fork/exec stubs)
- ELF loader, ring 3 context switch via iretq, address spaces per process
- Lua interpreter (lexer, parser, AST, VM, API) — compiled and working
- Keyboard flush support for clean input between programs

## What needs to be done

### Critical — boot stability
- [x] Verify kernel boots past GDT init (latest fix: TssEntry alignment)
- [x] Solve SSE #UD mystery (movups/xorps cause #UD despite CR4.OSFXSR=1)
- [x] Fix sys_exit_return IF flag (sti before ret — keyboard was dead after user exit)
- [x] Fix panic.zig missing CLI before halt
- [x] Fix VMM/address_space nextPageTable OOM (was returning undefined)
- [x] Fix keyboard init command byte (0x47→0x45, was disabling keyboard scan)
- [x] Fix syscall exit code display for values >= 100
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
- [ ] Virtual filesystem (VFS) layer
- [ ] Disk driver (ATA/AHCI or virtio-blk)
- [ ] Filesystem (FAT16/ext2/ramfs)
- [ ] Load programs from disk instead of compiled-in

### Networking improvements
- [ ] DHCP client (currently hardcoded 10.0.2.15)
- [ ] DNS resolver
- [ ] UDP support
- [ ] Socket API for user-space programs

### Memory management
- [ ] User-space heap allocator (malloc/free via syscall)
- [ ] Shared memory between processes
- [ ] Copy-on-write fork

### Process management
- [ ] exec syscall (load and run ELF binary)
- [ ] waitpid / exit with status
- [ ] Signals (SIGTERM, SIGKILL, etc.)
- [ ] Process groups / sessions

### Driver improvements
- [ ] PS/2 mouse driver
- [ ] AHCI/virtio-blk disk driver
- [ ] Virtio-net driver (better than e1000 for QEMU)
- [ ] PCI enumeration improvements

### Shell improvements
- [ ] Tab completion
- [ ] Command history (up/down arrows)
- [ ] Pipes (cmd1 | cmd2)
- [ ] I/O redirection (cmd > file, cmd < file)
- [ ] Environment variables

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
- [ ] GUI / window manager (framebuffer)
