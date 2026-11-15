# Limine bootloader binaries

Limine replaced GRUB as the Zirconium bootloader. These are the three files
the ISO builder (`tools/mkiso.py`) and the USB writer (`create_usb.sh`) need.
They are vendored so that building a bootable image never needs the network.

| File | What it is |
|---|---|
| `limine-bios-cd.bin` | El Torito BIOS boot image: stage 1 + stage 2 for BIOS. |
| `limine-uefi-cd.bin` | El Torito UEFI boot image: a FAT image holding the EFI application. |
| `limine-bios.sys` | The BIOS stage 2, read from the boot volume by `limine-bios-cd.bin`. |

## Origin

Limine 8.7.0, built by the Alpine Linux packaging
(`limine`, `limine-cd` and `limine-sys` packages, `v3.21/community`):

    https://dl-cdn.alpinelinux.org/alpine/v3.21/community/x86_64/

Upstream: <https://limine-bootloader.org> — BSD-2-Clause, see `LICENSE`.

| File | SHA-256 |
|---|---|
| `limine-bios-cd.bin` | `2d1e99968af7f9b302638135baa96faa0ce8d4ef6b4ab1dce353795f3809c07d` |
| `limine-uefi-cd.bin` | `b9c97e5f659f3986b8084adeaf0c6d866bf382df3c75a7dd695f454f0365ad9b` |
| `limine-bios.sys` | `1e45a99c61304bcccd2799b0ca678fddcd181b84cb85cde5bd30b5bd2f6b49d8` |

## Upgrading

Replace the three files with the ones from a newer Limine release and update
the checksums above. The bootloader is a separate artefact from the kernel:
the protocol between them is Multiboot 1, so a newer Limine does not require
a kernel change.
