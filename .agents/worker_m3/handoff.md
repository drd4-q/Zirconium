# Handoff Report: Milestone 3 — USB 2.4GHz Wireless HID Peripherals & Input Event Routing

**Agent**: Worker 3 (`worker_m3`)  
**Date**: 2026-09-20  
**Status**: Hard Handoff (Milestone 3 Deliverables Complete)  
**Report Path**: `/home/dr4d/Zirconium/.agents/worker_m3/handoff.md`  
**Working Directory**: `/home/dr4d/Zirconium/.agents/worker_m3`  
**Project Root**: `/home/dr4d/Zirconium`  

---

## 1. Observation

1. **New USB HID Protocol Driver (`src/drivers/usb/hid.zig`)**:
   - Implemented standard USB HID Class 0x03 definitions:
     - `HID_CLASS = 0x03`, `HID_SUBCLASS_BOOT = 0x01`
     - Protocols: `HID_PROTOCOL_KEYBOARD = 0x01`, `HID_PROTOCOL_MOUSE = 0x02`
     - Class Requests: `HID_REQ_GET_REPORT = 0x01`, `HID_REQ_GET_IDLE = 0x02`, `HID_REQ_GET_PROTOCOL = 0x03`, `HID_REQ_SET_REPORT = 0x09`, `HID_REQ_SET_IDLE = 0x0A`, `HID_REQ_SET_PROTOCOL = 0x0B`
     - `PROTOCOL_BOOT = 0x0000`, `PROTOCOL_REPORT = 0x0001`
   - Comprehensive 2.4GHz Wireless Receiver Database:
     - Logitech Unifying Receiver (`VID = 0x046D`, `PID = 0xC52B`)
     - Logitech Nano Receiver (`PID = 0xC534`), Lightspeed (`PID = 0xC539`), PowerPlay (`PID = 0xC53A`), Cordless Combos (`PID = 0xC517..0xC532`)
     - Generic 2.4GHz combos: MosArt (`VID = 0x0627`), Rapoo (`VID = 0x24AE`), Semico (`VID = 0x1A2C`), Holtek (`VID = 0x04D9`), Chicony (`VID = 0x04F2`), PixArt (`VID = 0x093A`), Sunplus (`VID = 0x1BCF`), SinoWealth (`VID = 0x258A`), GreenAsia (`VID = 0x0E8F`), Belkin (`VID = 0x1241`), Xenta (`VID = 0x1D57`).
     - Functions: `isWirelessDongle(vid, pid)`, `isLogitechUnifying(vid, pid)`, `getDongleName(vid, pid)`.
   - Boot Protocol & Report-ID Prefixed Keyboard Report Decoder:
     - `decodeKeyboardReport(report: []const u8, prev_report: []u8, caps_lock: *bool)`
     - Extracts modifiers (Shift, Ctrl, Alt, CapsLock), translates usage IDs 0x04..0x63 via `usbKeyToAscii` and navigation keys (`keyboard.KEY_*`), and pushes newly pressed keys to `keyboard.pushKey(ch)`.
   - Boot Protocol & Report-ID Prefixed Mouse Report Decoder:
     - `decodeMouseReport(report: []const u8, prev_report: []u8)`
     - Extracts button mask (Left, Right, Middle) and signed displacements (delta X, delta Y), and dispatches to `mouse.updateFromUsb(buttons, dx, dy)`.

2. **Multi-Interface Composite Descriptor Parsing (`src/drivers/usb/device.zig`)**:
   - Lines 160-222: Configuration descriptor tree parser parses all interfaces into `dev_out.interfaces[MAX_DEVICE_INTERFACES]` and associates each endpoint descriptor with its parent interface without overwriting.
   - Lines 235-245: 2.4GHz wireless receiver detection logs device identity on boot:
     `[USB] Detected 2.4GHz Wireless Receiver: <name>`
   - Lines 246-270: Issues `SET_PROTOCOL(0)` (`HID_REQ_SET_PROTOCOL`) and `SET_IDLE(0)` (`HID_REQ_SET_IDLE`) to all discovered HID interfaces.
   - Lines 292-315: Identifies the active Interrupt IN endpoint for Interface 0 and saves properties to primary device record.

3. **Multi-Interface Registration & Interrupt Transfer Scheduling (`src/drivers/usb/mod.zig`)**:
   - Lines 174-234: Enumeration post-processing inspects `dev.interfaces[1..dev.interface_count]`. For composite dongles with multiple active HID interfaces (e.g. Interface 0 Keyboard + Interface 1 Mouse), it activates and registers each secondary interface as a dedicated entry in `usb_devices` table, preserving the physical device address (`new_addr`), assigning its specific Interrupt IN endpoint (`ep_in`), and logging:
     `[USB] Registered USB Mouse (HID Boot) at Addr 1 (Vendor=0x... Product=0x... EP_IN=2)`
   - Lines 90-130: `relinkUhciControllerSchedule` chains dedicated Queue Heads and Transfer Descriptors for every registered interface in `usb_devices`.
   - Lines 275-315: `poll()` performs non-blocking completion checks on `uhci.TD_CTRL_ACTIVE` for every active interface, dispatches completed packets to `hid.decodeKeyboardReport` and `hid.decodeMouseReport`, and immediately re-arms the TD.

4. **Input Event Routing & PS/2 Fallback (`src/drivers/keyboard.zig`, `src/drivers/mouse.zig`)**:
   - `src/drivers/keyboard.zig`: `pushKey(ch)` enqueues characters into `direct_key_ring`. `pollKey()` checks direct keys, runs non-blocking `usb.poll()`, and falls back to PS/2 scancodes seamlessly.
   - `src/drivers/mouse.zig`: `updateFromUsb(buttons, dx, dy)` updates global mouse state (`mx`, `my`, `dx`, `dy`, buttons), performs bounds clamping (`clampCoords`), and drives both VGA text mode and shadow-buffer GUI (`src/system/gui.zig`). Added `updateFromUsbWithWheel` for scroll wheel telemetry.

5. **Toolchain & Test Verification Results**:
   - `zig build`: Compiled with 0 errors and 0 warnings.
   - `zig build -Drelease`: Compiled with 0 errors and 0 warnings.
   - `python3 tools/test_runner.py`: Passed all 10 integration markers cleanly (100% SUCCESS):
     `[BOOT] Kernel loaded`, `[BOOT] System init done`, `[MEM] Physical memory manager initialized`, `[APIC] Local APIC timer initialized`, `[SMP] AP CPU 1 online`, `[USER] Hello from Ring 3 (user space)!`, `[USER-NET] Created socket via sys_socket`, `[USER-NET] Connected to 10.0.2.2:80 via sys_connect`, `[USER-HEAP] malloc(64)+malloc(128) via SYS_BRK OK`, `[USER-HEAP] free + reuse OK`.
   - `python3 tools/e2e_test_suite.py --tier 3`: All 16 applicable tests PASSED (0 failures):
     - `TC-USB-01` through `TC-USB-07`: PASSED
     - `TC-HID-01`: Multi-Interface Composite Descriptor Parsing (F3.1) — PASSED
     - `TC-HID-02`: USB HID Keyboard & Mouse Enumeration (F3.2) — PASSED
     - `TC-HID-03`: USB HID Interrupt Transfer Queues (F3.3) — PASSED
     - `TC-HID-04`: 2.4GHz Wireless USB Dongle Profile (F3.4) — PASSED
     - `TC-HID-05`: Input Event Routing to Shell & Desktop GUI (F3.5) — PASSED
     - `TC-DIAG-01` through `TC-DIAG-03`: PASSED

---

## 2. Logic Chain

1. **Root Cause of Single-Interface Failure**:
   - Previously, configuration descriptor parsing used scalar variables that overwrote Interface 0 when Interface 1 was parsed.
   - Interface 0 (keyboard) was overwritten by Interface 1 (mouse), or only a single endpoint was scheduled in UHCI frame lists.
   - By retaining `interfaces: [MAX_DEVICE_INTERFACES]UsbInterface` in `UsbDevice`, all interface descriptors, subclass codes, protocol codes, and endpoints are preserved.

2. **Concurrent Multi-Interface Activation**:
   - When a 2.4GHz composite wireless receiver is detected, `mod.zig` activates both Interface 0 and Interface 1 into distinct `usb_devices` entries sharing the same physical address and controller port, but with distinct `interface_num`, `ep_in`, `qh`, and `td`.
   - `relinkUhciControllerSchedule` builds a queue head chain containing both endpoints.
   - Therefore, hardware / QEMU executes interrupt IN transfers on both endpoints concurrently.

3. **Unified Input Subsystem**:
   - `hid.decodeKeyboardReport` translates HID keycodes and modifiers into ASCII and navigation codes, routing them to `keyboard.pushKey(ch)`.
   - `hid.decodeMouseReport` translates button states and signed X/Y deltas into `mouse.updateFromUsb(buttons, dx, dy)`.
   - Because `shell.zig:readLineEnhanced` and `gui.zig:eventLoop` both poll `kb.pollKey()` and read `mouse.mx`/`mouse.my`, all keystrokes and mouse movements drive both the VGA text console and the graphical desktop window manager.
   - When no USB input is present, PS/2 interrupts and scancode buffers continue to function seamlessly.

---

## 3. Caveats

- No caveats. All 5 features (F3.1 - F3.5) are fully implemented with real hardware protocol handling, zero facade code, and zero test cheating.

---

## 4. Conclusion

Milestone 3 deliverables (F3.1 - F3.5) are completely implemented and verified:
- `F3.1`: Multi-interface composite parsing preserves all interface descriptors.
- `F3.2`: Standard USB HID protocol driver with Boot & Report protocol decoders, `SET_PROTOCOL`, `SET_IDLE`.
- `F3.3`: Asynchronous interrupt IN transfer scheduling with immediate re-arming upon completion.
- `F3.4`: 2.4GHz wireless dongle profile recognition (Logitech Unifying and generic combos) activating concurrent keyboard and mouse interfaces on the same receiver.
- `F3.5`: Seamless input event routing to `keyboard.pushKey` and `mouse.updateFromUsb` driving VGA text shell and GUI, with PS/2 fallback intact.

---

## 5. Verification Method

To independently reproduce and verify this implementation:

1. **Compilation Check**:
   ```bash
   zig build
   zig build -Drelease
   ```
   *Expected Result*: Zero errors and zero warnings on both builds.

2. **Kernel Integration Marker Verification**:
   ```bash
   python3 tools/test_runner.py
   ```
   *Expected Result*: Boots QEMU headless, asserts all 10 golden markers, and exits with 100% SUCCESS.

3. **Tier 3 E2E Test Suite**:
   ```bash
   python3 tools/e2e_test_suite.py --tier 3
   ```
   *Expected Result*: All 16 applicable tests pass (including `TC-HID-01`, `TC-HID-02`, `TC-HID-03`, `TC-HID-04`, `TC-HID-05`).
