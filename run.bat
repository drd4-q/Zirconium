@echo off
setlocal enabledelayedexpansion

set DISPLAY_MODE=-display gtk
set VNC_MSG=
set GDB_OPTS=

for %%a in (%*) do (
    if "%%a"=="--vnc" (
        set DISPLAY_MODE=-vnc 0.0.0.0:1
        set VNC_MSG= Access: VNC at ^<host-ip^>:5901
    )
    if "%%a"=="--test" (
        echo === Running Integration Test Suite ===
        python tools\test_runner.py
        exit /b !ERRORLEVEL!
    )
    if "%%a"=="--gdb" (
        set GDB_OPTS=-s -S
        echo === GDB Remote Debugging Enabled (target remote localhost:1234) ===
    )
)

echo === Building Zirconium (ReleaseFast) ===
zig build -Drelease
if errorlevel 1 (
    echo [ERROR] Build failed!
    exit /b %ERRORLEVEL%
)

echo === Creating ISO / Boot Image ===
rmdir /s /q isodir 2>nul
mkdir isodir\boot\grub 2>nul
copy /y zig-out\bin\kernel isodir\boot\kernel.bin >nul
copy /y grub.cfg isodir\boot\grub\grub.cfg >nul

where grub-mkrescue >nul 2>nul
if !ERRORLEVEL!==0 (
    grub-mkrescue -o kernel.iso isodir 2>nul
) else (
    where python >nul 2>nul
    if !ERRORLEVEL!==0 (
        python tools\patch_iso.py .
    )
)

if not exist kernel.iso (
    echo [ERROR] kernel.iso missing and grub-mkrescue unavailable.
    exit /b 1
)

set BOOT_OPT=-cdrom kernel.iso -boot d

REM Create disk image if missing
if not exist disk.img (
    echo === Creating 64MB disk image ===
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
    if exist disk.img (
        echo disk.img created (64MB raw)
        REM Format as FAT16 so the kernel's FAT16 driver can mount it
        where mkfs.fat >nul 2>nul
        if !ERRORLEVEL!==0 (
            mkfs.fat -F 16 disk.img >nul 2>nul
            echo disk.img formatted as FAT16
        )
    )
)

echo === Launching QEMU ===
echo  Network: e1000 NIC, port forward 8080-^>80
echo  Disk: virtio-blk 64MB
echo  Open http://localhost:8080 in host browser to test
echo !VNC_MSG!
echo.

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

!QEMU_CMD! ^
    !BOOT_OPT! ^
    -m 512M ^
    -smp 4 ^
    -device e1000,netdev=net0 ^
    -netdev user,id=net0,hostfwd=tcp::8080-:80 ^
    -drive if=none,id=hd0,file=disk.img,format=raw ^
    -device virtio-blk,drive=hd0 ^
    !DISPLAY_MODE! ^
    -serial stdio ^
    -d int,cpu_reset ^
    -D qemu.log ^
    !GDB_OPTS! ^
    -no-reboot
