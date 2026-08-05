# TODO — Zig Kernel

## Current state
- Kernel boots via Multiboot/GRUB, identity-mapped 2MB pages
- VGA + serial output, keyboard driver, timer (PIT), PCI, e1000 NIC
- PMM + VMM, scheduler with kernel tasks
- TCP/IP stack (ARP, IP, ICMP, TCP, HTTP), web server on port 8080→80
- Shell with commands: help, clear, echo, calc, clock, ping, web, ps, mem, reboot
- GDT with ring 0+3 segments, IDT (256 entries), PIC, TSS
- Syscall interface (INT 0x80): write, read, sleep, time, exit
- Context switch infrastructure (address space, task, scheduler)
- Lua interpreter (lexer, parser, AST, VM, API) — files exist but NOT compiled in

## What needs to be done

### Critical — boot stability
- [ ] Verify kernel boots past GDT init (latest fix: TssEntry alignment)
- [ ] Solve SSE #UD mystery (movups/xorps cause #UD despite CR4.OSFXSR=1)
- [ ] Test all shell commands after stable boot

### Lua integration
- [ ] Uncomment lua import in shell.zig
- [ ] Add `lua` command back to shell dispatcher
- [ ] Test Lua REPL in kernel
- [ ] Fix any compilation issues with Lua code on Zig 0.16

### User-space (ring 3)
- [ ] ELF loader — load user binaries into address space
- [ ] Test ring 3 context switch (jumpToUser with iretq)
- [ ] Test syscalls from user-space (INT 0x80)
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
