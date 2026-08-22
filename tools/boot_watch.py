#!/usr/bin/env python3
"""Build the ISO + FAT16 disk, boot headless, drive the shell over serial.

Usage:
  python tools/boot_watch.py <seconds> [disk] [cmd:"shell command" ...]

COM1 is exposed on a local TCP port (Windows pipes do not reliably feed
`-serial stdio`). After the shell banner appears, every cmd: argument is typed
into the guest console followed by Enter. Serial output is captured to
ser_capture.log and a QMP screendump is written to screen.ppm before quit.
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(REPO, "tools"))
os.chdir(REPO)
import test_runner as tr  # reuse build/patch helpers

QEMU = tr.find_qemu()
args = sys.argv[1:]
WAIT = float(args[0]) if args else 30.0
ATTACH_DISK = "disk" in args
COMMANDS = [a[4:] for a in args if a.startswith("cmd:")]

subprocess.run(["zig", "build", "-Drelease"], check=True)
tr.patch_kernel_iso(REPO)

cmd = [
    QEMU, "-cdrom", "kernel.iso", "-boot", "d", "-m", "512M", "-smp", "4",
    "-display", "none", "-serial", "tcp:127.0.0.1:4450,server,nowait",
    "-netdev", "user,id=n0", "-device", "e1000,netdev=n0",
    "-qmp", "tcp:127.0.0.1:4445,server,nowait",
    "-no-reboot",
]
if ATTACH_DISK:
    disk = os.path.join(REPO, "disk.img")
    if not os.path.exists(disk):
        with open(disk, "wb") as f:
            f.truncate(64 * 1024 * 1024)
        print("[BOOT WATCH] created blank 64MB disk.img")
    cmd += ["-drive", "if=none,id=hd0,file=disk.img,format=raw",
            "-device", "virtio-blk,drive=hd0"]

p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# Connect to the guest serial console.
ser = None
for _ in range(50):
    try:
        ser = socket.create_connection(("127.0.0.1", 4450), timeout=1)
        break
    except OSError:
        time.sleep(0.1)
if ser is None:
    print("[BOOT WATCH] could not connect to guest serial port")
    p.kill()
    sys.exit(1)
ser.settimeout(1)

collected = []
lock = threading.Lock()
shell_ready = threading.Event()


logf = open("ser_capture.log", "w", encoding="utf-8")


def reader():
    tail = ""  # markers may straddle recv() boundaries
    while True:
        try:
            chunk = ser.recv(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        if not chunk:
            break
        text = chunk.decode("utf-8", errors="ignore")
        logf.write(text)
        logf.flush()
        with lock:
            collected.append(text)
        tail = (tail + text)[-256:]
        if "keyboard ready" in tail or "zirc>" in tail:
            shell_ready.set()


t = threading.Thread(target=reader, daemon=True)
t.start()

deadline = time.time() + max(WAIT, 5)
while time.time() < deadline:
    if shell_ready.wait(timeout=1):
        break

if shell_ready.is_set():
    time.sleep(2)  # let the banner finish before typing

    for c in COMMANDS:
        print(f"[BOOT WATCH] > {c}")
        logf.write(f"\n### HOST SENT: {c}\n")
        logf.flush()
        # Type slowly so the guest's 16-byte UART FIFO never overflows.
        for ch in c + "\r":
            ser.sendall(ch.encode())
            time.sleep(0.02)
        # Give the program time to run to completion before the next command;
        # back-to-back spawns right after exit occasionally race in the
        # block device path.
        time.sleep(9)
else:
    print("[BOOT WATCH] shell never became ready")

time.sleep(2)
logf.close()


# --- graceful stop: screendump then quit -----------------------------------
def qmp(payload):
    s = socket.create_connection(("127.0.0.1", 4445), timeout=3)
    s.settimeout(3)
    out = b""
    try:
        s.recv(4096)  # greeting
        s.sendall((json.dumps({"execute": "qmp_capabilities"}) + "\n").encode())
        s.recv(4096)
        s.sendall((json.dumps(payload) + "\n").encode())
        time.sleep(0.5)
        out = s.recv(65536)
    finally:
        s.close()
    return out.decode(errors="ignore").strip()


try:
    qmp({"execute": "screendump", "arguments": {"filename": "screen.ppm"}})
except Exception as e:
    print("screendump failed:", e)

# Where is CPU0 stuck? Useful when a spawned program hangs silently.
try:
    s = socket.create_connection(("127.0.0.1", 4445), timeout=3)
    s.settimeout(3)
    s.recv(4096)
    s.sendall((json.dumps({"execute": "qmp_capabilities"}) + "\n").encode())
    s.recv(4096)
    s.sendall((json.dumps({"execute": "human-monitor-command",
                           "arguments": {"command-line": "info registers"}}) + "\n").encode())
    time.sleep(1)
    out = s.recv(65536).decode(errors="ignore")
    s.close()
    print("[REGS-FULL]", out)
except Exception as e:
    print("regs failed:", e)

time.sleep(1)
try:
    qmp({"execute": "quit"})
except Exception:
    pass
try:
    p.wait(timeout=5)
except Exception:
    p.kill()
print("[BOOT WATCH] done; see ser_capture.log / screen.ppm")
