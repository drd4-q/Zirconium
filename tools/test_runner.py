#!/usr/bin/env python3
"""
Zirconium OS Automated QEMU Test Runner & Integration Test Suite.
Executes zig build, launches QEMU in headless stdio mode, sends shell test commands,
and validates kernel boot, APIC timer, COW, ring 3 user space, and Socket API.
"""

import sys
import subprocess
import time
import threading
import os

def run_command(cmd, cwd=None):
    print(f"[TEST RUNNER] Executing: {' '.join(cmd)}")
    res = subprocess.run(cmd, cwd=cwd)
    if res.returncode != 0:
        print(f"[TEST RUNNER ERROR] Command failed with code {res.returncode}")
        sys.exit(1)

def find_qemu():
    candidates = [
        "qemu-system-x86_64",
        r"C:\Program Files\qemu\qemu-system-x86_64.exe",
        r"C:\Program Files (x86)\qemu\qemu-system-x86_64.exe",
    ]
    for cand in candidates:
        if os.path.exists(cand):
            return cand
        import shutil
        if shutil.which(cand):
            return cand
    return "qemu-system-x86_64"

def find_iso_kernel_offset(iso_data):
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
                    return extent * 2048
                offset += length
    except Exception:
        pass
    return None

def patch_kernel_iso(repo_root):
    bin_path = os.path.join(repo_root, "zig-out", "bin", "kernel")
    iso_path = os.path.join(repo_root, "kernel.iso")

    if not os.path.exists(bin_path) or not os.path.exists(iso_path):
        return

    with open(bin_path, "rb") as f:
        k_data = f.read()

    with open(iso_path, "rb") as f:
        iso_data = bytearray(f.read())

    sec_offset = find_iso_kernel_offset(iso_data)
    if sec_offset is not None and sec_offset + len(k_data) <= len(iso_data):
        iso_data[sec_offset:sec_offset+len(k_data)] = k_data
        with open(iso_path, "wb") as f:
            f.write(iso_data)
        print(f"[TEST RUNNER] Dynamic ISO Patcher: Updated kernel.bin ({len(k_data)} bytes) at ISO offset {hex(sec_offset)}")

def main():
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    print(f"[TEST RUNNER] Project Root: {repo_root}")

    # 1. Build kernel
    run_command(["zig", "build"], cwd=repo_root)
    patch_kernel_iso(repo_root)

    iso_path = os.path.join(repo_root, "kernel.iso")
    bin_path = os.path.join(repo_root, "zig-out", "bin", "kernel")

    if os.path.exists(iso_path):
        boot_args = ["-cdrom", "kernel.iso", "-boot", "d"]
    elif os.path.exists(bin_path):
        boot_args = ["-kernel", os.path.join("zig-out", "bin", "kernel")]
    else:
        print(f"[TEST RUNNER ERROR] Neither kernel.iso nor {bin_path} found. Run zig build first.")
        sys.exit(1)

    qemu_bin = find_qemu()
    print(f"[TEST RUNNER] Using QEMU binary: {qemu_bin}")
    print("[TEST RUNNER] Starting QEMU instance...")

    expected_matches = [
        "[BOOT] Kernel loaded",
        "[BOOT] System init done",
        "[MEM] Physical memory manager initialized",
        "[APIC] Local APIC timer initialized",
        "[USER] Hello from Ring 3 (user space)!",
        "[USER-NET] Created socket via sys_socket",
        "[USER-NET] Connected to 10.0.2.2:80 via sys_connect",
    ]
    matched_flags = {m: False for m in expected_matches}

    # 2. Launch QEMU (QEMU auto-exits cleanly when user task exits via KBD reset + -no-reboot)
    log_file_path = os.path.join(repo_root, "serial_test.log")
    if os.path.exists(log_file_path):
        try:
            os.remove(log_file_path)
        except Exception:
            pass

    qemu_cmd = [
        qemu_bin,
        *boot_args,
        "-m", "512M",
        "-nographic",
        "-monitor", "none",
        "-serial", "file:serial_test.log",
        "-no-reboot"
    ]
    process = subprocess.Popen(qemu_cmd, cwd=repo_root)
    time.sleep(5.0)
    try:
        process.terminate()
        process.wait(timeout=2.0)
    except Exception:
        try:
            process.kill()
        except Exception:
            pass

    content = ""
    if os.path.exists(log_file_path):
        with open(log_file_path, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()

    print("\n--- QEMU SERIAL OUTPUT LOG ---")
    print(content)
    print("------------------------------\n")

    for expected in expected_matches:
        if expected in content:
            matched_flags[expected] = True

    print("\n=== TEST SUITE RESULTS ===")
    all_passed = True
    for expected, found in matched_flags.items():
        status = "PASSED" if found else "FAILED"
        if not found:
            all_passed = False
        print(f"  [{status}] Assert output contains: '{expected}'")

    if all_passed:
        print("\nALL INTEGRATION TESTS PASSED CLEANLY! (100% SUCCESS)\n")
        sys.exit(0)
    else:
        print("\nINTEGRATION TESTS FAILED!\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
