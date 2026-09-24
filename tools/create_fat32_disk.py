#!/usr/bin/env python3
"""Create a small MBR + FAT32 disk image without requiring mtools.

The image is intentionally generated rather than committed.  It is useful for
QEMU tests of the native FAT32/VFS path; the guest can create files after boot.
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

SECTOR = 512
PART_START_LBA = 2048


def put16(buf: bytearray, off: int, value: int) -> None:
    struct.pack_into("<H", buf, off, value & 0xFFFF)


def put32(buf: bytearray, off: int, value: int) -> None:
    struct.pack_into("<I", buf, off, value & 0xFFFFFFFF)


def fat32_geometry(total_sectors: int, sectors_per_cluster: int = 8):
    reserved = 32
    fats = 2
    fat_size = 1
    while True:
        data_sectors = total_sectors - reserved - fats * fat_size
        clusters = data_sectors // sectors_per_cluster
        needed = ((clusters + 2) * 4 + SECTOR - 1) // SECTOR
        if needed <= fat_size:
            return reserved, fats, fat_size, clusters
        fat_size = needed


def write_fat32_partition(path: Path, disk_sectors: int) -> None:
    partition_sectors = disk_sectors - PART_START_LBA
    if partition_sectors < 65525 * 8:
        raise ValueError("image is too small for FAT32")
    reserved, fats, fat_size, clusters = fat32_geometry(partition_sectors)
    data_start = reserved + fats * fat_size

    with path.open("wb") as f:
        f.truncate(disk_sectors * SECTOR)

        # MBR with one FAT32 LBA partition.
        mbr = bytearray(SECTOR)
        mbr[446] = 0x00  # legacy CHS
        mbr[450] = 0x0C  # FAT32 LBA
        put32(mbr, 454, PART_START_LBA)
        put32(mbr, 458, partition_sectors)
        mbr[510:512] = b"\x55\xAA"
        f.seek(0)
        f.write(mbr)

        base = PART_START_LBA * SECTOR
        boot = bytearray(SECTOR)
        boot[0:3] = b"\xEB\x58\x90"
        boot[3:11] = b"ZIRCOS2 "
        put16(boot, 0x0B, SECTOR)
        boot[0x0D] = 8
        put16(boot, 0x0E, reserved)
        boot[0x10] = fats
        put16(boot, 0x11, 0)  # FAT32 has no fixed root directory
        put16(boot, 0x13, 0)
        boot[0x15] = 0xF8
        put16(boot, 0x16, 0)
        put16(boot, 0x18, 63)
        put16(boot, 0x1A, 255)
        put32(boot, 0x1C, PART_START_LBA)
        put32(boot, 0x20, partition_sectors)
        put32(boot, 0x24, fat_size)
        put16(boot, 0x28, 0)
        put16(boot, 0x2A, 0)
        put32(boot, 0x2C, 2)  # first root cluster
        put16(boot, 0x30, 1)  # FSInfo sector
        put16(boot, 0x32, 6)  # backup boot sector
        boot[0x40] = 0x29
        boot[0x42:0x46] = b"ZIR1"
        boot[0x47:0x52] = b"ZLOG       "
        boot[0x52:0x5A] = b"FAT32   "
        boot[510:512] = b"\x55\xAA"
        f.seek(base)
        f.write(boot)

        # FSInfo and its backup.
        fsinfo = bytearray(SECTOR)
        struct.pack_into("<I", fsinfo, 0x000, 0x41615252)
        struct.pack_into("<I", fsinfo, 0x1E4, 0x61417272)
        struct.pack_into("<I", fsinfo, 0x1E8, 0xAA550000)
        struct.pack_into("<I", fsinfo, 0x1EC, 0xFFFFFFFF)
        struct.pack_into("<I", fsinfo, 0x1F0, 0xFFFFFFFF)
        struct.pack_into("<I", fsinfo, 0x1F4, 0)
        struct.pack_into("<I", fsinfo, 0x1F8, 0)
        for sector in (1, 7):
            f.seek(base + sector * SECTOR)
            f.write(fsinfo)
        f.seek(base + 6 * SECTOR)
        f.write(boot)

        # Initialize the first sector of each FAT copy; the remainder is
        # sparse zero data, which is valid free FAT space.
        fat_head = bytearray(SECTOR)
        put32(fat_head, 0, 0x0FFFFF00)
        put32(fat_head, 4, 0x0FFFFFFF)
        put32(fat_head, 8, 0x0FFFFFFF)  # root cluster 2
        for copy in range(fats):
            f.seek(base + (reserved + copy * fat_size) * SECTOR)
            f.write(fat_head)

        # Root cluster is sparse-zero; writing one explicit sector makes the
        # layout obvious in hexdumps and is harmless.
        f.seek(base + data_start * SECTOR)
        f.write(b"\x00" * SECTOR)

    print(
        f"created {path} ({disk_sectors * SECTOR // (1024 * 1024)} MiB): "
        f"FAT32 partition at LBA {PART_START_LBA}, {clusters} clusters"
    )


def add_fat32_file(image: Path, name: str, first_cluster: int, payload: bytes) -> None:
    """Add one 8.3 file to an image, optionally at a high FAT32 cluster."""
    if "." in name:
        base_name, ext = name.split(".", 1)
    else:
        base_name, ext = name, ""
    if not (1 <= len(base_name) <= 8 and len(ext) <= 3):
        raise ValueError(f"not an 8.3 name: {name}")
    with image.open("r+b") as f:
        partition_base = PART_START_LBA * SECTOR
        f.seek(partition_base)
        boot = f.read(SECTOR)
        reserved = struct.unpack_from("<H", boot, 14)[0]
        fats = boot[16]
        fat_size = struct.unpack_from("<I", boot, 36)[0]
        spc = boot[13]
        data_start = reserved + fats * fat_size
        total_sectors = struct.unpack_from("<I", boot, 32)[0]
        cluster_count = (total_sectors - data_start) // spc
        if first_cluster < 2 or first_cluster >= cluster_count + 2:
            raise ValueError(f"cluster {first_cluster} is outside the volume")

        entry = bytearray(32)
        entry[0:8] = b"        "
        entry[8:11] = b"   "
        entry[0 : len(base_name)] = base_name.encode("ascii")
        entry[8 : 8 + len(ext)] = ext.encode("ascii")
        entry[11] = 0x20
        struct.pack_into("<H", entry, 20, (first_cluster >> 16) & 0xFFFF)
        struct.pack_into("<H", entry, 26, first_cluster & 0xFFFF)
        struct.pack_into("<I", entry, 28, len(payload))

        root_sector = partition_base + data_start * SECTOR
        f.seek(root_sector + 32)  # slot 1; slot 0 is left for KERNEL.LOG
        f.write(entry)

        fat_offset = first_cluster * 4
        fat_sector = partition_base + reserved * SECTOR + (fat_offset // SECTOR) * SECTOR
        for copy in range(fats):
            f.seek(fat_sector + copy * fat_size * SECTOR)
            sector = bytearray(f.read(SECTOR))
            struct.pack_into("<I", sector, fat_offset % SECTOR, 0x0FFFFFFF)
            f.seek(fat_sector + copy * fat_size * SECTOR)
            f.write(sector)

        f.seek(partition_base + (data_start + (first_cluster - 2) * spc) * SECTOR)
        f.write(payload)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="fat32-test.img")
    parser.add_argument("--size-mb", type=int, default=1024)
    args = parser.parse_args()
    if args.size_mb < 600:
        raise SystemExit("--size-mb must be at least 600")
    path = Path(args.output)
    write_fat32_partition(path, args.size_mb * 1024 * 1024 // SECTOR)


if __name__ == "__main__":
    main()
