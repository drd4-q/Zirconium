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
        exit /b %ERRORLEVEL%
    )
    if "%%a"=="--gdb" (
        set GDB_OPTS=-s -S
        echo === GDB Remote Debugging Enabled (target remote localhost:1234) ===
    )
)

echo === Building Zirconium ===
zig build

echo === Creating ISO ===
rmdir /s /q isodir 2>nul
mkdir isodir\boot\grub
copy zig-out\bin\kernel isodir\boot\kernel.bin
copy grub.cfg isodir\boot\grub\grub.cfg
grub-mkrescue -o kernel.iso isodir

REM Create disk image if missing
if not exist disk.img (
    echo === Creating 64MB disk image ===
    dd if=/dev/zero of=disk.img bs=1M count=64 2>nul
    echo disk.img created (64MB raw)
)

echo === Launching QEMU ===
echo  Network: e1000 NIC, port forward 8080-^>80
echo  Disk: virtio-blk 64MB
echo  Open http://localhost:8080 in host browser to test
echo !VNC_MSG!
echo.

qemu-system-x86_64 ^
    -cdrom kernel.iso ^
    -m 512M ^
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
