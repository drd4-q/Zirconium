# Dispatch Task: Milestone 3 Challenger 1 (`challenger_m3_1`)

**Role**: Empirical Challenger  
**Date**: 2026-09-20  
**Project Root**: `/home/dr4d/Zirconium`  
**Working Directory**: `/home/dr4d/Zirconium/.agents/challenger_m3_1`  

---

## Instructions
1. Read `/home/dr4d/Zirconium/.agents/ORIGINAL_REQUEST.md`, `/home/dr4d/Zirconium/.agents/PROJECT.md`, and `/home/dr4d/Zirconium/AGENTS.md`.
2. Read the worker handoff report at `/home/dr4d/Zirconium/.agents/worker_m3/handoff.md`.
3. Empirically verify Milestone 3 deliverables in QEMU:
   - Test composite multi-interface dongle emulation in QEMU:
     - USB Keyboard alone: `-device usb-kbd`
     - USB Mouse alone: `-device usb-mouse`
     - Concurrent Keyboard and Mouse on same controller: `-device usb-kbd -device usb-mouse`
   - Verify that both devices are registered with distinct endpoints and addresses.
   - Verify input routing into both the VGA text shell (`keyboard.pushKey()`) and shadow-buffer GUI (`mouse.updateFromUsb()`).
   - Verify PS/2 fallback when no USB input devices are connected.
4. Execute builds and tests:
   - `zig build`
   - `zig build -Drelease`
   - `python3 tools/test_runner.py` (10/10 markers)
   - `python3 tools/e2e_test_suite.py --tier 3`
5. Write your handoff report to `/home/dr4d/Zirconium/.agents/challenger_m3_1/handoff.md` with explicit verdict (`APPROVE` or `REQUEST_CHANGES`).
6. Send a message to parent via `send_message`.
