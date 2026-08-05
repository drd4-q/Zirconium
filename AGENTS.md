# AGENTS.md — Zig Kernel

## What this is

Bare-metal x86_64 OS kernel written in Zig. Boots via Multiboot (GRUB), sets up long mode (identity-mapped 2MB pages), runs a shell with programs, a TCP/IP network stack over an e1000 NIC, and a Lua interpreter. Ring 3 user-space support with syscall interface. Runs in QEMU.

## Build and run

```bash
./run.sh          # build → create ISO → launch QEMU (full cycle)
zig build          # build only (output: zig-out/bin/kernel)
```

`run.sh` calls `zig build`, then `grub-mkrescue` to produce `kernel.iso`, then launches QEMU. QEMU forwards host port 8080 → guest port 80.

**External toolchain dependencies:** GNU `as` (assembler), `grub-mkrescue` (ISO creation), `qemu-system-x86_64`.

**Minimum Zig version:** 0.14.0 (per `build.zig.zon`).

**Target:** x86_64-freestanding, ReleaseFast preferred. Build strips SSE/AVX features via `cpu_features_sub`.

## Architecture

**Boot sequence** (`src/entry.S` → `src/main.zig`):
1. `entry.S`: 32-bit Multiboot entry → sets up identity-mapped page tables (4 PDs, 2MB pages) → enables long mode → jumps to `_start64` → calls `kernel_entry`
2. `main.zig:kernel_entry`: serial init → GDT (with ring 3 segments) → system init (PIC, IDT) → PMM → VMM → kernel modules (scheduler tasks) → scheduler → shell

**Key source layout:**
- `src/entry.S` — 32-bit asm bootstrap, page table setup, GDT, long mode switch
- `src/arch/` — GDT (ring 0+3 segments, TSS), IDT (256 entries + syscall gate 0x80), PIC, port I/O, ISR handlers (`isr.S` + `isr.zig`)
- `src/kernel/` — PMM, VMM, scheduler, task management, address spaces, syscall handler
- `src/system/` — serial, VGA, init, panic handler
- `src/drivers/` — keyboard, timer, PCI, e1000 NIC
- `src/net/` — ARP, IP, ICMP, TCP, HTTP (custom stack)
- `src/programs/` — shell commands (calc, clock, ping, web server, Lua REPL, etc.)
- `src/shell.zig` — command dispatcher, shell loop
- `src/lua/` — Minimal Lua interpreter (lexer/parser/VM/API bindings)

**No external Zig dependencies.** Everything is self-contained.

## User-space support

**GDT segments:**
- 0x08: Kernel code (DPL=0)
- 0x10: Kernel data (DPL=0)
- 0x18: User code (DPL=3)
- 0x20: User data (DPL=3)
- 0x38: TSS

**Syscall interface:** INT 0x80 with standard ABI (rax=syscall number, rdi/rsi/rdx=args). Syscalls: write(1), read(2), sleep(10), time(11), exit(60).

**Address space management** (`src/kernel/address_space.zig`): Per-process PML4 page tables, create/destroy/switch, user page mapping with PAGE_USER flag.

**Task structure** (`src/kernel/task.zig`): Supports kernel and user tasks with separate kernel/user stacks, saved register state (rax-r15, rip, rsp, rflags, cs, ss), and per-task address space.

## Lua interpreter

Minimal Lua 5.x port in Zig (`src/lua/`):
- **Lexer** (`src/lua/lexer.zig`): Tokenizer for Lua source
- **Parser** (`src/lua/parser.zig`): Recursive descent parser → AST
- **VM** (`src/lua/vm.zig`): Tree-walking interpreter with global variables
- **API** (`src/lua/api.zig`): Kernel bindings via syscalls (vga_write, serial_write, sleep, read_key, print, type, tostring, tonumber)
- **REPL** (`src/programs/lua.zig`): Interactive Lua shell, run via `lua` command

Supported Lua features: variables, arithmetic/comparison/logical operators, if/elseif/else, while/repeat loops, numeric for loops, functions (declared but not yet callable), string concatenation.

## Conventions

- Root module is `src/main.zig`. Other modules import it via `@import("root")` to access public decls (e.g. `root.vga`, `root.serial`, `root.scheduler`).
- Kernel entry point is `kernel_entry` (exported in `src/main.zig:30`), called from assembly. The assembler files (`src/entry.S`, `src/arch/isr.S`) are built with GNU `as`, not Zig's built-in assembler.
- VGA output is the primary user interface. Serial (`/dev/ttyS0`) is for debug logging.
- Hardcoded network config: IP `10.0.2.15`, gateway `10.0.2.2` (QEMU user-mode default).
- New shell commands go in `src/programs/`, imported and dispatched in `shell.zig:execute`.
- New Lua bindings go in `src/lua/api.zig`, registered in `src/lua/vm.zig:init`.
- Inline assembly uses Zig 0.14+ clobber syntax: `: .{ .rax = true, .memory = true }` (not string lists).
- `std.ArrayList` in Zig 0.14+ has no `.init()` — use `.empty` or fixed-size stack arrays instead.
