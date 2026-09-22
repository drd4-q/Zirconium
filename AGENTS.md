# AGENTS.md — Zirconium

<<<<<<< HEAD
Bare-metal x86_64 kernel in Zig (Multiboot/GRUB, 2MB identity pages, SMP, VGA/FB shell, TCP/IP over e1000/rtl8169, VFS ramfs+FAT16/virtio-blk, ring 3 INT 0x80 + `syscall`, Lua, modular USB stack). QEMU only.
=======
Bare-metal x86_64 OS kernel in Zig. Multiboot/GRUB boot, identity-mapped 2MB pages, SMP via ACPI + AP trampoline, VGA-text shell with programs, custom TCP/IP stack over e1000, ring 3 user-space with INT 0x80 syscalls, VFS with ramfs + FAT16 over virtio-blk, framebuffer GUI, a minimal Lua interpreter, and execution of foreign binaries: static Linux ELF (via the `syscall` instruction) and Win32 PE32+ .exe (via emulated thunks). Runs in QEMU; real-hardware USB boot is supported by `create_usb.sh`.
>>>>>>> b588c390dec30ac14d775895765ce1109b2ad3db

## Build & run

```bash
zig build            # Debug → zig-out/bin/kernel
zig build -Drelease  # ReleaseFast — what run.sh and both harnesses ship
./run.sh             # build -Drelease → grub-mkrescue ISO → QEMU (gtk)
<<<<<<< HEAD
./run.sh --vnc       # VNC :5901 instead of gtk
./run.sh --gdb       # -s -S, gdb localhost:1234
./run.sh --test      # python3 tools/test_runner.py
run.bat              # Windows equiv
```

- **Zig 0.16.0 required.** `build.zig.zon` says `0.14.0` — stale. `tools/bin2zig.zig` uses 0.16 APIs (`std.process.Init`, `std.Io.Dir`, `std.Options.debug_io`).
- No `zig build test`, no unit tests. Verification is QEMU harnesses only. Full clean build ≈8 s — always rebuild before claiming anything.
- `-Drelease` selects `ReleaseFast` via `standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast })`; without flag you get Debug.
- Release enables `--gc-sections` → `linker.ld` must `KEEP(*(.multiboot))` or GRUB fails "no multiboot header" (Debug still boots).
- Toolchain: `grub-mkrescue`, `qemu-system-x86_64`, `python3`, GNU `as`+`ld` (only for `src/arch/trampoline.S` via `build.zig`; `src/entry.S` + `src/arch/isr.S` go through `addAssemblyFile`). `use_llvm = true`, target `x86_64-freestanding` with `sse3/ssse3/sse4/avx/avx2` removed (SSE/SSE2 stay — don't emit wide vector ops).
- Stale helpers `qemu.sh/bat`, `qemu_vnc.sh/bat` lack `-smp`/`-m 512M`/virtio-blk — use `run.sh`. `create_disk.sh` builds rich `disk.img` via mtools; `run.sh` only `dd`+`mkfs.fat -F 16` (64 MB).
=======
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
>>>>>>> b588c390dec30ac14d775895765ce1109b2ad3db

## Testing — two harnesses

<<<<<<< HEAD
**`tools/test_runner.py`** (the gate): `zig build -Drelease` → patch/rebuild `kernel.iso` → QEMU `-nographic -smp 4 -m 512M -serial stdio` → poll `serial_test.log` for `[USER-HEAP] free + reuse OK` (timeout 45 s), then assert 10 exact substring markers (`tools/test_runner.py:177`):

`[BOOT] Kernel loaded`, `[BOOT] System init done`, `[MEM] Physical memory manager initialized`, `[APIC] Local APIC timer initialized`, `[SMP] AP CPU 1 online`, `[USER] Hello from Ring 3 (user space)!`, `[USER-NET] Created socket via sys_socket`, `[USER-NET] Connected to 10.0.2.2:80 via sys_connect`, `[USER-HEAP] malloc(64)+malloc(128) via SYS_BRK OK`, `[USER-HEAP] free + reuse OK`.

Run after any boot/SMP/syscall/ring3/TCP change. Markers are raw substrings — renaming log strings breaks suite silently. QEMU runs `-d int,cpu_reset -D qemu.log`; read `qemu.log` after triple fault. `run.sh` logs to `-serial stdio`, harness to `serial_test.log`.
=======
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
>>>>>>> b588c390dec30ac14d775895765ce1109b2ad3db

**`tools/e2e_test_suite.py`** (Tiers 1–4, 34 cases, see `TEST_INFRA.md:3` / `TEST_READY.md`):

<<<<<<< HEAD
```bash
python3 tools/e2e_test_suite.py --all             # all tiers
python3 tools/e2e_test_suite.py --tier 1          # 1=smoke, 2=subsystem, 3=USB/HID/Wi-Fi, 4=stress
python3 tools/e2e_test_suite.py -k usb            # filter by id/name/feature (e.g. -k wifi, -k F2.3)
python3 tools/e2e_test_suite.py --all --json out.json
python3 tools/e2e_test_suite.py --list
```
=======
`build.zig` runs the host tool `tools/bin2zig.zig` twice to turn binaries into Zig byte arrays injected as anonymous modules:
- `user_test_bin` ← `src/user/test.zig` built as a freestanding ELF, `image_base = 0x2000000`, entry `_start`. `kernel/init.zig` registers it with `scheduler.addElfUserTask`, so it runs in ring 3 **before the shell on every boot** and exercises write/socket/connect/send/recv/brk. The shell `user` command respawns it on demand via `scheduler.spawnProgramImage`.
- `ap_tramp_bin` ← `src/arch/trampoline.S` (Zig assembler + flat link at 0x8000 + objcopy `.bin`).
>>>>>>> b588c390dec30ac14d775895765ce1109b2ad3db

ISO handling (both runners): patch `kernel.bin` in-place inside existing `kernel.iso` if it fits the slot, else `grub-mkrescue` rebuild; fallback `-kernel zig-out/bin/kernel` only if no ISO. Standalone patcher `tools/patch_iso.py` (used by `run.bat`).

## Codegen — two embedded blobs

`build.zig` runs host tool `tools/bin2zig.zig` → byte arrays injected as anonymous modules:
- `user_test_bin` ← `src/user/test.zig` freestanding ELF (`image_base=0x2000000`, entry `_start`). Registered in `kernel/init.zig` via `scheduler.addElfUserTask` — runs in ring 3 **before shell on every boot** and via shell `user` command; exercises write/socket/connect/send/recv/brk.
- `ap_tramp_bin` ← `src/arch/trampoline.(S|ld)` linked flat at `0x8000`.

Editing either source retriggers codegen on next `zig build`; no manual step.

## Architecture

<<<<<<< HEAD
**Boot:** `src/entry.S` (32-bit multiboot → zero 6 page tables → identity-map 4 GB with 4×512×2 MB pages → long mode) → `kernel_entry` (`src/main.zig:43`): serial → `gdt.init` (ring 3 + TSS) → `vga.initFb(mbi_ptr)` → `system_init` (PIC, IDT) → `syscall64.init` → PMM → VMM → kalloc → VFS/ramfs → `kernel_init.init()` (timer, scheduler) → `pci.scan()` + e1000/rtl8169 probe + `net/mod.zig:init()` → `smp.init()` → `scheduler.runAll()` → `shell.run()`. virtio-blk/FAT16 + USB + mouse + PCI rescan happen in `shell.zig:run`, not during boot — hence `pci.scan()` runs twice.

**Layout:** `src/arch/` (gdt, idt 256 + INT 0x80 DPL3, pic, port, isr.S/isr.zig, acpi MADT, smp+trampoline) · `src/kernel/` (pmm, vmm with COW fault handler, kalloc, scheduler, task, address_space, elf, syscall, init) · `src/system/` (serial, vga, framebuffer/tty/panic, gui) · `src/drivers/` (keyboard IRQ1, timer PIT 100 Hz IRQ0, apic, pci, e1000, rtl8169, mouse, virtio_blk, ahci) + `src/drivers/usb/` (modular stack, see below) · `src/net/` (arp/arp_cache/ip/icmp/tcp/udp/dns/dhcp/http, `mod.zig` is public surface) · `src/fs/` (vfs, ramfs at `/`, blockdev, partition, fat16 at `/mnt/disk`) · `src/programs/` (one file per shell command, dispatched in `src/shell.zig:execute`) · `src/lua/` (lexer/parser→AST, VM) · `src/user/` (ring 3 test ELF + heap).

**Root module pattern:** `src/main.zig` re-exports `serial`, `vga`, `scheduler`, `pmm`, `vmm`, `kalloc`. ~45 files use `const root = @import("root"); const vga = root.vga;` — follow that in new files.
=======
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
>>>>>>> b588c390dec30ac14d775895765ce1109b2ad3db

**Scheduler is not preemptive:** `scheduler.runAll()` runs each registered task to completion (kernel tasks directly, user tasks via `jumpToUser`) then returns to shell. `TIME_SLICE` is assigned but never enforced.

**LAPIC timer is intentionally masked** (`src/drivers/apic.zig:83`) — PIT is the single 100 Hz tick. Unmasked LAPIC on vector 32 double-counted ticks and made `sleep()`/TCP 2× fast. `[APIC] Local APIC timer initialized` is still printed; not "ticking".

<<<<<<< HEAD
**SMP:** `smp.init()` parses ACPI/MADT for LAPIC IDs, then INIT-SIPI-SIPI. SIPI mode is ICR bits 10:8 = `6` → `(6 << 8) | (0x8000 >> 12)` — not `0x6000`. Trampoline copied to `0x8000` with cells at `0x600` (GDT), `0x610` (IDT), `0x700` (PML4), `0x708` (stack top), `0x710` (index), `0x718` (entry). Each AP gets 16 KB stack, idle-loops in `ap_entry`. Wrong layout/ICR → APs silently never come online (`[SMP] AP CPU 1 online` missing). Shell: `smp`/`cpuinfo`.

## User-space (ring 3)

- **GDT selectors** (`src/arch/gdt.zig`): `0x08` kcode, `0x10` kdata, `0x18|3` ucode, `0x20|3` udata, `0x40` TSS; `0x28`/`0x30` unused dups. Now per-CPU GDT/TSS (`gdt_per_cpu`/`tss_per_cpu`, `MAX_CPUS=64`, `initCpu`/`setRsp0ForCpu`).
- **Syscalls:** `syscall` instruction (MSR `LSTAR` → `arch/syscall64.zig:syscall_entry_64`) and legacy `INT 0x80`, `rax`=num, args `rdi/rsi/rdx`. Numbers in `src/kernel/syscall.zig:15`. Implemented: write=1 (fd 1–2 VGA, 3 serial), read=2 (fd 0 keyboard), sleep=10, time=11, brk=12, fork=57 (COW clone), exec=59 (ELF from VFS path), exit=60, waitpid=61, socket/connect/send/recv=70–73. `SYS_OPEN=3`/`SYS_CLOSE=4` exist but return `ENOSYS` (-38). `IA32_FMASK` masks `TF|IF|DF|NT|AC` on entry so interrupts are off before stack switch.
- Fault isolation (`src/arch/isr.zig`): exceptions in ring 3 (CS.RPL=3) terminate the task via `process.exitCurrent(-11)` instead of kernel panic.
- Per-task: 8 TCP slots (`src/kernel/task.zig:57`), heap at `USER_HEAP_BASE=0x04000000` grown page-wise by `brk` (`src/user/heap.zig` free-list malloc).
- **Address spaces** (`src/kernel/address_space.zig`): per-task PML4, `PAGE_USER`, `destroy()` frees user pages.
=======
**SMP:** `smp.init()` parses ACPI/MADT for LAPIC IDs, then INIT-SIPI-SIPI. SIPI delivery mode lives in ICR bits 10:8 (`(6 << 8) | (0x8000 >> 12)`, **not** the `0x6000` form — see `src/arch/smp.zig:30`). The trampoline is copied to 0x8000 with fixed control cells at 0x600 (GDT desc), 0x610 (IDT desc), 0x700 (PML4), 0x708 (stack top), 0x710 (index), 0x718 (entry). Each AP gets a 16 KB stack and idle-loops in `ap_entry`. A wrong cell layout or ICR encoding makes APs silently never come online — the only signal is the missing `[SMP] AP CPU 1 online`. Shell: `smp`, `cpuinfo`.

## Foreign binaries (binfmt personalities)

`kernel/binfmt.zig` sniffs `\x7fELF` vs `MZ`/PE and dispatches `load()` to `elf.load` or `pe.load`. Each image carries a **personality** that decides its kernel ABI:

- **ELF64 static** (`ET_EXEC` and static-PIE `ET_DYN`) → personality `.linux`. These enter the kernel with the `syscall` instruction, not INT 0x80: `arch/syscall64.zig` sets IA32_LSTAR to the `syscall_entry_64` stub in `isr.S`, which builds an InterruptFrame-compatible frame on the task's kernel stack and returns via `iretq`, so the C-side handler is shared with the INT 0x80 path. FMASK=0 keeps IF set — masking it would hang every blocking wait. `syscall_kernel_rsp` must be updated per task alongside TSS.RSP0.
- **PE32+ console x86-64** → personality `.windows`. Imports are resolved to 8-byte thunks (`mov eax, imm32; int 0x81; ret`) mapped at `WIN_THUNK_BASE`; `winapi.win_thunk_handler` services vector **0x81** (deliberately distinct from 0x80).
- Dynamically linked images are rejected with a clear error (no runtime loader exists).

`syscall_handler` (`kernel/syscall.zig:65`) routes by the current task's personality. The native and Linux tables must stay separate — numbers collide with different meanings (1=write in both, but 2=read natively vs open in Linux). A PE task issuing a raw syscall is terminated.

**Linux ABI coverage worth knowing:** directories open into a `.dir` FileDesc (path remembered inline in `task.DirDesc`, cursor inside) so `getdents64` works — `vfs.readdir` enumerates by path, not handle. `chdir`/`getcwd` hit the real VFS CWD. `pipe`/`pipe2` return ENOSYS honestly instead of handing out dead fds. `fcntl(F_DUPFD)` really duplicates. `sysinfo` fills totalram/freeram/procs from PMM/scheduler. Still fake-but-harmless: poll/select always "ready", munmap/mprotect are no-ops, fork/vfork/clone are NOT implemented (musl system() will fail).

**Win32 coverage:** environment is fully wired — `GetEnvironmentVariableA` and `GetEnvironmentStringsW` both read `system/env.zig` (the block is built in fresh anonymous user memory). Console I/O goes through fdtable; files through VFS handles encoded in pseudo-handle values ≥ 0xF0001000. PE tasks get a fake TEB (GS_BASE → zeroed pages; CRT startup derefs `gs:[0x30]`) and a per-task `crt_block` in user memory backing the UCRT `__p__*` accessors. A UCRT subset lives in winapi.zig: startup no-ops, stdio over pseudo-FILE* (`STREAM_BASE+fd`, `__acrt_iob_func`), a C-printf engine (`cFormat`) driven by both register varargs and MSVC `va_list` structures (`__stdio_common_vfprintf/vsprintf`), string/memory/wcs helpers, `_open/_read/_write/_close` on VFS fds, and WinSock 2 basics. Math functions taking double args are NOT bindable — InterruptFrame has no XMM state. Real-app test matrix: `tools/fetch_apps.py` downloads static musl Linux binaries + console PEs into `samples/apps`; `create_test_disk.py` copies them onto disk.img under 8.3 aliases (coreutils→`cu`/`ls`, hello_linux→`hl`). Drive them headless with `boot_watch.py <sec> disk cmd:"exec /mnt/disk/..."`. Known blockers: fork-less kernel hangs busybox sh on external commands; a rare second-spawn hang inside file read (see TODO Foreign binaries).

## User-space (ring 3)

- **GDT selectors** (`src/arch/gdt.zig`): 0x08 kernel code, 0x10 kernel data, `0x18|3` user code, `0x20|3` user data, 0x40 TSS; 0x28/0x30 are unused duplicate kernel segments.
- **Native syscalls:** INT 0x80, `rax` = number, args in `rdi`/`rsi`/`rdx`. Numbers in `src/kernel/syscall.zig:17`. Implemented: write=1 (fd 1–2 → VGA, 3 → serial), read=2 (fd 0 → keyboard), sleep=10, time=11, brk=12, fork=57 (COW clone), exec=59 (ELF **or PE** from a VFS path), exit=60, waitpid=61, socket/connect/send/recv=70–73. `SYS_OPEN=3` and `SYS_CLOSE=4` exist in the enum but fall through the `else` arm to ENOSYS (-38).
- Per-task state: 8 TCP socket slots (`src/kernel/task.zig:108`), user heap at `USER_HEAP_BASE = 0x04000000` grown page-wise by `brk`. `src/user/heap.zig` is the ring-3 free-list malloc built on `brk`.
- **Address spaces** (`src/kernel/address_space.zig`): per-task PML4, create/destroy/switch, user pages mapped `PAGE_USER`; `destroy()` frees user physical pages.
>>>>>>> b588c390dec30ac14d775895765ce1109b2ad3db

## USB subsystem

<<<<<<< HEAD
Modular stack under `src/drivers/usb/` — `usb.zig` is a thin re-export shim, real logic in `usb/mod.zig`:

- `types.zig` — descriptors, speeds, setup packets; `dma.zig` — PMM-backed 16/32/64 B aligned DMA pool; `pci_detect.zig` — PCI BAR + bus-master scan for UHCI/EHCI/xHCI; `uhci.zig`/`ehci.zig`/`xhci.zig` — controller drivers (frame lists/QH·qTD/TRB rings/DCBAA/doorbells); `device.zig` — enumeration pipeline (GET_DESCRIPTOR→SET_ADDRESS→config parse→SET_CONFIGURATION→HID SET_PROTOCOL/SET_IDLE) with bounds check `desc_len < 2 or off+desc_len > total` + composite multi-interface parsing (`MAX_DEVICE_INTERFACES=4`); `hid.zig` — Boot/Report protocol, wireless dongle profile table, `decodeKeyboardReport`/`decodeMouseReport`.
- `mod.zig:init()` scans PCI, initializes each controller instance (separate arrays: 4×UHCI, 2×EHCI, 2×xHCI, `MAX_USB_CONTROLLERS=8`, `MAX_USB_DEVICES=8`), enumerates ports via `device.enumerateDevice` over `uhciCtrlTransferWrapper`, splits composite wireless receivers into secondary devices (keyboard+mouse on one dongle), builds UHCI frame-list schedule (`relinkUhciControllerSchedule`). `poll()` is non-blocking (re-arms interrupt TD if `ACTIVE` cleared, routes via `hid` → `keyboard.pushKey()` / `mouse.updateFromUsb()`).
- Init is called from `shell.run` (`usb_drv.init()`), not `kernel_entry`; `usb.poll()` must be wired into the main loop/tick if you want live input.
- Diagnostics: `src/programs/usb.zig` → shell `usb`/`lsusb` → `usb.printUsbStatus`. QEMU profiles: `-device ich9-usb-uhci1` + `usb-kbd`/`usb-mouse`, `-device qemu-xhci`, `-device ich9-usb-ehci1`. Multi-controller tested in `e2e_test_suite.py:TC-USB-03`/`TC-STRESS-01`.

## Net / storage / display gotchas

- **NIC abstraction:** `src/net/mod.zig` routes all TX/RX through `net.sendFrame`/`receiveFrame` dispatching on `active_nic` (`.e1000` or `.rtl8169`; `.none` if absent). `our_ip=10.0.2.15/24`, `gateway=10.0.2.2`, `dns=10.0.2.3` (DHCP `dhcp` overwrites). `nextHopMac()` picks on-link vs gateway MAC, ARPs with 3×500 ms retries via `ensureArp`; returns `null` (drop) instead of broadcast when unresolved, and polling-aware (inside handler only fires ARP, doesn't wait) with re-entrancy guard.
- **Polling, not IRQs:** e1000 IRQs masked intentionally; `net.poll()` drains up to 32 RX descriptors and is called from `ensureArp`/`waitEstablished`/`dns`/`http`/`sys_recv`. `net.tick()` (ARP aging + TCP retx) runs from `scheduler.scheduleTick` 1 Hz.
- **e1000 bits:** RCTL bit 15 = BAM (broadcast, needed for DHCP), bit 3 = UPE not BAM, bit 6 = loopback not BSIZE; BSIZE=2048 is default (17:16=00, BSEX clear); TX descriptors need RS (0x08) for DD, RDT = recycled index not next. Named constants at top of `src/drivers/e1000.zig`; `e1000.debug_trace` off by default (per-packet dumps break timing).
- **IP length trimming:** `ip.handlePacket` trims to `total_len` — Ethernet pads to 60 B. TCP/UDP/ICMP derive payload from that slice.
- **TCP minimal:** MSS 1440, sender splits; single retransmit slot; ISN per conn; SYN retried 3× in `waitEstablished`; in-order only (out-of-order re-ACKed, not buffered). Checksums after payload is in buffer (`buildTcpHeader` takes whole segment).
- **Disk/FAT16:** `run.sh` creates 64 MB FAT16 `disk.img` if missing; `virtio_blk.init()` + `ahci.init()` + `partition.scanAll()` + `fat16.init()` auto-mount at `/mnt/disk` at shell start. Without block device, `ls/cat/cd/touch/mkdir/rm/write/save` hit ramfs at `/` and you get `[FAT16] No block device found`. FAT16 handle recycling and VFS BSS guard (`vfs.isStaticHandle` prevents `kfree` on `open_files` BSS) are fixed.
- **Framebuffer/GUI:** `src/entry.S` requests 1024×768×32 (multiboot VIDEO flag). If present, `vga.isFbActive()` → `gui`/`resolution <WxH>`/`mouse` work. `framebuffer.zig` is shadow buffer + dirty-rect `flush()`; `gui.zig` is draggable windows (Esc quits). Console shell stays VGA text. GUI needs framebuffer VM — harness runs `-nographic` so can't test it there.
- **Shell commands:** adding one needs 4 edits in `src/shell.zig`: import `src/programs/<name>.zig`, branch in `execute`, line in `printHelp`, entry in `commands[]` (tab-completion source). Missing the array leaves command working but uncompletable.

## Kernel / toolchain conventions

- No std I/O in kernel: VGA is UI, serial `/dev/ttyS0` is debug. `src/main.zig:panic` does VGA+serial+`system/panic.zig:printBacktrace` then `hlt`; std panic unused. `kernel_entry`, `syscall_handler`, `sys_exit_return`, `syscall_entry_64` are `export callconv(.c)` for asm ABI. Inline asm clobber syntax `: .{ .rax = true, .memory = true }` (Zig 0.16).
- `kalloc` never coalesces non-contiguous chunks (physical contiguity check: `block_end == @intFromPtr(next)`).
- `.gitignore` covers `.zig-cache/`, `zig-out/`, `isodir/`, `build/`, `kernel.iso`, `qemu.log`, `serial*.log`, `disk.img`, `*.img`. Artifacts committed before those rules remain tracked — don't add more.
- Docs: `README.md` is cosmetic. `AGENTS.md` + `TODO.md` (real gaps) are working docs. Milestone/task spec lives in `promtpt.txt` (and copied `PROJECT.md` under `.agents/` if present); full test matrix in `TEST_INFRA.md`.

## Lua

`lua` shell command (`src/programs/lua.zig`, 128 KB `FixedBufferAllocator`). Bindings in `src/lua/api.zig`, registered in `vm.zig:VM.init`: `print`, `type`, `tostring`, `tonumber`, `assert`, `error`, `ipairs`, `pairs`, `vga_write`, `serial_write`, `sleep`, `read_key`, `time`, plus `math.*`/`string.*`. Add new bindings there. `function` definitions via `vm.callFunction`. No modules/stdlib beyond that.
=======
- **Disk/FAT16:** `run.bat`/`run.sh` create a raw `disk.img` if missing; `virtio_blk.init()` + `fat16.init()` run at boot and **auto-format blank disks** (`fat16.format()` writes BPB + FATs + root dir in-kernel, then mounts at `/mnt/disk`) — no host-side mkfs needed. `mkfs` reformats on demand, `df` shows usage. Without a block device the file commands hit ramfs at `/`.
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
>>>>>>> b588c390dec30ac14d775895765ce1109b2ad3db
