#!/usr/bin/env python3
"""Prove a real USB HID report reaches the kernel key ring.

QEMU's ``usb-kbd`` is an actual emulated USB device.  We route QMP input to a
named VGA console so the events are delivered through the USB HID endpoint,
then require the kernel's opt-in serial trace to contain both a raw report and
decoded ``keyboard.pushKey()`` values.

Usage:
    python3 tools/usb_input_test.py [uhci|ehci|xhci|all]
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time
from typing import List


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def find_qemu() -> str:
    from shutil import which

    for candidate in ("qemu-system-x86_64", r"C:\Program Files\qemu\qemu-system-x86_64.exe"):
        if os.path.exists(candidate) or which(candidate):
            return candidate
    return "qemu-system-x86_64"


def connect(port: int) -> socket.socket:
    deadline = time.time() + 15.0
    while time.time() < deadline:
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=1.0)
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"could not connect to localhost:{port}")


class Qmp:
    def __init__(self, port: int):
        self.sock = connect(port)
        self.sock.settimeout(3.0)
        self._drain_greeting()
        self.command({"execute": "qmp_capabilities"})

    def _drain_greeting(self) -> None:
        try:
            self.sock.recv(65536)
        except socket.timeout:
            pass

    def command(self, payload: dict) -> dict:
        self.sock.sendall((json.dumps(payload) + "\n").encode())
        deadline = time.time() + 3.0
        while time.time() < deadline:
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                continue
            if not data:
                break
            for line in data.decode(errors="ignore").splitlines():
                try:
                    response = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "return" in response or "error" in response:
                    return response
        raise RuntimeError(f"QMP timeout for {payload}")

    def send_key(self, key: str) -> None:
        events = [
            {"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": key}}},
            {"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": key}}},
        ]
        response = self.command({
            "execute": "input-send-event",
            "arguments": {"device": "video0", "head": 0, "events": events},
        })
        if "error" in response:
            raise RuntimeError(f"QMP input injection failed: {response}")

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def serial_type(sock: socket.socket, text: str) -> None:
    # The guest UART FIFO is small; typing in boot_watch.py uses the same rate.
    for byte in text.encode():
        sock.sendall(bytes((byte,)))
        time.sleep(0.025)


def run_profile(profile: str, base_port: int) -> str:
    serial_port = base_port
    qmp_port = base_port + 1
    if profile == "uhci":
        devices = [
            "-device", "ich9-usb-uhci1,id=uhci",
            "-device", "usb-kbd,bus=uhci.0,port=1,display=video0",
        ]
    elif profile == "ehci":
        devices = [
            "-device", "ich9-usb-ehci1,id=ehci",
            "-device", "usb-kbd,bus=ehci.0,port=1,display=video0",
        ]
    elif profile == "xhci":
        devices = [
            "-device", "qemu-xhci,id=xhci",
            "-device", "usb-kbd,bus=xhci.0,port=1,display=video0",
        ]
    else:
        raise ValueError(profile)

    command: List[str] = [
        find_qemu(), "-M", "pc,i8042=off", "-vga", "none",
        "-device", "VGA,id=video0", "-cdrom", "kernel.iso", "-boot", "d",
        "-m", "512M", "-smp", "1", "-display", "none",
        "-serial", f"tcp:127.0.0.1:{serial_port},server,nowait",
        "-qmp", f"tcp:127.0.0.1:{qmp_port},server,nowait", "-no-reboot",
        *devices,
    ]
    process = subprocess.Popen(
        command, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    serial = connect(serial_port)
    serial.settimeout(0.1)
    qmp = Qmp(qmp_port)
    output: List[str] = []

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
    try:
        deadline = time.time() + 30.0
        while time.time() < deadline and "[SERIAL] zirc>" not in "".join(output):
            time.sleep(0.05)
        text = "".join(output)
        if "[SERIAL] zirc>" not in text:
            raise RuntimeError(f"{profile}: shell did not start")

        serial_type(serial, "usb debug on\r")
        deadline = time.time() + 5.0
        while time.time() < deadline and "[USB-HID] debug=ON" not in "".join(output):
            time.sleep(0.05)
        if "[USB-HID] debug=ON" not in "".join(output):
            raise RuntimeError(f"{profile}: could not enable HID trace")

        for key in ("h", "i", "ret"):
            qmp.send_key(key)
            time.sleep(0.35)

        time.sleep(1.0)
        text = "".join(output)
        required = (
            "[USB-HID] keyboard report",
            "[USB-HID] key=0000000000000068",  # h
            "[USB-HID] key=0000000000000069",  # i
            "[USB-HID] key=000000000000000A",  # Enter
        )
        missing = [marker for marker in required if marker not in text]
        if missing:
            raise RuntimeError(f"{profile}: missing markers: {', '.join(missing)}; serial tail: {text[-2500:]}")
        return text
    finally:
        try:
            qmp.command({"execute": "quit"})
        except Exception:
            pass
        qmp.close()
        serial.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
        process.wait(timeout=3)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", nargs="?", choices=("uhci", "ehci", "xhci", "all"), default="all")
    args = parser.parse_args()
    profiles = ("uhci", "ehci", "xhci") if args.profile == "all" else (args.profile,)
    base_port = 4600 + (os.getpid() % 200) * 4
    try:
        for index, profile in enumerate(profiles):
            print(f"[{profile}] injecting h, i, Enter through usb-kbd ...", flush=True)
            run_profile(profile, base_port + index * 2)
            print(f"[{profile}] PASS: USB report -> HID decoder -> keyboard ring", flush=True)
    except Exception as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
