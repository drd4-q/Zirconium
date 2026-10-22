# TODO — Zirconium

## Current state
- Kernel boots via Multiboot/GRUB, identity-mapped 2MB pages
- VGA + serial output, keyboard driver (IRQ1), timer (PIT 100Hz), PCI, e1000 NIC, RTL8169 NIC, USB Wi-Fi (RTL8188EU), virtio-blk disk
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
- [x] USB 2.4GHz Wi-Fi adapter support (Realtek RTL8188EU/RTL8192CU, `usb wifi` command)
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
- [ ] xHCI downstream hub/hotplug: root-port `usb-kbd`/`usb-tablet` enumeration and interrupt/bulk paths now work on QEMU; internal USB2 hubs and reconnect events still need full traversal/teardown
- [ ] Real time-of-day clock feeding gettimeofday/clock_gettime/_time64 (currently PIT ticks since boot)
- [ ] Math double-args (sin/pow/...) need XMM state in InterruptFrame before UCRT math can bind

### DynamicalKVM (hypervisor)
- [x] Declarative guest profiles (device set, CPU model, display, RAM) — `src/kvm/profile.zig`
- [x] Auto device selection from what the guest does while probing — `profile.autoSelect()`
- [x] Resource partitioning: cores and RAM per guest, manual or automatic — `src/kvm/resources.zig`
- [x] Core masks: each guest's threads bound to disjoint host CPUs
- [x] Virtual displays and the compositor (host / solo / tile / focus) — `src/system/gfx/{output,display}.zig`
- [x] Shell driver: `vm` (add/rm/layout/focus/policy/budget/dev/guest/view) — `src/programs/kvm.zig`
- [x] The autoload: the machines come up from the configuration, unprompted — `config.machines`, `vm.autoload()`
- [x] The guest kernel loader: ELF into the guest's RAM, with a Multiboot 1 boot information block — `src/vm/loader.zig`
- [x] A built-in sample guest, so a ZVM with an empty disk still has something to load — `samples/guest_kernel.zig`
- [x] The supervisor console: the banner lists the machines, the prompt names the focused one
- [x] Per-machine identity: a different plausible computer for every guest, and a different one on every boot — `src/kvm/identity.zig`
- [x] The hypervisor's own device (ZVP): PCI config space, MMIO registers, shared window, doorbell protocol — `src/kvm/devices/zvp.zig`
- [x] The guest driver, in ring 3, proving the device end to end — `src/user/kvm_test.zig`
- [x] The shared UAPI both sides include — `src/kvm/proto.zig`
- [ ] CPU emulator: the vCPUs are still guest-console renderers
- [ ] The 32-bit Multiboot stub of the sample guest is written but not linked: putting a 32-bit stub and 64-bit code in one image needs the linker's own layout (`samples/guest_stub.S` and `samples/guest_kernel.ld` are ready)
- [ ] Serve the ZVP's PCI configuration space from a real PCI model, so a guest finds it by scanning the bus
- [ ] Map the guest's devices into its address space (the ZVP's BARs) rather than into the driver's
- [ ] Interrupt the guest when the ZVP has something to say, instead of polling it
- [x] Guest memory: each machine gets a block of RAM and builds its own page tables in it
- [x] The MMU: the hypervisor walks the guest's page tables (PML4/PDPT/PD/PT, huge pages) — `src/kvm/mmu.zig`
- [ ] Real device model: the 8259/8254/APIC/IOAPIC/virtio devices the profiles describe
- [ ] Load a real guest kernel and probe it (the auto-selection path needs a guest to observe)

### Driver improvements
- [x] PS/2 mouse driver
- [x] Virtio-blk disk driver (PCI discovery, MMIO, single virtqueue, read/write sectors, blockdev registration)
- [x] USB host controller stack (UHCI 1.1, EHCI 2.0, xHCI 3.0) — `src/drivers/usb/`
- [x] USB HID keyboard/mouse (Boot Protocol, composite wireless dongles)
- [x] USB 2.4GHz Wi-Fi adapter driver (Realtek RTL8188EU/RTL8192CU, 802.11 ↔ 802.3 conversion)
- [x] Shell diagnostic commands (`usb`, `usb wifi`, `lsusb`)
- [ ] AHCI/virtio-blk improvements (multi-queue, interrupt-driven I/O)
- [ ] PCI enumeration improvements

### Shell improvements
- [x] Tab completion (auto-complete from known commands, show matches on ambiguous)
- [x] Command history (up/down arrows, 16 entries circular buffer)
- [x] Environment variables (set KEY=V, unset K, env) with $KEY expansion + echo
- [x] Scrollback buffer (PageUp/PageDown, 512 lines)
- [x] Resolution command (framebuffer; rescales the viewport inside the boot mode)
- [x] `screen [info|redraw|refresh|clear]` (LFB geometry, console repaint, forced full refresh)
- [ ] Runtime video-mode setter (`screen set 1920x1080`) — needs a real VBE path: use the
      VBE 3.0 protected-mode interface from the Multiboot info (offsets 82/84/86, `0xFFFF`
      when absent, see Linux `arch/x86/boot/video/vbe.c`), else a V86 `int 0x10` trampoline.
      Until then the mode only changes via a `grub.cfg` menu entry. This is also the only
      way out of the "GRUB handed us no LFB" trap: under UEFI the VGA text buffer is not
      displayed, so a firmware/GRUB fallback to `text` looks like a black screen.
- [x] 16bpp RGB565 LFB support (GRUB lands on 16bpp when no 32bpp mode exists; without it
      the machine gets no framebuffer at all)
- [x] NX for kernel/RAM pages, and no `PAGE_USER` on the inherited identity map
- [ ] W^X for user segments: with NXE on, ELF/PE data segments are still executable because the
      loaders map every segment with the same flags. Honour `PF_X` (omit `PAGE_NX` only for
      executable segments) now that `entry.S` enables NXE.
- [ ] Per-interrupt kernel stack (IST in the IDT, or an explicit RSP swap in the ISR stubs).
      Preemption can today only rewrite an `InterruptFrame` taken from ring 3, so a tick arriving
      while a syscall holds IF=0 cannot switch tasks and a task in `sleep` keeps the CPU. This
      is also what would make it safe to re-enable interrupts inside a syscall instead of the
      bounded spin in `fdtable.IDLE_SPIN_LIMIT`.
- [ ] Let APs run tasks: the run queue, `current_task` and the tick bookkeeping are BSP-only, and
      `syscall_kernel_rsp` is a single global, so it is wrong the moment a second CPU takes a
      syscall.
- [x] Honor the framebuffer channel layout. `fb_red_first` is derived from the reported
      channel field positions (MBI offset 112) and honoured by `lfbPut`, `lfbGet` and the
      32bpp `flush()` fast path, so a UEFI GOP `RGBA8`/`BLT_ONLY` mode (R@0) no longer
      renders with red and blue swapped.
- [ ] Write-combining MTRR for the LFB (`rdmsr 0xFE`, set `0x200`/`0x201` like GRUB's
      `grub_vbe_enable_mtrr`) — the biggest win for GUI/redraw bandwidth on real hardware.

### Found by the kernel audit, not yet fixed
- [ ] `fork` cannot work as written: `address_space.cloneUserSpace` deep-copies every
      inherited identity map (entry.S maps 64 GB as 2 MB pages), so one `SYS_FORK` asks
      for ~64 GB and always fails with ENOMEM. It must copy the *entries* for the shared
      supervisor huge pages, not their payload. AGENTS.md previously blamed the
      cooperative scheduler — that is not the reason. It also `incRef`s kernel leaves that
      `destroy()` never revisits, so every fork permanently leaks kernel page refs.
- [ ] `uaccess` is called before the task's CR3 is active in `process.setup` /
      `setupWindowsStack`, so the PE TEB/CRT writes land on kernel-visible physical memory
      instead of the task's freshly mapped pages. Needs writes through the target address
      space (as `pe.zig` does) or a switch/restore around init.
- [ ] The user stack (0x7FFE_0000) is mapped through the *shared kernel* PD, and exit
      frees the frames without clearing the PT entries, leaving them user-writable
      through a page table shared with the kernel and every other task.
- [ ] `winapi.dispatch` declares ~60 KB of locals across its switch arms against a 16 KB
      task kernel stack; a Debug build reserves the full sum on every thunk call and
      overflows into the rest of `Task`. Move the large buffers into `noinline` helpers or
      grow `task.KERNEL_SIZE`.
- [ ] The native syscall ABI validates no user pointers or lengths: `SYS_WRITE`/`SYS_SEND`
      hand raw ring-3 pointers and 64-bit counts to the VGA and TCP code. Route them
      through `uaccess` and cap the length.
- [ ] `readUserStr` dereferences an unvalidated user pointer and its `?` return can never
      be null, making the caller's EFAULT branch unreachable.
- [ ] `exec` failure leaks the 128 KB user stack (`setup`'s errdefer never clears
      `user_stack_phys`).
- [ ] xHCI CRCR.CSZ is still 0 and `writeMmio64` still writes low dword first. Linux
      writes high-then-low and reports the ring size; both are needed before real-hardware
      bring-up, and CSZ must be validated against QEMU in the same change.
- [ ] `net/tcp.zig` ACKs a segment even when its payload did not fit in `rx_buf`, so data
      is silently dropped; stop advancing `ack_num` when `copy_len < data_len`.
- [ ] `net/tcp.zig` and `udp.zig` read the source IP at a hard-coded offset that assumes
      IHL = 5; the IP layer accepts IHL up to 15.
- [ ] Lua: no index/call postfix syntax (`t[1]` is a syntax error), multi-target assignment
      silently drops values, and function *expressions* parse then discard their body and
      leak two dupes. Parser recursion (`if a then` repeated) is still unbounded.
- [ ] `fat32.zig` refuses to open a directory because `OpenFlags.directory` is never set
      by any caller, so `vfs.open("subdir")` fails on FAT32 while FAT16 succeeds.
- [ ] `vfs.resolvePath` silently truncates at 255 bytes and returns a slice into one global
      buffer, so an over-long path can resolve to a different existing file and the result
      is invalid across a re-entrant call.
- [ ] `pci_detect.readMmioBar` documents returning 0 for BARs outside the identity map but
      maps them instead, so every caller's guard is dead code.
- [ ] `hid.zig` and `hid_input.zig` keep two near-identical HID usage tables that have
      already diverged, and `dma.zig`'s pools are unused `undefined` instances.
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
- [x] USB driver (xHCI/EHCI/UHCI host controllers, HID, Wi-Fi adapter)
- [x] GUI / window manager (framebuffer desktop, XOR mouse cursor, draggable/focusable windows, `gui` command)
