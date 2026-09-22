#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Флаг --vnc: если передан, используем VNC вместо обычного дисплея
DISPLAY_MODE="-display gtk"
VNC_MSG=""
GDB_OPTS=""

for arg in "$@"; do
    if [ "$arg" == "--vnc" ]; then
        DISPLAY_MODE="-vnc 0.0.0.0:1"
        VNC_MSG=" Access: VNC at <host-ip>:5901"
    elif [ "$arg" == "--test" ]; then
        echo "=== Running Integration Test Suite ==="
        python3 tools/test_runner.py
        exit 0
    elif [ "$arg" == "--gdb" ]; then
        GDB_OPTS="-s -S"
        echo "=== GDB Remote Debugging Enabled (target remote localhost:1234) ==="
    fi
done

echo "=== Building Zirconium (ReleaseFast) ==="
zig build -Drelease

echo "=== Creating ISO ==="
rm -rf isodir
mkdir -p isodir/boot/grub
cp zig-out/bin/kernel isodir/boot/kernel.bin
cp grub.cfg isodir/boot/grub/grub.cfg
grub-mkrescue -o kernel.iso isodir

# Create disk image if missing
if [ ! -f disk.img ]; then
    echo "=== Creating 64MB disk image ==="
    dd if=/dev/zero of=disk.img bs=1M count=64 2>/dev/null
    if command -v mkfs.fat >/dev/null 2>&1; then
        echo "=== Formatting disk.img as FAT16 ==="
        mkfs.fat -F 16 disk.img >/dev/null
    else
        echo "mkfs.fat not found — leaving raw (FAT16 mount will fail)"
    fi
    echo "disk.img created (64MB FAT16)"
fi

echo "=== Launching QEMU ==="
echo " Network: e1000 NIC, port forward 8080->80"
echo " Disk: virtio-blk 64MB"
echo " Open http://localhost:8080 in host browser to test"
echo "$VNC_MSG"
echo ""

qemu-system-x86_64 \
    -cdrom kernel.iso \
    -boot d \
    -m 512M \
    -smp 4 \
    -device e1000,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::8080-:80 \
    -drive if=none,id=hd0,file=disk.img,format=raw \
    -device virtio-blk,drive=hd0 \
    -device qemu-xhci -device usb-kbd -device usb-tablet \\
    $DISPLAY_MODE \
    -serial stdio \
    -d int,cpu_reset \
    -D qemu.log \
    $GDB_OPTS \
    -no-reboot
