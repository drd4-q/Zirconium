# AGENTS.md — Zirconium

Bare-metal x86_64 kernel in Zig (Multiboot/GRUB, 2MB identity pages, SMP, VGA/FB shell, TCP/IP over e1000/rtl8169, VFS ramfs+FAT16/virtio-blk, ring 3 INT 0x80 + `syscall`, Lua, modular USB stack). QEMU only.

## Build & run

```bash
zig build            # Debug → zig-out/bin/kernel
zig build -Drelease  # ReleaseFast — what run.sh and both harnesses ship
./run.sh             # build -Drelease → grub-mkrescue ISO → QEMU (gtk)
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

## Testing — two harnesses

**`tools/test_runner.py`** (the gate): `zig build -Drelease` → patch/rebuild `kernel.iso` → QEMU `-nographic -smp 4 -m 512M -serial stdio` → poll `serial_test.log` for `[USER-HEAP] free + reuse OK` (timeout 45 s), then assert 10 exact substring markers (`tools/test_runner.py:177`):

`[BOOT] Kernel loaded`, `[BOOT] System init done`, `[MEM] Physical memory manager initialized`, `[APIC] Local APIC timer initialized`, `[SMP] AP CPU 1 online`, `[USER] Hello from Ring 3 (user space)!`, `[USER-NET] Created socket via sys_socket`, `[USER-NET] Connected to 10.0.2.2:80 via sys_connect`, `[USER-HEAP] malloc(64)+malloc(128) via SYS_BRK OK`, `[USER-HEAP] free + reuse OK`.

Run after any boot/SMP/syscall/ring3/TCP change. Markers are raw substrings — renaming log strings breaks suite silently. QEMU runs `-d int,cpu_reset -D qemu.log`; read `qemu.log` after triple fault. `run.sh` logs to `-serial stdio`, harness to `serial_test.log`.

**`tools/e2e_test_suite.py`** (Tiers 1–4, 34 cases, see `TEST_INFRA.md:3` / `TEST_READY.md`):

```bash
python3 tools/e2e_test_suite.py --all             # all tiers
python3 tools/e2e_test_suite.py --tier 1          # 1=smoke, 2=subsystem, 3=USB/HID/Wi-Fi, 4=stress
python3 tools/e2e_test_suite.py -k usb            # filter by id/name/feature (e.g. -k wifi, -k F2.3)
python3 tools/e2e_test_suite.py --all --json out.json
python3 tools/e2e_test_suite.py --list
```

ISO handling (both runners): patch `kernel.bin` in-place inside existing `kernel.iso` if it fits the slot, else `grub-mkrescue` rebuild; fallback `-kernel zig-out/bin/kernel` only if no ISO. Standalone patcher `tools/patch_iso.py` (used by `run.bat`).

## Codegen — two embedded blobs

`build.zig` runs host tool `tools/bin2zig.zig` → byte arrays injected as anonymous modules:
- `user_test_bin` ← `src/user/test.zig` freestanding ELF (`image_base=0x2000000`, entry `_start`). Registered in `kernel/init.zig` via `scheduler.addElfUserTask` — runs in ring 3 **before shell on every boot** and via shell `user` command; exercises write/socket/connect/send/recv/brk.
- `ap_tramp_bin` ← `src/arch/trampoline.(S|ld)` linked flat at `0x8000`.

Editing either source retriggers codegen on next `zig build`; no manual step.

## Architecture

**Boot:** `src/entry.S` (32-bit multiboot → zero 6 page tables → identity-map 4 GB with 4×512×2 MB pages → long mode) → `kernel_entry` (`src/main.zig:43`): serial → `gdt.init` (ring 3 + TSS) → `vga.initFb(mbi_ptr)` → `system_init` (PIC, IDT) → `syscall64.init` → PMM → VMM → kalloc → VFS/ramfs → `kernel_init.init()` (timer, scheduler) → `pci.scan()` + e1000/rtl8169 probe + `net/mod.zig:init()` → `smp.init()` → `scheduler.runAll()` → `shell.run()`. virtio-blk/FAT16 + USB + mouse + PCI rescan happen in `shell.zig:run`, not during boot — hence `pci.scan()` runs twice.

**Layout:** `src/arch/` (gdt, idt 256 + INT 0x80 DPL3, pic, port, isr.S/isr.zig, acpi MADT, smp+trampoline) · `src/kernel/` (pmm, vmm with COW fault handler, kalloc, scheduler, task, address_space, elf, syscall, init) · `src/system/` (serial, vga, framebuffer/tty/panic, gui) · `src/drivers/` (keyboard IRQ1, timer PIT 100 Hz IRQ0, apic, pci, e1000, rtl8169, mouse, virtio_blk, ahci) + `src/drivers/usb/` (modular stack, see below) · `src/net/` (arp/arp_cache/ip/icmp/tcp/udp/dns/dhcp/http, `mod.zig` is public surface) · `src/fs/` (vfs, ramfs at `/`, blockdev, partition, fat16 at `/mnt/disk`) · `src/programs/` (one file per shell command, dispatched in `src/shell.zig:execute`) · `src/lua/` (lexer/parser→AST, VM) · `src/user/` (ring 3 test ELF + heap).

**Root module pattern:** `src/main.zig` re-exports `serial`, `vga`, `scheduler`, `pmm`, `vmm`, `kalloc`. ~45 files use `const root = @import("root"); const vga = root.vga;` — follow that in new files.

**Scheduler is not preemptive:** `scheduler.runAll()` runs each registered task to completion (kernel tasks directly, user tasks via `jumpToUser`) then returns to shell. `TIME_SLICE` is assigned but never enforced.

**LAPIC timer is intentionally masked** (`src/drivers/apic.zig:83`) — PIT is the single 100 Hz tick. Unmasked LAPIC on vector 32 double-counted ticks and made `sleep()`/TCP 2× fast. `[APIC] Local APIC timer initialized` is still printed; not "ticking".

**SMP:** `smp.init()` parses ACPI/MADT for LAPIC IDs, then INIT-SIPI-SIPI. SIPI mode is ICR bits 10:8 = `6` → `(6 << 8) | (0x8000 >> 12)` — not `0x6000`. Trampoline copied to `0x8000` with cells at `0x600` (GDT), `0x610` (IDT), `0x700` (PML4), `0x708` (stack top), `0x710` (index), `0x718` (entry). Each AP gets 16 KB stack, idle-loops in `ap_entry`. Wrong layout/ICR → APs silently never come online (`[SMP] AP CPU 1 online` missing). Shell: `smp`/`cpuinfo`.

## User-space (ring 3)

- **GDT selectors** (`src/arch/gdt.zig`): `0x08` kcode, `0x10` kdata, `0x18|3` ucode, `0x20|3` udata, `0x40` TSS; `0x28`/`0x30` unused dups. Now per-CPU GDT/TSS (`gdt_per_cpu`/`tss_per_cpu`, `MAX_CPUS=64`, `initCpu`/`setRsp0ForCpu`).
- **Syscalls:** `syscall` instruction (MSR `LSTAR` → `arch/syscall64.zig:syscall_entry_64`) and legacy `INT 0x80`, `rax`=num, args `rdi/rsi/rdx`. Numbers in `src/kernel/syscall.zig:15`. Implemented: write=1 (fd 1–2 VGA, 3 serial), read=2 (fd 0 keyboard), sleep=10, time=11, brk=12, fork=57 (COW clone), exec=59 (ELF from VFS path), exit=60, waitpid=61, socket/connect/send/recv=70–73. `SYS_OPEN=3`/`SYS_CLOSE=4` exist but return `ENOSYS` (-38). `IA32_FMASK` masks `TF|IF|DF|NT|AC` on entry so interrupts are off before stack switch.
- Fault isolation (`src/arch/isr.zig`): exceptions in ring 3 (CS.RPL=3) terminate the task via `process.exitCurrent(-11)` instead of kernel panic.
- Per-task: 8 TCP slots (`src/kernel/task.zig:57`), heap at `USER_HEAP_BASE=0x04000000` grown page-wise by `brk` (`src/user/heap.zig` free-list malloc).
- **Address spaces** (`src/kernel/address_space.zig`): per-task PML4, `PAGE_USER`, `destroy()` frees user pages.

## USB subsystem

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
