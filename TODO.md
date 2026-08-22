# TODO — Zirconium

## Current state
- Kernel boots via Multiboot/GRUB, identity-mapped 2MB pages
- VGA + serial output, keyboard driver (IRQ1), timer (PIT 100Hz), PCI, e1000 NIC, virtio-blk disk
- PMM (bitmap page allocator) + VMM (page tables) + kernel heap (kmalloc/kfree/krealloc)
- TCP/IP stack (ARP, IP, ICMP, TCP, HTTP), DNS resolver, UDP, DHCP, ARP cache
- VFS layer + ramfs (ls, cat, touch, mkdir, rm, write, cd, mount)
- Shell with table-driven command dispatch: help, clear, calc, clock, ping, get/wget, dillo (web browser), net, ps, mem, reboot, uptime, matrix, fib, lua, user, exec, save, mouse, set/unset/env, echo ($VAR expansion), dhcp, arpcache, nslookup, resolution, ls, cat, cp, hexdump, touch, mkdir, rm, write, cd, mount, df, mkfs, smp, cpuinfo, usb/lsusb, gui, nano
- GDT with ring 0+3 segments, IDT (256 entries + INT 0x80 DPL3), PIC, TSS
- Syscall interface (INT 0x80): write, read, sleep, time, exit, exec, waitpid, fork (COW), socket/connect/send/recv (70–73)
- ELF loader, ring 3 context switch via iretq, address spaces per process
- Lua interpreter (lexer, parser, AST, VM, API) — compiled and working
- Keyboard flush support for clean input between programs
- PS/2 mouse driver with IRQ12
- Framebuffer support (Multiboot FBFLAG, CP437 bitmap font); **24bpp and 32bpp LFB accepted**, `[FB] ...` serial diagnostics on every boot, gfxpayload text fallback in grub.cfg
- Scrollback buffer (512 lines, VGA text mode + framebuffer)
- Environment variables (`src/system/env.zig`): `set/unset/env`, `$KEY` expansion on the shell command line, exposed to PE programs via GetEnvironmentVariableA/GetEnvironmentStringsW
- Copy-on-write fork (ref-counted pages, page-fault write handler in VMM)
- Socket API for user-space (8 per-task TCP slots; exercised by the embedded ring-3 test binary)
- SMP bring-up (ACPI/MADT + AP trampoline at 0x8000, INIT-SIPI-SIPI; `[SMP] AP CPU 1 online`)
- APIC initialized at boot (IPIs/EOI for SMP; LAPIC timer masked — the PIT alone drives the 100 Hz tick; an unmasked periodic LAPIC timer on the PIT's vector 32 doubled every tick)
- QEMU integration test suite (`tools/test_runner.py`, run via `./run.sh --test`) + headless visual debugging (`tools/boot_watch.py <sec> [disk]`: QMP screendump → `screen.ppm`, full serial → `ser_capture.log`)
- GDB remote debugging stub (`./run.sh --gdb` → `-s -S`, localhost:1234)
- User-space heap allocator (malloc/free in ring 3 via `SYS_BRK`, free-list allocator in `src/user/heap.zig`)
- Foreign binaries (`kernel/binfmt.zig` personalities): static Linux ELF64 enters via the `syscall` instruction (Linux syscall numbers incl. getdents64/chdir/getcwd/sysinfo/fcntl-dup); Win32 PE32+ runs through INT 0x81 thunks (console I/O, files on VFS, heap, env, cmdline, fake TEB via GS_BASE, UCRT subset: startup no-ops, __p__* globals block, stdio over pseudo-FILE*, printf engine incl. `__stdio_common_vfprintf/vsprintf`, WinSock 2 basics). Busybox, uutils coreutils (as `ls`/`cu`), jq.exe/curl.exe load and run; real-app matrix lives in TODO below
- In-kernel FAT16 formatter: blank/unformatted disks are formatted and mounted automatically at boot; `mkfs` reformats on demand, `df` shows usage
- Serial console input: COM1 RX polling drives the shell and program stdin — headless automation via `tools/boot_watch.py <sec> disk cmd:"..."` (QMP screendump → `screen.ppm`, serial → `ser_capture.log`)
- procfs-lite seeding at boot: /etc/os-release, /etc/hostname, /proc/{cpuinfo,meminfo,uptime,loadavg,version}, /sys/class/dmi/id/* from live kernel state; uname reports "Zirconium"
- Kernel heap kalloc fixed: free list is address-sorted and mergeBlocks verifies physical adjacency (previously LIFO inserts + blind merges produced fake huge blocks that corrupted large file buffers)
- ramfs handle ownership fixed: ramfsClose used to kfree() vfs.open_files[] slots (BSS) — every ramfs close corrupted the heap
- xHCI driver skeleton (`src/drivers/xhci.zig`): PCI detect, MMIO cap/operational parse, stop/reset/run, DCBAA+contexts, command/event rings via RTSOFF, doorbells, port power; QEMU devices attach but root-port CCS stays clear — HID bring-up blocked on qemu-xhci port topology (see TODO below)

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
- [x] exec syscall — load and run ELF binary from ramfs path
- [x] waitpid syscall — check finished child tasks
- [x] Shell commands: save (write user binary to ramfs), exec (run from path)
- [x] AddressSpace.destroy() frees user-mapped physical pages (no more leaks)
- [ ] Run Lua as a user-space process (ring 3)

### Filesystem / storage
- [x] Virtual filesystem (VFS) layer
- [x] RAM filesystem (ramfs) with directories /dev, /tmp, /etc
- [x] Shell commands: ls, cat, touch, mkdir, rm, write, cd, mount
- [x] Block device abstraction (blockdev.zig)
- [x] Virtio-blk driver (PCI discovery, MMIO, read/write sectors)
- [x] FAT16 filesystem (auto-mounts virtio-blk at /mnt/disk)
- [x] VFS path resolution (relative paths, CWD, makeRelPath)
- [x] cd/ls fix for /etc, /dev, /tmp
- [x] In-kernel FAT16 formatter (`fat16.format()`) — blank disks auto-format+mount at boot; `mkfs` command reformats on demand
- [x] `cp` file copy and `hexdump` viewer; `df` disk usage via FAT free-cluster scan
- [ ] FAT16 long file names (LFN)
- [ ] File append mode + O_APPEND semantics

### Networking
- [x] DNS resolver (UDP to 10.0.2.3)
- [x] UDP support (basic send/receive for DNS)
- [x] DHCP client (discover/offer/request/ack, auto-configures IP/gateway/DNS)
- [x] ARP cache (32-entry table with TTL, auto-eviction)
- [x] TCP: connection multiplexing (4 concurrent connections)
- [x] TCP: retransmission timer (500ms, exponential backoff, max 10 retries)
- [x] ICMP RTT measurement (ping shows round-trip time in ms)
- [x] Socket API for user-space programs (syscalls 70–73, 8 per-task TCP slots)
- [ ] TCP improvements (window scaling, congestion control)

### Memory management
- [x] Physical page allocator (PMM bitmap, 4KB pages)
- [x] Virtual memory manager (VMM, page tables, mapPage/unmapPage)
- [x] Kernel heap allocator (kmalloc/kfree/krealloc, free-list with coalescing)
- [x] User-space heap allocator (malloc/free via SYS_BRK=12; user-side free-list allocator in `src/user/heap.zig`)
- [ ] Shared memory between processes
- [x] Copy-on-write fork (ref-counted pages, COW write-fault handler in `vmm.handlePageFault`)

### Process management
- [x] Scheduler with kernel + user tasks
- [x] ELF loader
- [x] Address spaces per process
- [x] exec syscall (load and run ELF binary from VFS path)
- [x] waitpid syscall (check for finished children, non-blocking)
- [x] fork syscall (clone task + address space; COW page sharing via `cloneUserSpace`)
- [x] exit with status propagation to parent (SYS_EXIT stores task.exit_code + wakes blocked parent; waitpid returns child PID)
- [ ] Signals (SIGTERM, SIGKILL, etc.)
- [ ] Process groups / sessions
- [ ] Forked children are never scheduled (cooperative runAll/runTask model) — needed before fork+exec actually works

### Foreign binaries
- [x] binfmt dispatch: ELF64 static/static-PIE → `.linux`, PE32+ console → `.windows`
- [x] Linux entry via `syscall`/SYSRET MSRs; separate native vs Linux syscall tables
- [x] Win32 import thunks (`int 0x81`), heap/VirtualAlloc arena, TLS slots, fake TEB via GS_BASE
- [x] Linux ABI: getdents64 (dir FileDesc with path+cursor), chdir/getcwd on real VFS CWD, sysinfo, fcntl F_DUPFD, honest ENOSYS for pipe
- [x] Win32 environment fully wired (GetEnvironmentVariableA / GetEnvironmentStringsW → system/env.zig)
- [x] UCRT subset for real PE binaries: startup no-ops (_initterm/_configure_*_argv/_set_app_type...), __p__* globals via per-task crt_block, __acrt_iob_func + stdio on pseudo-FILE*, printf engine with MSVC va_list (__stdio_common_vfprintf/vsprintf), string/memory/wcs basics, _open/_read/_write/_close on VFS fds, WinSock 2 (WSAStartup/socket/connect/send/recv/htons/inet_addr...)
- [x] Real-app matrix (`tools/fetch_apps.py` → samples/apps → disk.img): busybox ✓, uutils coreutils ✓ (`ls --version`, 14 MB Rust ELF), jq.exe loads+starts (crashes late-CRT — needs more UCRT), curl.exe/rg.exe hit remaining unimplemented imports, fastfetch = glibc-dynamic honestly rejected
- [ ] fork/vfork/clone for the Linux personality (busybox sh needs it — `sh script` hangs at first external command)
- [ ] Second-spawn race: a spawn right after another task's exit occasionally hangs inside file read (REGS show kernel spin, IF=0, rep-movs-sized RCX); single spawns and some sequences work — needs virtio/kalloc trace
- [ ] xHCI HID bring-up: qemu-xhci detected+reset+running, PORTSC reads work (PP/PLS), but usb-kbd/usb-tablet never set CCS on any root port even though QEMU lists them on "Port 1/2" — likely internal USB2/USB3 hub topology of qemu-xhci; next step: enumerate via hub descriptors or test with `-device nec-usb-xhci`
- [ ] Real time-of-day clock feeding gettimeofday/clock_gettime/_time64 (currently PIT ticks since boot)
- [ ] Math double-args (sin/pow/...) need XMM state in InterruptFrame before UCRT math can bind

### Driver improvements
- [x] PS/2 mouse driver
- [x] Virtio-blk disk driver (PCI discovery, MMIO, single virtqueue, read/write sectors, blockdev registration)
- [ ] AHCI/virtio-blk improvements (multi-queue, interrupt-driven I/O)
- [ ] PCI enumeration improvements

### Shell improvements
- [x] Tab completion (auto-complete from known commands, show matches on ambiguous)
- [x] Command history (up/down arrows, 16 entries circular buffer)
- [x] Environment variables (set KEY=V, unset K, env) with $KEY expansion + echo
- [x] Scrollback buffer (PageUp/PageDown, 512 lines)
- [x] Resolution command (framebuffer, change resolution at runtime)
- [ ] Pipes (cmd1 | cmd2)
- [ ] I/O redirection (cmd > file, cmd < file)
- [ ] Serial console input so tests can drive the shell headless

### Build / tooling
- [x] Automated test suite (`tools/test_runner.py`, `./run.sh --test`)
- [ ] CI pipeline
- [x] Stack traces on panic (RBP frame walk in `system/panic.zig`, also wired into `std.panic` in main.zig; numeric addresses, no symbol names yet)
- [x] GDB stub for QEMU debugging (`./run.sh --gdb` → `-s -S` on localhost:1234)

### Nice to have
- [x] SMP (multi-core) support
- [x] APIC timer (initialized for IPIs/EOI; LAPIC timer masked, PIT drives the 100 Hz tick + sleep)
- [x] ACPI support
- [ ] USB driver
- [x] GUI / window manager (framebuffer desktop, XOR mouse cursor, draggable/focusable windows, `gui` command)
