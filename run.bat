@echo off
set "PATH=%PATH%;C:\Program Files\qemu"

echo === Building Zig Kernel ===
zig build
if errorlevel 1 (
    echo.
    echo [ERROR] Native Windows build failed!
    exit /b 1
)

echo === Patching ELF Header for QEMU ===
powershell -NoProfile -Command "$bytes = [System.IO.File]::ReadAllBytes('zig-out\bin\kernel'); if ($bytes[18] -eq 0x3e) { $bytes[18] = 3; [System.IO.File]::WriteAllBytes('zig-out\bin\kernel32', $bytes); Write-Output '  ELF patched successfully (kernel32)' } else { Write-Output '  ELF already patched or invalid' }"

echo.
echo === Launching QEMU ===
echo   Network: e1000 NIC, port forward 8080-^>80
echo   Open http://localhost:8080 in host browser to test
echo.

qemu-system-x86_64 ^
    -kernel zig-out\bin\kernel32 ^
    -m 128M ^
    -device e1000,netdev=net0 ^
    -netdev user,id=net0,hostfwd=tcp::8080-:80 ^
    -serial stdio ^
    -no-reboot ^
    -d int,cpu_reset ^
    -D qemu.log
