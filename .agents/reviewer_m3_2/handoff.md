# Handoff Report: Milestone 3 Review & Adversarial Stress Test

**Agent**: Reviewer 2 (`reviewer_m3_2`)  
**Roles**: Reviewer & Critic  
**Date**: 2026-09-20  
**Status**: Hard Handoff (Review & Stress Test Complete)  
**Report Path**: `/home/dr4d/Zirconium/.agents/reviewer_m3_2/handoff.md`  
**Verdict**: **REQUEST_CHANGES**  

---

## Review Summary

**Verdict**: **REQUEST_CHANGES**  
**Integrity Audit**: **PASSED** (Zero integrity violations; no hardcoded test mocks, dummy facades, or fabricated logs).  
**Test Suite Verification**: **PASSED** (Dual build clean, 10/10 kernel markers passed in `test_runner.py`, 16/16 applicable tests passed in `e2e_test_suite.py --tier 3`).  
**Functional Defect Summary**: While the composite interface preservation in `device.zig`, secondary registration in `mod.zig`, UHCI interrupt queue chaining, and non-blocking polling engine are implemented with high engineering rigor, adversarial scrutiny discovered a critical defect in `decodeMouseReport` where normal mouse clicks on standard boot mice are falsely detected as report-ID prefixes and dropped, and a companion defect in `decodeKeyboardReport` where prefixed reports are rendered dead code due to caller slice truncation.

---

## 1. Observation

### 1.1 Toolchain & Automated Verification Commands
1. `zig build`:
   - Command executed: `zig build`
   - Exit Code: 0
   - Diagnostics: 0 errors, 0 warnings.
2. `zig build -Drelease`:
   - Command executed: `zig build -Drelease`
   - Exit Code: 0
   - Diagnostics: 0 errors, 0 warnings.
3. Automated Integration Harness (`python3 tools/test_runner.py`):
   - Exit Code: 0 (100% SUCCESS in 4.0s)
   - All 10 golden markers verified:
     - `[BOOT] Kernel loaded`
     - `[BOOT] System init done`
     - `[MEM] Physical memory manager initialized`
     - `[APIC] Local APIC timer initialized`
     - `[SMP] AP CPU 1 online`
     - `[USER] Hello from Ring 3 (user space)!`
     - `[USER-NET] Created socket via sys_socket`
     - `[USER-NET] Connected to 10.0.2.2:80 via sys_connect`
     - `[USER-HEAP] malloc(64)+malloc(128) via SYS_BRK OK`
     - `[USER-HEAP] free + reuse OK`
4. Tier 3 E2E Test Suite (`python3 tools/e2e_test_suite.py --tier 3`):
   - Exit Code: 0 (Wall clock duration: 17.17s)
   - Results: 16 PASSED, 4 PROGRESSIVE (M4 Wi-Fi roadmap items), 0 FAILED, 0 SKIPPED.
   - All Milestone 3 test cases passed:
     - `TC-HID-01`: Multi-Interface Composite Descriptor Parsing (F3.1) — PASSED
     - `TC-HID-02`: USB HID Keyboard & Mouse Enumeration (F3.2) — PASSED
     - `TC-HID-03`: USB HID Interrupt Transfer Queues (F3.3) — PASSED
     - `TC-HID-04`: 2.4GHz Wireless USB Dongle Profile (F3.4) — PASSED
     - `TC-HID-05`: Input Event Routing to Shell & Desktop GUI (F3.5) — PASSED

### 1.2 Code Inspection Observations

1. **Mouse Report Decoder False-Positive Heuristic (`src/drivers/usb/hid.zig:250-265`)**:
   ```zig
   pub fn decodeMouseReport(report: []const u8, prev_report: []u8) void {
       if (report.len < 3) return;

       // Detect Report-ID prefixed report (e.g. 4+ bytes where byte 0 is Report ID 2)
       const is_prefixed = (report.len >= 4 and report[0] != 0 and report[0] <= 4);
       const offset: usize = if (is_prefixed) 1 else 0;
       if (report.len < offset + 3) return;

       const buttons = report[offset + 0];
       const dx = @as(i32, @as(i8, @bitCast(report[offset + 1])));
       const dy = @as(i32, @as(i8, @bitCast(report[offset + 2])));

       const last_buttons = if (prev_report.len > 0) prev_report[0] else 0;
       if (dx != 0 or dy != 0 or buttons != last_buttons) {
           mouse.updateFromUsb(buttons, dx, dy);
       }
   ...
   ```
   Direct observation: In `src/drivers/usb/mod.zig:320`, the caller passes a fixed 4-byte slice:
   ```zig
   hid.decodeMouseReport(dev.report_buf[0..4], dev.prev_report[0..4]);
   ```
   Thus, `report.len` is always 4.

2. **Keyboard Report Decoder Caller Slicing (`src/drivers/usb/mod.zig:318`)**:
   ```zig
   hid.decodeKeyboardReport(dev.report_buf[0..8], dev.prev_report[0..8], &dev.caps_lock);
   ```
   Direct observation: In `src/drivers/usb/hid.zig:211`:
   ```zig
   const is_prefixed = (report.len >= 9 and report[0] != 0 and (report[0] <= 4 or report[1] == 0));
   const offset: usize = if (is_prefixed) 1 else 0;
   if (report.len < offset + 8) return;
   ```
   Because `mod.zig:318` passes a slice of length 8 (`dev.report_buf[0..8]`), `report.len >= 9` is always false.

3. **Composite Interface Preservation & Registration (`src/drivers/usb/device.zig:160-223` & `src/drivers/usb/mod.zig:176-235`)**:
   - `device.zig:32`: `interfaces: [MAX_DEVICE_INTERFACES]UsbInterface = [_]UsbInterface{.{}} ** MAX_DEVICE_INTERFACES`.
   - `device.zig:167-192`: Configuration descriptor iterator parses interface descriptors sequentially without overwriting interface 0.
   - `device.zig:253-258`: Issues `SET_PROTOCOL(0)` (`HID_REQ_SET_PROTOCOL`, Boot Protocol) and `SET_IDLE(0)` to all HID interfaces.
   - `mod.zig:178-234`: Scans `dev.interfaces[1..dev.interface_count]`, allocating separate `usb_devices` entries for secondary HID interfaces (e.g. mouse on composite dongles), assigning distinct `ep_in` endpoints.
   - `mod.zig:67-106`: `relinkUhciControllerSchedule` builds a sequential QH chain across all active devices in `usb_devices` and attaches them to all 1024 frame list slots.
   - `mod.zig:302-332`: `poll()` checks `(st & uhci.TD_CTRL_ACTIVE) == 0` non-blockingly for each active device and immediately re-arms the TD.

4. **Input Subsystem Integration & Fallback (`src/drivers/keyboard.zig` & `src/drivers/mouse.zig`)**:
   - `keyboard.zig:101-108`: `pushKey(ch)` enqueues characters into `direct_key_ring`.
   - `keyboard.zig:131-147`: `pollKey()` checks `direct_key_ring`, invokes `usb.poll()`, rechecks `direct_key_ring`, and falls back to PS/2 scancodes from IRQ 1.
   - `mouse.zig:185-197`: `updateFromUsb(buttons, dx, dy)` updates `mx`, `my`, `dx`, `dy`, button booleans, and clamps coordinates.
   - `mouse.zig:224-226`: `poll()` delegates to `usb.poll()`.
   - `mouse.zig:218`: `updateFromUsbWithWheel` is defined but uncalled.

---

## 2. Logic Chain

1. **Failure Mode in `decodeMouseReport` for Standard Boot Mice**:
   - Under standard USB operation, `device.zig:253` configures all HID interfaces into Boot Protocol using `SET_PROTOCOL(0)`.
   - Per USB HID 1.11 Specification Appendix B.2, Boot Protocol Mouse reports have NO Report ID prefix. The report format is:
     - Byte 0: Button mask (bit 0 = Button 1 / Left, bit 1 = Button 2 / Right, bit 2 = Button 3 / Middle).
     - Byte 1: X displacement (signed 8-bit).
     - Byte 2: Y displacement (signed 8-bit).
     - Byte 3: Optional wheel displacement.
   - In `src/drivers/usb/mod.zig:320`, `hid.decodeMouseReport(dev.report_buf[0..4], dev.prev_report[0..4])` passes a 4-byte slice (`report.len == 4`).
   - When a user presses:
     - Left Button: `report[0] = 0x01`
     - Right Button: `report[0] = 0x02`
     - Left + Right: `report[0] = 0x03`
     - Middle Button: `report[0] = 0x04`
   - In all four cases, `report[0]` is non-zero and `<= 4`.
   - The condition on line 252 evaluates to:
     `report.len >= 4` (TRUE) `and report[0] != 0` (TRUE) `and report[0] <= 4` (TRUE) -> `is_prefixed = true`.
   - Consequently, `offset` is set to `1`.
   - The decoder incorrectly skips `report[0]` (the actual button mask), and reads:
     - `buttons = report[1]` (the X displacement)
     - `dx = report[2]` (the Y displacement)
     - `dy = report[3]` (the wheel displacement or 0)
   - When the mouse is stationary (`dx == 0`, `dy == 0`) and Left button is clicked: `buttons` evaluates to `report[1] = 0`. Since `buttons == last_buttons == 0`, `mouse.updateFromUsb` is NEVER CALLED. The click is completely lost.
   - If the mouse is moving horizontally when clicked (`dx != 0`), `dx` is erroneously interpreted as button clicks, while horizontal motion is zeroed and vertical motion takes the horizontal delta.
   - This represents a critical functional flaw in mouse input processing.

2. **Dead Code / Misalignment in `decodeKeyboardReport`**:
   - `src/drivers/usb/hid.zig:211` expects that a report-ID prefixed keyboard packet will have length `>= 9` (1 byte Report ID + 8 bytes standard keyboard boot data).
   - However, `src/drivers/usb/mod.zig:318` truncates the buffer before passing it:
     `hid.decodeKeyboardReport(dev.report_buf[0..8], ...)`
   - Because `report.len` is always 8, `report.len >= 9` can never evaluate to true.
   - If a 2.4GHz composite wireless dongle sends a 9-byte prefixed report (Report ID = 1), `is_prefixed` remains `false`, `offset` remains `0`, and:
     - `report[0]` (Report ID 1) is treated as the modifier byte. Since bit 0 is 1, Left Ctrl is permanently latched as pressed.
     - `report[1]` (actual modifiers) is treated as reserved.
     - Keys in bytes 2..7 are misaligned by 1 byte.
     - Byte 8 (the 6th keycode) is dropped.

3. **Integrity & Conformance Assessment**:
   - Despite the two bugs above, there is NO evidence of cheating or integrity violations:
     - The UHCI queue schedule linking is real and correct.
     - The non-blocking polling loop checks hardware TD active bits without blocking spin-waits.
     - The keycode conversion table `usbKeyToAscii` correctly maps all 0x04..0x63 usage IDs and ASCII/Ctrl shifts.
     - The multi-interface parsing logic preserves all interface descriptors without clobbering.
   - The failures stem from well-intentioned but flawed heuristic prefix detection that was not tested against live mouse button clicks in the headless QEMU test runner.

---

## 3. Findings

### [Critical] Finding 1: `decodeMouseReport` Heuristic Falsely Treats Button Presses as Report ID Prefixes
- **What**: Left, Right, and Middle mouse button clicks on standard USB mice in boot mode are misidentified as report-ID prefixes and discarded or corrupted.
- **Where**: `src/drivers/usb/hid.zig`, lines 251–264, and `src/drivers/usb/mod.zig`, line 320.
- **Why**: `is_prefixed` evaluates to true whenever `report.len >= 4 and report[0] != 0 and report[0] <= 4`. Because `mod.zig` passes `dev.report_buf[0..4]`, `report.len` is always 4. Any button press produces `report[0] \in {1, 2, 3, 4}`, triggering the prefix skip (`offset = 1`).
- **Suggestion**: 
  1. Since the driver explicitly issues `SET_PROTOCOL(0)` (Boot Protocol) during enumeration, standard boot reports do not have report IDs.
  2. If report ID prefix support is required for non-compliant composite devices that remain in Report Protocol, test `report.len >= 5` and verify that the alleged Report ID matches the device's registered report ID (or check that `(report[1] & 0xF8) == 0` for valid button bits). For standard 3- or 4-byte reports (`report.len <= 4`), `offset` must remain 0.

### [Major] Finding 2: `decodeKeyboardReport` Prefix Detection Blocked by Caller Slice Truncation
- **What**: 9-byte report-ID prefixed keyboard reports cannot be parsed because the caller slices `dev.report_buf[0..8]`.
- **Where**: `src/drivers/usb/mod.zig`, line 318.
- **Why**: `hid.decodeKeyboardReport` checks `if (report.len >= 9)`. Passing `dev.report_buf[0..8]` guarantees `report.len == 8`, disabling prefix handling and causing 9-byte packets to latch Left Ctrl (`report[0] = 1`).
- **Suggestion**:
  Pass `dev.report_buf[0..@min(dev.ep_max_packet, 16)]` (or `&dev.report_buf`) from `mod.zig:318`. In `hid.zig:decodeKeyboardReport`, check `if (report.len >= 9 and report[0] <= 4 and report[2] == 0)` (noting that byte 2 of a prefixed report or byte 1 of an unprefixed report is the reserved `0x00` byte).

### [Minor] Finding 3: Dead Code in Mouse Driver
- **What**: `updateFromUsbWithWheel` is defined in `src/drivers/mouse.zig:218`, but is unreferenced across the entire codebase.
- **Where**: `src/drivers/mouse.zig`, lines 218–222.
- **Why**: `decodeMouseReport` in `hid.zig` only extracts `buttons`, `dx`, and `dy`, ignoring the optional wheel byte (byte 3).
- **Suggestion**: If scroll wheel support is desired, extract `delta_wheel` when `report.len >= 4` and forward it via `mouse.updateFromUsbWithWheel`.

---

## 4. Caveats

- Hardware hot-plugging (dynamic detach/reattach of USB devices after boot) was not tested, as the current kernel does not implement dynamic port status change interrupt handlers; enumeration is performed at boot time during PCI scan.
- Physical bare-metal testing on real Logitech Unifying hardware was not performed directly by Reviewer 2, as execution environment is restricted to virtualized QEMU targets.

---

## 5. Conclusion

Milestone 3 has achieved major architectural milestones:
- Clean compilation on both Debug and ReleaseFast targets.
- 100% pass on all 10 integration markers in `tools/test_runner.py`.
- 100% pass on Tier 3 in `tools/e2e_test_suite.py`.
- Correct multi-interface parsing and dual-interface UHCI queue scheduling.

However, because the mouse report decoder's heuristic actively breaks standard mouse clicks, Milestone 3 cannot be approved in its current state.

**Verdict**: **REQUEST_CHANGES**  
The implementation requires addressing Finding 1 and Finding 2 before final milestone sign-off.

---

## 6. Verification Method

To independently verify these findings and reproduce the test results:

1. **Compilation Verification**:
   ```bash
   zig build
   zig build -Drelease
   ```
2. **Harness Non-Regression Verification**:
   ```bash
   python3 tools/test_runner.py
   ```
3. **Tier 3 E2E Test Suite**:
   ```bash
   python3 tools/e2e_test_suite.py --tier 3
   ```
4. **Decoder Heuristic Verification**:
   Inspect `src/drivers/usb/hid.zig` line 252 and `src/drivers/usb/mod.zig` line 320:
   - For `report = [_]u8{ 0x01, 0x00, 0x00, 0x00 }` (Left Click), trace `is_prefixed`:
     `report.len (4) >= 4 and report[0] (1) != 0 and report[0] (1) <= 4` evaluates to `true`.
   - Verify that `buttons` is read from `report[1]` (0x00) instead of `report[0]` (0x01).
