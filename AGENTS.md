# AGENTS.md — Zirconium

Bare-metal x86_64 OS kernel in Zig. Multiboot/GRUB boot, identity-mapped 2MB pages, SMP via ACPI + AP trampoline, VGA-text shell with programs, custom TCP/IP stack over e1000, ring 3 user-space with INT 0x80 syscalls, VFS with ramfs + FAT16 over virtio-blk, framebuffer GUI, and a minimal Lua interpreter. Runs in QEMU only.

## Build & run

```bash
zig build            # Debug kernel (safety checks on) → zig-out/bin/kernel
zig build -Drelease  # ReleaseFast — what run.sh and the tests ship
./run.sh             # build -Drelease → grub-mkrescue ISO → QEMU (gtk)
./run.sh --vnc       # VNC on host port 5901 instead of gtk
./run.sh --gdb       # QEMU -s -S; attach gdb to localhost:1234
./run.sh --test      # = python3 tools/test_runner.py (the only automated check)
run.bat              # Windows equivalent of run.sh
```

- **Zig 0.16.0 required.** `build.zig.zon` says `minimum_zig_version = "0.14.0"` — stale. `tools/bin2zig.zig` uses 0.16-only std APIs (`std.process.Init`, `std.Io.Dir`, `std.Options.debug_io`).
- `zig build` exposes only `install` (default) and `build` steps. There is **no `zig build test`** and no unit tests anywhere; verification is the QEMU harness.
- `-Drelease` is required for ReleaseFast: `standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast })` only honors the preference when the flag is passed. Full clean build ≈8 s, so always build before claiming anything.
- Release enables `--gc-sections`, so `linker.ld` must keep `KEEP(*(.multiboot))` for `src/entry.S`'s header. Break it and Debug still boots while release fails in GRUB with "no multiboot header found".
- **Toolchain:** `grub-mkrescue`, `qemu-system-x86_64`, `python3`, and GNU `as`+`ld` — the latter two **only** for `src/arch/trampoline.S` (`as --64` → `ld -Ttext=0x8000 --oformat=binary`, run as system commands from `build.zig`). `src/entry.S` and `src/arch/isr.S` go through Zig's own assembler via `addAssemblyFile`. Kernel requires `use_llvm = true`.
- Stale helpers: `qemu.sh`, `qemu.bat`, `qemu_vnc.sh`, `qemu_vnc.bat` predate SMP/disk support (128 MB, no `-smp`, no virtio-blk). Use `run.sh`. `create_disk.sh` builds a richer `disk.img` via mtools (`mformat`/`mcopy`, with `/hello.txt`, `/test/data.txt`); `run.sh` only does `dd` + `mkfs.fat -F 16`.

## Testing

`tools/test_runner.py`: builds `zig build -Drelease`, gets the kernel into `kernel.iso`, boots QEMU headless (`-nographic -monitor none -smp 4 -m 512M`, serial → `serial_test.log`), **polls the log for the terminal marker `[USER-HEAP] free + reuse OK`** with a 90 s deadline (not a fixed sleep), kills QEMU, then asserts the exact marker list in `tools/test_runner.py:155`:

`[BOOT] Kernel loaded`, `[BOOT] System init done`, `[MEM] Physical memory manager initialized`, `[APIC] Local APIC timer initialized`, `[SMP] AP CPU 1 online`, `[USER] Hello from Ring 3 (user space)!`, `[USER-NET] Created socket via sys_socket`, `[USER-NET] Connected to 10.0.2.2:80 via sys_connect`, `[USER-HEAP] malloc(64)+malloc(128) via SYS_BRK OK`, `[USER-HEAP] free + reuse OK`.

Notes:
- Run it after any change touching the boot path, SMP bring-up, syscalls, ring 3, or the TCP client path. It cannot test the shell, GUI, or FAT16 (no framebuffer under `-nographic`, no input driven).
- Markers are matched as raw substrings — renaming a log string silently breaks the suite.
- ISO handling: patches the new kernel in place into an existing `kernel.iso` **only if it fits the old ISO slot**, else rebuilds with `grub-mkrescue`. Falls back to `-kernel zig-out/bin/kernel` only when there is no ISO. `tools/patch_iso.py` is the standalone version of the same patcher (used by `run.bat` when grub-mkrescue is missing).
- Crash triage: QEMU runs `-d int,cpu_reset -D qemu.log` — read `qemu.log` after a triple fault. Under `run.sh` the kernel debug log goes to the terminal (`-serial stdio`); only the harness writes `serial_test.log`.

## Codegen (two embedded blobs)

`build.zig` runs the host tool `tools/bin2zig.zig` twice to turn binaries into Zig byte arrays injected as anonymous modules:
- `user_test_bin` ← `src/user/test.zig` built as a freestanding ELF, `image_base = 0x2000000`, entry `_start`. `kernel/init.zig` registers it with `scheduler.addElfUserTask`, so it runs in ring 3 **before the shell on every boot** and exercises write/socket/connect/send/recv/brk. The shell `user` command loads it on demand.
- `ap_tramp_bin` ← `src/arch/trampoline.S` linked flat at 0x8000.

Editing either source re-runs codegen on the next `zig build`; no manual step.

## Architecture

**Boot:** `src/entry.S` (32-bit multiboot entry → zero 6 page tables → identity map 4 GB with 4 PDs × 512 × 2 MB pages → long mode) → `kernel_entry` (`src/main.zig:40`): serial → GDT (ring 3 segments + TSS) → `vga.initFb(mbi_ptr)` → `system_init` (PIC, IDT) → PMM → VMM → kalloc → VFS + ramfs mount → `kernel_init.init()` (timer, scheduler, task registration) → `pci.scan()` + e1000 + `net/mod.zig.init()` → `smp.init()` → `scheduler.runAll()` → `shell.run()`. **virtio-blk and FAT16 init happen in `shell.zig:run`, not during boot**, and `pci.scan()` runs twice as a result.

**Layout:**
- `src/arch/` — gdt, idt (256 entries + INT 0x80 DPL3 gate), pic, port, isr (`isr.S` + `isr.zig`), acpi (MADT scan), smp + trampoline.S
- `src/kernel/` — pmm, vmm (incl. COW fault resolution), kalloc, scheduler, task, address_space, elf, syscall, init
- `src/system/` — serial, vga, framebuffer, gui, init, panic
- `src/drivers/` — keyboard, timer (PIT 100 Hz on IRQ0), apic, pci, e1000, mouse, virtio_blk
- `src/net/` — arp, arp_cache, ip, icmp, tcp, udp, dns, dhcp, http; `mod.zig` is the public surface
- `src/fs/` — vfs, ramfs (mounted at `/`), blockdev, fat16 (mounted at `/mnt/disk`)
- `src/programs/` — one file per shell command, dispatched from `src/shell.zig:execute`
- `src/lua/` — lexer, parser → AST, tree-walking VM; `mod.zig` re-exports

**Root module pattern:** `src/main.zig` is the root and re-exports `serial`, `vga`, `scheduler`, `pmm`, `vmm`, `kalloc`. ~45 files reach them via `const root = @import("root"); const vga = root.vga;` rather than relative imports. Follow that in new files.

**Scheduler is not preemptive:** `scheduler.runAll()` runs each registered task to completion in order (kernel tasks called directly, user tasks via `jumpToUser`), then returns and the shell starts. `TIME_SLICE` is assigned to tasks but never enforced.

**LAPIC timer is intentionally masked** (`src/drivers/apic.zig:83`) — the PIT is the single 100 Hz tick source. An unmasked periodic LAPIC timer on the same vector 32 double-counted every tick and made `sleep()`/`time()`/TCP timeouts run 2× fast. The `[APIC] Local APIC timer initialized` test marker is printed anyway; don't read it as "LAPIC timer ticking".

**SMP:** `smp.init()` parses ACPI/MADT for LAPIC IDs, then INIT-SIPI-SIPI. SIPI delivery mode lives in ICR bits 10:8 (`(6 << 8) | (0x8000 >> 12)`, **not** the `0x6000` form). The trampoline is copied to 0x8000 with fixed control cells at 0x600 (GDT desc), 0x610 (IDT desc), 0x700 (PML4), 0x708 (stack top), 0x710 (index), 0x718 (entry). Each AP gets a 16 KB stack and idle-loops in `ap_entry`. A wrong cell layout or ICR encoding makes APs silently never come online — the only signal is the missing `[SMP] AP CPU 1 online`. Shell: `smp`, `cpuinfo`.

## User-space (ring 3)

- **GDT selectors** (`src/arch/gdt.zig`): 0x08 kernel code, 0x10 kernel data, `0x18|3` user code, `0x20|3` user data, 0x40 TSS; 0x28/0x30 are unused duplicate kernel segments.
- **Syscalls:** INT 0x80, `rax` = number, args in `rdi`/`rsi`/`rdx`. Numbers in `src/kernel/syscall.zig:15`. Implemented: write=1 (fd 1–2 → VGA, 3 → serial), read=2 (fd 0 → keyboard), sleep=10, time=11, brk=12, fork=57 (COW clone), exec=59 (ELF from a VFS path), exit=60, waitpid=61, socket/connect/send/recv=70–73. `SYS_OPEN=3` and `SYS_CLOSE=4` exist in the enum but fall through the `else` arm to ENOSYS (-38).
- Per-task state: 8 TCP socket slots (`src/kernel/task.zig:57`), user heap at `USER_HEAP_BASE = 0x04000000` grown page-wise by `brk`. `src/user/heap.zig` is the ring-3 free-list malloc built on `brk`.
- **Address spaces** (`src/kernel/address_space.zig`): per-task PML4, create/destroy/switch, user pages mapped `PAGE_USER`; `destroy()` frees user physical pages.

## Gotchas

- **Disk/FAT16:** `run.sh` creates a 64 MB FAT16 `disk.img` if missing; `virtio_blk.init()` + `fat16.init()` auto-mount it at `/mnt/disk` at shell start. Without a block device the `ls/cat/cd/touch/mkdir/rm/write/save` commands hit ramfs at `/` and FAT16 logs `[FAT16] No block device found`.
- **Network is client-only:** static IP 10.0.2.15/24, gateway 10.0.2.2, DNS 10.0.2.3 (`dhcp` overwrites all three from a lease). Real routing is in place — `net.nextHopMac()` picks the destination MAC (on-link host vs. gateway) and drops the packet when ARP fails, so `get`/`wget` reach the internet through QEMU's slirp, not just the host. Nothing listens on guest:80, so `run.sh`'s "open http://localhost:8080" hostfwd message is misleading.
- **The stack polls, it does not use IRQs.** e1000 interrupts are masked on purpose; `net.poll()` drains the RX ring and is called from the blocking loops (`ensureArp`, `waitEstablished`, `dns.resolve`, `http`, `sys_recv`). `net.tick()` (ARP cache aging + TCP retransmit) runs from `scheduler.scheduleTick` once a second. `poll()` has a re-entrancy guard because handlers transmit and transmitting can ARP; inside a handler `nextHopMac` only fires the request and returns null instead of waiting.
- **e1000 register bits are easy to get wrong** — RCTL bit 15 is BAM (broadcast accept, required for DHCP OFFERs), bit 3 is UPE (not BAM), bit 6 is loopback (not BSIZE). BSIZE=2048 is the default (bits 17:16 = 00, BSEX clear). TX descriptors need the RS bit (0x08) for the DD status bit to ever be set, and RDT must be written with the index just recycled, not the next one. Named constants for these live at the top of `src/drivers/e1000.zig`; `e1000.debug_trace` gates per-packet serial dumps (off by default — they are slower than the network and cause the timeouts they are meant to diagnose).
- **IP payload length comes from the header, not the frame.** Ethernet pads to 60 bytes, so `ip.handlePacket` trims to the declared `total_len` before dispatch; TCP/UDP/ICMP all derive payload size from the slice they receive.
- **TCP is minimal but real:** one segment per `MSS` (1440) with `send()` doing the splitting, a single retransmission slot per connection, ISN varied per connection, SYN retransmitted up to 3× inside `waitEstablished`, and in-order-only data acceptance (out-of-order/duplicate segments are re-ACKed, not appended). Checksums must be computed after the payload is in the buffer — `buildTcpHeader` takes the whole segment slice for that reason.

- **Framebuffer/GUI:** `src/entry.S` requests a linear 1024x768x32 framebuffer (multiboot VIDEO flag). If GRUB supplies one, `vga.isFbActive()` is true and `gui`/`resolution <WxH>` (640x480, 800x600, 1024x768, 1280x720)/`mouse` work. `src/system/framebuffer.zig` is a shadow buffer: draw into RAM, then `flush()` the tracked dirty rect to the LFB (flicker-free). `src/system/gui.zig` is a small windowing shell (draggable clock/system/about windows, PS/2 mouse, Esc quits). The console shell stays VGA text. GUI changes need visual verification in a VM that provides a framebuffer — the harness runs `-nographic`.
- **Adding a shell command needs four edits** in `src/shell.zig`: import the `src/programs/<name>.zig` module, add a branch in `execute`, add a line in `printHelp`, and append the name to the `commands` array (tab-completion source). Missing the array leaves the command working but uncompletable — `acpi` is currently in that state.
- Kernel code has no std I/O: VGA is the user-facing UI, serial (`/dev/ttyS0`) is the debug log. `main.zig` defines its own `pub fn panic` (VGA + serial + `system/panic.zig:printBacktrace`, then `hlt`); the std panic handler is unused. `kernel_entry`, `syscall_handler` and `sys_exit_return` are `export`/`callconv(.c)` for the asm ABI.
- Inline asm uses Zig 0.16 clobber syntax: `: .{ .rax = true, .memory = true }`.
- Build target is x86_64-freestanding with SSE3–AVX2 removed via `cpu_features_sub` in `build.zig` (SSE/SSE2 stay). Don't emit wide vector ops.
- `.gitignore` covers `.zig-cache/`, `zig-out/`, `isodir/`, `build/`, `kernel.iso`, `qemu.log`, `serial*.log`, `test_out.log`, `disk.img`, `*.o`. Several artifacts were committed before those rules and are still tracked (`fat_test.log`, `qemu_dbg.log`, `qemu_exec.log`, `qemu_smp.log`) — don't add more, and don't "fix" them without being asked. Loose `zig-out/bin/<hash>` binaries in the working copy are stale.
- `README.md` is cosmetic prose. `AGENTS.md` and `TODO.md` (which tracks real known gaps) are the working docs.

## Lua

`lua` shell command (`src/programs/lua.zig`) runs the interpreter on a 128 KB `FixedBufferAllocator`. Native bindings live in `src/lua/api.zig` and are registered in `vm.zig:VM.init`: `print`, `type`, `tostring`, `tonumber`, `assert`, `error`, `ipairs`, `pairs`, `vga_write`, `serial_write`, `sleep`, `read_key`, `time`, plus `math.*` and `string.*` tables. Add new bindings there. User `function` definitions parse and run (`vm.callFunction`). No modules, no stdlib beyond the above.

## Working tree state

Uncommitted WIP touches `src/net/*`, `drivers/e1000.zig`, `drivers/keyboard.zig`, `fs/ramfs.zig`, `kernel/syscall.zig`, `main.zig`, `shell.zig`, `programs/web.zig`, plus untracked `src/programs/nano.zig`. Themes: network init moved from `shell.run` into `kernel_entry`, `sys_connect`/`sys_recv` block on the real handshake/data (`tcp.openConn` + `tcp.waitEstablished`), and the net stack was fixed (checksums, routing, RCTL/BAM, IP length trimming — see the Gotchas above).

Debug and ReleaseFast both build, and `./run.sh --test` passes all ten markers.

