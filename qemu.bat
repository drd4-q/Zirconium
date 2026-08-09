@echo off
setlocal enabledelayedexpansion

set QEMU_CMD=qemu-system-x86_64
where qemu-system-x86_64 >nul 2>nul
if errorlevel 1 (
    if exist "C:\Program Files\qemu\qemu-system-x86_64.exe" (
        set QEMU_CMD="C:\Program Files\qemu\qemu-system-x86_64.exe"
    ) else if exist "C:\Program Files (x86)\qemu\qemu-system-x86_64.exe" (
        set QEMU_CMD="C:\Program Files (x86)\qemu\qemu-system-x86_64.exe"
    ) else if exist "C:\msys64\ucrt64\bin\qemu-system-x86_64.exe" (
        set QEMU_CMD="C:\msys64\ucrt64\bin\qemu-system-x86_64.exe"
    ) else if exist "C:\msys64\mingw64\bin\qemu-system-x86_64.exe" (
        set QEMU_CMD="C:\msys64\mingw64\bin\qemu-system-x86_64.exe"
    ) else (
        echo [ERROR] qemu-system-x86_64.exe not found!
        echo Please install QEMU or add C:\Program Files\qemu to system PATH.
        exit /b 1
    )
)

where python >nul 2>nul
if !ERRORLEVEL!==0 (
    python tools\patch_iso.py .
)

if not exist kernel.iso (
    echo [ERROR] kernel.iso missing.
    exit /b 1
)

set BOOT_OPT=-cdrom kernel.iso -boot d

if not exist disk.img (
    where qemu-img >nul 2>nul
    if !ERRORLEVEL!==0 (
        qemu-img create -f raw disk.img 64M >nul
    ) else (
        where dd >nul 2>nul
        if !ERRORLEVEL!==0 (
            dd if=/dev/zero of=disk.img bs=1M count=64 2>nul
        ) else (
            fsutil file createnew disk.img 67108864 >nul
        )
    )
)

!QEMU_CMD! ^
    !BOOT_OPT! ^
    -m 512M ^
    -device e1000,netdev=net0 ^
    -netdev user,id=net0,hostfwd=tcp::8080-:80 ^
    -drive if=none,id=hd0,file=disk.img,format=raw ^
    -device virtio-blk,drive=hd0 ^
    -display gtk ^
    -serial stdio ^
    -d int,cpu_reset ^
    -D qemu.log ^
    -no-reboot
