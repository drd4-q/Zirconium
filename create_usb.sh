#!/bin/bash
# Script to build Zirconium OS and write to a USB flash drive for booting on real hardware (bare metal)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ "$EUID" -ne 0 ] && [ -n "$1" ]; then
    echo "Warning: Writing directly to a disk device usually requires root (sudo)."
fi

TARGET_DEV="$1"

echo "=========================================="
echo "  Building Zirconium OS (ReleaseFast)"
echo "=========================================="
zig build -Drelease

echo "=== Preparing ISO structure ==="
rm -rf isodir
mkdir -p isodir/boot/grub
cp zig-out/bin/kernel isodir/boot/kernel.bin
cp grub.cfg isodir/boot/grub/grub.cfg

echo "=== Creating hybrid bootable ISO ==="
if command -v grub-mkrescue >/dev/null 2>&1; then
    grub-mkrescue -o kernel.iso isodir
    echo "✓ kernel.iso created successfully!"
else
    echo "Error: grub-mkrescue not found. Install grub-pc-bin, grub-efi-amd64-bin and xorriso."
    exit 1
fi

if [ -z "$TARGET_DEV" ]; then
    echo ""
    echo "=========================================================="
    echo "  kernel.iso is ready for real hardware!"
    echo "=========================================================="
    echo "How to boot on real hardware:"
    echo "  1. Ventoy: Simply copy 'kernel.iso' onto a Ventoy USB flash drive."
    echo "  2. Direct write (Linux):"
    echo "     sudo ./create_usb.sh /dev/sdX   (replace sdX with your USB drive)"
    echo "     OR: sudo dd if=kernel.iso of=/dev/sdX bs=4M status=progress; sync"
    echo "  3. Rufus / Etcher (Windows/macOS):"
    echo "     Select 'kernel.iso' and write in DD mode to your USB drive."
    echo "  4. In BIOS/UEFI Settings:"
    echo "     - Enable Legacy / CSM Boot (or boot GRUB in CSM mode)"
    echo "     - Disable Secure Boot"
    echo "     - Select your USB drive as boot device"
    echo "=========================================================="
    exit 0
fi

if [ ! -b "$TARGET_DEV" ]; then
    echo "Error: $TARGET_DEV is not a valid block device!"
    exit 1
fi

echo ""
echo "WARNING: ALL DATA ON $TARGET_DEV WILL BE PERMANENTLY ERASED!"
read -p "Are you sure you want to write Zirconium OS to $TARGET_DEV? [y/N] " -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Writing kernel.iso to $TARGET_DEV..."
    dd if=kernel.iso of="$TARGET_DEV" bs=4M status=progress
    sync
    echo "✓ Successfully written to $TARGET_DEV! You can now boot real hardware from this USB drive."
else
    echo "Aborted."
fi
