@echo off
setlocal
cd /d "%~dp0"

echo === Downloading and preparing test programs for Zirconium ===
python tools\create_test_disk.py
if errorlevel 1 (
    echo [ERROR] Failed to prepare test disk.
    exit /b 1
)
