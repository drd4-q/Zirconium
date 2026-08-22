#!/usr/bin/env python3
"""Boot the ISO headless, screendump via QMP, quit gracefully, dump serial file."""
import json, os, socket, subprocess, sys, threading, time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(REPO, "tools"))
os.chdir(REPO)
import test_runner as tr

QEMU = tr.find_qemu()
WAIT = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0

subprocess.run(["zig", "build", "-Drelease"], check=True)
tr.patch_kernel_iso(REPO)

cmd = [
    QEMU, "-cdrom", "kernel.iso", "-boot", "d", "-m", "512M", "-smp", "4",
    "-display", "none", "-serial", "file:ser_capture.log",
    "-netdev", "user,id=n0", "-device", "e1000,netdev=n0",
    "-qmp", "tcp:127.0.0.1:4445,server,nowait",
    "-no-reboot",
]
p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(WAIT)

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
    print("screendump:", qmp({"execute": "screendump",
                              "arguments": {"filename": "screen.ppm"}}))
except Exception as e:
    print("screendump failed:", e)
time.sleep(1)
try:
    qmp({"execute": "quit"})  # graceful: flushes serial file
except Exception:
    pass
try:
    p.wait(timeout=5)
except Exception:
    p.kill()
