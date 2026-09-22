# Dispatch Task: Milestone 3 Challenger 2 (`challenger_m3_2`)

**Role**: Stress Challenger  
**Date**: 2026-09-20  
**Project Root**: `/home/dr4d/Zirconium`  
**Working Directory**: `/home/dr4d/Zirconium/.agents/challenger_m3_2`  

---

## Instructions
1. Read `/home/dr4d/Zirconium/.agents/ORIGINAL_REQUEST.md`, `/home/dr4d/Zirconium/.agents/PROJECT.md`, and `/home/dr4d/Zirconium/AGENTS.md`.
2. Read the worker handoff report at `/home/dr4d/Zirconium/.agents/worker_m3/handoff.md`.
3. Adversarially challenge the HID subsystem and input event processing:
   - Challenge 1: Key rollover & rapid report decoding. Verify that reports containing multiple simultaneous keypresses or rapid sequences do not overflow the input ring buffer or drop characters.
   - Challenge 2: Corrupted or truncated HID reports. Verify that invalid packet lengths or unknown usage IDs do not trigger panics or out-of-bounds memory accesses.
   - Challenge 3: Continuous mouse motion & coordinate clamping. Verify that large delta X/Y values are properly clamped to screen bounds (0..1024, 0..768) without integer overflow.
4. Execute verification commands:
   - `zig build`
   - `zig build -Drelease`
   - `python3 tools/test_runner.py` (10/10 markers)
   - `python3 tools/e2e_test_suite.py --tier 3`
5. Write your handoff report to `/home/dr4d/Zirconium/.agents/challenger_m3_2/handoff.md` with explicit verdict (`APPROVE` or `REQUEST_CHANGES`).
6. Send a message to parent via `send_message`.
