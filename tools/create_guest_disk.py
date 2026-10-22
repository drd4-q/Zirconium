#!/usr/bin/env python3
"""Builds the guest kernels and puts them on the ZVM's disk.

A ZVM's guests are ordinary files on the host's disk: the loader reads them
through the VFS, so a guest kernel is just an ELF in /vms.  This script
builds the sample guests, and optionally fetches a real one, and copies them
into disk.img.

    python3 tools/create_guest_disk.py            # the sample guests
    python3 tools/create_guest_disk.py --fetch    # plus a real guest, if one is reachable
"""

import os
import shutil
import subprocess
import sys
import urllib.request

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SAMPLES_DIR = os.path.join(REPO_ROOT, "samples")
DISK_PATH = os.path.join(REPO_ROOT, "disk.img")
GUEST_DIR = os.path.join(SAMPLES_DIR, "guests")

# The guests this script builds.  Each one is a freestanding x86-64 ELF with a
# Multiboot-compatible entry.
GUEST_SOURCES = [
    # The guest that talks to the ZVP: it finds the device, pings the
    # hypervisor and posts a message.  It is written in assembly on purpose:
    # the interpreter implements a specific set of instructions, and a
    # hand-written guest is a list of exactly those.
    ("guest_hello.S", "linux.elf"),
    ("guest_hello.S", "bsd.elf"),
]

# Real guests, if they can be fetched.  These are the ones a ZVM would
# actually be pointed at; the sample guests exist because these are large and
# need a lot of emulated hardware.
REAL_GUESTS = [
    # Linux's own "hello" style test payload is not a kernel, but a real
    # Multiboot ELF is what the loader has to cope with.
    (
        "https://github.com/SinglyOS/Singly/releases/download/v0.4.1/"
        "SinglyOS-v0.4.1-x86_64-generic.iso",
        "singly.iso",
    ),
]


def build_guests():
    """Build the sample guests as freestanding ELFs."""
    os.makedirs(GUEST_DIR, exist_ok=True)
    built = []

    for source, out_name in GUEST_SOURCES:
        src = os.path.join(SAMPLES_DIR, source)
        if not os.path.exists(src):
            print(f"[GUEST] {source}: missing, skipping")
            continue
        out = os.path.join(GUEST_DIR, out_name)
        try:
            if source.endswith(".S"):
                # A hand-written guest: assemble it and link it with the
                # module root that gives the assembly an entry point.
                root = os.path.join(SAMPLES_DIR, "guest_root.zig")
                subprocess.run(
                    ["zig", "build-exe", root, src,
                     "-target", "x86_64-freestanding",
                     "-femit-bin=" + out,
                     "-fentry=guest_entry", "--image-base", "0x100000",
                     "-fstrip", "--gc-sections", "-OReleaseSmall"],
                    check=True, cwd=SAMPLES_DIR,
                )
            else:
                subprocess.run(
                    ["zig", "build-exe", source,
                     "-target", "x86_64-freestanding",
                     "-fno-emit-bin", f"-femit-bin={out}"],
                    check=True, cwd=SAMPLES_DIR,
                )
            size = os.path.getsize(out)
            print(f"[GUEST] Built {out_name} ({size} bytes)")
            built.append((out, out_name))
        except subprocess.CalledProcessError as e:
            print(f"[GUEST WARNING] Could not build {source}: {e}")

    return built


def fetch_guests():
    """Fetch the real guests, if the network reaches them."""
    fetched = []
    for url, out_name in REAL_GUESTS:
        out = os.path.join(GUEST_DIR, out_name)
        if os.path.exists(out):
            print(f"[GUEST] {out_name} already present")
            fetched.append((out, out_name))
            continue
        print(f"[GUEST] Fetching {url}...")
        try:
            urllib.request.urlretrieve(url, out)
            print(f"[GUEST] Downloaded {out_name} ({os.path.getsize(out)} bytes)")
            fetched.append((out, out_name))
        except Exception as e:
            print(f"[GUEST WARNING] Could not fetch {out_name}: {e}")
    return fetched


def copy_to_disk(files):
    """Copy the guests into disk.img, under /vms."""
    if not os.path.exists(DISK_PATH):
        print("[GUEST] No disk.img; run ./run.sh or create_test_disk.py first")
        return False
    if not shutil.which("mcopy") or not shutil.which("mmd"):
        print("[GUEST WARNING] mtools (mcopy/mmd) not found; cannot populate the disk")
        return False

    subprocess.run(["mmd", "-i", DISK_PATH, "::/vms"], check=False)
    for path, name in files:
        subprocess.run(["mcopy", "-o", "-i", DISK_PATH, path, f"::/vms/{name}"], check=True)
        print(f"[GUEST] disk.img:/vms/{name}")

    # The loader wants the guest at /vms/<name>, so also put the sample
    # guests where the default configuration looks for them.
    for path, name in files:
        if name in ("zvm.elf", "linux.elf", "bsd.elf"):
            subprocess.run(["mcopy", "-o", "-i", DISK_PATH, path, f"::/vms/{name}"], check=False)
    return True


def main():
    fetch = "--fetch" in sys.argv
    built = build_guests()
    if fetch:
        built += fetch_guests()
    if not built:
        print("[GUEST] No guests were built")
        return 1
    copy_to_disk(built)
    return 0


if __name__ == "__main__":
    sys.exit(main())
