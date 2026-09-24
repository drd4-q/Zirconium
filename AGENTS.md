# AGENTS.md — Zirconium

Bare-metal x86_64 OS kernel in Zig: Multiboot/GRUB boot, identity-mapped 2 MB pages (first 64 GB), SMP via ACPI MADT + AP trampoline, VGA-text shell + framebuffer GUI, custom TCP/IP over e1000/rtl8169/USB-Wi-Fi, VFS (ramfs + FAT16 over virtio-blk), ring 3 with native INT 0x80 syscalls **and** foreign binaries (static Linux ELF via the `syscall` instruction, Win32 PE32+ via INT 0x81 thunks), a modular USB stack with a unified HID/input layer, a minimal Lua interpreter, and a small dillo web browser. QEMU is primary; `create_usb.sh` targets real hardware.

## Build & run

```bash
zig build                          # Debug production kernel → zig-out/bin/kernel
zig build -Drelease                # ReleaseFast production kernel
zig build -Drelease -Dselftest=true # ReleaseFast with the embedded ring-3 self-test
./build_iso.sh                     # production kernel + ISO, without QEMU/disk setup
./run.sh                           # build -Drelease → grub-mkrescue ISO → QEMU (gtk)
./run.sh --vnc       # VNC on host port 5901 instead of gtk
./run.sh --gdb       # QEMU -s -S; attach gdb to localhost:1234
./run.sh --test      # = python3 tools/test_runner.py (the gate harness)
run.bat              # Windows equivalent (patch_iso.py / qemu-img / fsutil fallbacks)
./test_prog.sh       # rebuild disk.img with test executables (see below)
```

- **Zig 0.16.0 required.** `build.zig.zon` still says `minimum_zig_version = "0.14.0"` — stale; `tools/bin2zig.zig` uses 0.16-only std APIs (`std.process.Init`, `std.Io.Dir`, …).
- `zig build` exposes only the default `install` step and `build`. **There is no `zig build test` and no unit tests anywhere** — verification is the QEMU harness only (below). Full clean build ≈8 s, so always rebuild before claiming anything.
- `-Drelease` is required for ReleaseFast: `standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast })` only honors the preference when the flag is passed; without it you get Debug.
- Release enables `--gc-sections`, so `linker.ld` must keep `KEEP(*(.multiboot))` for `src/entry.S`'s header. Break it and Debug still boots while release fails in GRUB with "no multiboot header found".
- **Toolchain:** `grub-mkrescue`, `qemu-system-x86_64`, `python3`. All assembly (`entry.S`, `isr.S`, `trampoline.S`) goes through Zig's own assembler (`addAssemblyFile`) — no GNU as/ld anywhere. The AP trampoline links flat at 0x8000 via `src/arch/trampoline.ld` and becomes a blob with `addObjCopy(.{ .format = .bin })`. Kernel needs `use_llvm = true`; target `x86_64-freestanding` with `sse3/ssse3/sse4_1/sse4_2/avx/avx2` removed via `cpu_features_sub` (SSE/SSE2 stay — don't emit wide vector ops).
- Disk: `run.sh` creates a 64 MB `disk.img` + `mkfs.fat -F 16` when missing (leaves it raw if mkfs.fat is absent — format in-guest with `mkfs`). `create_disk.sh` builds a test disk via mtools (`mformat`/`mcopy`).

## Testing — two harnesses

**`tools/test_runner.py`** (the gate): runs `zig build -Drelease -Dselftest=true`, gets the kernel into `kernel.iso` (patches `kernel.bin` in place if the new binary fits the old slot, else rebuilds with `grub-mkrescue` incl. a WSL fallback; with no ISO at all it boots `-kernel zig-out/bin/kernel` — standalone patcher `tools/patch_iso.py`, used by `run.bat`). Then boots QEMU headless:

```
-cdrom kernel.iso -boot d -m 512M -smp 4 -display none -serial stdio
-netdev user,id=net0 -device e1000,... -no-reboot
```

**No disk, no framebuffer, no `-d int`.** It reads serial, waits up to **45 s** for the terminal marker `[USER-HEAP] free + reuse OK`, writes everything to `serial_test.log`, then asserts the 10 raw substrings in `expected_matches` (`tools/test_runner.py:178`):

`[BOOT] Kernel loaded`, `[BOOT] System init done`, `[MEM] Physical memory manager initialized`, `[APIC] Local APIC timer initialized`, `[SMP] AP CPU 1 online`, `[USER] Hello from Ring 3 (user space)!`, `[USER-NET] Created socket via sys_socket`, `[USER-NET] Connected to 10.0.2.2:80 via sys_connect`, `[USER-HEAP] malloc(64)+malloc(128) via SYS_BRK OK`, `[USER-HEAP] free + reuse OK`.

- The same 10 markers are re-asserted by e2e `TC-REGR-01`. Markers are **raw substrings** — renaming a kernel log string silently breaks both suites.
- Crash triage: only `run.sh` passes `-d int,cpu_reset -D qemu.log` (and attaches disk/USB devices); read `qemu.log` after a triple fault. `run.sh` sends serial to the terminal, the harness to `serial_test.log`.
- Run the gate after any change touching boot, SMP bring-up, syscalls, ring 3, or the TCP client path. It cannot see the shell UI, GUI, FAT16 contents, or foreign binaries.

**`tools/e2e_test_suite.py`** — **37 cases** in 4 tiers (1=smoke×5, 2=subsystem×7, 3=USB/HID/Wi-Fi×20, 4=stress×5; feature matrix in `TEST_INFRA.md` / `TEST_READY.md`):

```bash
python3 tools/e2e_test_suite.py --all             # all tiers
python3 tools/e2e_test_suite.py --tier 2          # 1=smoke, 2=subsystem, 3=USB/HID/Wi-Fi, 4=stress
python3 tools/e2e_test_suite.py -k usb            # filter by id/name/feature (e.g. -k wifi, -k F2.3)
python3 tools/e2e_test_suite.py --all --json out.json
python3 tools/e2e_test_suite.py --list
```

It boots several QEMU profiles through its `get_*_log` helpers: baseline, UHCI+HID, multi-controller USB, and — when `disk.img` exists — one with `-drive file=disk.img,if=virtio` (`TC-VFS-02`).

## Test programs & samples

- `samples/` holds committed fixtures: `busybox` (static musl multi-call ELF), `hello_linux` (+ `.zig` source), `hello.exe` / `hello_win.exe` (PE32+, source `hello_win.zig`). Rebuild them with plain `zig build-exe -target x86_64-{freestanding,windows}` per `tools/create_test_disk.py`.
- `test_prog.sh|bat` → `python3 tools/create_test_disk.py`: downloads busybox from busybox.net, compiles the samples, writes a fresh 64 MB FAT16 `disk.img` (needs mtools: `mformat`/`mcopy`, native or WSL).
- `tools/fetch_apps.py` downloads real apps into `samples/apps/` (busybox, uutils coreutils, jq.exe, curl.exe, …); `create_test_disk.py` copies them onto `disk.img` under 8.3 aliases (coreutils→`cu` and `ls`, hello_linux→`hl` — no LFN support).
- In the guest these appear at `/mnt/disk/...`. Run them via `exec /mnt/disk/hello.exe`, `exec /mnt/disk/busybox uname -a`, **or just type the name** — unknown commands fall through to `resolveExecutablePath` in `src/shell.zig`.
- `tools/boot_watch.py <seconds> [disk] [cmd:"shell command" ...]` boots the ISO headless, drives the shell over serial (full log → `ser_capture.log`), and takes a QMP screendump → `screen.ppm`. This is how you exercise disk/foreign-binary/GUI behavior outside the gate.
- `tools/create_fat32_disk.py --output fat32-test.img --size-mb 1024` creates a sparse MBR/FAT32 fixture without host `mtools`; `tools/test_fat32_log.py` boots it and checks mount, `KERNEL.LOG`, nested directories, append/copy, and a cluster above `0xFFFF`.
- `create_usb.sh [device]` writes `kernel.iso` to a USB stick for bare-metal boot (Legacy/CSM GRUB, Secure Boot off; Ventoy also works).

## Codegen — two embedded blobs

`build.zig` runs the host tool `tools/bin2zig.zig` twice, turning binaries into Zig byte arrays injected as anonymous modules:

- `user_test_bin` ← `src/user/test.zig` built as a freestanding ELF (`image_base = 0x2000000`, entry `_start`). With `-Dselftest=true`, `kernel/init.zig` registers it via `scheduler.addElfUserTask`, so it runs in ring 3 **before the shell** and exercises write/socket/connect/send/recv/brk; production builds skip only this automatic task, while the shell `user` command can still respawn it.
- `ap_tramp_bin` ← `src/arch/trampoline.S` (Zig assembler, flat link at 0x8000 via `trampoline.ld`, `objcopy` to `.bin`).

Editing either source retriggers codegen on the next `zig build`; no manual step.

## Architecture

**Boot:** `src/entry.S` (32-bit multiboot entry → zeroes `.bss` → identity-maps the first 64 GB with 64 PDs × 512 × 2 MB pages → long mode) → `kernel_entry` (`src/main.zig:43`): serial → `gdt.init` (ring 3 segments + per-CPU TSS) → `vga.initFb(mbi_ptr)` → `system_init.init` (PIC, IDT) → `syscall64.init()` (MSRs enabling the `syscall` instruction) → PMM → VMM → kalloc → VFS + ramfs mount + `seedfs.init()` (writes static `/etc/*`, `/proc/*`, `/sys/*` snapshots into ramfs — there is no real procfs) → `kernel_init.init()` (timer, scheduler; registers the embedded ring-3 user test only with `-Dselftest=true`) → one `pci.scan()` + e1000-**or**-rtl8169 probe + lazy/selftest-aware `net/mod.zig.init()` → one storage/input pass: `virtio_blk.init()`, `ahci.init()`, `usb.zig.init()`, `partition.scanAll()`, FAT16/FAT32 probe, `kernel_log.init()`, `mouse.init()` → `smp.init()` → `scheduler.runAll()` → shell. The shell no longer repeats PCI/storage initialization; the raw USB `mod.init()` remains a guarded compatibility call.

**Layout:**
- `src/arch/` — gdt (per-CPU GDT/TSS, `MAX_CPUS=64`), idt (256 entries; INT 0x80 **and** the Win32 INT 0x81 thunk gate, both DPL 3), pic, port, isr (`isr.S` + `isr.zig`; `isr.S` also defines `syscall_entry_64` and `sys_exit_return`), acpi (MADT scan), smp + `trampoline.S/.ld`, msr, syscall64 (STAR/LSTAR/FMASK/SCE MSRs).
- `src/kernel/` — pmm, vmm (incl. COW fault resolution), kalloc, scheduler, task, address_space, elf (ELF64 loader), pe (PE32+ loader), binfmt (format sniffing + personalities), linux_syscalls (Linux ABI table), winapi (Win32 emulation), fdtable, uaccess, process, seedfs, syscall, init.
- `src/system/` — serial, vga, framebuffer, gui, tty, init, panic.
- `src/system/env.zig` — kernel-wide KEY=VALUE environment table; the shell manages it (`set`/`unset`/`env`, `echo` with `$KEY` expansion) and Win32 PE programs read it via emulated `GetEnvironmentVariableA`/`GetEnvironmentStringsW`. Static storage, no allocation.
- `src/drivers/` — keyboard (IRQ1), mouse (PS/2), input (unified input facade, see USB), timer, apic, pci, e1000, rtl8169, virtio_blk, ahci, xhci (poll-based xHCI HID drain behind `usb.zig:pollHid`), usb (re-export shim) + `usb/` (16-file stack, see below).
- `src/net/` — arp, arp_cache, ip, icmp, tcp, udp, dns, dhcp, http; `mod.zig` is the public surface **and** the NIC dispatcher.
- `src/fs/` — vfs (including append flags and cursor-aware directory reads), ramfs (mounted at `/` plus `/dev`, `/tmp`, `/etc`), blockdev, partition (MBR/GPT), fat16 (legacy `/mnt/disk` fallback), fat32 (512-byte-sector, 8.3-name MVP).
- `src/programs/` — one file per shell command (dispatch via `command_table` in `shell.zig`) plus the dillo browser package `dillo/` (browser, css, entities, html, layout, mod, url) and its engines `dillo_engine.zig` / `js_engine.zig`.
- `src/lua/` — lexer, parser, ast, value, vm, api; `mod.zig` re-exports.
- `src/user/` — ring-3 test ELF + heap.

**Root module pattern:** `src/main.zig` is the root and re-exports `serial`, `vga`, `scheduler`, `pmm`, `vmm`, `kalloc`, `tty`. Most files reach them via `const root = @import("root"); const vga = root.vga;` rather than relative imports — follow that in new files.

**Scheduler is not preemptive:** `scheduler.runAll()` runs each registered task to completion (kernel tasks directly, user tasks via `jumpToUser`) then returns to the shell. `TIME_SLICE` (10 ticks) is assigned to tasks but never enforced.

**Tick source is the LAPIC timer, not the PIT:** `apic.zig` calibrates the local APIC timer against a one-shot PIT pulse, then runs it periodic on **vector 32 at 100 Hz** and masks legacy PIT IRQ 0 in the 8259 PIC (`pic.mask(0)`) so exactly one source ticks. `[APIC] Local APIC timer initialized …` is still printed each boot (it is a harness marker). `timer.ticks` (100 Hz) drives `sleep()`, TCP deadlines, and `uptime`.

**SMP:** `smp.init()` parses ACPI/MADT for LAPIC IDs, then INIT-SIPI-SIPI. SIPI delivery mode lives in ICR bits 10:8 — `(6 << 8) | (0x8000 >> 12)`, **not** the `0x6000` form (`src/arch/smp.zig`). The trampoline is copied to 0x8000 with fixed control cells at 0x600 (GDT desc), 0x610 (IDT desc), 0x700 (PML4), 0x708 (stack top), 0x710 (CPU index), 0x718 (entry). Each AP gets a 16 KB stack and idle-loops in `ap_entry`. A wrong cell layout or ICR encoding makes APs silently never come online — the only signal is the missing `[SMP] AP CPU 1 online`. Shell: `smp`, `cpuinfo`.

## Foreign binaries (binfmt personalities)

`kernel/binfmt.zig` sniffs `\x7fELF` vs `MZ`/PE and dispatches `load()` to `elf.load` or `pe.load`. Each image carries a **personality** that decides its kernel ABI:

- **ELF64 static** (`ET_EXEC` and static-PIE `ET_DYN`) → personality `.linux`. These enter the kernel with the `syscall` instruction, not INT 0x80: `arch/syscall64.zig` sets IA32_LSTAR to the `syscall_entry_64` stub in `isr.S`, which builds an InterruptFrame-compatible frame on the task's kernel stack and returns via `iretq`, so the C-side handler is shared with the INT 0x80 path. `syscall_kernel_rsp` must be kept in sync with TSS.RSP0 per task (`scheduler.jumpToUser`).
- **PE32+ console x86-64** → personality `.windows`. Imports resolve to 8-byte thunks (`mov eax, imm32; int 0x81; ret`, `THUNK_SIZE=8`) mapped at `WIN_THUNK_BASE=0x0F000000` (`kernel/task.zig:39`); `winapi.win_thunk_handler` services vector **0x81** (registered DPL 3 in `idt.zig`, deliberately distinct from 0x80).
- Dynamically linked images are rejected with a clear error (no runtime loader exists; e.g. glibc-dynamic fastfetch).

`syscall_handler` (`kernel/syscall.zig:65`) routes by the current task's personality (`switch (t.personality)`: `.linux` → `linux_syscalls.dispatch`, `.windows` → terminate the task, `.native` → `nativeDispatch`). The native and Linux tables must stay separate — numbers collide with different meanings (1=write in both, but 2=read natively vs open in Linux).

**Linux ABI coverage:** `getdents64` works because directories open into a `.dir` FileDesc (`task.DirDesc` remembers path + cursor; `vfs.readdir` enumerates by path). `chdir`/`getcwd` hit the real VFS CWD. `sysinfo` fills totals from PMM/scheduler. `fcntl(F_DUPFD)` really duplicates. `pipe`/`pipe2` return ENOSYS honestly. Fake-but-harmless: `poll`/`select` always return "ready", `mprotect` returns 0 (all pages already RW), `munmap` returns 0 (memory reclaimed on exit). **`fork`/`vfork`/`clone` are NOT implemented for this personality** — musl `system()` and busybox `sh` hang on the first external command (see TODO "Foreign binaries").

**Win32 coverage:** console I/O goes through fdtable, files through VFS handles; environment via `system/env.zig`. PE tasks get a fake TEB (GS_BASE → zeroed pages; CRT startup reads `gs:[0x30]`) and a per-task CRT globals block in user memory. UCRT subset in `winapi.zig`: startup no-ops, stdio over pseudo-FILE*, a C-printf engine driven both by Win64 register varargs (rdx/r8/r9 + stack) and MSVC `va_list` structures (`__stdio_common_vfprintf/vsprintf`), string/memory/wcs helpers, `_open/_read/_write/_close` on VFS fds, WinSock 2 basics. **Math functions taking double args are NOT bindable** — the InterruptFrame has no XMM state. Real-app status (TODO): busybox ✓, uutils coreutils ✓ (`ls`, `cu`), jq.exe loads but crashes late-CRT, curl.exe/rg.exe hit unimplemented imports.

## User-space (ring 3)

- **GDT selectors** (`src/arch/gdt.zig`): `0x08` kernel code, `0x10` kernel data, `0x18|3` user code, `0x20|3` user data, `0x40` TSS; `0x28`/`0x30` unused duplicates. Per-CPU GDT/TSS: `gdt_per_cpu`/`tss_per_cpu`, `MAX_CPUS=64`, `setRsp0ForCpu`.
- **Two entry paths into the kernel:** legacy `INT 0x80` (native ABI) and the `syscall` instruction (LSTAR → `syscall_entry_64`, used by the `.linux` personality). Args: `rax`=number, `rdi/rsi/rdx`. Native numbers in `src/kernel/syscall.zig:17`. Implemented: write=1 (fd 1–2 → VGA, 3 → serial), read=2 (fd 0 → keyboard), sleep=10, time=11, brk=12, fork=57 (COW clone — but forked children are never scheduled under the cooperative scheduler, so fork+exec doesn't complete yet), exec=59 (ELF **or PE** from a VFS path), exit=60, waitpid=61, socket/connect/send/recv=70–73. `SYS_OPEN=3`/`SYS_CLOSE=4` exist in the enum but return ENOSYS (-38); unknown numbers are rejected via `isKnownNative` (ENOSYS + serial log) instead of tripping `@enumFromInt` UB.
- **IA32_FMASK** masks `TF|IF|DF|NT|AC` on `syscall` entry (`syscall64.zig:29-32`) so interrupts are off before the stack switch to kernel RSP.
- Fault isolation (`src/arch/isr.zig:140`): exceptions in ring 3 (CS.RPL=3) terminate the task via `process.exitCurrent(-11)` instead of panicking the kernel.
- Per-task state: 8 TCP socket slots (`sockets` field in `kernel/task.zig`), user heap at `USER_HEAP_BASE = 0x04000000` (`task.zig:31`) grown page-wise by `brk`; `src/user/heap.zig` is the ring-3 free-list malloc built on `brk`.
- **Address spaces** (`src/kernel/address_space.zig`): per-task PML4, create/destroy/switch, user pages mapped `PAGE_USER`; `destroy()` frees user physical pages.

## USB subsystem

Modular stack under `src/drivers/usb/` (16 files); `src/drivers/usb.zig` is a re-export shim that mirrors `mod.zig`'s controller/device arrays (`syncState`), keeps compat accessors, and adds `pollHid()`.

- **Controllers:** `uhci.zig`, `ehci.zig`, `xhci.zig` — **4 instances each**, `MAX_USB_CONTROLLERS=12`, `MAX_USB_DEVICES=16` (`usb/mod.zig:35-36`). PCI discovery + bus mastering in `pci_detect.zig`, PMM-backed aligned DMA pool in `dma.zig`, descriptors/setup packets in `types.zig`.
- **Enumeration:** `device.zig` — GET_DESCRIPTOR → SET_ADDRESS → config parse → SET_CONFIGURATION, bounds-checked, composite multi-interface up to `MAX_DEVICE_INTERFACES=4`; `hub.zig` handles hubs. `mod.zig:init()` does the PCI scan and re-scans **reset the instance counters** on every call.
- **Unified HID stack** (modeled on Linux): `usbhid.zig` = transport, `hid_core.zig` = device lifecycle + cyclic polling + report dispatch (registered from `mod.zig` via `hid_core.registerHidDevice` / `processRawDeviceReport`), `hid_generic.zig` = binds class 0x03 devices, `hid_input.zig` = usage-page → keycode/mouse mapping incl. Num/Caps/Scroll-Lock LED state. Legacy `hid.zig` still does boot-protocol report decoding and 2.4 GHz wireless-dongle profiles (`hid.isWirelessDongle` is called from `device.zig`).
- **Unified input layer:** `src/drivers/input.zig` gives one API over USB HID keyboards/mice (wired + wireless dongles) and legacy PS/2 (kbd IRQ1, mouse IRQ12), re-exporting the key constants, and calls `usb.poll()` itself.
- **Wi-Fi:** `rtl8188eu.zig` registers as `NicType.usb_wifi` and TX/RX through `net/mod.zig`. **Storage:** `storage.zig` (mass storage; `usb storage` subcommand).
- **Everything polls — no USB IRQs.** Call sites: `input.zig` → `usb.poll()`; `scheduler.scheduleTick` → `usb.poll()` + `pollHid()` (xHCI drain lives in the separate `drivers/xhci.zig`, which is fully interrupt-free). Beware: two xHCI-related files exist — `usb/xhci.zig` (controller driver in the modular stack) and `drivers/xhci.zig` (poll-based HID drain behind `usb.zig:pollHid`).
- **Diagnostics:** shell `usb`/`lsusb` → `src/programs/usb.zig` → `usb.printUsbStatus(...)`. QEMU: `run.sh` adds `-device qemu-xhci -device usb-kbd -device usb-tablet`; the e2e suite boots extra profiles (UHCI+HID, multi-controller) via its `get_uhci_hid_log`/`get_multi_usb_log` helpers. Coverage: `TC-USB-01..07`, `TC-HID-01..05`, `TC-WIFI-01..05`, `TC-DIAG-01..03`, `TC-STRESS-01/04`.

## Net / storage / display gotchas

- **NIC abstraction:** `src/net/mod.zig` routes all TX/RX through `net.sendFrame`/`receiveFrame` dispatching on `active_nic` (`.e1000`, `.rtl8169`, `.usb_wifi`; `.none` if absent — `hasNic()` gates everything).
- **Network is client-only:** static IP 10.0.2.15/24, gateway 10.0.2.2, DNS 10.0.2.3 (`dhcp` overwrites all three from a lease). `net.nextHopMac()` picks the destination MAC (on-link host vs gateway) and **drops the packet when ARP fails**, so `get`/`wget` reach the internet through QEMU's slirp. `ensureArp` retries 3× with a 500 ms deadline per attempt, polling inside the wait. Nothing listens on guest:80 — `run.sh`'s "open http://localhost:8080" hostfwd message is misleading.
- **The stack polls, it does not use IRQs.** e1000 interrupts are masked on purpose; `net.poll()` drains the RX ring from the blocking paths (`ensureArp`, `waitEstablished`, `dns.resolve`, `http`, `sys_recv`). `net.tick()` (ARP cache aging + TCP retransmit) runs from `scheduler.scheduleTick` at 1 Hz. `poll()` has a re-entrancy guard because handlers transmit and transmitting can ARP; inside a handler `nextHopMac` only fires the request and returns null instead of waiting.
- **e1000 register bits are easy to get wrong** — RCTL bit 15 is BAM (broadcast accept, required for DHCP OFFERs), bit 3 is UPE (not BAM), bit 6 is loopback (not BSIZE). BSIZE=2048 is the default (bits 17:16 = 00, BSEX clear). TX descriptors need the RS bit (0x08) for the DD status bit to ever be set, and RDT must be written with the index just recycled, not the next one. Named constants at the top of `src/drivers/e1000.zig`; `e1000.debug_trace` gates per-packet serial dumps (off by default — they are slower than the network and cause the timeouts they are meant to diagnose).
- **IP payload length comes from the header, not the frame.** Ethernet pads to 60 bytes, so `ip.handlePacket` trims to the declared `total_len` before dispatch; TCP/UDP/ICMP all derive payload size from the slice they receive.
- **TCP is minimal but real:** `MSS=1440` (fits MTU + single `retx_buf`), `send()` splits, a single retransmission slot per connection, ISN varied per connection, SYN retransmitted while `syn_retries < 3` in `waitEstablished`, in-order-only data acceptance (out-of-order/duplicate segments are re-ACKed, not appended). Checksums must be computed after the payload is in the buffer — `buildTcpHeader` takes the whole segment slice for that reason.
- **Disk/FAT16/FAT32:** `run.sh`/`run.bat` create a raw 64 MB `disk.img` if missing. Boot scans providers and partitions once, then mounts FAT16 at `/mnt/disk` and probes FAT32 (512-byte sectors, 8.3 names, one static volume in the MVP) at `/mnt/disk` or `/log`; a FAT32 volume labelled `ZLOG` wins over an unlabelled candidate. `klog` stores `/KERNEL.LOG` through a 64 KiB async RAM queue with early-boot replay and best-effort panic flush; `klog status|flush|dump|clear` is available. `tools/test_fat32_log.py` validates a 1 GiB image, nested files, multi-cluster append/copy, and a cluster above `0xFFFF`. `mkfs` still reformats FAT16 only. `drivers/ahci.zig` and `fs/partition.zig` (MBR/GPT) exist alongside virtio-blk. `vfs.isStaticHandle` prevents `kfree` on the static `open_files` BSS array — don't "fix" handle allocation in a way that bypasses it.
- **Framebuffer/GUI:** `src/entry.S` requests a linear 1024x768x32 framebuffer (multiboot VIDEO flag); `grub.cfg` tries `1024x768x32,800x600x32,640x480x32` and always ends `gfxpayload` with a `text` fallback so the console stays visible for unusable modes. `vga.isFbActive()` accepts both **24bpp and 32bpp** (`fb_bytes_pp` in `framebuffer.zig`; all raw-LFB access goes through `lfbPut`/`lfbGet`). Commands `gui`, `resolution <WxH>`, `mouse` work once the fb is active; the console shell stays VGA text. `framebuffer.zig` is a shadow buffer: draw into RAM, then `flush()` the tracked dirty rect to the LFB. The harness runs `-display none`, so GUI changes need visual verification via `tools/boot_watch.py` (QMP screendump → `screen.ppm`).
- **Adding a shell command needs two required edits** in `src/shell.zig`: a handler `fn(args: []const u8)` (zero-arg programs get an adapter like `fn runX(_: []const u8)`) and one `command_table` entry. The table drives **dispatch and tab completion** (`execute` iterates it — there is no separate dispatch branch to add). Also add a line to `printHelp` — it is a hand-written list, not generated from the table. Full-screen programs (lua/matrix/gui/nano) clear the screen and reprint the banner on exit — see `cmdLua` for the pattern. Unknown input falls through to `execFromPath` → `resolveExecutablePath`, which tries the raw name, `/bin/<name>`, `/mnt/disk/<name>`, then each with a `.exe` suffix.

## Kernel / toolchain conventions

- No std I/O in kernel code: VGA is the user-facing UI, serial (`/dev/ttyS0`) is the debug log. `main.zig` defines `pub fn panic` (VGA + serial + `system/panic.zig:printBacktrace`, then `hlt`); the std panic handler is unused. `kernel_entry`, `syscall_handler`, and `win_thunk_handler` are exported (the latter two forced via a `comptime` block in `main.zig`) because asm references them; `syscall_entry_64` and `sys_exit_return` are defined in `isr.S` and `extern` in Zig. Inline asm uses Zig 0.16 clobber syntax: `: .{ .rax = true, .memory = true }`.
- `kalloc` never coalesces non-contiguous chunks (physical contiguity check: `block_end == @intFromPtr(next)`).
- `.gitignore` covers `.zig-cache/`, `zig-out/`, `build/`, `isodir/`, `kernel.iso`, `*.o`, `qemu.log`, `serial*.log`, `test_out.log`, `*.img`, `screen.ppm`, `ser_capture.log`, `regs_out.txt`. `samples/*` (incl. `busybox`) and the other committed binaries are fixtures **on purpose** — don't add more.
- Docs: `README.md` is cosmetic. `AGENTS.md` + `TODO.md` (real gaps, incl. "Foreign binaries") are the working docs. Milestone/task spec lives in `promtpt.txt`; full test matrix in `TEST_INFRA.md`.

## Lua

`lua` shell command (`src/programs/lua.zig`) runs the interpreter on a 128 KB `FixedBufferAllocator`. Native bindings live in `src/lua/api.zig` and are registered in `vm.zig:VM.init`: `print`, `type`, `tostring`, `tonumber`, `assert`, `error`, `ipairs`, `pairs`, `vga_write`, `serial_write`, `sleep`, `read_key`, `time`, plus `math.*` and `string.*` tables. Add new bindings there. User `function` definitions parse and run (`vm.callFunction`). No modules, no stdlib beyond the above.
