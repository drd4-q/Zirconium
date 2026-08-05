#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Building Zig Kernel ==="
zig build

echo "=== Creating ISO ==="
rm -rf isodir
mkdir -p isodir/boot/grub
cp zig-out/bin/kernel isodir/boot/kernel.bin
cp grub.cfg isodir/boot/grub/grub.cfg
grub-mkrescue -o kernel.iso isodir

echo "=== Launching QEMU ==="
echo "  Network: e1000 NIC, port forward 8080→80"
echo "  Open http://localhost:8080 in host browser to test"
echo ""

qemu-system-x86_64 \
    -cdrom kernel.iso \
    -m 128M \
    -device e1000,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::8080-:80 \
    -display gtk \
    -serial stdio \
    -d int,cpu_reset \
    -D qemu.log \
    -no-reboot
