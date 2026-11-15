#!/usr/bin/env python3
"""Build a bootable ISO for the Zirconium kernel.

Limine replaces GRUB as the bootloader.  The kernel still speaks Multiboot 1
(the protocol GRUB used to speak), so `src/entry.S` is unchanged: it still
receives EAX = 0x2BADB002 and EBX = the Multiboot info block.

The ISO is a BIOS+UEFI hybrid:

  * BIOS  - El Torito boots `limine-bios-cd.bin`, which loads `limine-bios.sys`.
  * UEFI  - El Torito boots `limine-uefi-cd.bin` (a FAT image holding the EFI
            application).

`limine.conf` sits at the ISO root, and the kernel at `boot/kernel.bin`.
The name `kernel.bin` matters: the test harnesses patch a freshly built
kernel into an existing ISO in place, and they look the file up by that name.

Usage:
    python3 tools/mkiso.py [--output kernel.iso] [--kernel zig-out/bin/kernel]
                           [--config limine.conf] [--stage DIR]
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# The Limine binaries.  They are vendored in the repository so that building
# an ISO never needs the network; see limine/README.md for their origin.
LIMINE_DIR = os.path.join(REPO_ROOT, "limine")

BIOS_CD = "limine-bios-cd.bin"
UEFI_CD = "limine-uefi-cd.bin"
BIOS_SYS = "limine-bios.sys"


def find_xorriso() -> str | None:
    for name in ("xorriso", "xorrisofs"):
        path = shutil.which(name)
        if path:
            return path
    return None


def stage_iso(stage: str, kernel: str, config: str) -> None:
    """Lay out the ISO tree: the config at the root, the kernel under /boot."""
    boot = os.path.join(stage, "boot")
    os.makedirs(boot, exist_ok=True)
    # The EFI directory is empty but must exist: xorriso warns (and the
    # Windows USB-stick recipe it mentions relies on it) when the ISO has EFI
    # boot equipment but no /EFI/BOOT directory.
    os.makedirs(os.path.join(stage, "EFI", "BOOT"), exist_ok=True)

    shutil.copy2(kernel, os.path.join(boot, "kernel.bin"))
    shutil.copy2(config, os.path.join(stage, "limine.conf"))

    for name in (BIOS_CD, UEFI_CD, BIOS_SYS):
        src = os.path.join(LIMINE_DIR, name)
        if not os.path.exists(src):
            raise SystemExit(
                f"missing {name} in {LIMINE_DIR}\n"
                f"see limine/README.md for where these come from"
            )
        shutil.copy2(src, os.path.join(boot, name))


def build_iso(stage: str, output: str) -> None:
    xorriso = find_xorriso()
    if xorriso is None:
        raise SystemExit(
            "xorriso is required to build the ISO (xorriso -as mkisofs ...)"
        )

    # The command line is the one Limine's own documentation gives for a
    # BIOS+UEFI hybrid ISO.
    cmd = [
        xorriso,
        "-as", "mkisofs",
        "-R", "-r", "-J",
        "-b", f"boot/{BIOS_CD}",
        "-no-emul-boot", "-boot-load-size", "4", "-boot-info-table", "-hfsplus",
        "-apm-block-size", "2048",
        "--efi-boot", f"boot/{UEFI_CD}",
        "-efi-boot-part", "--efi-boot-image",
        "--protective-msdos-label",
        stage,
        "-o", output,
    ]
    subprocess.run(cmd, check=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", default=os.path.join(REPO_ROOT, "kernel.iso"))
    ap.add_argument("--kernel", default=os.path.join(REPO_ROOT, "zig-out", "bin", "kernel"))
    ap.add_argument("--config", default=os.path.join(REPO_ROOT, "limine.conf"))
    ap.add_argument("--stage", default=None, help="keep the staged tree here")
    args = ap.parse_args()

    if not os.path.exists(args.kernel):
        raise SystemExit(f"kernel not found: {args.kernel}\nrun `zig build` first")
    if not os.path.exists(args.config):
        raise SystemExit(f"config not found: {args.config}")

    stage = args.stage
    if stage is None:
        import tempfile
        stage = tempfile.mkdtemp(prefix="zirconium-iso-")
        try:
            stage_iso(stage, args.kernel, args.config)
            build_iso(stage, args.output)
        finally:
            shutil.rmtree(stage, ignore_errors=True)
    else:
        os.makedirs(stage, exist_ok=True)
        stage_iso(stage, args.kernel, args.config)
        build_iso(stage, args.output)

    size = os.path.getsize(args.output)
    print(f"ISO written: {args.output} ({size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
