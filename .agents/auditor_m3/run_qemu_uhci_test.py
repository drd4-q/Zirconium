#!/usr/bin/env python3
import subprocess
import time
import os
import sys

REPO_ROOT = "/home/dr4d/Zirconium"
ISO_PATH = os.path.join(REPO_ROOT, "kernel.iso")
LOG_PATH = "/home/dr4d/Zirconium/.agents/auditor_m3/uhci_test.log"

if os.path.exists(LOG_PATH):
    os.remove(LOG_PATH)

cmd = [
    "qemu-system-x86_64",
    "-cdrom", ISO_PATH,
    "-nographic",
    "-monitor", "none",
    "-smp", "4",
    "-m", "512M",
    "-serial", f"file:{LOG_PATH}",
    "-device", "ich9-usb-uhci1,id=uhci",
    "-device", "usb-kbd,bus=uhci.0,port=1",
    "-device", "usb-mouse,bus=uhci.0,port=2",
]

print(f"Starting QEMU: {' '.join(cmd)}")
proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

start_time = time.time()
passed = False
log_content = ""

try:
    while time.time() - start_time < 35.0:
        if os.path.exists(LOG_PATH):
            with open(LOG_PATH, "r", encoding="utf-8", errors="ignore") as f:
                log_content = f.read()
            if "[USB] Subsystem initialized with" in log_content:
                passed = True
                break
        time.sleep(0.5)
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()

print("--- RAW SERIAL LOG EXCERPT ---")
for line in log_content.splitlines():
    if any(k in line for k in ["[USB]", "[BOOT]", "[USER-HEAP]", "UHCI"]):
        print(line)

assert "[BOOT] Kernel loaded" in log_content, "Missing kernel loaded marker"
assert "[USB] Registered USB Keyboard" in log_content, "Missing USB Keyboard registration"
assert "[USB] Registered USB Mouse" in log_content, "Missing USB Mouse registration"
assert "[USB] Subsystem initialized with" in log_content, "Missing USB subsystem initialized marker"

print("\nSUCCESS: All QEMU USB UHCI HID runtime assertions passed!")
