# AGENTS.md — Zirconium

## What this is

Bare-metal x86_64 OS kernel in Zig. Multiboot (GRUB) boot, identity-mapped 2MB pages, a shell with programs, a custom TCP/IP stack over an e1000 NIC, ring 3 user-space with INT 0x80 syscalls, VFS with ramfs, and a minimal Lua interpreter. Runs in QEMU.

## Build & run

```bash
zig build    # build only → zig-out/bin/kernel
./run.sh     # build → grub-mkrescue ISO → launch QEMU (Linux/macOS)
./run.sh --vnc   # same but VNC display (port 5901) instead of GTK
run.bat      # Windows equivalent (same flow as run.sh)
```

**Zig version: 0.16.0.** `build.zig.zon` says 0.14.0 but that is stale — `tools/bin2zig.zig` uses Zig 0.16 std APIs (`std.process.Init`, `std.Io.Dir`, `std.Options.debug_io`). `zig build` only compiles on 0.16.

**Toolchain deps:** GNU `as` (builds `src/entry.S` + `src/arch/isr.S`), `grub-mkrescue`, `qemu-system-x86_64`. The kernel requires the LLVM backend (`use_llvm = true`).

**No test suite, no CI.** `zig build` is the only automated check. On crash/triple-fault, read `qemu.log` (QEMU runs with `-d int,cpu_reset -D qemu.log`). Serial output goes to both stdio and `serial.log`.

**Embedded user binary (codegen):** `build.zig` compiles `src/user/test.zig` (freestanding ELF, image base 0x2000000), runs host tool `tools/bin2zig.zig` to emit it as a Zig byte array, and injects it as the anonymous module `user_test_bin`. The shell `user` command loads it via `scheduler.addElfUserTask` (`src/kernel/elf.zig:loadElf`). Editing `src/user/test.zig` re-embeds it on the next `zig build`.

**Network gotcha:** the guest is an HTTP *client* — `get`/`wget` fetches from the gateway 10.0.2.2 (= the host), and nothing listens on guest:80 despite the "open localhost:8080" comment in `run.sh`.

## Architecture

**Boot sequence** (`src/entry.S` → `src/main.zig`):
1. `entry.S`: 32-bit Multiboot entry → zeroes 6 page tables → identity maps 4 GB (4 PDs × 512 × 2MB pages) → enables long mode → calls `kernel_entry`.
2. `main.zig:36 kernel_entry`: serial → GDT (ring 3 segments + TSS) → framebuffer init → system init (PIC, IDT) → PMM → VMM → `kernel_init.init()` (registers kernel tasks) → `scheduler.runAll()` → `shell.run()`.

**Key source layout:**
- `src/arch/` — GDT, IDT (256 entries + INT 0x80 DPL3 gate), PIC, port I/O, ISR/IRQ handlers (`isr.S` + `isr.zig`)
- `src/kernel/` — pmm, vmm, kalloc (heap), scheduler, task, address_space, elf, syscall
- `src/system/` — serial, vga, framebuffer, init, panic
- `src/drivers/` — keyboard, timer (PIT 100 Hz), pci, e1000, mouse, virtio_blk
- `src/net/` — arp, arp_cache, ip, icmp, tcp, udp, dns, dhcp, http; `mod.zig` is the public interface
- `src/fs/` — vfs, ramfs, blockdev
- `src/programs/` — shell commands; `src/shell.zig:execute` dispatches them
- `src/lua/` — interpreter; `mod.zig` re-exports lexer/parser/vm/value/api

**The scheduler is not preemptive:** `scheduler.runAll()` runs each registered task to completion in order (kernel tasks called directly; the user task via `jumpToUser`), then returns to the shell. `TIME_SLICE` is stored but unused.

**Root module pattern:** `src/main.zig` is the root module and re-exports `vga`, `serial`, `scheduler`, `pmm`, `vmm`; other files reach them via `@import("root")` (e.g. `root.vga`).

## User-space (ring 3)

**GDT selectors** (`src/arch/gdt.zig`): 0x08 kernel code, 0x10 kernel data, 0x18|3 user code, 0x20|3 user data, 0x40 TSS (plus duplicate 0x28/0x30 kernel segments).

**Syscalls:** INT 0x80; numbers in `src/kernel/syscall.zig` (rax=num, rdi/rsi/rdx=args). write=1, read=2, open=3, close=4, sleep=10, time=11, fork=57, exec=59, exit=60, waitpid=61. write/read/sleep/time/exit/exec/waitpid are implemented; fork/open/close return errors.

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
- Build target: x86_64-freestanding, ReleaseFast default; SSE3–AVX2 stripped via `cpu_features_sub` in `build.zig`.
- No `.gitignore`: `.zig-cache/`, `zig-out/`, `isodir/`, `kernel.iso`, `qemu.log`, `serial.log`, `*.o` are build noise — don't commit them.
- `kernel_entry` is exported `callconv(.c)` and called from asm; `syscall_handler` and `main.zig:panic` are similarly exported for asm/ABI use. `main.zig` defines its own `pub fn panic` (prints to VGA+serial, halts) — the std one is unused.
