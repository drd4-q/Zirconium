# AGENTS.md — Zirconium

Bare-metal x86_64 OS kernel in Zig that is now **a virtual machine monitor (ZVM)**: it boots
guest operating systems (Linux, Android, XNU, BSD) and its own shell is the *supervisor's
console*, not a program runner. Limine boot, identity-mapped 2 MB pages (first
64 GB), SMP via ACPI MADT + AP trampoline, VGA-text shell + framebuffer GUI, custom TCP/IP
over e1000/rtl8169/USB-Wi-Fi, VFS (ramfs + FAT16/FAT32 over virtio-blk), ring 3 with native
INT 0x80 syscalls **and** foreign binaries (static Linux ELF via the `syscall` instruction,
Win32 PE32+ via INT 0x81 thunks), a modular USB stack with a unified HID/input layer, a
minimal Lua interpreter, and a small dillo web browser. QEMU is primary; `create_usb.sh`
targets real hardware.

Read this file before touching the kernel — most of it is *why the code looks the way it
does*, and the reasons are not recoverable from the code itself.

## Build & run

```bash
zig build                          # Debug production kernel → zig-out/bin/kernel
zig build -Drelease                # ReleaseFast production kernel
zig build -Drelease -Dselftest=true # ReleaseFast with the embedded ring-3 self-test
zig build -Dconfig=<path.json>     # build from a different kernel configuration
./build_iso.sh                     # production kernel + ISO, without QEMU/disk setup
./build_iso.sh --selftest          # ISO whose kernel runs the ring-3 self-test
./build_iso.sh --menu-debug       # diagnostic ISO: the Limine menu stays up, COM1 mirrored
./run.sh                           # build -Drelease → Limine ISO → QEMU (gtk)
./run.sh --vnc                     # VNC on host port 5901 instead of gtk
./run.sh --gdb                     # QEMU -s -S; attach gdb to localhost:1234
./run.sh --test                    # = python3 tools/test_runner.py (the gate harness)
run.bat                            # Windows equivalent (patch_iso.py / qemu-img / fsutil fallbacks)
./test_prog.sh                     # rebuild disk.img with test executables (see below)
```

- **Zig 0.16 or 0.17 — both work.** `build_iso.sh` enforces `0.16.x` or `0.17.x` and fails loudly
  otherwise (`ZIG=/path/to/zig` overrides the binary). Zig 0.17 removed the array
  multiplication syntax (`a ** b`) and replaced the enum field list with parallel
  name/value arrays; the tree uses `@splat` and `std.enums`, which both versions have, so
  it builds with either. `build.zig.zon` still says `minimum_zig_version = "0.14.0"` —
  stale; `tools/bin2zig.zig` and `tools/gen_config.zig` use std APIs that only exist in
  0.16 and later (`std.process.Init`, `std.Io.Dir`, `std.Io.Writer.Allocating`).
- `zig build` exposes only the default `install` step and `build`. **There is no
  `zig build test` and no unit tests anywhere** — verification is the QEMU harness only
  (below). A clean build is a few seconds; always rebuild before claiming anything works.
- `-Drelease` is required for ReleaseFast: `standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast })`
  only honors the preference when the flag is passed; without it you get Debug.
- Release enables `--gc-sections`, so `linker.ld` must keep `KEEP(*(.multiboot))` for
  `src/entry.S`'s header. Break it and Debug still boots while release fails in Limine with
  "no multiboot header found".
- **Toolchain:** `xorriso`, `qemu-system-x86_64`, `python3`. All assembly (`entry.S`,
  `isr.S`, `trampoline.S`) goes through Zig's own assembler (`addAssemblyFile`) — no GNU
  as/ld anywhere. The AP trampoline links flat at 0x8000 via `src/arch/trampoline.ld` and
  becomes a blob with `addObjCopy(.{ .format = .bin })`. The kernel needs `use_llvm = true`;
  target `x86_64-freestanding` with `sse3/ssse3/sse4_1/sse4_2/avx/avx2` removed via
  `cpu_features_sub` (SSE/SSE2 stay — don't emit wide vector ops).
- Disk: `run.sh` creates a 64 MB `disk.img` + `mkfs.fat -F 16` when missing (leaves it raw
  if `mkfs.fat` is absent — format in-guest with `mkfs`). `create_disk.sh` builds a second
  test disk (`disk2.img`) via mtools (`mformat`/`mcopy`).

## Testing — two harnesses

**`tools/test_runner.py`** (the gate): runs `zig build -Drelease -Dselftest=true`, gets the
kernel into `kernel.iso` (patches `kernel.bin` in place if the new binary fits the old
slot, else rebuilds with `tools/mkiso.py` incl. a WSL fallback; with no ISO at all it boots
`-kernel zig-out/bin/kernel` — standalone patcher `tools/patch_iso.py`, used by `run.bat`).
Then boots QEMU headless:

```
-cdrom kernel.iso -boot d -m 512M -smp 4 -display none -serial stdio
-netdev user,id=net0 -device e1000,... -no-reboot
```

**No disk, no framebuffer, no `-d int`.** It reads serial, waits up to **45 s** for the
terminal marker `[USER-HEAP] free + reuse OK`, writes everything to `serial_test.log`, then
asserts these 10 raw substrings:

`[BOOT] Kernel loaded`, `[BOOT] System init done`, `[MEM] Physical memory manager initialized`, `[APIC] Local APIC timer initialized`, `[SMP] AP CPU 1 online`, `[USER] Hello from Ring 3 (user space)!`, `[USER-NET] Created socket via sys_socket`, `[USER-NET] Connected to 10.0.2.2:80 via sys_connect`, `[USER-HEAP] malloc(64)+malloc(128) via SYS_BRK OK`, `[USER-HEAP] free + reuse OK`.

- The same 10 markers are re-asserted by e2e `TC-REGR-01`. Markers are **raw substrings** —
  renaming a kernel log string silently breaks both suites.
- Crash triage: only `run.sh` passes `-d int,cpu_reset -D qemu.log` (and attaches
  disk/USB devices); read `qemu.log` after a triple fault. `run.sh` sends serial to the
  terminal, the harness to `serial_test.log`.
- **Stale-`kernel.iso` trap:** the dynamic ISO patcher rewrites `/boot/kernel.bin` in
  place, and a `kernel.iso` that has been patched many times (or by a much smaller kernel)
  can end up in a state where a *later* harness fails to boot with no obvious cause — e.g.
  `tools/usb_input_test.py` reporting `[FAIL] xhci: missing markers` while the very same
  source tree passes after a rebuild. **When a USB/storage/xHCI test fails with the driver
  initialising fine but the first hardware command timing out, delete and rebuild the ISO
  first** (`rm -f kernel.iso && ./build_iso.sh`) before believing it is a code regression.
  It is not self-healing.
- Run the gate after any change touching boot, SMP bring-up, syscalls, ring 3, or the TCP
  client path. It cannot see the shell UI, GUI, FAT16 contents, or foreign binaries.

**`tools/e2e_test_suite.py`** — **37 cases** in 4 tiers (1=smoke×5, 2=subsystem×7,
3=USB/HID/Wi-Fi×20, 4=stress×5; feature matrix in `TEST_INFRA.md` / `TEST_READY.md`):

```bash
python3 tools/e2e_test_suite.py --all             # all tiers
python3 tools/e2e_test_suite.py --tier 2          # 1=smoke, 2=subsystem, 3=USB/HID/Wi-Fi, 4=stress
python3 tools/e2e_test_suite.py -k usb            # filter by id/name/feature (e.g. -k wifi, -k F2.3)
python3 tools/e2e_test_suite.py --all --json out.json
python3 tools/e2e_test_suite.py --list
```

It boots several QEMU profiles through its `get_*_log` helpers: baseline, UHCI+HID,
multi-controller USB, and — when `disk.img` exists — one with
`-drive file=disk.img,format=raw,if=virtio` (`TC-VFS-02`).

### Other harnesses

| Tool | What it does |
|---|---|
| `tools/boot_watch.py <sec> [disk] [cmd:"shell cmd" ...]` | Boots the ISO headless, drives the shell over a TCP serial port, writes `ser_capture.log`, takes a QMP screendump → `screen.ppm`. The only way to see the GUI/framebuffer (`-display none` elsewhere). |
| `tools/usb_input_test.py [uhci\|ehci\|xhci\|xhci-hub\|all]` | Proves a real HID report reaches the key ring (QMP input → USB endpoint → decoded keys). |
| `tools/stress_m1.py` | Adversarial M1 checks: heap coalescing oracle, TX routing, FMASK bit 9, ring-3 fault isolation, per-CPU TSS, TCP slot recycling, VFS handle ownership. |
| `tools/stress_m2.py` | USB stress: unattached root ports, rapid polling, allocation/overflow immunity. |
| `tools/stress_m3.py` | HID stress: 6KRO rollover, truncated/corrupt reports, 10k rapid decodes. |
| `tools/test_hid_stress.zig` | Host-side mirror of the HID/keyboard data structures (pure logic, no QEMU). |
| `tools/test_edid.zig` | Host-side test of the EDID parser (`zig run --dep edid -Mroot=tools/test_edid.zig -Medid=src/drivers/drm/edid.zig`). It imports the real parser. |
| `tools/test_ftdi.zig` | Host-side test of the FTDI chip protocol: the baud divisors, the chip IDs, the status bits. |
| `tools/test_hidpp.zig` | Host-side test of the HID++ protocol: the report formats, the requests, the feature table. |
| `tools/test_hid_report.zig` | Host-side test of the HID report descriptor parser, using QEMU's keyboard/tablet descriptors and a numbered receiver descriptor. |
| `tools/test_fat32_log.py` | Boots a FAT32 image and checks mount, `KERNEL.LOG`, nested dirs, multi-cluster append/copy. |
| `tools/create_guest_disk.py` | Builds the sample guest kernels and copies them into `disk.img` under `/vms/`. |

**The host-side tests import the real code**, not a copy of it: the modules they need
(`edid.zig`, `ftdi_proto.zig`, `hidpp_proto.zig`, `hid_report.zig`) are free of kernel
dependencies for exactly that reason. Run them with:

```bash
zig run --dep edid      -Mroot=tools/test_edid.zig      -Medid=src/drivers/drm/edid.zig
zig run --dep ftdi      -Mroot=tools/test_ftdi.zig      -Mftdi=src/drivers/usb/serial/ftdi_proto.zig
zig run --dep hidpp     -Mroot=tools/test_hidpp.zig     -Mhidpp=src/drivers/hid/hidpp_proto.zig
zig run --dep hidreport -Mroot=tools/test_hid_report.zig -Mhidreport=src/drivers/hid/hid_report.zig
```

## Test programs & samples

- `samples/` holds committed fixtures: `busybox` (static musl multi-call ELF), `hello_linux`
  (+ `.zig` source), `hello.exe` / `hello_win.exe` (PE32+, source `hello_win.zig`),
  `guest_hello.S` / `guest_root.zig` / `guest_stub.S` / `guest_kernel.zig` (the sample
  guest, see the ZVM section), plus `samples/apps/` (fetched real apps).
  Rebuild the C-ish ones with plain `zig build-exe -target x86_64-{freestanding,windows}`
  per `tools/create_test_disk.py`.
- `test_prog.sh|bat` → `python3 tools/create_test_disk.py`: downloads busybox from
  busybox.net, compiles the samples, writes a fresh 64 MB FAT16 `disk.img` (needs mtools:
  `mformat`/`mcopy`, native or WSL).
- `tools/fetch_apps.py` downloads real apps into `samples/apps/` (busybox, uutils coreutils,
  jq.exe, curl.exe, rg.exe, fastfetch, btop, 7zr.exe, neofetch); `create_test_disk.py` copies
  them onto `disk.img` under 8.3 aliases (coreutils→`cu` and `ls`, hello_linux→`hl` — no
  LFN support).
- In the guest these appear at `/mnt/disk/...`. Run them via `exec /mnt/disk/hello.exe`,
  `exec /mnt/disk/busybox uname -a`, **or just type the name** — unknown commands fall
  through to `execFromPath` → `resolveExecutablePath` in `src/shell.zig`.
- `tools/create_fat32_disk.py --output fat32-test.img --size-mb 1024` creates a sparse
  MBR/FAT32 fixture without host `mtools`.
- `create_usb.sh [device]` writes the kernel to a USB stick for bare-metal boot (Limine;
  Secure Boot off; Ventoy also works).

## Codegen — five embedded blobs

`build.zig` runs the host tool `tools/bin2zig.zig` five times, turning binaries into Zig
byte arrays injected as anonymous modules:

- `user_test_bin` ← `src/user/test.zig` built as a freestanding ELF (`image_base = 0x2000000`,
  entry `_start`). With `-Dselftest=true`, `kernel/init.zig` registers it via
  `scheduler.addElfUserTask`, so it runs in ring 3 **before the shell** and exercises
  write/socket/connect/send/recv/brk; production builds skip only this automatic task, while
  the shell `user` command can still respawn it.
- `user_test2_bin` ← `src/user/test2.zig`, a pure user-mode spinner registered **first** on
  purpose: it never blocks, so only a tick can switch away from it. Interleaved
  `[USER2]`/`[USER]` output in the log is the proof that preemption works.
- `ap_tramp_bin` ← `src/arch/trampoline.S` (Zig assembler, flat link at 0x8000 via
  `trampoline.ld`, `objcopy` to `.bin`).
- `kvm_test_bin` ← `src/user/kvm_test.zig`, the ring-3 guest driver for the ZVP device.
- `guest_kernel_bin` ← `samples/guest_root.zig` + `samples/guest_hello.S`: the built-in
  sample guest, used when a configured machine's image is not on the disk.

Editing any of those sources retriggers codegen on the next `zig build`; no manual step.

## The bootloader: Limine

GRUB is gone. **Limine 8.7.0** replaces it, and the kernel still speaks **Multiboot 1** to
it — so the contract between bootloader and kernel did not change: `src/entry.S` is
untouched, still receives `EAX = 0x2BADB002` and `EBX` = the Multiboot info block, and
the framebuffer still arrives in mbi bit 12. Only the thing that loads the kernel changed.

- **`limine.conf`** (repo root) is the bootloader's configuration. It matters:
  - `protocol: multiboot1` — the protocol the kernel speaks. `path:` is where the kernel
    image lives.
  - `path: boot():/boot/kernel.bin` — `boot():` means "the volume/partition that holds
    this config file", which is why the *same* line works for the ISO (config at the root)
    and for a USB stick (config at the root of the FAT partition). **`odd():` does not work
    on the ISO** — it resolves to the whole optical volume, and the lookup fails; use
    `odd(1:):` if you must address the disc by number.
  - `resolution: 1024x768x32` — the mode Limine sets up. It picks another one
    automatically if this is unavailable, so the old GRUB "the payload chain must not
    contain `text`" trap simply does not exist any more.
  - `serial: yes` — the bootloader mirrors its own output to COM1, so the serial log shows
    the menu and the handoff, not just the kernel's messages.
  - `timeout: 0` — the menu does not wait.  The **video modes are separate
    entries**: Limine takes one `resolution:` per entry, while GRUB had a
    *chain* (`set gfxmode=1024x768x32,800x600x32,640x480x32` and
    `set gfxpayload=...,text`).  The alternatives are entries now
    (1024x768, 1920x1080, 800x600 and a text mode entry), and
    `./build_iso.sh --menu-debug` builds the image whose menu offers them
    all, so the mode can be picked by hand. Three seconds of countdown on every boot was
    a third of the boot time; `--menu-debug` still builds the image whose menu never
    times out.
- **The kernel file must be named `kernel.bin`** inside the image. The test harnesses
  patch a freshly built kernel into an existing ISO *in place* (much faster than rebuilding)
  and they look the file up by that name; renaming it to `kernel.elf` silently breaks the
  patcher and every harness then boots a stale kernel.
- **`limine/`** holds the three vendored bootloader binaries (`limine-bios-cd.bin`,
  `limine-uefi-cd.bin`, `limine-bios.sys`) with their checksums and origin — see
  `limine/README.md`. They are committed so building an ISO never needs the network.
- **`tools/mkiso.py`** builds the BIOS+UEFI hybrid ISO (El Torito boots the BIOS image and
  the UEFI image; `xorriso` does the work — it is required, `grub-mkrescue` is not).
  `build_iso.sh` calls the same command line directly.
- **`build_iso.sh --menu-debug`** produces a diagnostic ISO whose config sets
  `timeout: no`, so the Limine menu stays up and its output goes to COM1. Use it when the
  boot stops at the menu or when you need to see the modes Limine offers.
- **A USB stick** is prepared by `create_usb.sh`: a FAT partition holding `limine.conf`,
  `limine-bios.sys` and the kernel, then `limine bios-install` writes the stage-1 boot
  code. That needs the `limine`, `mkfs.vfat` and `mcopy` tools. A Ventoy stick needs
  none of it — copy `kernel.iso` onto it.
- **The ISO is BIOS+UEFI hybrid**, so one image boots real hardware either way. The BIOS
  path is the one exercised by QEMU in the harnesses.

## Boot time

**Boot to the shell: 1.2 s** (it was 6.6 s before this was worked on). Three things
dominated it, and all three are gone:

- **The Limine menu.** `timeout: 3` was three seconds of countdown on every boot. It is `0`
  now; `--menu-debug` is the diagnostic path.
- **The AP bring-up.** `sendInitAp()` waited 100 ms after the INIT pulse and `sendStartupAp()`
  waited 2 ms between the two SIPIs — 0.3 s on a 4-CPU machine, more than a second on a
  16-CPU one. The timings are now the ones Linux uses (**10 µs** INIT assertion, **200 µs**
  between the SIPIs; `arch/x86/kernel/apic/intel.c`, `apic_send_init_sipi_sipi_shorter()`).
  The 10 ms tick is far too coarse for those gaps, so they are measured with the **TSC**:
  `src/arch/tsc.zig` calibrates it against the LAPIC timer, which `drivers/apic` has already
  calibrated against the PIT, so no new time reference is introduced.
- **The ARP resolution of the gateway.** It could fail outright, see the QEMU note below.

**The rest of the time is the bootloader and the kernel image**: 0.65 s of BIOS and Limine,
0.44 s to load a 3.9 MB kernel over an emulated CD-ROM, 0.1 s of kernel init, 0.05 s of
ZVM setup. A smaller kernel loads faster; the features are configurable in
`config/kernel.json`.

**QEMU's e1000 holds every packet back for a second.** `set_rx_control()` in QEMU's
`hw/net/e1000.c` arms a one second flush timer on *every* write to RCTL, and the NIC
reports "cannot receive" until that timer fires — so the first packet after the driver
programs RCTL is a full second late. The guest cannot shorten the window (every RCTL write
re-arms it), so `net.ensureArp()` retries with a growing interval and a budget long enough
to win the race. **A 500 ms budget lost it**, and the connect failed with it.

## Architecture

**Boot:** `src/entry.S` (32-bit multiboot entry → zeroes `.bss` → identity-maps the first
64 GB with 64 PDs × 512 × 2 MB pages, NX above the kernel image → long mode) → `kernel_entry`
(`src/main.zig`) → `kernel/boot.zig`, which **runs the configured boot sequence**
(`config.boot_stages`, from `config/kernel.json`):

gdt → framebuffer → system (PIC, IDT, then `probeLfbSafe()` and the DRM model) → syscall64
(MSRs enabling the `syscall` instruction) → memory (PMM, VMM, kalloc) → filesystem (VFS +
ramfs mount + `seedfs.init()`) → kernel (`kernel_init.init()`: timer, scheduler; registers the
embedded ring-3 user tests only with `-Dselftest=true`) → pci (`pci.scan()`) → storage
(`virtio_blk.init()`, `ahci.init()`, `usb.zig.init()`, `partition.scanAll()`, FAT16/FAT32
probe, `kernel_log.init()`) → network (e1000-**or**-rtl8169 probe + `net/mod.zig.init()`) →
input (`mouse.init()`) → bluetooth → smp → **machines** (the ZVM creates the machines its
configuration names) → **guests** (their kernels are loaded into their memory) → scheduler
(`scheduler_ready = true` — the tick must be live *before* the first task, or nothing is
preemptible during `runAll` — then `scheduler.runAll()`) → shell.

**The order matters:** the hypervisor's own hardware comes up *first* (storage, network,
input, smp), and only then do the machines. The `machines` stage needs the CPU count, so it
has to run after the APs are up; `guests` needs the disk, so it runs after storage.

**Adding a boot stage means editing three places:** `config/kernel.json` *and*
`tools/gen_config.zig` (`stage_names` — an unknown stage name is a **build error**) *and*
`kernel/boot.zig` (its switch is exhaustive, so a stage nobody implemented is a compile
error).

## Declarative configuration

`config/kernel.json` is the single source of truth for what the kernel contains and what it
does at boot. `tools/gen_config.zig` (a host tool invoked by `build.zig`) parses it,
validates it, and emits a `config` module that the kernel imports as `@import("config")`.

- **Features** (`features.*` → `config.features.<name>`): `usb`, `hid`, `network`, `storage`,
  `smp`, `gui`, `lua`, `fat32`, `ahci`, `usb_wifi`, `kvm`, `selftest`. A feature that is off
  removes its code: the optional subsystems are reached through a comptime-selected wrapper
  (`const gui = if (config.features.gui) struct { const mod = @import("system/gui.zig"); … }
  else struct { … };`), so the untaken branch is never analysed and the module is not linked.
- **Tunables**: `timer.hz` → `config.timer_hz` (the tick rate), `heap.kernel_kb` →
  `config.heap_kernel_bytes`, `network.ip`/`gateway`/`dns`/`prefix` → `config.net_ip` /
  `net_gateway` / `net_dns` / `net_prefix`. Nothing in the kernel hardcodes these any more.
- **The boot sequence** (`boot.stages` → `config.boot_stages`): an ordered list of stage
  names. A stage may name a feature in `requires`; if that feature is off, the generator
  **drops the stage** (and says so), so switching a feature off cannot leave half-initialised
  code behind.
- **The machines** (`machines.list` → `config.machines`): the machines this ZVM runs. This is
  the heart of the configuration — a virtual machine monitor is defined by the machines it
  runs, not by the host's own features. Each entry names a machine, the profile it is shown
  as, the guest's kernel image, whether it is autostarted, and optionally its own core and
  RAM budget. The generator rejects a duplicate name, a nameless machine and an unknown
  profile.
- `config.featureEnabled(f)` looks a feature up by name; the shell's `command_table` entries
  carry an optional `.feature`, and a command whose feature is off is hidden from the help
  text and from tab completion.
- The generator **rejects** an unknown feature or stage name, a non-boolean feature, a bad
  IP address, a prefix > 32, and a zero heap or tick rate. A misspelled feature is a build
  error, not a feature that looks disabled forever.
- The generator's own progress output goes to stderr; the build runs it with `stdio = .inherit`
  so the output is readable instead of making the build system echo the whole command back.

**Machine profiles** (`src/vm/profiles.zig`) — the only names `config/kernel.json` may use:
`linux-i386-legacy`, `linux-i386`, `linux-x86_64`, `android-x86_64`, `xnu-darwin`,
`bsd-x86_64`. The default config ships `linux` (`linux-x86_64`) and `bsd` (`bsd-x86_64`),
both pointing at `/mnt/disk/vms/{linux,bsd}.elf` — which only exist if you ran
`tools/create_guest_disk.py`. **If the image is missing the loader falls back to the
built-in sample guest** and logs `[ZVM] No image at <path>, using the built-in sample guest`;
that is not an error.

**Layout:**
- `src/arch/` — gdt (per-CPU GDT/TSS, `MAX_CPUS=64`), idt (256 entries; INT 0x80 **and**
  the Win32 INT 0x81 thunk gate, both DPL 3), pic, port, isr (`isr.S` + `isr.zig`; `isr.S`
  also defines `syscall_entry_64` and `sys_exit_return`), acpi (MADT scan), smp +
  `trampoline.S/.ld`, msr, syscall64 (STAR/LSTAR/FMASK/SCE MSRs).
- `src/kernel/` — pmm, vmm (incl. COW fault resolution), kalloc, scheduler, task,
  address_space, elf (ELF64 loader), pe (PE32+ loader), binfmt (format sniffing +
  personalities), linux_syscalls (Linux ABI table), winapi (Win32 emulation), fdtable,
  uaccess, process, seedfs, syscall, init, **boot** (the configured boot sequence).
- `src/system/` — serial, vga (a re-export of `gfx/mod.zig`), framebuffer (the LFB driver),
  `gfx/` (surface interface, console engine, VGA-text surface, palette, font, **output** = a
  virtual display, **display** = the compositor), gui, tty, init, panic, env, kernel_log.
- `src/vm/` — the ZVM: `mod.zig` (the facade, the autoload and `loadGuests`),
  `machine.zig`, `profile.zig` (+ `profiles.zig`, the shared data), `resources.zig`,
  `identity.zig`, `mmu.zig`, `loader.zig`, `proto.zig`, `cpu.zig` (the interpreter),
  `uart.zig` (the guest's 8250), `pci.zig` (the guest's PCI bus), `devices/zvp.zig`.
- `src/drivers/` — keyboard (IRQ1), mouse (PS/2), input (unified input facade, see USB),
  timer, apic, pci, e1000, rtl8169, virtio_blk, ahci, `usb.zig` (re-export shim) + `usb/`
  (16-file stack, see below), plus `hid/` (the HID++ protocol for the 2.4GHz receivers),
  `bluetooth/` (the HCI stack), `drm/` (the display model) and `video/`
  (`pcidisplay.zig`, the FB_SIMPLE interface, and `vga_mode.zig`, the legacy VGA text mode).
  The xHCI driver lives in `usb/xhci.zig` — there is no `src/drivers/xhci.zig`.
- `src/net/` — arp, arp_cache, ip, icmp, tcp, udp, dns, dhcp, http; `mod.zig` is the public
  surface **and** the NIC dispatcher.
- `src/fs/` — vfs (including append flags and cursor-aware directory reads), ramfs (mounted
  at `/` plus `/dev`, `/tmp`, `/etc`), blockdev, partition (MBR/GPT), fat16 (legacy
  `/mnt/disk` fallback), fat32 (512-byte-sector, 8.3-name MVP).
- `src/programs/` — one file per shell command (dispatch via `command_table` in `shell.zig`)
  plus the dillo browser package `dillo/` (browser, css, entities, html, layout, mod, url)
  and its engines `dillo_engine.zig` / `js_engine.zig` (both at `src/programs/` top level).
- `src/lua/` — lexer, parser, ast, value, vm, api; `mod.zig` re-exports.
- `src/user/` — ring-3 programs: `test.zig` (the self-test), `test2.zig` (the spinner),
  `kvm_test.zig` (the guest driver), `heap.zig` (the ring-3 malloc).

**Root module pattern:** `src/main.zig` is the root and re-exports `serial`, `vga`,
`scheduler`, `pmm`, `vmm`, `kalloc`, `tty`. Most files reach them via
`const root = @import("root"); const vga = root.vga;` rather than relative imports — follow
that in new files.

**Tick source is the LAPIC timer, not the PIT:** `apic.zig` calibrates the local APIC timer
against a one-shot PIT pulse, then runs it periodic on **vector 32 at 100 Hz** and masks
legacy PIT IRQ 0 in the 8259 PIC (`pic.mask(0)`) so exactly one source ticks.
`[APIC] Local APIC timer initialized …` is still printed each boot (it is a harness marker).
`timer.ticks` (100 Hz) drives `sleep()`, TCP deadlines, and `uptime`. It is updated with
`@atomicRmw` and read via `timer.tickCount()` — a plain read in a spin loop can be hoisted
out, silently deleting the delay.

**The tick handler must never block.** `scheduleTick` does only the preemption decision
(bounded, no waits) plus servicing the ZVP devices. USB/HID/net polling lives in
`scheduler.pollDeferred()`, called from the shell input loop and between scheduled tasks. A
poll that spins on a hardware bit inside an ISR deadlocks the machine: IF is clear, so the
tick that would release it can never arrive.

**Scheduling:** `runAll`/`runTask` still launch one program at a time, but a running ring-3
task is preemptible. On a tick with an expired slice (`TIME_SLICE`), `onTick` rewrites the
**current `InterruptFrame`** in place — save the old task's `saved_state`, load the next
task's, set CR3/TSS.RSP0/FS/GS — and the ISR's normal `iretq` transfers control, so there is
no nested context switch and no per-interrupt stack yet. Transitions are therefore
restricted to user↔user; kernel-mode is non-preemptible, and a task inside a syscall
(e.g. `sleep`) holds the CPU. A task that exits while a live parent exists is resumed
through `exit_redirect` → `applyExitRedirect`, otherwise `sys_exit_return` would land in
the C frame of whoever launched the *original* task. `preempted_from` records who to hand
the CPU back to and `redirectTargetFor` excludes the exiting task so it cannot resurrect
itself. `scheduler.preemptions` is logged at the end of `runAll`. The selftest's second
ring-3 program (`src/user/test2.zig`) spins in user code; interleaved `[USER2]`/`[USER]`
output in the log is the proof — and its busy loop **must** contain something the optimizer
cannot delete (an empty `while` is removed in ReleaseFast, which made the task finish in
10 ms and look like a non-preemption).

**NX / user isolation:** `entry.S` sets EFER.NXE (bit 11) and marks the identity map
non-executable through PTE bit 63. **NX is not privilege-dependent**, so the first
`EXEC_PD_ENTRIES` (6 MB) 2 MB pages stay executable for the kernel image and its page
tables — raise that constant if the kernel outgrows it. `AddressSpace.create()` no longer
ORs `PAGE_USER` into the inherited kernel PDPT/PD0 entries: doing so handed every task the
entire low 64 GB as read/write user memory. User segments are mapped explicitly by the
loaders and are executable (data segments too; a W^X split is not implemented).
`[BOOT] EFER NXE=on` proves the bit is live.

**SMP:** `smp.init()` parses ACPI/MADT for LAPIC IDs, then INIT-SIPI-SIPI. SIPI delivery
mode lives in ICR bits 10:8 — `(6 << 8) | (0x8000 >> 12)`, **not** the `0x6000` form
(`src/arch/smp.zig`). The trampoline is copied to 0x8000 with fixed control cells at 0x600
(GDT desc), 0x610 (IDT desc), 0x700 (PML4), 0x708 (stack top), 0x710 (CPU index), 0x718
(entry). Each AP gets a 16 KB stack and idle-loops in `ap_entry`. A wrong cell layout or
ICR encoding makes APs silently never come online — the only signal is the missing
`[SMP] AP CPU 1 online`. Shell: `smp`, `cpuinfo`.

## Foreign binaries (binfmt personalities)

`kernel/binfmt.zig` sniffs `\x7fELF` vs `MZ`/PE and dispatches `load()` to `elf.load` or
`pe.load`. Each image carries a **personality** that decides its kernel ABI:

- **ELF64 static** (`ET_EXEC` and static-PIE `ET_DYN`) → personality `.linux`. These enter
  the kernel with the `syscall` instruction, not INT 0x80: `arch/syscall64.zig` sets
  IA32_LSTAR to the `syscall_entry_64` stub in `isr.S`, which builds an
  InterruptFrame-compatible frame on the task's kernel stack and returns via `iretq`, so the
  C-side handler is shared with the INT 0x80 path. `syscall_kernel_rsp` must be kept in sync
  with TSS.RSP0 per task (`scheduler.jumpToUser`).
- **PE32+ console x86-64** → personality `.windows`. Imports resolve to 8-byte thunks
  (`mov eax, imm32; int 0x81; ret`, `THUNK_SIZE=8`) mapped at `WIN_THUNK_BASE=0x0F000000`
  (`kernel/task.zig`); `winapi.win_thunk_handler` services vector **0x81** (registered DPL 3
  in `idt.zig`, deliberately distinct from 0x80).
- Dynamically linked images are rejected with a clear error (no runtime loader exists; e.g.
  glibc-dynamic fastfetch).

`syscall_handler` (`kernel/syscall.zig`) routes by the current task's personality
(`switch (t.personality)`: `.linux` → `linux_syscalls.dispatch`, `.windows` → terminate the
task, `.native` → `nativeDispatch`). The native and Linux tables must stay separate —
numbers collide with different meanings (1=write in both, but 2=read natively vs open in
Linux).

**Linux ABI coverage:** `getdents64` works because directories open into a `.dir` FileDesc
(`task.DirDesc` remembers path + cursor; `vfs.readdir` enumerates by path). `chdir`/`getcwd`
hit the real VFS CWD. `sysinfo` fills totals from PMM/scheduler. `fcntl(F_DUPFD)` really
duplicates. `pipe`/`pipe2` return ENOSYS honestly. Fake-but-harmless: `poll`/`select` always
return "ready", `mprotect` returns 0 (all pages already RW), `munmap` returns 0 (memory
reclaimed on exit). **`fork`/`vfork`/`clone` are NOT implemented for this personality** — musl
`system()` and busybox `sh` hang on the first external command (see TODO "Foreign binaries").

**Win32 coverage:** console I/O goes through fdtable, files through VFS handles; environment
via `system/env.zig`. PE tasks get a fake TEB (GS_BASE → zeroed pages; CRT startup reads
`gs:[0x30]`) and a per-task CRT globals block in user memory. UCRT subset in `winapi.zig`:
startup no-ops, stdio over pseudo-FILE*, a C-printf engine driven both by Win64 register
varargs (rdx/r8/r9 + stack) and MSVC `va_list` structures
(`__stdio_common_vfprintf/vsprintf`), string/memory/wcs helpers, `_open/_read/_write/_close`
on VFS fds, WinSock 2 basics. **Math functions taking double args are NOT bindable** — the
InterruptFrame has no XMM state. Real-app status (TODO): busybox ✓, uutils coreutils ✓
(`ls`, `cu`), jq.exe loads but crashes late-CRT, curl.exe/rg.exe hit unimplemented imports.

## User-space (ring 3)

- **GDT selectors** (`src/arch/gdt.zig`): `0x08` kernel code, `0x10` kernel data, `0x18|3`
  user code, `0x20|3` user data, `0x40` TSS; `0x28`/`0x30` unused duplicates. Per-CPU
  GDT/TSS: `gdt_per_cpu`/`tss_per_cpu`, `MAX_CPUS=64`, `setRsp0ForCpu`.
- **Two entry paths into the kernel:** legacy `INT 0x80` (native ABI) and the `syscall`
  instruction (LSTAR → `syscall_entry_64`, used by the `.linux` personality). Args:
  `rax`=number, `rdi/rsi/rdx`. Native numbers live in `src/kernel/syscall.zig`. Implemented:
  write=1 (fd 1–2 → VGA, 3 → serial), read=2 (fd 0 → keyboard), sleep=10, time=11, brk=12,
  fork=57 (COW clone — but forked children are never scheduled under the cooperative
  scheduler, so fork+exec doesn't complete yet), exec=59 (ELF **or** PE from a VFS path),
  exit=60, waitpid=61, socket/connect/send/recv=70–73. `SYS_OPEN=3`/`SYS_CLOSE=4` exist in
  the enum but return ENOSYS (-38); unknown numbers are rejected via `isKnownNative`
  (ENOSYS + serial log) instead of tripping `@enumFromInt` UB.
- **IA32_FMASK** masks `TF|IF|DF|NT|AC` on `syscall` entry (`arch/syscall64.zig`) so
  interrupts are off before the stack switch to kernel RSP.
- Fault isolation (`src/arch/isr.zig`): exceptions in ring 3 (CS.RPL=3) terminate the task
  via `process.exitCurrent(-11)` instead of panicking the kernel.
- Per-task state: 8 TCP socket slots (`sockets` field in `kernel/task.zig`), user heap at
  `USER_HEAP_BASE = 0x04000000` grown page-wise by `brk`; `src/user/heap.zig` is the ring-3
  free-list malloc built on `brk`.
- **Address spaces** (`src/kernel/address_space.zig`): per-task PML4, create/destroy/switch,
  user pages mapped `PAGE_USER`; `destroy()` frees user physical pages.

## USB subsystem

Modular stack under `src/drivers/usb/` (16 files); `src/drivers/usb.zig` is a re-export
shim that mirrors `mod.zig`'s controller/device arrays (`syncState`), keeps compat
accessors, and adds `pollHid()`.

- **Controllers:** `uhci.zig`, `ehci.zig`, `xhci.zig` — **4 instances each**,
  `MAX_USB_CONTROLLERS=12`, `MAX_USB_DEVICES=16` (`usb/mod.zig`). PCI discovery + bus
  mastering in `pci_detect.zig`, PMM-backed aligned DMA pool in `dma.zig`, descriptors/setup
  packets in `types.zig`.
- **Enumeration:** `device.zig` — GET_DESCRIPTOR → SET_ADDRESS → config parse →
  SET_CONFIGURATION, bounds-checked, composite multi-interface up to
  `MAX_DEVICE_INTERFACES=4`; `hub.zig` handles hubs. `mod.zig:init()` does the PCI scan and
  re-scans **reset the instance counters** on every call.
- **Unified HID stack** (modeled on Linux): `usbhid.zig` = transport, `hid_core.zig` =
  device lifecycle + cyclic polling + report dispatch (registered from `mod.zig` via
  `hid_core.registerHidDevice` / `processRawDeviceReport`), `hid_generic.zig` = binds class
  0x03 devices, `hid_input.zig` = usage-page → keycode/mouse mapping incl. Num/Caps/Scroll-Lock
  LED state. Legacy `hid.zig` still does boot-protocol report decoding and 2.4 GHz
  wireless-dongle profiles (`hid.isWirelessDongle` is called from `device.zig`).
- **The report descriptor is the layout.** `hid_report.zig` is a port of the item parser,
  report/field model and bit-stream helpers in `drivers/hid/hid-core.c`: main/global/local
  items, push/pop, usage ranges, `snto32`, `__extract`/`__implement`, and the top-level
  application collection that names a keyboard or a pointer. `hid_core.registerHidDevice()`
  reads the descriptor with GET_DESCRIPTOR(0x22) — the length comes from the HID class
  descriptor's `wDescriptorLength`, because a low-speed control endpoint can only carry about
  112 bytes in one UHCI transfer — and parses it. A parsed descriptor puts a boot interface
  into **report** protocol; only a descriptor that fails to parse leaves it in **boot**
  protocol. `hid_input.handleDescriptorReport()` then walks the fields the way
  `drivers/hid/hid-input.c` does: variable fields name one usage per bit range, array fields
  name the usage that is currently down (the press is the usage that was not down in the
  previous report), and the LED output field (Usage Page 0x08) is what SET_REPORT writes.
  LEDs are never guessed from a report ID any more.
- **HID registration happens after the hub pass.** `mod.zig:init()` initializes `hid_core`
  only after the downstream hubs have been enumerated; registering first means a keyboard
  behind a hub never gets a descriptor table (and therefore never leaves the boot protocol).
  The class drivers are still probed from `usb.poll()`, but the HID *descriptor* read is a
  boot-time control transfer.
- **Composite receivers fan out only by report ID.** When keyboard and mouse share one
  interrupt endpoint, `processRawDeviceReport()` copies a numbered report to the aliases whose
  own descriptor declares that input report ID. The old "byte 0 is 1 or 2" guess is only the
  fallback for an interface with no descriptor — a boot keyboard's modifier byte can be 1
  (left Ctrl) or 2 (left Shift), which used to deliver phantom reports to the mouse half.
- **Unified input layer:** `src/drivers/input.zig` gives one API over USB HID
  keyboards/mice (wired + wireless dongles) and legacy PS/2 (kbd IRQ1, mouse IRQ12),
  re-exporting the key constants, and calls `usb.poll()` itself.
- **Wi-Fi:** `rtl8188eu.zig` registers as `NicType.usb_wifi` and TX/RX through
  `net/mod.zig`. **Storage:** `storage.zig` (mass storage; `usb storage` subcommand).
- **Everything polls — no USB IRQs.** Call sites: `input.zig` → `usb.poll()`;
  `scheduler.pollDeferred()` → `usb.poll()` + `pollHid()`. There is exactly **one** xHCI
  driver, `usb/xhci.zig` (controller + HID in the modular stack); `usb.zig:pollHid()` is
  just an alias of `poll()` because draining the controller event ring *is* the HID path. An
  older standalone `src/drivers/xhci.zig` was dead code (861 lines, imported by nothing,
  with a 0x04 port stride, stack-allocated transfer rings and a 32-bit BAR0 truncation) and
  has been deleted — do not reintroduce a second xHCI path.
- **Diagnostics:** shell `usb`/`lsusb` → `src/programs/usb.zig` → `usb.printUsbStatus(...)`.
  QEMU: `run.sh` adds `-device qemu-xhci -device usb-kbd -device usb-tablet`; the e2e suite
  boots extra profiles (UHCI+HID, multi-controller) via its `get_uhci_hid_log`/
  `get_multi_usb_log` helpers. Coverage: `TC-USB-01..07`, `TC-HID-01..05`, `TC-WIFI-01..05`,
  `TC-DIAG-01..03`, `TC-STRESS-01/04`.
- **A class driver can claim the interrupt endpoint:** `dev.intr_complete` takes the report
  instead of the HID layer — Linux's "the driver owns the interface" rule. The Bluetooth HCI
  transport uses it for the events.
- **The class drivers are probed from `usb.poll()`**, not from `init()`: the xHCI controller
  finds its devices *while it is polled*, so a device on an xHCI port is invisible to
  `init()`.
- **Class 0xff means "vendor specific" and says nothing.** The identity comes from the
  vendor and the product ID (`device.classifyVendorDevice`): the FTDI chips are serial
  adapters, the Realtek ones are Wi-Fi. Before that, every vendor specific device was
  called a Wi-Fi adapter.

## The USB serial adapters (FTDI)

`src/drivers/usb/serial/` — a port of Linux's `drivers/usb/serial/ftdi_sio.c`.

- **`ftdi_proto.zig`** is the chip protocol (the vendor requests, the baud rate divisors,
  the status bits). It has no kernel dependencies, so `tools/test_ftdi.zig` imports the real
  thing and checks the divisors against the values FTDI's application note gives.
- **`ftdi.zig`** is the driver: reset, latency timer, line, modem control, data path. The
  baud rate is a *divisor* of the chip's clock, and each chip family has its own formula
  (the 232R: 48 MHz over a 16-bit divisor; the 2232H: 120 MHz with a fractional one).
- Every packet the chip sends carries **two status bytes** in front of the data: the modem
  status (CTS, DSR, RI, carrier) and the line status (the error bits). They are taken off
  before the data is handed on.
- `usb serial` shows the adapters. QEMU's `usb-serial` emulates an FTDI: it needs
  `always-plugged=true` (or an open chardev), because QEMU only attaches the device when the
  chardev's backend is open.

## The 2.4GHz receivers (HID++)

`src/drivers/hid/hidpp.zig` + `hidpp_proto.zig` — a port of Linux's
`drivers/hid/hid-logitech-hidpp.c`.

A Logitech receiver is a USB device, but the keyboard behind it is not: the receiver forwards
the **HID++** reports and the driver asks the receiver about the device it is interested in.
The protocol has a short report (0x10, 7 bytes, HID++ 1.0) and a long one (0x11, 20 bytes,
HID++ 2.0); both carry the feature index, the function and the parameters.

- The **root feature** (0x0000) is how the host asks for the index of every other feature;
  the answers go into the device's feature table.
- The **device name** (0x0005) comes in parts of four bytes; the parameter index says which
  part.
- The **battery level** (0x1000) and the **LED state** (0x0008) are the other two the
  driver reads.
- The USB stack tells a HID++ report from a boot protocol report by the report ID: the boot
  protocol decoder would make nonsense of them.
- `usb hidpp` shows the receivers and the devices behind them.

## Bluetooth

`src/drivers/bluetooth/` — a port of the Linux Bluetooth stack, in three pieces:

- **`hci.zig`** is the Host Controller Interface protocol core, from
  `net/bluetooth/hci_core.c` and `include/net/bluetooth/hci.h`: the packet formats, the
  command builder, the reset sequence and the inquiry procedure.
- **`btusb.zig`** is the USB transport, from `drivers/bluetooth/btusb.c`: the Bluetooth class
  interface (0xe0/0x01/0x01), the three endpoints the way `usb_find_common_endpoints()`
  picks them, and the command transfer, which Linux sends as a class specific control
  request.
- **`vhci.zig`** is the virtual controller, from `drivers/bluetooth/hci_vhci.c`. Linux leaves
  the answering to userspace; here the controller is emulated in the kernel, so the protocol
  core has something to talk to and the hypervisor can hand a controller to a guest.

`bt` lists the controllers and runs an inquiry; the driver writes the peers it finds to the
serial log, the way the other drivers in the tree do.

## Net / storage / display gotchas

- **NIC abstraction:** `src/net/mod.zig` routes all TX/RX through `net.sendFrame`/
  `receiveFrame` dispatching on `active_nic` (`.e1000`, `.rtl8169`, `.usb_wifi`; `.none` if
  absent — `hasNic()` gates everything).
- **Network is client-only:** static IP 10.0.2.15/24, gateway 10.0.2.2, DNS 10.0.2.3
  (`dhcp` overwrites all three from a lease). `net.nextHopMac()` picks the destination MAC
  (on-link host vs gateway) and **drops the packet when ARP fails**, so `get`/`wget` reach
  the internet through QEMU's slirp. `ensureArp` retries with a growing interval and a 2.5 s
  budget, polling inside the wait — the budget has to outlast QEMU's one second flush
  window (see "Boot time"). Nothing listens on guest:80 — `run.sh`'s "open
  http://localhost:8080" hostfwd message is misleading.
- **The stack polls, it does not use IRQs.** e1000 interrupts are masked on purpose;
  `net.poll()` drains the RX ring from the blocking paths (`ensureArp`, `waitEstablished`,
  `dns.resolve`, `http`, `sys_recv`). `net.tick()` (ARP cache aging + TCP retransmit) runs
  from `scheduler.pollDeferred()` at 1 Hz. `poll()` has a re-entrancy guard because handlers
  transmit and transmitting can ARP; inside a handler `nextHopMac` only fires the request
  and returns null instead of waiting.
- **e1000 register bits are easy to get wrong** — RCTL bit 15 is BAM (broadcast accept,
  required for DHCP OFFERs), bit 3 is UPE (not BAM), bit 6 is loopback (not BSIZE). BSIZE=2048
  is the default (bits 17:16 = 00, BSEX clear). TX descriptors need the RS bit (0x08) for
  the DD status bit to ever be set, and RDT must be written with the index just recycled,
  not the next one. Named constants at the top of `src/drivers/e1000.zig`;
  `e1000.debug_trace` gates per-packet serial dumps (off by default — they are slower than
  the network and cause the timeouts they are meant to diagnose).
- **IP payload length comes from the header, not the frame.** Ethernet pads to 60 bytes, so
  `ip.handlePacket` trims to the declared `total_len` before dispatch; TCP/UDP/ICMP all
  derive payload size from the slice they receive.
- **TCP is minimal but real:** `MSS=1440` (fits MTU + single `retx_buf`), `send()` splits, a
  single retransmission slot per connection, ISN varied per connection, SYN retransmitted
  while `syn_retries < 3` in `waitEstablished`, in-order-only data acceptance
  (out-of-order/duplicate segments are re-ACKed, not appended). Checksums must be computed
  after the payload is in the buffer — `buildTcpHeader` takes the whole segment slice for
  that reason.
- **Disk/FAT16/FAT32:** `run.sh`/`run.bat` create a raw 64 MB `disk.img` if missing. Boot
  scans providers and partitions once, then mounts FAT16 at `/mnt/disk` and probes FAT32
  (512-byte sectors, 8.3 names, one static volume in the MVP) at `/mnt/disk` or `/log`; a
  FAT32 volume labelled `ZLOG` wins over an unlabelled candidate. `klog` stores
  `/KERNEL.LOG` through a 64 KiB async RAM queue with early-boot replay and best-effort
  panic flush; `klog status|flush|dump|clear` is available. `tools/test_fat32_log.py`
  validates a 1 GiB image, nested files, multi-cluster append/copy, and a cluster above
  `0xFFFF`. `mkfs` still reformats FAT16 only. `drivers/ahci.zig` and `fs/partition.zig`
  (MBR/GPT) exist alongside virtio-blk. `vfs.isStaticHandle` prevents `kfree` on the
  static `open_files` BSS array — don't "fix" handle allocation in a way that bypasses it.
- **Framebuffer/GUI:** `src/entry.S` requests a linear 1024x768x32 framebuffer (multiboot
  VIDEO flag). **The bootloader is Limine, and it sets the video mode itself** — there is
  no `set gfxpayload=` chain to get wrong, and no `grub.cfg` any more. `limine.conf` asks for
  `resolution: 1024x768x32` and Limine picks another mode automatically if that one is
  unavailable; `textmode` is the fallback. The framebuffer arrives in the Multiboot info
  block (bit 12), so the kernel-side driver is unchanged. `vga.isFbActive()` accepts **16bpp
  (RGB565), 24bpp and 32bpp** LFBs (`fb_bytes_pp`; all raw-LFB access must go through
  `lfbPut`/`lfbGet` or `rawPutPixel`/`rawPixel` — never index the LFB as `[*]u32`, which
  breaks on 24bpp). 16bpp matters on real hardware: when no 32bpp mode exists, Limine lands
  on a 16bpp one, and rejecting it leaves the machine with **no LFB at all**.
  `initFromMultiboot` also runs `probeLfbSafe()` (from `kernel/boot.zig`'s `system` stage,
  **after** the IDT is installed — a fault before that is an unhandled page fault = triple
  fault = reboot with an empty log), which touches every page of the reported LFB and
  round-trips one pixel plus a full colour-bar pattern, so a bogus address surfaces as
  `[FB] probe MISMATCH/SKIP` in the log and a writable-but-not-scanned-out LFB surfaces as
  bars that never appear (`screen test` re-runs it on demand). **Two video sources, in
  order:** multiboot bit 12 (addr@88, pitch@96, width@100, height@104, bpp@108, type@109)
  and, if bit 12 is clear, the **spec's bit 11 VBE table** (`vbe_mode_info` at mbi+76 → a
  VESA VBE 3.0 mode info block; the driver reads only the *linear* fields: x_res@18,
  y_res@20, bpp@25, memory_model@27, phys_base_addr@40, lin_bytes_per_scan_line@50,
  lin_{red,green,blue}@54-59, and rejects banked/YUV models). Bit 11 is what a spec-only
  loader provides, and the driver used to ignore it entirely. **Channel bytes are ambiguous
  between the spec and GRUB:** the spec puts them at mbi+110, but GRUB's `struct
  multiboot_info` is unpacked and its union holds a `u32` palette address, so the compiler
  aligns it to 4 and they land at **112**. `readChannels()` tries 110 and 112 and accepts
  whichever yields non-empty masks with every field position below the bpp, so do not "fix"
  it to one of them — GRUB is gone, but other Multiboot loaders still exist, and the same
  ambiguity applies. Byte order is **derived** from the reported positions
  (`fb_red_first`; `R@16 G@8 B@0` = BGR, as on nearly all PC displays) and honoured by
  `lfbPut`, `lfbGet` and the 32bpp `flush()` fast path. `dumpMbiVideo()` prints raw
  `mbi[80..144]`, the only way to tell a misread offset from a genuinely absent field on
  hardware unlike QEMU. If `[FB] No framebuffer info from bootloader` appears (bits 11
  *and* 12 both clear), the bootloader passed no video mode at all — check `limine.conf`'s
  `resolution:` and that the ISO was actually rebuilt, not a driver bug. **There is no runtime
  video-mode setter:** `boot_width`/`boot_height`/`boot_pitch` hold the real hardware
  geometry, and `fb_width`/`fb_height` are a *viewport* clamped to it by `setViewport`, so
  `resolution <WxH>` only rescales inside the boot mode (it used to grow the viewport past
  the real LFB). Changing the actual mode means changing `limine.conf` and rebuilding the
  ISO — the kernel cannot do it at runtime. `limine.conf` also has a `serial: yes` option:
  with it the *bootloader* mirrors its output to COM1 as well, the only way to see anything
  when the display is dead. Commands: `screen`/`video` (`info|redraw|refresh|clear|test`),
  `gui`, `resolution`, `mouse`. `framebuffer.zig` is a shadow buffer: draw into RAM, then
  `flush()` the tracked dirty rect (clamped to the boot geometry) to the LFB;
  `shadow_stride_px` tracks the width the allocation was made for so a viewport change
  re-strides instead of walking rows with the wrong stride. **The console and the
  framebuffer are separate layers** (see "Console
  and surfaces" below) — `framebuffer.zig` is the graphics driver only. The harness runs
  `-display none`, so GUI changes need visual verification via `tools/boot_watch.py` (QMP
  screendump → `screen.ppm`), and shell commands there need the `cmd:` prefix.

- **Adding a shell command needs two required edits** in `src/shell.zig`: a handler
  `fn(args: []const u8)` (zero-arg programs get an adapter like `fn runX(_: []const u8)`) and
  one `command_table` entry. The table drives **dispatch and tab completion** (`execute`
  iterates it — there is no separate dispatch branch to add). Also add a line to `printHelp` —
  it is a hand-written list, not generated from the table. Full-screen programs
  (lua/matrix/gui/nano) clear the screen and reprint the banner on exit — see `cmdLua` for
  the pattern. Unknown input falls through to `execFromPath` → `resolveExecutablePath`, which
  tries the raw name, `/bin/<name>`, `/mnt/disk/<name>`, then each with a `.exe` suffix.

## Console and surfaces

The text console exists **once**, and draws through a `Surface` (`src/system/gfx/surface.zig` —
a vtable of `cell_width`/`cell_height`/`grid_cols`/`grid_rows`/`put_cell`/`clear`/`flush`/
`scroll_up`). Two surfaces implement it: `gfx/vga_text.zig` (the 0xB8000 character buffer) and
the linear framebuffer (`src/system/framebuffer.zig`). `gfx/mod.zig` owns the active surface
and exposes the console API; `src/system/vga.zig` re-exports it, so `vga.write(...)` and
friends are unchanged for the ~750 call sites.

- `gfx/console.zig` owns the grid, the cell mirror, the cursor, the colours and the
  scrollback ring (256 lines). The grid follows the surface (up to 160x60) instead of being
  pinned to 80x25, so a 1024-wide framebuffer uses 1024 pixels of text, not 640.
- **A scrolling console scrolls the *shadow*, never the LFB.** The old code copied shadow
  rows into the LFB byte-wise, but the shadow holds `0x00RRGGBB` while the mode wants its
  own byte order — so red landed in the blue channel of every 24/32bpp mode and the help
  output came out red after the first scroll. The surface's `scroll_up` moves the shadow
  only; the normal flush path repacks it.
- **`shadowUsable()` must call `ensureShadow()` first.** Testing `shadow_pixels != 0` before
  it short-circuits on the very first draw, the shadow is never allocated, and every draw
  lands straight in the LFB — invisible until something needs the shadow, i.e. a scroll
  (the screen then fills up and the rest of the output is lost).
- `redrawRow` must not mutate the console's colours while repainting, and `vga.putChar` must
  not re-derive the colours on every character: a program that sets a custom colour loses it
  otherwise.
- The PgUp/PgDn scrollback is **one** implementation now; the shell used to branch on
  `vga_fb.active` because the VGA-text and framebuffer consoles kept separate histories.

## The display stack (DRM)

`src/drivers/drm/` — a port of the Linux DRM model around the framebuffer the bootloader
hands over.

The kernel's display is exactly Linux's **"simple framebuffer"** (`drivers/video/fbdev/
simplefb.c`): the bootloader sets a mode and the kernel draws into the memory it was given.
What was missing was the model around it.

- **`edid.zig`** is the EDID parser, from `drivers/gpu/drm/drm_edid.c` and
  `include/drm/drm_edid.h`: the manufacturer ID (three letters in five bits each), the
  product code, the monitor's name, the detailed timings and the established timings.
  **The display descriptor's type is in byte 3 and its text in bytes 5..17** — Linux's
  `struct detailed_non_pixel`, and the only layout that matches a real EDID.
- **`connector.zig`** is the connector (`drm_connector.c`): the status (connected,
  disconnected, unknown), the detection and the mode list the EDID provides. The
  **preferred mode is the largest one**, not the EDID's own "preferred" bit — that is what
  Linux's `edid_fixup_preferred()` does.
- **`fbdev.zig`** is the CRTC and the fbdev emulation (`drm_crtc.c`,
  `drm_fbdev_client.c`): the mode the CRTC runs at, the power state and the
  `fb_var_screeninfo`/`fb_fix_screeninfo` a program sees.
- **`ddc.zig`** reads the EDID over the VGA's display data channel, the way
  `drivers/video/mfb.c` does. The lines only exist on an adapter that is wired for them, so
  a failure means "no EDID", not "the kernel is broken".
- The parser has no kernel dependencies, so `tools/test_edid.zig` imports the real thing and
  checks it against the EDIDs Linux's own DRM tests use — 46 checks against blobs that
  `edid-decode` also decodes.
- `drm` shows the connector, the modes and the EDID.

## The display falls back to software rendering

**A display that cannot be driven is not a reason to stop the boot.** The
chain is:

1. the linear framebuffer the loader handed over (multiboot bit 12, or the
   VBE table in bit 11);
2. the linear framebuffer of a PCI display adapter
   (`drivers/video/pcidisplay.zig`, the X.Org `FB_SIMPLE` interface);
3. **the legacy VGA text mode**, where the kernel paints the characters
   itself - software rendering, no adapter involved;
4. **the serial port**, when there is no display at all.

The fallback is what `probeLfbSafe()` decides, and it is **not** fatal: the
console moves to the text mode and the boot goes on, so the machine still
runs and the reason still reaches the kernel log. `screen text` and
`screen fb` switch between the surfaces by hand.

### A framebuffer above the identity map

**The identity map covers the low 64 GB, and a framebuffer does not have to
be inside it.** A discrete GPU's framebuffer BAR at 8 TB (`0x7FE0000000`) is
perfectly normal - that is where the firmware puts it - and the old driver
refused such an address and left the machine with no console at all.

The range is now mapped where it is: `vmm.mapRange()` walks the current
page tables and installs 2 MB pages at the *identity* virtual addresses, so
the address the firmware reported can be used as it is - no relocation, no
copy. The page tables come from the memory manager when it is up and from a
small static pool in the kernel's .bss when it is not: the framebuffer is
mapped in the boot stage *before* the memory one.

The mapping is only made in the **kernel's** address space. A task that runs
later does not get it: `AddressSpace.create()` copies the lower half and the
kernel half of the PML4, and the framebuffer lives in the middle, where a
user address space has nothing.

Two checks say whether the mapping is really there: `fb_mapped` (the range
was mapped) and `virtToPhys(fb_addr) == fb_addr` (the page walk resolves
the address to itself). The second one is the line in the log that separates
"the kernel cannot reach it" from "the hardware does not scan it out".

### The legacy VGA text mode, programmed by hand

Writing characters into 0xB8000 is not enough: the adapter has to be *in*
the text mode for that buffer to be displayed at all. `drivers/video/
vga_mode.zig` programs it - the register values are the ones Linux's own
`arch/ppc/boot/vreset.c` uses ("Initialize VGA control registers to 80x25
text mode"), the register names come from `include/linux/vga.h`, and the way
the console uses the buffer comes from `arch/x86/kernel/video/vgacon.c`.

The adapter's presence is decided by the graphics controller's miscellaneous
register: it reads as all ones when there is no legacy VGA at all, which is
the case on a machine whose only display is a discrete GPU. `screen text`
refuses to switch the console there - the picture on the screen would stay
the framebuffer's and the console would paint into a buffer nobody looks at.

The registers are read back and logged (`[VGA] registers: SR4=.. GCR6=..
AR=..`), because the adapter is the only witness of what the programming did.
One adapter ignores it: **QEMU's Bochs VGA keeps the graphics mode while its
VBE extensions are enabled** - the VBE code rewrites the graphics
controller's miscellaneous register after every write to it - so the legacy
text mode cannot be reached there once the firmware has switched to a VBE
mode. That is a property of that adapter, not of the machine.

### The serial port is the console when there is no display

A machine with no usable framebuffer *and* no legacy VGA has no console at
all. The shell is driven over the serial port, so its output has to come
back the same way: `console.setSerialMirror()` mirrors every character that
goes through the console engine (the one place they all pass, so a number
written with `writeDec()` is mirrored too). The boot turns it on when there
is no display at all, and `console serial on` turns it on by hand - which is
the only way to see what the shell does on a machine whose screen stays
black.

Three rules the framebuffer driver follows so that a bad address cannot
hurt the machine:

- **Nothing is written to an address the kernel cannot reach.** The range is
  mapped first, and the probe checks that the address resolves to itself.
- **Nothing is written to an address the kernel has not checked.** The
  console renders into the shadow buffer (ordinary RAM) and nothing is
  pushed out until the probe has read back the pixel it wrote.  A loader
  can hand out an address that belongs to a *device* - a display adapter's
  register file - and writing a whole screen of pixels there is how a
  machine hangs: the write never comes back.
- **The probe never kills the boot.** A framebuffer that does not read back
  what was written to it is disabled, not fatal.  The probe writes **one**
  pixel; the full colour bar pattern is the `screen test` command, never
  something the boot does on its own.

**The kernel log needs a volume the kernel can mount.** It is a file on a
FAT16 or FAT32 volume, so a stick whose filesystem the kernel does not know
(Ventoy's own partition, for instance) gets no kernel log at all - the
messages stay in the serial log and in RAM.

**The virtio-blk driver had never worked.** The device status register of
the legacy virtio interface is **eight bits** wide, and the driver wrote it
with `outl` - four bytes - so the status never stuck, the queue was never
enabled, and every request timed out.  The disk was neither read nor
written: the kernel log was always empty, and `TC-VFS-02` had been
PROGRESSIVE rather than PASSED for exactly that reason.  The status is
written byte by byte now, the queue address has its enable bit set, and
the ring memory and the request buffers are sized for the queue QEMU
offers (1024 descriptors).

The order of the writes matters too: the descriptors have to reach the
device before the available ring is updated, so there is an `sfence`
between them.  Without it the compiler may move the stores after the ring
update, the device works from the previous descriptor, and a read returns
the sector before the one that was asked for.

## When the machine comes up with a black screen

**The serial log is the primary diagnostic.** A black screen means the kernel
cannot say anything on the display it was supposed to use, and the kernel log
(`/KERNEL.LOG`) only exists once the storage stage has run — a failure before
that leaves no file at all. So: **capture COM1** (115200, 8N1).

The boot log now names the stage it is in (`[BOOT] stage 7/17 storage`), and
the panic message repeats it, so a machine with a black screen still says how
far it got.

**A framebuffer above the identity map used to be the reason for a black
screen.** The identity map covers the low 64 GB and a discrete GPU's
framebuffer BAR at 8 TB is perfectly normal, so the driver refused the
address and the machine was left with the text mode - which the same adapter
does not scan out either. The range is mapped on demand now
(`vmm.mapRange()`), and the log says which of the two it is:

- `[FB] the LFB range is mapped (3072 KiB at its own address)` - the mapping
  is there;
- `[FB] probe OK: LFB is readable and writable` - the pixels can be written
  and read back;
- `[FB] probe MISMATCH` - the address is not backed by anything.

If the probe passes and the screen is still black, the buffer is writable
and the hardware is simply not scanning it out: that is the case of a GPU
whose display engine was programmed for another mode, and the serial log is
the console then (`console serial on`).

**The PCI base address registers are printed for every display adapter**
(`[DISP]   BAR0 0x...`). The address in the multiboot info and the address
in the BAR have to be the same one - that is what says whether the mode the
firmware set up lives on the adapter the kernel found.

**A silent reboot is a triple fault**, and a triple fault means the failure
was never reported: the CPU tried to handle a fault, could not do it on the
stack it was given, and reset. The double fault now has a stack of its own
(the interrupt stack table, `ist1` in the TSS) and prints what happened
instead of letting the machine die silently — and it never returns, because
going back to the state that faulted would fault again.

Two things in the display code can disturb a machine and are guarded
against:

- **The graphics controller's miscellaneous register decides how the legacy
  VGA window is decoded**, and its bits 3:4 are the memory map. Writing
  0xff there takes the text buffer at 0xB8000 out of the window — a black
  screen. The register reads as all ones when there is no legacy VGA at all
  (a machine whose only display is a discrete GPU), so the DDC reader refuses
  to write it.
- **Reading a device's register file can have side effects** (it can clear a
  status bit, or wake the card up), so only *prefetchable* BARs are probed
  for a framebuffer: a register file is not prefetchable, a framebuffer is.

## Traps that cost real time

- **The xHCI slot context's speed is the port status register's encoding.**
  Linux's `drivers/usb/host/xhci.h` says so in as many words ("Device speed -
  values defined by PORTSC Device Speed field"): 1 = full speed, 2 = low
  speed, 3 = high speed, 4 = super speed, 5 = super speed plus. Writing a
  converted value programs a *different* device class into the slot, and the
  xHC answers with a Parameter Error for the Address Device command. The
  driver writes `port_status.speed` straight through; there is nothing to
  convert.
- **A hub's slot context is updated with Configure Endpoint, not Evaluate
  Context.** Linux (`xhci_update_hub_device()` in `drivers/usb/host/xhci.c`)
  distinguishes them by the controller revision: above 0.95 it sends
  Configure Endpoint, 0.95 and older use Evaluate Context. Only the former
  makes the xHC treat the slot as a hub, so with Evaluate Context every
  Address Device command for a device below the hub comes back a Parameter
  Error - and the hub's downstream ports look empty. The same command is
  where the TT think time (`wHubCharacteristics` bits 6:5) and the port
  count go. QEMU stores the context as it is given and never checks, so the
  emulator enumerates hub children either way.
- **The interrupt endpoint's Interval is an exponent, and the encoding
  differs by speed.** A high-speed endpoint's `bInterval` is already
  `2^(bInterval-1)` microframes, so the field is `bInterval - 1`
  (`xhci_parse_exponent_interval` in `drivers/usb/host/xhci-mem.c`). A
  full- or low-speed `bInterval` is a count of *frames* (milliseconds),
  which is `log2(bInterval * 8)` microframes clamped to 3..10
  (`xhci_parse_frame_interval`). Using the high-speed formula for both - or
  adding a constant to both - makes a full-speed keyboard be polled every
  16 ms or worse. QEMU ignores the field and delivers the pending report on
  the next IN token, which is why the emulator test passes while the
  keyboard on the bench needs every key held down.
- **The Input Context has a leading context, the Output Context does not.**
  In an Input Context, DCI N lives at `(N + 1) * ctx_size` because the Input
  Control Context comes first; in the Output Device Context there is no such
  header, so DCI N is at `N * ctx_size`. Copying an endpoint context out of
  the output with the input's offset reads the *next* endpoint (or past the
  end of a fresh slot), so the follow-up command carries a zeroed context
  and the controller rejects it while the emulator quietly accepts it.

- **A global declared `undefined` does not get the field defaults of its type.** The virtual
  Bluetooth controller lives in such a global, so its address and its flags were silently
  zero. Declare it `.{}` — and give the type defaultable fields (a function pointer needs a
  default stub).
- **A `u3` loop counter can never reach 8**, so `while (i < 8)` never ends. The DDC reader
  had exactly that, and the machine hung in a loop the compiler was allowed to assume could
  not happen.

## The emulator's speed

Two things made the guests slow, and the shell paid for both of them because the shell's
input loop polls the machines on every character.

- **The page walk is the most expensive thing the emulator does**, so an access that stays
  inside one page is translated **once** and the bytes are read from the host address. The
  emulator used to read and write byte by byte, and every byte walked the guest's page
  tables: an eight byte load cost thirty two table reads.
- **A guest that has halted stays halted.** The emulator used to step past the `hlt` and run
  whatever followed it in the guest's memory, forever; `cpu.run()` returns at the halt now and
  `machine.runCpu()` does not even start a slice for a guest that is already halted.
- **The console scrolls without repainting the row it exposes.** The framebuffer fills it
  with the background and the VGA text with the console's colours, so the row the mirror
  shows as blank is blank on the screen too. Repainting it meant drawing 160 glyphs — 20 000
  pixel stores — for a row that was already blank.
- **`drawGlyph()` is already fast**: the compiler turns the eight conditional pixel stores
  into a vectorised blend. Unrolling the loop by hand (`inline for`) *broke* that and made
  the console half again slower.

## DynamicalKVM (ZVM)

`src/vm/` — the hypervisor. The kernel itself has **no programs of its own**: it is a
hypervisor with a device model, and everything the operator sees comes from a guest (Linux,
Android, XNU, BSD). The host's own shell exists to *drive* the machines, not to be one.

- `profile.zig` — **what machine a guest is shown.** A guest kernel is written against a
  machine: Linux 2.4 on a 1998 i386 expects an 8259 PIC, an 8254 PIT, one core and a
  1024x768 15-bit framebuffer. Emulating the *wrong* machine is not "more capable", it is
  broken — the guest takes a fallback path it was never tested on. So each guest gets a
  profile: the device set, the CPU model, the RAM, and the display.
  - `CpuModel` is the "weak CPU" part: `i386` (no SSE, no APIC), `pentium` (SSE), `core2`
    (SSE2, local APIC), `x86_64` (everything). A guest that never used SSE gets a Pentium,
    not a Core 2 — the *absence* of a feature is what makes the guest take its intended
    fallback path.
  - `DisplaySpec` is the "weak GPU" part: an old guest gets 640x480 16bpp, a modern one
    1280x800 32bpp. A guest has a fixed idea of its screen size and pixel format, and a
    mismatch shows up as a corrupted console.
  - `autoSelect(observations)` is the **auto-detection** path. The hypervisor records what
    the guest actually did while probing (`Observations`: did it program the 8259, did it
    read the I/O APIC, did it touch the local APIC, did it scan PCI, which CPUID leaves did
    it ask for, did it announce a screen size) and then picks the machine that fits. The
    rules, in order: the interrupt controller the guest *uses* decides whether there is an
    I/O APIC; the strongest feature it asked for sets the CPU (never more); no PCI scan
    means no PCI bus, and therefore no virtio devices.
- `resources.zig` — **how many cores and how much RAM each guest gets.** Two policies:
  `manual` (the operator's numbers stand) and `auto` (the hypervisor divides the host's
  resources, weighted by what each guest asked for — a 1 GB Android guest and a 32 MB Linux
  2.4 guest get very different shares, and both get enough to boot). The partitioner also
  produces the **core masks**: the host CPUs a machine's threads are bound to. The masks are
  disjoint, so two machines never fight over the same core — the "re-addressing the threads"
  part. `MAX_MACHINES = 8`.
- `machine.zig` — one guest: its profile, its budget, its display, its vCPUs. `runSlice`
  executes the guest's instructions on the virtual CPU (`cpu.zig`); with no guest loaded the
  machine renders its identity into its virtual display instead, which exercises the whole
  display path.
- **`vm.autoload()`** — the **autoload**. Every machine in `config.machines` is created at
  boot, without the operator typing anything: the profile it is shown as, its identity, its
  display, its device and its budget. The machines are all created first and the partition is
  computed once at the end, because the partition depends on how many machines there are.
- **`vm.loadGuests()`** — loads each machine's guest kernel into its memory. This is a
  separate stage from the machine creation because it needs the disk, and the disk is only
  mounted by the storage stage.
- The guests' RAM is **one contiguous block** the hypervisor reserves at startup and carves
  up per machine. A guest's physical memory has to be contiguous — guest physical address X
  is at `ram_base + X` and its page tables point straight at that — so asking the memory
  manager for a contiguous run per machine fails as soon as two machines exist, because the
  first has already taken the top of the pool. The partitioner's shares are rounded **down**
  to whole pages, because rounding them up would make the total larger than the pool and
  squeeze the last machine out.
- `vm.poll()` runs the guests. It is called from `scheduler.pollDeferred()` (the shell's
  input loop), **not** from the tick handler: emulating a guest is not a bounded operation,
  and the tick handler must never block. The partitioner's `time_share` divides the emulated
  quanta between the machines, so a machine with a smaller budget visibly advances less per
  tick.

### The hypervisor's own device, and the identity it presents

**Every machine is presented as a different computer, and the hypervisor itself is
invisible.** That is the whole point: a guest that can identify the hypervisor can also
target it — a driver that recognises the virtual platform behaves differently, an
anti-cheat system refuses to run, a kernel takes a "virtual machine" fallback path that is
slower and less tested than the native one. And two guests on the same hypervisor must not
be able to tell they are on the same one.

- `src/vm/identity.zig` — the identity. It is built from a **persona** (eight plausible
  physical computers: Intel desktop, AMD desktop, Intel server, AMD server, legacy i386 PC,
  AMD K8-era, workstation, compact PC) plus a per-boot seed:
  - A **real vendor ID** (`0x8086` Intel, `0x1022` AMD, `0x10DE` NVIDIA, `0x1033` …), so the
    guest's driver binds to that vendor's ordinary driver instead of a "virtual" one.
  - A **device ID unique per machine** but drawn from that vendor's range, so it looks like
    an obscure model rather than a giveaway. Real device IDs are arbitrary 16-bit numbers and
    many are unassigned.
  - ACPI OEM strings, SMBIOS manufacturer and product, a machine UUID and a CPU brand string
    that all agree with each other and with the vendor — a "Dell OptiPlex 7090" with an
    Intel i5-10500, not a mismatched pile.
  - **No hypervisor CPUID leaf.** Leaf `0x40000000` is where a hypervisor announces itself;
    it is never implemented, so a guest that probes for it finds nothing.
    `hypervisor_leaf_present` is a field so the intent is explicit and testable.
  - The seed comes from `mixSeed()` over the timestamp counter, the tick count and the
    memory manager's state, so the identities differ **between boots** as well as between
    machines. A guest that records its machine's identity and reboots finds a different
    machine next time.
- `src/vm/proto.zig` — the **shared UAPI**. It is imported by the hypervisor's device *and*
  by the guest driver, so the two cannot drift apart. It contains only constants, so a
  freestanding guest program can include it. It also carries the guest-visible addresses:
  `REGS_VADDR = 0x7000_0000`, `WINDOW_VADDR = 0x7010_0000`, `GUEST_RAM_VADDR =
  0x7200_0000`, `REGS_SIZE = 4096`, `WINDOW_SIZE = 64 KiB`.
- `src/vm/devices/zvp.zig` — the **ZVP (Zirconium Virtual Platform)**: the hypervisor's own
  device. A PCI function with a configuration space (built the way a guest's PCI model would
  serve it) and two memory-mapped BARs: BAR0 the register block, BAR2 the 64 KB shared
  window. Commands: `PING`, `IDENTITY` (the identity blob into the shared window),
  `SET_ACCENT`, `POST` (a message from the guest), `CLOCK`, `OBSERVE` (the guest reports
  what it found while probing, and the hypervisor re-chooses the machine it should have
  shown it), `MACHINE`, plus `TRANSLATE`/`READ_MEM`/`WRITE_MEM` for the guest's own memory.
  - **The command protocol is a doorbell, not a status flag.** The guest writes its
    arguments, the command, and then a sequence number to `REG_DOORBELL`; the hypervisor
    echoes that number to `REG_SERVICED` when it is done. A flag cannot work: the guest
    writes the registers directly, so the hypervisor never sees the write and cannot clear
    the flag, and a stale answer from the previous command is indistinguishable from the
    current one.
  - `Zvp.service()` runs **from the tick handler** (`scheduler.scheduleTick` →
    `vm.serviceDevices()`), because a guest spinning in a wait loop needs an answer and the
    tick is the only thing that runs while the guest has the CPU. It must not block, so a
    guest that posts a message leaves it behind and `flushLog()` writes it out later, from
    the deferred path.
- `src/user/kvm_test.zig` — a **guest driver**, in ring 3, that behaves exactly as a guest
  kernel's driver would: find the device, check the magic, ping it, ask what machine it has
  been given, check that the hypervisor bit is clear, report its observations, post a
  message, set the accent colour. It is built as a freestanding ELF (`kvm_test_bin`, built
  by `build.zig` like the other user tests) and the hypervisor's registers and shared window
  are mapped into its address space by `scheduler.addElfUserTaskMapped()`. **The same code
  will run unchanged under the CPU emulator**, where the registers are reached through a
  guest page table instead of a mapping the hypervisor set up. Run it with `kvm guest [id]`.

### The guest's PCI bus

`src/vm/pci.zig` — a guest finds its hardware the ordinary way: it writes a
bus/slot/function/register address to **0xCF8** and reads or writes the configuration space
through **0xCFC** (ports 0xCFC..0xCFF are the four byte lanes, so a driver that only knows
how to write bytes still works).

- **The device is where the guest says it is.** A memory BAR is a place the guest chooses:
  when it programs a BAR the hypervisor moves the device there (`mmu.Memory.moveRegion`
  plus `mmu.Tables.mapDevice`) and the guest's page tables follow. The BARs are 32-bit and
  live in the PCI memory window at 0xF000_0000, above the guest's RAM, so a guest that only
  knows 32-bit BARs can still reach them.
- The hypervisor's device sits at **bus 0, slot 0x1E, function 0**. Its vendor/device IDs
  are the machine's own (see `identity.zig`), so two guests never see the same device.
- **Compare the vendor, not the whole dword.** An absent function reads all ones, so the
  *vendor* — the low half — is what tells a present function from an absent one.
- `samples/guest_hello.S` scans the bus, relocates the device to 0xE000_0000 and verifies
  the magic there — a real guest, not one that assumes a fixed address.

### Guest memory and the MMU

`src/vm/mmu.zig` — the guest's memory and the page walker. Two address spaces are in play,
and confusing them is the classic bug:

- The **guest physical** address: what the guest's page tables talk about, a number in the
  guest's own address space starting at zero.
- The **host physical** address: where those bytes actually live.

A machine's RAM is one contiguous block of host memory, so the two differ by a constant:
`host = ram_base + guest`. `Memory.translate()` walks PML4 -> PDPT -> PD -> PT exactly as
the hardware does, reading each level out of the guest's RAM, and short-circuits on a huge
page. It returns the *host* physical address, which is what a CPU emulator needs.

- Each machine's RAM is allocated from the PMM according to its budget. The pool is
  **sized to what the configured machines ask for** — their profiles' `ram_mb`, or an
  explicit `ram_mb` in `config/kernel.json` — capped at three quarters of the free memory
  so the guests' display buffers, the kernel heap and the shadow buffer always have room.
  It used to be three quarters of the free memory unconditionally, which on a 32 GB host
  handed 24 GB to two guests that had asked for 1.5 GB. A configuration that names no
  machines still gets the whole fraction, because the operator is going to add machines at
  runtime and the pool cannot grow after it has been reserved.
- The guest's RAM is mapped into the guest driver's address space (`GUEST_RAM_VADDR`), so
  the driver can build page tables in it — which is exactly what a guest kernel does at boot.
  The mapping's offset *is* the guest physical address, so the driver can compute a guest
  physical address for anything it writes.
- The device grew `CMD_TRANSLATE`, `CMD_READ_MEM` and `CMD_WRITE_MEM`. A 64-bit value does
  not fit in the 32-bit argument registers, so it is passed in two of them (ARG1 and ARG2)
  and comes back in two result registers (RESULT0 and RESULT1).
- The initial page tables (`mmu.Tables`) map the guest's RAM identically and map the device
  regions (`DEVICE_GPA`, `WINDOW_GPA`) into the guest's address space. The page table
  entries hold **guest** physical addresses — it is the walk that turns them into host
  addresses — and the walk resolves a device mapping through the machine's *device regions*,
  because the device is not in the guest's RAM.

### The virtual CPU, and guests that actually run

`src/vm/cpu.zig` — the interpreter. It implements the opcodes a guest uses while it brings
itself up, and it traps on anything else rather than guessing. Two rules keep it honest:

- **Every memory access goes through the guest's page tables.** The host address is whatever
  the walk says, and a guest that touches a page it does not own faults, exactly as on real
  hardware.
- **The flags are computed properly.** A guest's boot path branches on them, and an emulator
  that gets `ZF` wrong does not fail loudly — it takes the wrong branch and hangs somewhere
  else.

The traps worth writing down, because each one cost a debugging session:

- **The eight arithmetic/logic groups lay their forms out the same way**, and the layout is
  the one that catches people out: `/0` r/m8,r8 · `/1` r/m,r · `/2` r/m8,imm8 · `/3` r/m,imm ·
  `/4` AL,imm8 · `/5` eAX,imm. The obvious reading — "the odd forms take an immediate" — is
  wrong: `/1` is the register form and `/2` is the *byte* immediate form. Reading them the
  other way eats a byte that is not an immediate, which desynchronises the instruction stream
  — and that looks like the guest jumping off into nowhere a few instructions later, with no
  hint of what went wrong.
- **`cmp` is `sub` without the store.** Group 7 computes the flags and leaves the operand
  alone; writing the difference back silently corrupts the guest's registers
  (`cmp $32, %r13d` turning the loop counter into −32), which the guest then uses as an
  address.
- **A RIP-relative displacement is signed.** Taking it as unsigned puts the effective address
  millions of bytes off.
- **The immediate follows the *operand* size.** `movw $imm16, %dx` carries a two-byte
  immediate, and reading four desynchronises the stream.
- **`in al, dx` puts the value in AL** and leaves the rest of RAX alone. Putting it anywhere
  else means a guest that polls a status register then tests a *different* bit spins forever.
- **The page walker returns a host address.** A huge page short-circuits the walk, and its
  branch has to end at the same place as the normal one — returning the *guest* address
  there makes every access land in the wrong place.

`src/vm/uart.zig` — the guest's **virtual 8250**. The guest's console is a serial port,
exactly as on a real PC, so the guest needs one. It does *not* get the host's: a guest that
programmed the host's UART would change the host's baud rate and mix its characters into the
host's log. The DLAB bit redirects **only** offsets 0 and 1 to the divisor latch — redirecting
every register leaves the guest unable to clear DLAB at all, and every later read of the
status register returns nonsense.

`src/vm/loader.zig` — the **guest kernel loader**. It reads the image through the host's
VFS (a guest kernel is just a file on the host's disk), parses the ELF, places the `PT_LOAD`
segments in the guest's RAM, and builds a **Multiboot 1** boot information block — the
cheapest protocol that Linux, NetBSD and FreeBSD all understand. The block lives at guest
physical 0x1000 (4 KiB, mostly zeroes) with the magic, flags and checksum in its last 12
bytes; the guest's entry is called with **RDI** (and RSI) pointing at it, and the command
line at 0x2000. The loader verifies the segments against the file after copying them and
computes the checksum — "the magic is not where I put it" is much easier to find from the
host than from inside the guest. If the configured image is not on the disk, the loader
falls back to the built-in sample guest.

`samples/guest_hello.S` — a **guest kernel**, in assembly on purpose: the interpreter
implements a specific set of instructions, and a hand-written guest is a list of exactly
those. It checks the Multiboot magic, scans the PCI bus for the ZVP, relocates it, reads its
version, asks which machine it was given, pings the hypervisor and halts.
`tools/create_guest_disk.py` builds it and puts it on the disk at `/vms/`.
`samples/guest_stub.S` + `samples/guest_kernel.zig` are the template for a real guest (32-bit
Multiboot stub + ordinary code); the stub is **not linked yet** — `build.zig` assembles
`guest_hello.S` with `guest_root.zig` instead.

The whole thing runs today:

```
[linux] [GUEST] ZVM guest: hello
[GUEST] multiboot magic ok
[GUEST] found the ZVP device
[GUEST] ZVP version 1 0000000000000001
[GUEST] machine 0
[GUEST] the hypervisor answered
[GUEST] guest: done
```

(the `[linux] ` prefix is added by the host when it drains the guest's virtual
UART; the guest's own strings are the `[GUEST] …` ones)

### Displays and the compositor

`src/system/gfx/output.zig` — a **virtual display**: the host-side view of one guest's video
memory. Allocated from the PMM in whole pages and exposed as a physical address, precisely so
it can be mapped into a guest's address space later without changing anything above it.
Pixels are 0x00RRGGBB, the same layout the framebuffer shadow uses. `MAX_OUTPUTS = 8`.

`src/system/gfx/display.zig` — the **compositor**. It owns the physical framebuffer and
decides what is on it:

| Layout | What is shown |
|---|---|
| `host` | the Zirconium console has the whole screen (the normal mode) |
| `solo` | one guest fills the screen |
| `tile` | **every guest at once, in a grid** |
| `focus` | the focused guest fills the screen, with a strip along the bottom showing the others |

The layout is a *mode*, not a window manager: a guest either has the screen, a cell in a
grid, or nothing. That is the right shape for a hypervisor — there is no desktop to drag
windows around on, there are machines. Compositing uses **nearest-neighbour scaling**
(`fb.blitScaled`): a guest's output is shown exactly as the guest produced it, just at a
different size. Switching back to `host` has to repaint the console, because the guest
layouts composite over the whole screen.

The shell command `vm` (also spelled `kvm`) drives it: `vm list` (the known guest profiles),
`kvm add <name> [profile]`, `kvm rm <id>`, `kvm layout <mode>`, `kvm focus <id|next|prev>`,
`kvm policy <auto|manual>`, `kvm budget <id> <cores> <ram_mb>`, `kvm dev [id]` (the device as
a guest sees it), `kvm guest [id]` (run the guest driver against a machine), and
`kvm view [seconds] [layout]` — the full-screen viewer, where **Tab** moves between the
systems, a digit focuses one directly, **t** cycles the layout, clicking a thumbnail in the
strip moves the focus there, and **Esc** goes back to the host.

## Kernel / toolchain conventions

- Run `zig fmt` on the files you edit. The tree is **not** uniformly formatted; do not do a
  repo-wide reformat as part of a feature change — it buries the real diff.
- No std I/O in kernel code: VGA is the user-facing UI, serial (`/dev/ttyS0`) is the debug
  log. `main.zig` defines `pub fn panic` (VGA + serial + `system/panic.zig:printBacktrace`,
  then `hlt`); the std panic handler is unused. `kernel_entry`, `syscall_handler`, and
  `win_thunk_handler` are exported (the latter two forced via a `comptime` block in
  `main.zig`) because asm references them; `syscall_entry_64` and `sys_exit_return` are
  defined in `isr.S` and `extern` in Zig. Inline asm uses Zig 0.16 clobber syntax:
  `: .{ .rax = true, .memory = true }`.
- `kalloc` never coalesces non-contiguous chunks (physical contiguity check:
  `block_end == @intFromPtr(next)`).
- `.gitignore` covers `.zig-cache/`, `zig-out/`, `build/`, `isodir/`, `*.iso`, `qemu.log`,
  `serial*.log`, `test_out.log`, `*.img`, `screen.ppm`, `ser_capture.log`, `__pycache__/`,
  `samples/guests/`. `samples/*` (incl. `busybox`) and the other committed binaries are
  fixtures **on purpose** — don't add more.
- Docs: `README.md` is cosmetic. `AGENTS.md` + `TODO.md` (real gaps, incl. "Foreign
  binaries") are the working docs. Milestone/task spec lives in `promtpt.txt`; full test
  matrix in `TEST_INFRA.md`; `.agents/` holds the per-milestone briefs, dispatches and
  handoffs from the earlier orchestrated effort (read-only history, not live state).

## Lua

`lua` shell command (`src/programs/lua.zig`) runs the interpreter on a 128 KB
`FixedBufferAllocator`. Native bindings live in `src/lua/api.zig` and are registered in
`vm.zig:VM.init`: `print`, `type`, `tostring`, `tonumber`, `assert`, `error`, `ipairs`,
`pairs`, `vga_write`, `serial_write`, `sleep`, `read_key`, `time`, plus `math.*` and
`string.*` tables. Add new bindings there. User `function` definitions parse and run
(`vm.callFunction`). No modules, no stdlib beyond the above.
