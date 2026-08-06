@echo off
setlocal enabledelayedexpansion

set DISPLAY_MODE=-display gtk
set VNC_MSG=

for %%a in (%*) do (
    if "%%a"=="--vnc" (
        set DISPLAY_MODE=-vnc 0.0.0.0:1
        set VNC_MSG= Access: VNC at ^<host-ip^>:5901
    )
)

echo === Building Zig Kernel ===
zig build

echo === Creating ISO ===
rmdir /s /q isodir 2>nul
mkdir isodir\boot\grub
copy zig-out\bin\kernel isodir\boot\kernel.bin
copy grub.cfg isodir\boot\grub\grub.cfg
grub-mkrescue -o kernel.iso isodir

echo === Launching QEMU ===
echo  Network: e1000 NIC, port forward 8080-^>80
echo  Open http://localhost:8080 in host browser to test
echo !VNC_MSG!
echo.

qemu-system-x86_64 ^
    -cdrom kernel.iso ^
    -m 128M ^
    -device e1000,netdev=net0 ^
    -netdev user,id=net0,hostfwd=tcp::8080-:80 ^
    !DISPLAY_MODE! ^
    -serial stdio ^
    -d int,cpu_reset ^
    -D qemu.log ^
    -no-reboot
