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

- Multiboot x86_64 boot via GRUB, identity-mapped 2MB pages
- Ring 3 user-space with INT 0x80 syscalls, per-task address spaces (COW)
- Foreign binaries: static Linux ELF (via `syscall`) and Win32 PE32+ .exe (emulated thunks)
- Custom TCP/IP stack over an e1000 NIC (ARP, IP, ICMP, TCP, UDP, DNS, DHCP, HTTP)
- Dillo web browser port (`dillo` command)
- VFS with ramfs, FAT16 over virtio-blk disk
- On-disk shell with programs: networking, Lua interpreter, nano editor, and more
- Minimal Lua interpreter with native bindings
- Serial debug output + VGA framebuffer UI

## Building & Running

Requires Zig 0.16.0, `grub-mkrescue`, and QEMU.

```bash
zig build            # build only → zig-out/bin/kernel (Debug, safety on)
zig build -Drelease  # ReleaseFast (what run.sh ships)

./run.sh             # build (ReleaseFast) → ISO → launch QEMU (Linux/macOS)
./run.sh --vnc       # same, VNC display (port 5901) instead of GTK
run.bat              # Windows equivalent
./run.sh --test      # run the integration test suite (QEMU headless)
```

## Docs

- Development notes, build gotchas, and architecture: [AGENTS.md](AGENTS.md)
- Current progress and roadmap: [TODO.md](TODO.md)
