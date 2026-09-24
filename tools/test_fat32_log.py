#!/usr/bin/env python3
"""QEMU smoke test for native FAT32 + asynchronous kernel log."""
from __future__ import annotations

import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import test_runner  # noqa: E402
from create_fat32_disk import (  # noqa: E402
    PART_START_LBA,
    SECTOR,
    add_fat32_file,
    write_fat32_partition,
)


def connect(port: int) -> socket.socket:
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=1)
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"cannot connect to localhost:{port}")


def read_fat32_path(image: Path, path: str) -> bytes:
    with image.open("rb") as f:
        partition_base = PART_START_LBA * SECTOR
        f.seek(partition_base)
        boot = f.read(SECTOR)
        if boot[510:512] != b"\x55\xAA":
            raise AssertionError("FAT32 test partition has no boot signature")
        reserved = struct.unpack_from("<H", boot, 14)[0]
        fats = boot[16]
        fat_size = struct.unpack_from("<I", boot, 36)[0]
        spc = boot[13]
        data_start = reserved + fats * fat_size
        fat_base = partition_base + reserved * SECTOR
        cluster_limit = 0x0FFFFFF8

        def fat_entry(cluster: int) -> int:
            fat_offset = cluster * 4
            f.seek(fat_base + (fat_offset // SECTOR) * SECTOR + (fat_offset % SECTOR))
            return struct.unpack("<I", f.read(4))[0] & 0x0FFFFFFF

        def directory_find(cluster: int, wanted: str) -> tuple[int, int, int] | None:
            current = cluster
            guard = 0
            while 2 <= current < cluster_limit and guard < 300000:
                guard += 1
                for sector_in_cluster in range(spc):
                    f.seek(partition_base + (data_start + (current - 2) * spc + sector_in_cluster) * SECTOR)
                    sector = f.read(SECTOR)
                    for off in range(0, SECTOR, 32):
                        entry = sector[off : off + 32]
                        if entry[0] == 0:
                            return None
                        if entry[0] == 0xE5 or entry[11] == 0x0F or entry[11] & 0x08:
                            continue
                        base = entry[:8].decode("ascii", "replace").rstrip()
                        ext = entry[8:11].decode("ascii", "replace").rstrip()
                        name = base + ("." + ext if ext else "")
                        if name.upper() == wanted.upper():
                            first = struct.unpack_from("<H", entry, 26)[0]
                            first |= struct.unpack_from("<H", entry, 20)[0] << 16
                            return first, struct.unpack_from("<I", entry, 28)[0], entry[11]
                current = fat_entry(current)
            return None

        parts = [part for part in path.strip("/").split("/") if part]
        if not parts:
            raise AssertionError("empty FAT32 path")
        current = 2
        found: tuple[int, int, int] | None = None
        for index, part in enumerate(parts):
            found = directory_find(current, part)
            if found is None:
                raise AssertionError(f"FAT32 path not found: {path}")
            current, size, attributes = found
            if index + 1 < len(parts) and not (attributes & 0x10):
                raise AssertionError(f"FAT32 non-directory component: {part}")
        assert found is not None
        cluster, size, _ = found
        data = bytearray()
        guard = 0
        while len(data) < size and 2 <= cluster < cluster_limit and guard < 300000:
            guard += 1
            f.seek(partition_base + (data_start + (cluster - 2) * spc) * SECTOR)
            data.extend(f.read(spc * SECTOR))
            cluster = fat_entry(cluster)
        if len(data) < size:
            raise AssertionError(f"FAT32 chain too short for {path}")
        return bytes(data[:size])


def read_fat32_file(image: Path, wanted_base: str) -> bytes:
    return read_fat32_path(image, f"{wanted_base}.LOG")


def qmp_command(sock: socket.socket, payload: dict) -> None:
    sock.sendall((json.dumps(payload) + "\n").encode())


def run(profile: str) -> None:
    subprocess.run(["zig", "build", "-Drelease"], cwd=ROOT, check=True)
    if not test_runner.patch_kernel_iso(str(ROOT)):
        raise AssertionError("failed to patch/build kernel.iso")

    with tempfile.TemporaryDirectory(prefix="zirconium-fat32-") as tmp:
        image = Path(tmp) / "fat32-test.img"
        write_fat32_partition(image, 1024 * 1024 * 1024 // SECTOR)
        high_payload = b"HIGH-CLUSTER-OK"
        add_fat32_file(image, "HIGH.TXT", 0x10005, high_payload)
        serial_port = 4610 + (os.getpid() % 100) * 2
        qmp_port = serial_port + 1
        proc = subprocess.Popen(
            [
                test_runner.find_qemu(),
                "-cdrom", "kernel.iso", "-boot", "d", "-m", "512M", "-smp", "1",
                "-display", "none", "-no-reboot",
                "-serial", f"tcp:127.0.0.1:{serial_port},server,nowait",
                "-qmp", f"tcp:127.0.0.1:{qmp_port},server,nowait",
                "-drive", f"if=none,id=hd0,file={image},format=raw",
                "-device", "virtio-blk,drive=hd0",
            ],
            cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        serial = connect(serial_port)
        qmp = connect(qmp_port)
        serial.settimeout(0.1)
        qmp.settimeout(2)
        try:
            qmp.recv(4096)
        except socket.timeout:
            pass
        qmp_command(qmp, {"execute": "qmp_capabilities"})
        output: list[str] = []

        def reader() -> None:
            while True:
                try:
                    chunk = serial.recv(4096)
                except socket.timeout:
                    continue
                except OSError:
                    return
                if not chunk:
                    return
                output.append(chunk.decode(errors="replace"))

        thread = threading.Thread(target=reader, daemon=True)
        thread.start()
        deadline = time.time() + 30
        while time.time() < deadline and "[SERIAL] zirc>" not in "".join(output):
            time.sleep(0.05)
        text = "".join(output)
        if "[SERIAL] zirc>" not in text:
            raise AssertionError("guest shell did not start")
        if "[FAT32] Mounted" not in text or "[KLOG] Enabled" not in text:
            raise AssertionError(f"FAT32/log markers missing:\n{text}")

        # Exercise directory traversal and create/write through the guest VFS.
        commands = [
            "mkdir /mnt/disk/TESTDIR",
            "write /mnt/disk/TESTDIR/HELLO.TXT FAT32-OK",
            "write /mnt/disk/ROOT.TXT ROOT-OK",
            "touch /mnt/disk/EMPTY.TXT",
            "klog dump",
        ]
        commands.extend(
            f"append /mnt/disk/BIG.TXT {index:03d}-" + ("X" * 70)
            for index in range(100)
        )
        commands.append("cp /mnt/disk/BIG.TXT /mnt/disk/COPIED.TXT")
        commands.append("cp /mnt/disk/HIGH.TXT /mnt/disk/HIGH.CP")
        for command in commands:
            serial.sendall(command.encode() + b"\r")
            time.sleep(0.08)

        # Let the foreground service point flush the queued early log.
        time.sleep(1.0)
        qmp_command(qmp, {"execute": "quit"})
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)

        content = read_fat32_file(image, "KERNEL").decode(errors="replace")
        for marker in ("[BOOT] Kernel loaded", "[KLOG] Enabled"):
            if marker not in content:
                raise AssertionError(f"log file lacks {marker!r}")
        try:
            nested = read_fat32_path(image, "TESTDIR/HELLO.TXT")
            root_file = read_fat32_path(image, "ROOT.TXT")
        except Exception as exc:
            raise AssertionError(f"{exc}; serial tail: {''.join(output)[-2000:]}") from exc
        if nested != b"FAT32-OK":
            raise AssertionError(f"nested FAT32 file content mismatch: {nested!r}")
        if root_file != b"ROOT-OK":
            raise AssertionError(f"root FAT32 file content mismatch: {root_file!r}")
        if read_fat32_path(image, "EMPTY.TXT") != b"":
            raise AssertionError("empty FAT32 file was not empty")
        expected_big = "".join(f"{index:03d}-" + ("X" * 70) for index in range(100)).encode()
        if read_fat32_path(image, "BIG.TXT") != expected_big:
            raise AssertionError("multi-cluster FAT32 append content mismatch")
        if read_fat32_path(image, "COPIED.TXT") != expected_big:
            raise AssertionError("FAT32 copy/truncate content mismatch")
        if read_fat32_path(image, "HIGH.CP") != high_payload:
            raise AssertionError("high FAT32 cluster copy content mismatch")
        print(f"[{profile}] FAT32 + KERNEL.LOG + file ops PASS ({len(content)} log bytes)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", default="fat32", choices=("fat32",))
    args = parser.parse_args()
    try:
        run(args.profile)
    except Exception as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
