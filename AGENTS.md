# AGENTS.md — Zirconium

Bare-metal x86_64 OS kernel in Zig. Multiboot/GRUB boot, identity-mapped 2MB pages, SMP via ACPI + AP trampoline, VGA-text shell with programs, custom TCP/IP stack over e1000, ring 3 user-space with INT 0x80 syscalls, VFS with ramfs + FAT16 over virtio-blk, framebuffer GUI, a minimal Lua interpreter, and execution of foreign binaries: static Linux ELF (via the `syscall` instruction) and Win32 PE32+ .exe (via emulated thunks). Runs in QEMU; real-hardware USB boot is supported by `create_usb.sh`.

## Build & run

```bash
zig build            # Debug kernel (safety checks on) → zig-out/bin/kernel
zig build -Drelease  # ReleaseFast — what run.sh and the tests ship
./run.sh             # build -Drelease → grub-mkrescue ISO → QEMU (gtk)
./run.sh --vnc       # VNC on host port 5901 instead of gtk
./run.sh --gdb       # QEMU -s -S; attach gdb to localhost:1234
./run.sh --test      # = python3 tools/test_runner.py (the only automated check)
run.bat              # Windows equivalent of run.sh
./test_prog.sh       # rebuild disk.img populated with test executables (see below)
```

- **Zig 0.16.0 required.** `build.zig.zon` says `minimum_zig_version = "0.14.0"` — stale. `tools/bin2zig.zig` uses 0.16-only std APIs.
- `zig build` exposes only `install` (default) and `build` steps. There is **no `zig build test`** and no unit tests anywhere; verification is the QEMU harness.
- `-Drelease` is required for ReleaseFast: `standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast })` only honors the preference when the flag is passed. Full clean build ≈8 s, so always build before claiming anything.
- Release enables `--gc-sections`, so `linker.ld` must keep `KEEP(*(.multiboot))` for `src/entry.S`'s header. Break it and Debug still boots while release fails in GRUB with "no multiboot header found".
- **Toolchain:** `grub-mkrescue`, `qemu-system-x86_64`, `python3`. All assembly (`entry.S`, `isr.S`, `trampoline.S`) goes through Zig's own assembler (`addAssemblyFile`) — no GNU as/ld anywhere anymore (README still claims it). The AP trampoline links flat at 0x8000 via `src/arch/trampoline.ld` and converts to a blob with `addObjCopy(.{ .format = .bin })`. Kernel requires `use_llvm = true`.
- Stale helpers: `qemu.sh/.bat`, `qemu_vnc.sh/.bat` predate SMP/disk support. Use `run.sh`. `create_disk.sh` builds a richer `disk.img` via mtools; `run.sh` only does `dd` + `mkfs.fat -F 16` (or qemu-img/fsutil fallbacks in `run.bat`).

## Testing

`tools/test_runner.py`: builds `zig build -Drelease`, gets the kernel into `kernel.iso`, boots QEMU headless (`-display none -serial stdio -smp 4 -m 512M`, user-mode networking with an e1000), polls serial output for the terminal marker `[USER-HEAP] free + reuse OK` with a **45 s deadline**, kills QEMU, then asserts the exact marker list in `tools/test_runner.py:177`:

`[BOOT] Kernel loaded`, `[BOOT] System init done`, `[MEM] Physical memory manager initialized`, `[APIC] Local APIC timer initialized`, `[SMP] AP CPU 1 online`, `[USER] Hello from Ring 3 (user space)!`, `[USER-NET] Created socket via sys_socket`, `[USER-NET] Connected to 10.0.2.2:80 via sys_connect`, `[USER-HEAP] malloc(64)+malloc(128) via SYS_BRK OK`, `[USER-HEAP] free + reuse OK`.

Notes:
- The harness has **no virtio-blk disk** and no `-d int,cpu_reset`; crash triage via `qemu.log` works only under `run.sh` (which also sends serial to the terminal). The harness writes `serial_test.log`.
- Markers are matched as raw substrings — renaming a log string silently breaks the suite.
- Run it after any change touching the boot path, SMP bring-up, syscalls, ring 3, or the TCP client path. It cannot test the shell, GUI, FAT16 contents, or foreign binaries (no framebuffer/input, no disk attached).
- ISO handling: patches `kernel.bin` into an existing `kernel.iso` in place **only if it fits the old slot**, else rebuilds with `grub-mkrescue` (with a WSL fallback on Windows), else falls back to `-kernel zig-out/bin/kernel` when there is no ISO. `tools/patch_iso.py` is the standalone patcher used by `run.bat` when grub-mkrescue is missing.

## Test programs & samples

- `samples/` holds committed fixtures: `busybox` (static musl multi-call ELF), `hello_linux` (ELF built from `hello_linux.zig`), `hello.exe` / `hello_win.exe` (PE32+ built from `hello_win.zig`). Rebuild them with plain `zig build-exe -target x86_64-{freestanding,windows}` per `tools/create_test_disk.py`.
- `test_prog.sh|bat` → `python3 tools/create_test_disk.py`: downloads busybox from busybox.net, compiles the samples, writes a fresh 64 MB FAT16 `disk.img` at the repo root. Requires mtools (`mformat`/`mcopy`) natively or via WSL on Windows.
- In the guest these appear at `/mnt/disk/...`. Run via `exec /mnt/disk/hello.exe`, `exec /mnt/disk/busybox uname -a`, **or just type the name** — unknown shell commands fall through to `resolveExecutablePath` in `src/shell.zig` and exec ELF/PE from a VFS path.
- `create_usb.sh [device]` writes `kernel.iso` to a USB stick for bare-metal boot (Legacy/CSM GRUB, Secure Boot off; Ventoy also works).

## Codegen (two embedded blobs)

`build.zig` runs the host tool `tools/bin2zig.zig` twice to turn binaries into Zig byte arrays injected as anonymous modules:
- `user_test_bin` ← `src/user/test.zig` built as a freestanding ELF, `image_base = 0x2000000`, entry `_start`. `kernel/init.zig` registers it with `scheduler.addElfUserTask`, so it runs in ring 3 **before the shell on every boot** and exercises write/socket/connect/send/recv/brk. The shell `user` command respawns it on demand via `scheduler.spawnProgramImage`.
- `ap_tramp_bin` ← `src/arch/trampoline.S` (Zig assembler + flat link at 0x8000 + objcopy `.bin`).

Editing either source re-runs codegen on the next `zig build`; no manual step.

## Architecture

**Boot:** `src/entry.S` (32-bit multiboot entry → zero 6 page tables → identity map 4 GB with 4 PDs × 512 × 2 MB pages → long mode) → `kernel_entry` (`src/main.zig:43`): serial → GDT (ring 3 segments + TSS) → `vga.initFb(mbi_ptr)` → `system_init` (PIC, IDT) → `syscall64.init()` (MSR setup enabling the `syscall` instruction) → PMM → VMM → kalloc → VFS + ramfs mount → `kernel_init.init()` (timer, scheduler, task registration incl. the embedded user test) → `pci.scan()` + e1000 + `net/mod.zig.init()` → virtio-blk + FAT16 mount + USB + mouse (all PCI-backed devices init right after the single bus scan) → `smp.init()` → `scheduler.runAll()` → `shell.run()`.

**Layout:**
- `src/arch/` — gdt, idt (256 entries + INT 0x80 DPL3 gate), pic, port, isr (`isr.S` + `isr.zig`; also hosts the `syscall_entry_64` stub), acpi (MADT scan), smp + trampoline.S/.ld, msr, syscall64 (STAR/LSTAR/FMASK/SCE MSRs)
- `src/kernel/` — pmm, vmm (incl. COW fault resolution), kalloc, scheduler, task, address_space, elf (ELF64 loader), pe (PE32+ loader), winapi (Win32 emulation), linux_syscalls (Linux ABI table), binfmt (format dispatch + personalities), fdtable, process, uaccess, syscall, init
- `src/system/` — serial, vga, framebuffer, gui, tty, init, panic
- `src/system/env.zig` — kernel-wide KEY=VALUE environment table; the shell manages it (`set`/`unset`/`env`, `echo`, `$KEY` expansion on every command line) and Win32 PE programs read it via emulated `GetEnvironmentVariableA`. Static storage, no allocation — slices stay valid until next set/unset.
- `src/drivers/` — keyboard, timer (PIT 100 Hz on IRQ0), apic, pci, e1000, mouse, virtio_blk, usb
- `src/net/` — arp, arp_cache, ip, icmp, tcp, udp, dns, dhcp, http; `mod.zig` is the public surface
- `src/fs/` — vfs, ramfs (mounted at `/`), blockdev, fat16 (mounted at `/mnt/disk`)
- `src/programs/` — one file per shell command plus the `dillo/` browser package (css/html/layout/url/entities + `js_engine`), dispatched from `src/shell.zig:execute`
- `src/lua/` — lexer, parser → AST, tree-walking VM; `mod.zig` re-exports

**Root module pattern:** `src/main.zig` is the root and re-exports `serial`, `vga`, `scheduler`, `pmm`, `vmm`, `kalloc`, `tty`. ~45 files reach them via `const root = @import("root"); const vga = root.vga;` rather than relative imports. Follow that in new files.

**Scheduler is not preemptive:** `scheduler.runAll()` runs each registered task to completion in order (kernel tasks called directly, user tasks via `jumpToUser`), then returns and the shell starts. `TIME_SLICE` is assigned to tasks but never enforced.

**LAPIC timer is intentionally masked** (`src/drivers/apic.zig:83`) — the PIT is the single 100 Hz tick source. An unmasked periodic LAPIC timer on the same vector 32 double-counted every tick and made `sleep()`/`time()`/TCP timeouts run 2× fast. The `[APIC] Local APIC timer initialized` test marker is printed anyway; don't read it as "LAPIC timer ticking".

**SMP:** `smp.init()` parses ACPI/MADT for LAPIC IDs, then INIT-SIPI-SIPI. SIPI delivery mode lives in ICR bits 10:8 (`(6 << 8) | (0x8000 >> 12)`, **not** the `0x6000` form — see `src/arch/smp.zig:30`). The trampoline is copied to 0x8000 with fixed control cells at 0x600 (GDT desc), 0x610 (IDT desc), 0x700 (PML4), 0x708 (stack top), 0x710 (index), 0x718 (entry). Each AP gets a 16 KB stack and idle-loops in `ap_entry`. A wrong cell layout or ICR encoding makes APs silently never come online — the only signal is the missing `[SMP] AP CPU 1 online`. Shell: `smp`, `cpuinfo`.

## Foreign binaries (binfmt personalities)

`kernel/binfmt.zig` sniffs `\x7fELF` vs `MZ`/PE and dispatches `load()` to `elf.load` or `pe.load`. Each image carries a **personality** that decides its kernel ABI:

- **ELF64 static** (`ET_EXEC` and static-PIE `ET_DYN`) → personality `.linux`. These enter the kernel with the `syscall` instruction, not INT 0x80: `arch/syscall64.zig` sets IA32_LSTAR to the `syscall_entry_64` stub in `isr.S`, which builds an InterruptFrame-compatible frame on the task's kernel stack and returns via `iretq`, so the C-side handler is shared with the INT 0x80 path. FMASK=0 keeps IF set — masking it would hang every blocking wait. `syscall_kernel_rsp` must be updated per task alongside TSS.RSP0.
- **PE32+ console x86-64** → personality `.windows`. Imports are resolved to 8-byte thunks (`mov eax, imm32; int 0x81; ret`) mapped at `WIN_THUNK_BASE`; `winapi.win_thunk_handler` services vector **0x81** (deliberately distinct from 0x80).
- Dynamically linked images are rejected with a clear error (no runtime loader exists).

`syscall_handler` (`kernel/syscall.zig:65`) routes by the current task's personality. The native and Linux tables must stay separate — numbers collide with different meanings (1=write in both, but 2=read natively vs open in Linux). A PE task issuing a raw syscall is terminated.

**Linux ABI coverage worth knowing:** directories open into a `.dir` FileDesc (path remembered inline in `task.DirDesc`, cursor inside) so `getdents64` works — `vfs.readdir` enumerates by path, not handle. `chdir`/`getcwd` hit the real VFS CWD. `pipe`/`pipe2` return ENOSYS honestly instead of handing out dead fds. `fcntl(F_DUPFD)` really duplicates. `sysinfo` fills totalram/freeram/procs from PMM/scheduler. Still fake-but-harmless: poll/select always "ready", munmap/mprotect are no-ops, fork/vfork/clone are NOT implemented (musl system() will fail).

**Win32 coverage:** environment is fully wired — `GetEnvironmentVariableA` and `GetEnvironmentStringsW` both read `system/env.zig` (the block is built in fresh anonymous user memory). Console I/O goes through fdtable; files through VFS handles encoded in pseudo-handle values ≥ 0xF0001000.

## User-space (ring 3)

- **GDT selectors** (`src/arch/gdt.zig`): 0x08 kernel code, 0x10 kernel data, `0x18|3` user code, `0x20|3` user data, 0x40 TSS; 0x28/0x30 are unused duplicate kernel segments.
- **Native syscalls:** INT 0x80, `rax` = number, args in `rdi`/`rsi`/`rdx`. Numbers in `src/kernel/syscall.zig:17`. Implemented: write=1 (fd 1–2 → VGA, 3 → serial), read=2 (fd 0 → keyboard), sleep=10, time=11, brk=12, fork=57 (COW clone), exec=59 (ELF **or PE** from a VFS path), exit=60, waitpid=61, socket/connect/send/recv=70–73. `SYS_OPEN=3` and `SYS_CLOSE=4` exist in the enum but fall through the `else` arm to ENOSYS (-38).
- Per-task state: 8 TCP socket slots (`src/kernel/task.zig:108`), user heap at `USER_HEAP_BASE = 0x04000000` grown page-wise by `brk`. `src/user/heap.zig` is the ring-3 free-list malloc built on `brk`.
- **Address spaces** (`src/kernel/address_space.zig`): per-task PML4, create/destroy/switch, user pages mapped `PAGE_USER`; `destroy()` frees user physical pages.

## Gotchas

- **Disk/FAT16:** `run.sh` creates a 64 MB FAT16 `disk.img` if missing; `virtio_blk.init()` + `fat16.init()` auto-mount it at `/mnt/disk` at shell start. Without a block device the `ls/cat/cd/touch/mkdir/rm/write/save` commands hit ramfs at `/` and FAT16 logs `[FAT16] No block device found`.
- **Network is client-only:** static IP 10.0.2.15/24, gateway 10.0.2.2, DNS 10.0.2.3 (`dhcp` overwrites all three from a lease). Real routing is in place — `net.nextHopMac()` picks the destination MAC (on-link host vs. gateway) and drops the packet when ARP fails, so `get`/`wget` reach the internet through QEMU's slirp, not just the host. Nothing listens on guest:80, so `run.sh`'s "open http://localhost:8080" hostfwd message is misleading.
- **The stack polls, it does not use IRQs.** e1000 interrupts are masked on purpose; `net.poll()` drains the RX ring and is called from the blocking loops (`ensureArp`, `waitEstablished`, `dns.resolve`, `http`, `sys_recv`). `net.tick()` (ARP cache aging + TCP retransmit) runs from `scheduler.scheduleTick` once a second. `poll()` has a re-entrancy guard because handlers transmit and transmitting can ARP; inside a handler `nextHopMac` only fires the request and returns null instead of waiting.
- **e1000 register bits are easy to get wrong** — RCTL bit 15 is BAM (broadcast accept, required for DHCP OFFERs), bit 3 is UPE (not BAM), bit 6 is loopback (not BSIZE). BSIZE=2048 is the default (bits 17:16 = 00, BSEX clear). TX descriptors need the RS bit (0x08) for the DD status bit to ever be set, and RDT must be written with the index just recycled, not the next one. Named constants live at the top of `src/drivers/e1000.zig`; `e1000.debug_trace` gates per-packet serial dumps (off by default — they are slower than the network and cause the timeouts they are meant to diagnose).
- **IP payload length comes from the header, not the frame.** Ethernet pads to 60 bytes, so `ip.handlePacket` trims to the declared `total_len` before dispatch; TCP/UDP/ICMP all derive payload size from the slice they receive.
- **TCP is minimal but real:** one segment per `MSS` (1440) with `send()` doing the splitting, a single retransmission slot per connection, ISN varied per connection, SYN retransmitted up to 3× inside `waitEstablished`, and in-order-only data acceptance (out-of-order/duplicate segments are re-ACKed, not appended). Checksums must be computed after the payload is in the buffer — `buildTcpHeader` takes the whole segment slice for that reason.
- **Framebuffer/GUI:** `src/entry.S` requests a linear 1024x768x32 framebuffer (multiboot VIDEO flag). `vga.isFbActive()` is true when the bootloader supplied a usable LFB; both **24bpp and 32bpp** are accepted (WSL grub-mkrescue + QEMU hands out 800x600x24 — a kernel that rejects it draws invisibly over live graphics = black screen). `grub.cfg` ends `gfxpayload` with a `text` fallback so the console stays visible even for unusable modes. `gui`/`resolution <WxH>` (640x480, 800x600, 1024x768, 1280x720)/`mouse` work once the fb is active. `src/system/framebuffer.zig` is a shadow buffer: draw into RAM, then `flush()` the tracked dirty rect to the LFB (flicker-free); all raw-LFB access goes through `lfbPut`/`lfbGet` or branches on `fb_bytes_pp`. `initFromMultiboot` logs `[FB] ...` diagnostics to serial on every boot. `src/system/gui.zig` is a small windowing shell (draggable clock/system/about windows, PS/2 mouse, Esc quits). The console shell stays VGA text. GUI changes need visual verification in a VM that provides a framebuffer — the harness runs `-display none`; use `tools/boot_watch.py <seconds>` to boot the ISO headless, screendump via QMP into `screen.ppm`, and capture full serial to `ser_capture.log`.
- **Adding a shell command needs two edits** in `src/shell.zig`: a handler function and one entry in `command_table` (name + handler). The table is the single source of truth for dispatch *and* tab completion. Zero-arg programs get an `fn runX(_: []const u8)` adapter; full-screen programs (lua/matrix/gui/nano) clear the screen and reprint the banner on exit — see `cmdLua` for the pattern. Unknown commands fall through to `execFromPath`, which runs ELF/PE from a VFS path (`/bin/`, `/mnt/disk/`, optional `.exe` suffix).
- Kernel code has no std I/O: VGA is the user-facing UI, serial (`/dev/ttyS0`) is the debug log. `main.zig` defines its own `pub fn panic` (VGA + serial + `system/panic.zig:printBacktrace`, then `hlt`); the std panic handler is unused. `kernel_entry`, `syscall_handler` and `win_thunk_handler` are exported because asm references them.
- Inline asm uses Zig 0.16 clobber syntax: `: .{ .rax = true, .memory = true }`.
- Build target is x86_64-freestanding with SSE3–AVX2 removed via `cpu_features_sub` in `build.zig` (SSE/SSE2 stay). Don't emit wide vector ops.
- `.gitignore` covers `.zig-cache/`, `zig-out/`, `isodir/`, `build/`, `kernel.iso`, `qemu.log`, `serial*.log`, `test_out.log`, `*.img`, `*.o`. Loose `zig-out/bin/<hash>` binaries in the working copy are stale. `samples/*` and `busybox` **are** committed binary fixtures on purpose.

## Lua

`lua` shell command (`src/programs/lua.zig`) runs the interpreter on a 128 KB `FixedBufferAllocator`. Native bindings live in `src/lua/api.zig` and are registered in `vm.zig:VM.init`: `print`, `type`, `tostring`, `tonumber`, `assert`, `error`, `ipairs`, `pairs`, `vga_write`, `serial_write`, `sleep`, `read_key`, `time`, plus `math.*` and `string.*` tables. Add new bindings there. User `function` definitions parse and run (`vm.callFunction`). No modules, no stdlib beyond the above.
