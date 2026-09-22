# Dispatch Task: Milestone 3 — USB 2.4GHz Wireless HID Peripherals & Input Event Routing

**Assigned To**: Worker 3 (`worker_m3`)  
**Role**: USB Wireless Peripherals & Input Routing Worker  
**Date**: 2026-09-20  
**Project Root**: `/home/dr4d/Zirconium`  
**Working Directory**: `/home/dr4d/Zirconium/.agents/worker_m3`  

---

## 1. Mandatory Reading Before Any Implementation
1. `/home/dr4d/Zirconium/.agents/ORIGINAL_REQUEST.md` (authoritative user requirements)
2. `/home/dr4d/Zirconium/.agents/PROJECT.md` (master architecture, milestone boundaries, code layout)
3. `/home/dr4d/Zirconium/AGENTS.md` (toolchain rules, test markers, non-preemption, coding constraints)
4. `/home/dr4d/Zirconium/.agents/explorer_survey_3/survey_report.md` & `handoff.md` (detailed multi-interface composite dongle specs, HID protocol details, input event routing into VGA text shell and GUI)

---

## 2. Mandatory Integrity Warning
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A `teamwork_preview_auditor` will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

---

## 3. Scope & Exclusive Write Ownership
You have exclusive write ownership of:
- `src/drivers/usb/hid.zig` (new or expanded USB HID protocol driver)
- `src/drivers/usb/device.zig` (multi-interface composite descriptor parsing & interface records)
- `src/drivers/usb/mod.zig` (interrupt transfer queues, polling loop, event routing)
- `src/drivers/usb.zig` (top-level exports and helpers)
- `src/drivers/keyboard.zig` (input queue handling and USB key injection)
- `src/drivers/mouse.zig` (mouse state update and relative motion handling)

---

## 4. Key Functional Requirements (F3.1 - F3.5)
1. **F3.1 Multi-Interface Composite Parsing**:
   - Parse full configuration descriptors containing multiple interface descriptors without overwriting interface records.
   - Store both Interface 0 (e.g. Keyboard) and Interface 1 (e.g. Mouse) with their respective endpoint descriptors (`ep_in`, packet size, polling interval) in the device's interface table.
2. **F3.2 USB HID Protocol Driver**:
   - Issue standard HID control requests: `SET_IDLE` (`bRequest = 0x0A`, `wValue = 0` to inhibit repetitive reporting), `SET_PROTOCOL` (`bRequest = 0x0B`, `wValue = 0` for Boot Protocol or `wValue = 1` for Report Protocol).
   - Boot Protocol keyboard report decoding (8-byte standard report: modifier byte, reserved, 6 keycodes) and mapping to ASCII characters with shift state handling.
   - Boot Protocol mouse report decoding (3-byte or 4-byte standard report: button mask, delta X, delta Y, optional scroll wheel).
3. **F3.3 Interrupt Transfer Queues**:
   - Asynchronous interrupt IN transfer scheduling for active endpoints across controllers (UHCI, EHCI, xHCI).
   - Non-blocking transfer completion checks on periodic polling tick without busy-wait delays.
   - Re-arm interrupt transfer descriptors immediately upon completion so subsequent user events are captured.
4. **F3.4 2.4GHz Wireless Dongle Support**:
   - Specifically detect and configure composite multi-interface 2.4GHz wireless dongles:
     - Logitech Unifying Receiver (Vendor ID `0x046D`, Product IDs `0xC52B`, `0xC534`, etc.).
     - Generic 2.4GHz wireless keyboard/mouse combo receivers (e.g., Vendor ID `0x0627`, `0x24AE`, `0x04F2`, etc.).
   - Configure both keyboard and mouse interfaces on the same physical dongle so both operate concurrently.
5. **F3.5 Input Event Routing**:
   - Route decoded keystrokes to `keyboard.pushKey(ch)` for VGA text console and shell.
   - Route mouse movement (buttons, dx, dy) to `mouse.updateFromUsb(buttons, dx, dy)` for both text cursor and shadow-buffer GUI (`src/system/gui.zig`).
   - Preserve PS/2 keyboard and PS/2 mouse fallback so that environments without USB peripherals continue to function seamlessly.

---

## 5. Verification & Acceptance Criteria
1. `zig build` compiles with 0 errors and 0 warnings.
2. `zig build -Drelease` compiles with 0 errors and 0 warnings.
3. `python3 tools/test_runner.py` passes all 10 golden markers (100% SUCCESS).
4. `python3 tools/e2e_test_suite.py --tier 1` passes 100%.
5. `python3 tools/e2e_test_suite.py --tier 3` passes all HID and USB test cases (`TC-USB-*`, `TC-HID-*`).
6. Write handoff report to `/home/dr4d/Zirconium/.agents/worker_m3/handoff.md` and notify parent via `send_message`.

## 2026-09-20T14:14:06Z
You are Worker 3 (`worker_m3`) for Milestone 3 of the Zirconium project.
Your working directory is `/home/dr4d/Zirconium/.agents/worker_m3`.
The project root is `/home/dr4d/Zirconium`.

Implement all Milestone 3 deliverables (F3.1 - F3.5):
1. Multi-Interface Composite Parsing: parse and store multi-interface descriptors without overwriting interface records.
2. USB HID Protocol Driver: Boot Protocol and Report Protocol handler for keyboards and mice (`SET_PROTOCOL`, `SET_IDLE`, report decoders).
3. Interrupt Transfer Queues: asynchronous interrupt IN endpoint transfer scheduling for HID inputs on active controllers (UHCI, EHCI, xHCI) with immediate re-arming upon completion.
4. 2.4GHz Wireless Dongle Support: Logitech Unifying (VID 0x046D, PID 0xC52B, etc.) and generic 2.4GHz composite receivers, activating both keyboard and mouse interfaces on the same physical dongle.
5. Input Event Routing: route keystrokes to `keyboard.pushKey(ch)` and mouse packets to `mouse.updateFromUsb(buttons, dx, dy)`, ensuring events drive both VGA text shell and GUI. Preserve PS/2 fallback.
