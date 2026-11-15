#!/bin/bash
# Script to build Zirconium OS and write to a USB flash drive for booting on real hardware (bare metal)
#
# The bootloader is Limine.  A USB stick is prepared the way Limine documents:
# a FAT partition holding `limine.conf`, `limine-bios.sys` and the kernel, and
# then `limine bios-install` to write the stage-1 boot code.  (A Ventoy stick
# needs none of this: copy kernel.iso onto it and let Ventoy boot it.)
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

echo "=== Creating hybrid bootable ISO (Limine) ==="
python3 tools/mkiso.py --output kernel.iso

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
    echo "     - Disable Secure Boot"
    echo "     - Select your USB drive as boot device"
    echo "=========================================================="
    exit 0
fi

if [ ! -b "$TARGET_DEV" ]; then
    echo "Error: $TARGET_DEV is not a valid block device!"
    exit 1
fi

for tool in limine mkfs.vfat mcopy; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: $tool not found."
        echo "  limine      - the Limine bootloader tools (bios-install)"
        echo "  mkfs.vfat   - dosfstools"
        echo "  mcopy       - mtools"
        echo "Install them, or use a Ventoy stick and just copy kernel.iso onto it."
        exit 1
    fi
done

echo ""
echo "WARNING: ALL DATA ON $TARGET_DEV WILL BE PERMANENTLY ERASED!"
read -p "Are you sure you want to write Zirconium OS to $TARGET_DEV? [y/N] " -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Partitioning and formatting $TARGET_DEV..."
    # A single FAT32 partition covering the whole device.
    sgdisk --zap-all "$TARGET_DEV" 2>/dev/null || true
    parted -s "$TARGET_DEV" mklabel msdos
    parted -s "$TARGET_DEV" mkpart primary fat32 1MiB 100%
    partprobe "$TARGET_DEV" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 2

    PART="${TARGET_DEV}1"
    [[ -b "$PART" ]] || PART="$TARGET_DEV"

    mkfs.vfat -F 32 "$PART" >/dev/null

    echo "Copying the kernel, the config and the Limine stage 2..."
    # Limine reads its config from the root of the boot volume.
    mcopy -i "$PART" limine.conf ::
    mcopy -i "$PART" limine/limine-bios.sys ::
    mcopy -i "$PART" zig-out/bin/kernel ::kernel.bin

    echo "Installing the Limine boot code..."
    limine bios-install "$TARGET_DEV"

    sync
    echo "✓ Successfully written to $TARGET_DEV! You can now boot real hardware from this USB drive."
else
    echo "Aborted."
fi
