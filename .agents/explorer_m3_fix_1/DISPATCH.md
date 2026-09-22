# DISPATCH: Explorer 1 (Milestone 3 Iteration 2)

## Mission
Analyze Milestone 3 Iteration 1 Review findings regarding `src/drivers/usb/hid.zig` (`decodeMouseReport` and `decodeKeyboardReport`).
Formulate a precise, robust fix strategy to resolve the mouse button swallowing and modifier handling hazards identified by `reviewer_m3_1` and `reviewer_m3_2`.

## Context & Review Feedback
In Milestone 3 Iteration 1:
- `reviewer_m3_1` and `reviewer_m3_2` both issued `REQUEST_CHANGES`.
- Finding 1: In `src/drivers/usb/hid.zig:251-258` (`decodeMouseReport`), the condition `const is_prefixed = (report.len >= 4 and report[0] != 0 and report[0] <= 4);` erroneously treats standard 4-byte Boot mouse reports where buttons are pressed (Left=0x01, Right=0x02, Left+Right=0x03, Middle=0x04) as Report-ID prefixed! This causes `offset = 1`, dropping the button click and reading buttons from `dx`, producing phantom clicks during horizontal movement.
- Finding 2: In `decodeKeyboardReport`, length heuristics can cause modifier shifting if length assumptions don't match callers.
- Finding 3: `mouse.updateFromUsbWithWheel` is implemented in `src/drivers/mouse.zig:218`, but `decodeMouseReport` ignores the scroll wheel (`report[3]`).

## Tasks
1. Read `/home/dr4d/Zirconium/.agents/ORIGINAL_REQUEST.md` and `/home/dr4d/Zirconium/AGENTS.md`.
2. Inspect `/home/dr4d/Zirconium/.agents/reviewer_m3_1/handoff.md` and `/home/dr4d/Zirconium/.agents/reviewer_m3_2/handoff.md`.
3. Inspect `src/drivers/usb/hid.zig`, `src/drivers/usb/mod.zig`, and `src/drivers/mouse.zig`.
4. Formulate the exact fix for `decodeMouseReport` and `decodeKeyboardReport` conforming to USB HID Boot Protocol (Appendix E.2).
5. Ensure `mouse.updateFromUsbWithWheel` is properly called when wheel data is present in 4-byte boot reports.
6. Write your report to `/home/dr4d/Zirconium/.agents/explorer_m3_fix_1/report.md` and handoff to `/home/dr4d/Zirconium/.agents/explorer_m3_fix_1/handoff.md`.
7. Message parent with `send_message`.
