#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Флаг --vnc: если передан, используем VNC вместо обычного дисплея
DISPLAY_MODE="-display gtk"
VNC_MSG=""
for arg in "$@"; do
    if [ "$arg" == "--vnc" ]; then
        DISPLAY_MODE="-vnc 0.0.0.0:1"
        VNC_MSG=" Access: VNC at <host-ip>:5901"
    fi
done

echo "=== Building Zig Kernel ==="
zig build

echo "=== Creating ISO ==="
rm -rf isodir
mkdir -p isodir/boot/grub
cp zig-out/bin/kernel isodir/boot/kernel.bin
cp grub.cfg isodir/boot/grub/grub.cfg
grub-mkrescue -o kernel.iso isodir

echo "=== Launching QEMU ==="
echo " Network: e1000 NIC, port forward 8080→80"
echo " Open http://localhost:8080 in host browser to test"
echo "$VNC_MSG"
echo ""

qemu-system-x86_64 \
    -cdrom kernel.iso \
    -m 128M \
    -device e1000,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::8080-:80 \
    $DISPLAY_MODE \
    -serial stdio \
    -d int,cpu_reset \
    -D qemu.log \
    -no-reboot
