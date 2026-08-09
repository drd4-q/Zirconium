#!/usr/bin/env python3
"""Overwrite kernel.bin inside an existing kernel.iso without grub-mkrescue.

Usage: python3 tools/patch_iso.py [repo_root]

Only works while the new kernel fits the slot the old kernel occupied in the
ISO. If it doesn't fit, prints a warning — rebuild the ISO via run.sh instead.
"""
import os
import sys


def find_iso_kernel_offset(iso_data):
    """Return (sector_offset, slot_bytes) of KERNEL.BIN inside the ISO, or (None, 0)."""
    try:
        pvd = iso_data[0x8000:0x8800]
        root_dir_rec = pvd[156:190]
        root_extent = int.from_bytes(root_dir_rec[2:6], 'little')
        root_size = int.from_bytes(root_dir_rec[10:14], 'little')

        root_data = iso_data[root_extent*2048 : root_extent*2048 + root_size]
        offset = 0
        boot_extent = None
        boot_size = None
        while offset < len(root_data):
            length = root_data[offset]
            if length == 0:
                offset = (offset + 2047) & ~2047
                continue
            rec = root_data[offset:offset+length]
            name_len = rec[32]
            name = rec[33:33+name_len].decode('ascii', 'ignore')
            if name.startswith('BOOT'):
                boot_extent = int.from_bytes(rec[2:6], 'little')
                boot_size = int.from_bytes(rec[10:14], 'little')
                break
            offset += length

        if boot_extent and boot_size:
            boot_data = iso_data[boot_extent*2048 : boot_extent*2048 + boot_size]
            offset = 0
            while offset < len(boot_data):
                length = boot_data[offset]
                if length == 0:
                    offset = (offset + 2047) & ~2047
                    continue
                rec = boot_data[offset:offset+length]
                name_len = rec[32]
                name = rec[33:33+name_len].decode('ascii', 'ignore')
                if name.startswith('KERNEL.BIN'):
                    extent = int.from_bytes(rec[2:6], 'little')
                    data_len = int.from_bytes(rec[10:14], 'big')
                    slot_bytes = ((data_len + 2047) & ~2047)
                    return extent * 2048, slot_bytes
                offset += length
    except Exception:
        pass
    return None, 0


def patch_kernel_iso(repo_root):
    bin_path = os.path.join(repo_root, "zig-out", "bin", "kernel")
    iso_path = os.path.join(repo_root, "kernel.iso")

    if not os.path.exists(bin_path) or not os.path.exists(iso_path):
        return False

    with open(bin_path, "rb") as f:
        k_data = f.read()

    with open(iso_path, "rb") as f:
        iso_data = f.read()

    sec_offset, slot_bytes = find_iso_kernel_offset(iso_data)
    if sec_offset is not None and slot_bytes >= len(k_data):
        iso_data = bytearray(iso_data)
        iso_data[sec_offset:sec_offset+len(k_data)] = k_data
        with open(iso_path, "wb") as f:
            f.write(iso_data)
        print(f"[ISO PATCHER] Updated kernel.bin ({len(k_data)} bytes) in kernel.iso")
        return True

    print(f"[ISO PATCHER] kernel.bin ({len(k_data)} bytes) does not fit ISO slot "
          f"({slot_bytes} bytes) — rebuild the ISO with run.sh")
    return False


if __name__ == "__main__":
    repo_root = sys.argv[1] if len(sys.argv) > 1 else "."
    patch_kernel_iso(repo_root)