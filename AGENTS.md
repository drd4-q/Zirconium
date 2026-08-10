# AGENTS.md — Zirconium

## What this is

Bare-metal x86_64 OS kernel in Zig. Multiboot (GRUB) boot, identity-mapped 2MB pages, SMP (secondary CPUs via ACPI + AP trampoline), a shell with programs, a custom TCP/IP stack over an e1000 NIC, ring 3 user-space with INT 0x80 syscalls, VFS with ramfs + FAT16 over virtio-blk, and a minimal Lua interpreter. Runs in QEMU.

## Build & run

```bash
zig build            # build only → zig-out/bin/kernel (Debug, safety on)
zig build -Drelease  # ReleaseFast (what run.sh/tests use)
./run.sh     # build (ReleaseFast) → grub-mkrescue ISO → launch QEMU (Linux/macOS)
./run.sh --vnc   # same but VNC display (port 5901) instead of GTK
run.bat      # Windows equivalent (same flow as run.sh)
```

**Build modes:** the build uses `standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast })`, which in Zig 0.16 returns ReleaseFast **only when `-Drelease` is passed** — plain `zig build` produces a Debug kernel with safety checks on. `run.sh`, `run.bat` and the test runner all pass `-Drelease`, so the shipped kernel is always ReleaseFast. **Gotcha:** Release builds enable `--gc-sections`, so the multiboot header in `src/entry.S` must be kept via `KEEP(*(.multiboot))` in `linker.ld` (easy to break; a fully-silent DRAM: debug boots, release says "no multiboot header found" in GRUB).

**Zig version: 0.16.0.** `build.zig.zon` says 0.14.0 but that is stale — `tools/bin2zig.zig` uses Zig 0.16 std APIs (`std.process.Init`, `std.Io.Dir`, `std.Options.debug_io`). `zig build` only compiles on 0.16.

**Toolchain deps:** GNU `as` (builds `src/entry.S` + `src/arch/isr.S`), `grub-mkrescue`, `qemu-system-x86_64`. The kernel requires the LLVM backend (`use_llvm = true`).

**Tests:** `./run.sh --test` = `python3 tools/test_runner.py` — the only automated check (no CI). It builds `zig build -Drelease` (ReleaseFast, same binary `run.sh` ships), boots QEMU headless (`-nographic`, `-smp 4`, serial into `serial_test.log`), sleeps 5s, then greps the log for exact markers (`tools/test_runner.py:153`): `[BOOT] Kernel loaded`, `[BOOT] System init done`, `[MEM] Physical memory manager initialized`, `[APIC] Local APIC timer initialized`, `[SMP] AP CPU 1 online`, `[USER] Hello from Ring 3 (user space)!`, `[USER-NET] Created socket/Connected to 10.0.2.2:80`, `[USER-HEAP] malloc/brk + free reuse`. Run it after any change that risks the boot path, SMP bring-up, or ring-3 (syscalls/heap). It patches the freshly built kernel into an existing `kernel.iso` (grub-mkrescue not re-run) **only if it fits the ISO slot** — otherwise it rebuilds the ISO from scratch (a grown kernel won't fit and silently breaks without this fallback). Boots `zig-out/bin/kernel` via `-kernel` only when no ISO exists.

**Crash triage:** QEMU runs with `-d int,cpu_reset -D qemu.log` — on crash/triple-fault read `qemu.log`. Serial (the kernel debug log) goes to the terminal (`-serial stdio`); only the test harness writes `serial_test.log`. The `serial.log` files in the repo root are stale artifacts — no script produces them.

**Embedded user binary (codegen):** `build.zig` compiles `src/user/test.zig` (freestanding ELF, image base 0x2000000), runs host tool `tools/bin2zig.zig` to emit it as a Zig byte array, and injects it as the anonymous module `user_test_bin`. `kernel_init.init()` (`src/kernel/init.zig`) registers it via `scheduler.addElfUserTask` (`src/kernel/elf.zig:loadElf`), so it runs **before the shell** on every boot and exercises syscalls socket/connect/send/recv (70–73) against 10.0.2.2:80. The shell `user` command does the same on demand. Editing `src/user/test.zig` re-embeds on next `zig build`. The same bin2zig pipeline emits a **second** anonymous module `ap_tramp_bin` (the SMP trampoline, below) — editing either source re-runs codegen on next build.

**SMP (multicore):** QEMU boots with `-smp 4`. `main.zig` calls `smp.init()` (`src/arch/smp.zig`) before the scheduler: parses ACPI/MADT for LAPIC IDs (`src/arch/acpi.zig`), then sends INIT-SIPI-SIPI (ICR mode bits in 10:8, not the `0x6000` variant) to wake APs into the embedded trampoline blob (`src/arch/trampoline.S`; built by `as` + `ld -Ttext=0x8000 --oformat=binary` in `build.zig`, loaded at 0x8000 with fixed control cells at 0x600–0x718). Each AP runs its own 16 KB stack from `CELL_STACK` and idle-loops in `ap_entry`. The test asserts `[SMP] AP CPU 1 online` — a broken trampoline layout or ICR encoding makes APs silently never come online. Shell: `smp` / `cpuinfo`.

**Disk / FAT16 gotcha:** `run.sh` creates a 64 MB `disk.img` (virtio-blk) if missing. At shell start `virtio_blk.init()` + `fat16.init()` auto-mount it at `/mnt/disk` — the `ls/cat/cd/touch/mkdir/rm/write/save` commands are FAT16-based and fail/empty if no `disk.img`/block device exists (`[FAT16]` messages). `disk.img` is gitignored build noise.

**Network gotcha:** the guest is an HTTP *client* — `get`/`wget` fetches from the gateway 10.0.2.2 (= the host), and nothing listens on guest:80 despite the "open localhost:8080" comment in `run.sh`.

## Architecture

**Boot sequence** (`src/entry.S` → `src/main.zig`):
1. `entry.S`: 32-bit Multiboot entry → zeroes 6 page tables → identity maps 4 GB (4 PDs × 512 × 2MB pages) → enables long mode → calls `kernel_entry`.
2. `main.zig:39 kernel_entry`: serial → GDT (ring 3 segments + TSS) → framebuffer init → system init (PIC, IDT) → PMM → VMM → kalloc heap → VFS + ramfs mount → `kernel_init.init()` (timer + scheduler; registers idle/hello kernel tasks and the embedded user ELF task) → `smp.init()` (ACPI/MADT, wake APs) → `scheduler.runAll()` (runs every task; the user task jumps to ring 3) → `shell.run()`. FAT16 auto-mount happens later, in `shell.zig:run` startup, not during boot.

**Key source layout:**
- `src/arch/` — GDT, IDT (256 entries + INT 0x80 DPL3 gate), PIC, port I/O, ISR/IRQ handlers (`isr.S` + `isr.zig`), ACPI/MADT scan (`acpi.zig`), SMP AP bootstrap (`smp.zig` + `trampoline.S`)
- `src/kernel/` — pmm, vmm (incl. COW resolution), kalloc (heap), scheduler, task, address_space, elf, syscall, init
- `src/system/` — serial, vga, framebuffer, init, panic
- `src/drivers/` — keyboard, timer (PIT 100 Hz IRQ0 + LAPIC timer via `apic.zig`), apic, pci, e1000, mouse, virtio_blk
- `src/net/` — arp, arp_cache, ip, icmp, tcp, udp, dns, dhcp, http; `mod.zig` is the public interface
- `src/fs/` — vfs, ramfs, blockdev, fat16 (auto-mounted at `/mnt/disk`)
- `src/programs/` — shell commands; `src/shell.zig:execute` dispatches them
- `src/lua/` — interpreter; `mod.zig` re-exports lexer/parser/vm/value/api

**The scheduler is not preemptive:** `scheduler.runAll()` runs each registered task to completion in order (kernel tasks called directly; the user task via `jumpToUser`), then returns to the shell. `TIME_SLICE` is stored but unused.

**Root module pattern:** `src/main.zig` is the root module and re-exports `vga`, `serial`, `scheduler`, `pmm`, `vmm`; other files reach them via `@import("root")` (e.g. `root.vga`).

## User-space (ring 3)

**GDT selectors** (`src/arch/gdt.zig`): 0x08 kernel code, 0x10 kernel data, 0x18|3 user code, 0x20|3 user data, 0x40 TSS (plus duplicate 0x28/0x30 kernel segments).

**Syscalls:** INT 0x80; numbers in `src/kernel/syscall.zig:15` (rax=num, rdi/rsi/rdx=args). Implemented: write=1 (fd 1–2 → VGA, 3 → serial), read=2 (fd 0 → keyboard), sleep=10, time=11, brk=12 (user heap: maps USER_HEAP_BASE pages per task), fork=57 (clones address space + user stack, COW), exec=59 (load ELF from ramfs path), exit=60, waitpid=61, socket/connect/send/recv=70–73 (8 per-task TCP socket slots). open=3 and close=4 still fall through to ENOSYS. `src/user/heap.zig` is a user-space malloc/free built on the brk syscall.

**Address spaces** (`src/kernel/address_space.zig`): per-task PML4, create/destroy/switch, user pages mapped with PAGE_USER. `user` shell command loads the compiled-in ELF into a fresh address space and jumps to ring 3.

## Lua interpreter

`src/lua/` — lexer, recursive-descent parser → AST, tree-walking VM. Runs via the `lua` shell command (`src/programs/lua.zig`; 128 KB `FixedBufferAllocator` heap).

- Native bindings live in `src/lua/api.zig` and are registered in `vm.zig:VM.init` (globals: `print`, `vga_write`, `serial_write`, `sleep`, `read_key`, `time`, plus `math.*` and `string.*` tables). Add new bindings there.
- User-defined `function` definitions are parsed and callable (`vm.callFunction`).
- No Lua modules/standard libraries beyond the above.

## Conventions

- Assembler files are built with GNU `as`. Inline asm uses Zig 0.16+ clobber syntax: `: .{ .rax = true, .memory = true }`.
- VGA is the user-facing UI; serial (`/dev/ttyS0`) is debug logging. Don't use std output facilities in kernel code.
- Hardcoded network config: IP 10.0.2.15, gateway 10.0.2.2, DNS 10.0.2.3, HTTP always targets 10.0.2.2:80.
- New shell commands: create `src/programs/<name>.zig`, then import + dispatch it in `shell.zig:execute` and list it in `printHelp`.
- `README.md` is cosmetic prose; `AGENTS.md` + `TODO.md` are the real docs.
- `tools/patch_iso.py` overwrites the kernel inside an existing `kernel.iso` (ISO patching, no grub-mkrescue) — the test runner does the same inline.
- Build target: x86_64-freestanding (Debug on plain `zig build`, ReleaseFast with `-Drelease`); SSE3–AVX2 stripped via `cpu_features_sub` in `build.zig`.
- `.gitignore` covers `.zig-cache/`, `zig-out/`, `isodir/`, `build/`, `kernel.iso`, `qemu.log`, `*.log`, `disk.img`, `*.o` — all build noise; don't commit them.
- `kernel_entry` is exported `callconv(.c)` and called from asm; `syscall_handler` and `main.zig:panic` are similarly exported for asm/ABI use. `main.zig` defines its own `pub fn panic` (prints to VGA+serial, halts) — the std one is unused.
