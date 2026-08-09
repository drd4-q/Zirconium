# Zirconium

A minimalist bare-metal x86_64 operating system kernel written in Zig.

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
- Custom TCP/IP stack over an e1000 NIC (ARP, IP, ICMP, TCP, UDP, DNS, DHCP, HTTP)
- VFS with ramfs, virtio-blk disk support
- On-disk shell with programs: networking, Lua interpreter, and more
- Minimal Lua interpreter with native bindings
- Serial debug output + VGA framebuffer UI

## Building & Running

Requires Zig 0.16.0, GNU `as`, `grub-mkrescue`, and QEMU.

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