# Zirconium

A minimalist bare-metal x86_64 operating system kernel written in Zig.

A special thanks to the [Dillo](https://git.dillo-browser.org/dillo/tree/) project for this browser.

[![Project Status](https://img.shields.io/badge/status-active-brightgreen)](#)
[![Roadmap](https://img.shields.io/badge/tasks-TODOs-blue)](TODO.md)

---

## Philosophy / Философия / Philosophia

> **EN:** Keep it simple, yet clear.
>
> **RU:** Делай просто, но понятно.
>
> **LA:** Fac simpliciter, sed manifeste.

---

## Features

- Multiboot x86_64 boot via Limine, identity-mapped 2MB pages — **1.2 s from power to shell**
- Ring 3 user-space with INT 0x80 syscalls, per-task address spaces (COW)
- Foreign binaries: static Linux ELF (via `syscall`) and Win32 PE32+ .exe (emulated thunks)//half worked 
- Custom TCP/IP stack over an e1000 NIC (ARP, IP, ICMP, TCP, UDP, DNS, DHCP, HTTP)
- Dillo web browser port (`dillo` command)// don't work correctly
- VFS with ramfs, FAT16 over virtio-blk disk
- On-disk shell with programs: networking, Lua interpreter, nano editor, and more
- Minimal Lua interpreter with native bindings//i dont test it
- Serial debug output + VGA framebuffer UI
- Drivers ported from the Linux kernel:
  - **Display** (DRM): the EDID parser, the connector, the CRTC and the fbdev emulation
  - **Bluetooth**: the HCI protocol core, the USB transport and a virtual controller
  - **2.4GHz receivers**: the HID++ protocol (Logitech)
  - **USB serial**: the FTDI chips
- A virtual machine monitor: Linux, Android, XNU and BSD guests run on it

## Building & Running

Requires Zig 0.16.x or 0.17.x (both work), `xorriso`, and QEMU.

```bash
zig build            # build only → zig-out/bin/kernel (Debug, safety on)
zig build -Drelease  # ReleaseFast (what run.sh ships)

./run.sh             # build (ReleaseFast) → ISO → launch QEMU (Linux/macOS)
./run.sh --vnc       # same, VNC display (port 5901) instead of GTK
run.bat              # Windows equivalent
./run.sh --test      # run the integration test suite (QEMU headless)
```

The host-side tests check the pure logic of the ported drivers without a machine:

```bash
zig run --dep edid  -Mroot=tools/test_edid.zig  -Medid=src/drivers/drm/edid.zig
zig run --dep ftdi  -Mroot=tools/test_ftdi.zig  -Mftdi=src/drivers/usb/serial/ftdi_proto.zig
zig run --dep hidpp -Mroot=tools/test_hidpp.zig -Mhidpp=src/drivers/hid/hidpp_proto.zig
```

## Docs

- Development notes, build gotchas, and architecture: [AGENTS.md](AGENTS.md)
- Current progress and roadmap: [TODO.md](TODO.md)
