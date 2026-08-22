#!/usr/bin/env python3
"""
Downloads and compiles test programs (Linux ELF + Windows PE .exe),
creates a 64MB FAT16 disk.img directly in the project root folder,
and populates it with test executables.
"""

import os
import sys
import shutil
import tempfile
import urllib.request
import subprocess

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SAMPLES_DIR = os.path.join(REPO_ROOT, "samples")
DISK_PATH = os.path.join(REPO_ROOT, "disk.img")
os.makedirs(SAMPLES_DIR, exist_ok=True)

BUSYBOX_URL = "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
BUSYBOX_PATH = os.path.join(SAMPLES_DIR, "busybox")

def download_busybox():
    if not os.path.exists(BUSYBOX_PATH):
        print(f"[TEST PROG] Downloading BusyBox Linux ELF from {BUSYBOX_URL}...")
        try:
            urllib.request.urlretrieve(BUSYBOX_URL, BUSYBOX_PATH)
            os.chmod(BUSYBOX_PATH, 0o755)
            print(f"[TEST PROG] Downloaded busybox ({os.path.getsize(BUSYBOX_PATH)} bytes)")
        except Exception as e:
            print(f"[TEST PROG WARNING] Failed to download busybox: {e}")
    else:
        print(f"[TEST PROG] BusyBox already present: {BUSYBOX_PATH}")

def build_sample_binaries():
    # 1. Linux ELF test binary
    hello_linux_src = os.path.join(SAMPLES_DIR, "hello_linux.zig")
    if os.path.exists(hello_linux_src):
        print("[TEST PROG] Compiling samples/hello_linux (Linux x86_64 ELF)...")
        try:
            subprocess.run([
                "zig", "build-exe", "hello_linux.zig",
                "-target", "x86_64-freestanding",
                "-fstrip", "-OReleaseSmall"
            ], check=True, cwd=SAMPLES_DIR)
        except Exception as e:
            print(f"[TEST PROG WARNING] Failed to compile hello_linux: {e}")

    # 2. Windows PE test binary
    hello_win_src = os.path.join(SAMPLES_DIR, "hello_win.zig")
    if os.path.exists(hello_win_src):
        print("[TEST PROG] Compiling samples/hello_win.zig -> hello.exe (Windows x86_64 PE)...")
        try:
            subprocess.run([
                "zig", "build-exe", "hello_win.zig",
                "-target", "x86_64-windows",
                "-fstrip", "-OReleaseSmall"
            ], check=True, cwd=SAMPLES_DIR)
            win_out = os.path.join(SAMPLES_DIR, "hello_win.exe")
            if os.path.exists(win_out):
                shutil.copy2(win_out, os.path.join(SAMPLES_DIR, "hello.exe"))
        except Exception as e:
            print(f"[TEST PROG WARNING] Failed to compile hello.exe: {e}")

def create_fat16_disk():
    print(f"[TEST PROG] Generating 64MB FAT16 image directly at: {DISK_PATH}...")

    # Create / truncate 64MB file in the project folder
    with open(DISK_PATH, "wb") as f:
        f.truncate(64 * 1024 * 1024)

    files_to_copy = []
    if os.path.exists(BUSYBOX_PATH):
        files_to_copy.append((BUSYBOX_PATH, "busybox"))
        files_to_copy.append((BUSYBOX_PATH, "uname"))
        files_to_copy.append((BUSYBOX_PATH, "echo"))
        files_to_copy.append((BUSYBOX_PATH, "sh"))
        files_to_copy.append((BUSYBOX_PATH, "cat"))
    hello_linux = os.path.join(SAMPLES_DIR, "hello_linux")
    if os.path.exists(hello_linux):
        # 8.3-safe alias so `exec /mnt/disk/hl` works (no LFN support).
        files_to_copy.append((hello_linux, "hl"))
    hello_win = os.path.join(SAMPLES_DIR, "hello.exe")
    if os.path.exists(hello_win):
        files_to_copy.append((hello_win, "hello.exe"))

    # Real third-party applications fetched by tools/fetch_apps.py.
    # The kernel's FAT16 driver only understands 8.3 names (no LFN), so long
    # names get short aliases here. uutils coreutils is a multicall binary:
    # copying it under an applet name (ls) makes that applet runnable, since
    # it dispatches on argv[0] basename. fastfetch ships a glibc-dynamic build
    # the kernel rejects anyway, so it stays off the disk.
    app_alias = {"coreutils": "cu", "hello_linux": "hl"}
    skip = {"fastfetch"}
    apps_dir = os.path.join(SAMPLES_DIR, "apps")
    if os.path.isdir(apps_dir):
        for name in sorted(os.listdir(apps_dir)):
            path = os.path.join(apps_dir, name)
            if os.path.isfile(path) and name not in skip:
                files_to_copy.append((path, app_alias.get(name, name)))
        coreutils = os.path.join(apps_dir, "coreutils")
        if os.path.exists(coreutils):
            files_to_copy.append((coreutils, "ls"))

    # Sample text file
    sample_txt = os.path.join(SAMPLES_DIR, "hello.txt")
    with open(sample_txt, "w", encoding="utf-8") as f:
        f.write("Hello from Zirconium FAT16 disk!\n")
    files_to_copy.append((sample_txt, "hello.txt"))

    # Check for native mtools (Linux / macOS / MSYS / Git Bash)
    if shutil.which("mformat") and shutil.which("mcopy"):
        print("[TEST PROG] Formatting and copying files with native mtools...")
        subprocess.run(["mformat", "-i", DISK_PATH, "::"], check=True)
        for src_path, dst_name in files_to_copy:
            subprocess.run(["mcopy", "-i", DISK_PATH, src_path, f"::/{dst_name}"], check=True)
        # Create test directory and file
        try:
            subprocess.run(["mmd", "-i", DISK_PATH, "::/test"], check=False)
            subprocess.run(["mcopy", "-i", DISK_PATH, sample_txt, "::/test/data.txt"], check=False)
        except Exception:
            pass
    elif shutil.which("wsl"):
        # Windows without native mtools -> use WSL
        print("[TEST PROG] Using WSL mtools...")
        temp_dir = os.path.join(tempfile.gettempdir(), "diskbuild")
        shutil.rmtree(temp_dir, ignore_errors=True)
        os.makedirs(temp_dir, exist_ok=True)
        for src_path, dst_name in files_to_copy:
            shutil.copy2(src_path, os.path.join(temp_dir, dst_name))
        wsl_win_temp = "/mnt/c" + temp_dir[2:].replace("\\", "/")
        copy_cmds = " && ".join([f"mcopy -i /tmp/wsl_diskbuild/disk.img '{wsl_win_temp}/{dst_name}' ::/{dst_name}" for _, dst_name in files_to_copy])
        script = f"rm -rf /tmp/wsl_diskbuild && mkdir -p /tmp/wsl_diskbuild && dd if=/dev/zero of=/tmp/wsl_diskbuild/disk.img bs=1M count=64 status=none && mformat -i /tmp/wsl_diskbuild/disk.img :: && mmd -i /tmp/wsl_diskbuild/disk.img ::/test && {copy_cmds} && mcopy -i /tmp/wsl_diskbuild/disk.img '{wsl_win_temp}/hello.txt' ::/test/data.txt && cp /tmp/wsl_diskbuild/disk.img '{wsl_win_temp}/disk.img'"
        subprocess.run(["wsl", "-e", "sh", "-c", script], check=True)
        shutil.copy2(os.path.join(temp_dir, "disk.img"), DISK_PATH)
    else:
        print("[TEST PROG ERROR] Neither mtools (mformat/mcopy) nor WSL was found. Please install mtools: sudo apt install mtools")
        sys.exit(1)

    print(f"[TEST PROG] disk.img successfully created in project directory: {DISK_PATH}")

def main():
    print("=== Zirconium Test Program Downloader & Disk Builder ===")
    download_busybox()
    build_sample_binaries()
    create_fat16_disk()
    print("\nDisk contents available at /mnt/disk/ in Zirconium:")
    print("  /mnt/disk/busybox     (Linux ELF - BusyBox multi-call binary)")
    print("  /mnt/disk/hello_linux (Linux ELF - standalone print & exit)")
    print("  /mnt/disk/hello.exe   (Windows PE - Win32 WriteFile & ExitProcess)")
    print("  /mnt/disk/hello.txt   (Text file)")
    print("\nIn Zirconium shell, test with:")
    print("  ls /mnt/disk")
    print("  exec /mnt/disk/hello.exe")
    print("  exec /mnt/disk/hello_linux")
    print("  exec /mnt/disk/busybox echo 'Hello from BusyBox'")
    print("  exec /mnt/disk/busybox uname -a")
    print("  exec /mnt/disk/busybox cal")
    print("  exec /mnt/disk/busybox ls -l /mnt/disk")

if __name__ == "__main__":
    main()
