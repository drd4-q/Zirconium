#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Create a 64MB disk image if it doesn't exist
if [ ! -f disk.img ]; then
    echo "=== Creating 64MB FAT16 disk image ==="
    dd if=/dev/zero of=disk.img bs=1M count=64 2>/dev/null
    # Format as FAT16 using mtools (no -F flag which forces FAT32)
    # For 64MB, mformat auto-detects FAT16
    mformat -i disk.img ::
    # Create directories
    mmd -i disk.img ::/test
    # Create test files
    echo "Hello from Zirconium!" | mcopy -i disk.img - ::/hello.txt
    echo "Test file in subdirectory" | mcopy -i disk.img - ::/test/data.txt
    echo "disk.img created (64MB FAT16 with test files)"
else
    echo "disk.img already exists"
fi
