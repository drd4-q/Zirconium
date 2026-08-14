#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Downloading and preparing test programs for Zirconium ==="

if command -v python3 >/dev/null 2>&1; then
    python3 tools/create_test_disk.py
elif command -v python >/dev/null 2>&1; then
    python tools/create_test_disk.py
else
    echo "[ERROR] Python 3 is required to run create_test_disk.py"
    exit 1
fi
