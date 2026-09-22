#!/usr/bin/env python3
"""Update kernel.bin inside kernel.iso for run.bat.

Delegates to test_runner's logic: patches the kernel in place while it fits
the existing slot, otherwise rebuilds kernel.iso with grub-mkrescue (native
or via WSL).

Usage: python3 tools/patch_iso.py [repo_root]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_runner as tr  # noqa: E402


def main():
    repo_root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    if not tr.patch_kernel_iso(repo_root):
        print("[ISO PATCHER] No bootable image could be produced.")
        sys.exit(1)


if __name__ == "__main__":
    main()
