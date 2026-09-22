# Review & Handoff Report: Milestone 3 — USB 2.4GHz Wireless HID Peripherals & Input Event Routing

**Reviewer**: Reviewer 1 (`reviewer_m3_1`)  
**Role**: Reviewer & Adversarial Critic  
**Date**: 2026-09-20  
**Project Root**: `/home/dr4d/Zirconium`  
**Working Directory**: `/home/dr4d/Zirconium/.agents/reviewer_m3_1`  
**Status**: Completed Review  
**Verdict**: **`REQUEST_CHANGES`**

---

## Review Summary

**Verdict**: **`REQUEST_CHANGES`**

While the core architecture for Milestone 3 (F3.1–F3.5) exhibits high structural quality—including real multi-interface composite parsing, true non-blocking interrupt queue scheduling, clean hardware control transfers, and seamless integration with `keyboard.zig` and `mouse.zig`—an adversarial code inspection revealed a **Critical Logic Flaw** in `src/drivers/usb/hid.zig` (`decodeMouseReport`).

Specifically, an erroneous heuristic designed to detect report-ID prefixed packets causes standard 4-byte Boot Mouse reports to misclassify any button click (Left=1, Right=2, Left+Right=3, Middle=4) as a Report ID. Consequently, byte offsets are shifted by 1: the button press is swallowed (ignored), while the horizontal displacement `dx` is interpreted as mouse button clicks (causing phantom clicks during horizontal movement). This completely breaks USB mouse button clicking across both the shell and GUI desktop.

Because this directly breaks acceptance criteria for USB HID peripheral input routing (R3, F3.2, F3.5), changes are requested before Milestone 3 can be approved.

---

## 1. Observation

### 1.1 Toolchain, Build, and Regression Suite Results
1. **Debug Build (`zig build`)**:
   - Command: `zig build`
   - Result: Exit code 0, 0 errors, 0 warnings.
2. **ReleaseFast Build (`zig build -Drelease`)**:
   - Command: `zig build -Drelease`
   - Result: Exit code 0, 0 errors, 0 warnings.
3. **Integration Test Harness (`tools/test_runner.py`)**:
   - Command: `python3 tools/test_runner.py`
   - Result: 100% SUCCESS (10/10 markers verified):
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
4. **Tier 3 E2E Test Suite (`tools/e2e_test_suite.py --tier 3`)**:
   - Command: `python3 tools/e2e_test_suite.py --tier 3`
   - Result: 16 Passed, 4 Progressive (M4 Wi-Fi), 0 Failed, 0 Skipped.
     - `TC-HID-01` (Multi-Interface Composite Descriptor Parsing): PASSED
     - `TC-HID-02` (USB HID Keyboard & Mouse Enumeration): PASSED
     - `TC-HID-03` (USB HID Interrupt Transfer Queues): PASSED
     - `TC-HID-04` (2.4GHz Wireless USB Dongle Profile): PASSED
     - `TC-HID-05` (Input Event Routing to Shell & Desktop GUI): PASSED
5. **Adversarial Stress Suite (`tools/stress_m3.py`)**:
   - Command: `python3 tools/stress_m3.py`
   - Result: 100% SUCCESS across all 3 challenge suites.

---

### 1.2 Direct Source Code Observations

#### Observation 1: Critical Logic Flaw in `src/drivers/usb/hid.zig:250-268`
In `src/drivers/usb/hid.zig`, lines 248–268:
```zig
// Decode USB HID Mouse Boot Report (3-4 bytes standard or 4-5 bytes report-ID prefixed)
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

    if (prev_report.len > 0) {
        prev_report[0] = buttons;
    }
}
```
And in `src/drivers/usb/mod.zig`, line 320:
```zig
hid.decodeMouseReport(dev.report_buf[0..4], dev.prev_report[0..4]);
```
- `mod.zig` passes a 4-byte slice (`report.len == 4`).
- Whenever a mouse button is pressed in standard Boot protocol (Left = 0x01, Right = 0x02, Middle = 0x04, Left+Right = 0x03), `report[0]` is in the range `1..4`.
- The condition `(report.len >= 4 and report[0] != 0 and report[0] <= 4)` evaluates to `true`.
- `offset` becomes `1`.
- `buttons` is read from `report[1]` (which contains `dx`), `dx` is read from `report[2]` (`dy`), and `dy` is read from `report[3]` (scroll wheel).
- The button press at `report[0]` is lost, and moving the mouse horizontally generates spurious clicks.

#### Observation 2: Multi-Interface Composite Parsing in `src/drivers/usb/device.zig:160-222`
```zig
        if (desc_type == types.DESC_INTERFACE and desc_len >= 9) {
            if (iface_count < MAX_DEVICE_INTERFACES) {
                current_iface = &dev_out.interfaces[iface_count];
                current_iface.?.* = UsbInterface{
                    .interface_num = cfg_buf[off + 2],
                    .class_code = cfg_buf[off + 5],
                    .subclass_code = cfg_buf[off + 6],
                    .protocol_code = cfg_buf[off + 7],
                };
...
                iface_count += 1;
            }
        } else if (desc_type == types.DESC_ENDPOINT and desc_len >= 7) {
            if (current_iface) |iface| {
                if (iface.endpoint_count < types.MAX_DEVICE_ENDPOINTS) {
                    const ep_addr = cfg_buf[off + 2];
...
                    iface.endpoints[iface.endpoint_count] = UsbEndpoint{ ... };
                    iface.endpoint_count += 1;
                }
            }
        }
```
- Each interface parsed from the configuration descriptor is assigned to `dev_out.interfaces[iface_count]`.
- Endpoints are linked to `current_iface`.
- Interface 0 and Interface 1 descriptors are maintained concurrently without overwriting.

#### Observation 3: Multi-Interface Scheduling in `src/drivers/usb/mod.zig:176-234`
```zig
var if_idx: usize = 1;
while (if_idx < dev.interface_count and usb_device_count < MAX_USB_DEVICES) : (if_idx += 1) {
    const iface = &dev.interfaces[if_idx];
    if (iface.class_code == 0x03) {
        var dev_extra = &usb_devices[usb_device_count];
        dev_extra.active = true;
        dev_extra.ctrl_idx = c_idx;
        dev_extra.port = p + 1;
        dev_extra.addr = new_addr;
        dev_extra.dev_type = iface.driver_type;
...
        usb_device_count += 1;
    }
}
```
- Dedicated `usb_devices` entry created for secondary interface (e.g. mouse).
- Physical address `new_addr` is shared while assigning independent `ep_in`, `qh`, `td`, and `report_buf`.
- `relinkUhciControllerSchedule(u, c_idx)` links both QHs into the 1024-entry UHCI frame list.

#### Observation 4: Non-Blocking Polling in `src/drivers/usb/mod.zig:301-332`
```zig
pub fn poll() void {
    if (!initialized or usb_device_count == 0) return;

    var i: usize = 0;
    while (i < usb_device_count) : (i += 1) {
        var dev = &usb_devices[i];
        if (!dev.active) continue;

        const st = @as(*const volatile u32, @ptrCast(&dev.td.ctrl_status)).*;
        if ((st & uhci.TD_CTRL_ACTIVE) == 0) {
            if ((st & 0x007E0000) == 0) {
                dev.packet_count +%= 1;
                if (dev.dev_type == .keyboard) {
                    hid.decodeKeyboardReport(dev.report_buf[0..8], dev.prev_report[0..8], &dev.caps_lock);
                } else if (dev.dev_type == .mouse) {
                    hid.decodeMouseReport(dev.report_buf[0..4], dev.prev_report[0..4]);
                }
            }
            // Re-arm TD
            dev.toggle ^= 1;
            dev.td.token = 0x69 | ...;
            @as(*volatile u32, @ptrCast(&dev.td.ctrl_status)).* = uhci.TD_CTRL_ACTIVE | ...;
            @as(*volatile u32, @ptrCast(&dev.qh.element_link)).* = @intCast(@intFromPtr(&dev.td));
        }
    }
}
```
- Polling reads volatile hardware TD status non-blockingly.
- If completed without error, dispatches to decoders and re-arms TD immediately with toggled DATA0/DATA1 bit.

#### Observation 5: Input Queue Hooks in `keyboard.zig` and `mouse.zig`
- `src/drivers/keyboard.zig:96-108`: `pushKey(ch)` enqueues to `direct_key_ring[64]`. `pollKey()` checks direct keys, calls `usb.poll()`, then falls back to PS/2 scancodes.
- `src/drivers/mouse.zig:185-212`: `updateFromUsb(buttons, dx, dy)` updates `mx`, `my`, `left_button`, `right_button`, `middle_button`, and calls `clampCoords()`.

---

## 2. Findings & Adversarial Challenges

### [Critical] Finding 1: Mouse Button Clicks Discarded & Scrambled into Motion Deltas in `decodeMouseReport`

- **Location**: `src/drivers/usb/hid.zig:251-258`
- **What**:
  ```zig
  const is_prefixed = (report.len >= 4 and report[0] != 0 and report[0] <= 4);
  const offset: usize = if (is_prefixed) 1 else 0;
  ```
- **Why this is a problem**:
  1. `device.zig:253` explicitly places all HID interfaces into **Boot Protocol** via `hid.makeSetProtocolPacket(..., hid.PROTOCOL_BOOT)`. Standard HID Boot Protocol mouse reports (USB HID Spec 1.11, Appendix E.2) **never** contain a Report ID prefix; byte 0 is strictly the button bitmask (`bit 0 = Left`, `bit 1 = Right`, `bit 2 = Middle`), byte 1 is `dx`, byte 2 is `dy`, and byte 3 is optional scroll wheel.
  2. In `mod.zig:320`, `hid.decodeMouseReport` is invoked with a 4-byte slice (`report.len == 4`).
  3. Whenever a user clicks the Left button (`report[0] = 1`), Right button (`report[0] = 2`), Left+Right (`report[0] = 3`), or Middle button (`report[0] = 4`), `report[0] <= 4` evaluates to `true`!
  4. This forces `is_prefixed = true` and `offset = 1`.
  5. The decoder reads `buttons = report[1]` (which is `dx`), `dx = report[2]` (which is `dy`), and `dy = report[3]` (wheel).
  6. **Concrete Attack Counterexample**:
     - User clicks Left Button while stationary: packet sent is `[0x01, 0x00, 0x00, 0x00]`.
     - `is_prefixed` triggers (`4 >= 4 and 1 != 0 and 1 <= 4`).
     - `offset = 1`.
     - `buttons = report[1] = 0`.
     - `dx = report[2] = 0`.
     - `dy = report[3] = 0`.
     - `mouse.updateFromUsb(0, 0, 0)` is called! `left_button` remains `false`! The click is completely ignored!
     - User moves mouse right by 1 pixel while not clicking: packet sent is `[0x00, 0x01, 0x00, 0x00]`.
     - `is_prefixed` is `false` (`report[0] == 0`).
     - `offset = 0`.
     - `buttons = 0`, `dx = 1`, `dy = 0`. Movement works.
     - User holds Left Button while moving mouse right by 1 pixel: packet sent is `[0x01, 0x01, 0x00, 0x00]`.
     - `is_prefixed` triggers!
     - `offset = 1`.
     - `buttons = report[1] = 1` (Left Button clicked by horizontal movement!).
     - `dx = report[2] = 0`.
     - Horizontal movement is stopped, and mouse movement generates phantom clicks.
- **Why Automated Tests Missed It**:
  - `e2e_test_suite.py` (`TC-HID-05`) only checked that `[BOOT] Framebuffer active` appeared in the serial log during headless boot.
  - `tools/test_hid_stress.zig` tested `updateFromUsb` directly with random buttons, but never called `decodeMouseReport` with a 4-byte report containing non-zero buttons and checked `left_button`.
- **Suggestion / Fix**:
  In Boot Protocol, do not guess Report IDs from button values. Since the device was configured to Boot Protocol, decode standard Boot reports directly:
  ```zig
  pub fn decodeMouseReport(report: []const u8, prev_report: []u8) void {
      if (report.len < 3) return;

      const buttons = report[0];
      const dx = @as(i32, @as(i8, @bitCast(report[1])));
      const dy = @as(i32, @as(i8, @bitCast(report[2])));

      const last_buttons = if (prev_report.len > 0) prev_report[0] else 0;
      if (dx != 0 or dy != 0 or buttons != last_buttons) {
          if (report.len >= 4) {
              const dwheel = @as(i32, @as(i8, @bitCast(report[3])));
              mouse.updateFromUsbWithWheel(buttons, dx, dy, dwheel);
          } else {
              mouse.updateFromUsb(buttons, dx, dy);
          }
      }

      if (prev_report.len > 0) {
          prev_report[0] = buttons;
      }
  }
  ```

---

### [Major] Finding 2: Latent Modifier Key Shifting Hazard in `decodeKeyboardReport`

- **Location**: `src/drivers/usb/hid.zig:211-213`
- **What**:
  ```zig
  const is_prefixed = (report.len >= 9 and report[0] != 0 and (report[0] <= 4 or report[1] == 0));
  const offset: usize = if (is_prefixed) 1 else 0;
  ```
- **Why this is a problem**:
  In a standard USB keyboard report, byte 0 is the modifier mask (Left Ctrl = 0x01, Left Shift = 0x02, Left Alt = 0x04), and byte 1 is reserved (0x00). If a 9-byte or larger buffer is ever passed to `decodeKeyboardReport` (e.g. from an endpoint with max packet size 16 or 64), holding Left Ctrl, Left Shift, or Left Alt causes `(report[0] <= 4 or report[1] == 0)` to evaluate to `true`! This shifts all keycodes by 1 byte and drops the modifier.
  *(Note: This did not trigger in QEMU only because `mod.zig:318` currently passes `dev.report_buf[0..8]`, truncating `report.len` to 8).*
- **Suggestion / Fix**:
  Remove heuristic prefix guessing for boot-mode keyboards. In boot protocol, keyboard reports are 8 bytes starting with modifiers at offset 0.

---

### [Minor] Finding 3: Ignored Mouse Scroll Wheel Telemetry in `decodeMouseReport`

- **Location**: `src/drivers/usb/hid.zig:262` vs `src/drivers/mouse.zig:214`
- **What**:
  `src/drivers/mouse.zig` defines `pub fn updateFromUsbWithWheel(buttons, dx, dy, dwheel)`, but `decodeMouseReport` in `hid.zig:262` only invokes `mouse.updateFromUsb(buttons, dx, dy)`, discarding byte 3 (wheel delta) when a 4-byte report is received.
- **Suggestion / Fix**:
  Inspect `report.len >= 4` and forward `report[3]` as signed `dwheel` to `mouse.updateFromUsbWithWheel()`.

---

### [Minor] Finding 4: Global Device Array Initialized as `undefined`

- **Location**: `src/drivers/usb/mod.zig:49`
- **What**:
  ```zig
  pub var usb_devices: [MAX_USB_DEVICES]UsbDevice = undefined;
  ```
- **Why this is a problem**:
  While active devices are initialized during enumeration, initializing the array with default values (`[_]UsbDevice{.{}} ** MAX_USB_DEVICES`) prevents potential undefined memory reads if diagnostic routines inspect inactive entries.
- **Suggestion / Fix**:
  Change to `pub var usb_devices: [MAX_USB_DEVICES]UsbDevice = [_]UsbDevice{.{}} ** MAX_USB_DEVICES;`.

---

## 3. Logic Chain

1. **Requirement R3 & F3.2/F3.5** mandates routing both keystrokes and mouse movement/button events into kernel input queues to drive VGA text shell and desktop GUI.
2. Direct observation shows `decodeMouseReport` contains a faulty condition:
   `is_prefixed = (report.len >= 4 and report[0] != 0 and report[0] <= 4);` (Observation 1.2, Finding 1).
3. In standard USB Boot Mouse reports, byte 0 is the button bitmask where Left Click is `1`, Right Click is `2`, and Middle Click is `4`.
4. When `mod.zig:320` feeds a 4-byte report into `decodeMouseReport`, any single-button or two-button click sets `is_prefixed = true`, setting `offset = 1`.
5. This offsets all report fields: byte 0 (buttons) is ignored, byte 1 (`dx`) becomes `buttons`, byte 2 (`dy`) becomes `dx`, and byte 3 (`wheel`) becomes `dy`.
6. Therefore, left clicks, right clicks, and middle clicks fail to register in both shell and GUI, while moving the mouse horizontally triggers phantom clicks.
7. Consequently, feature acceptance criteria for USB HID peripheral input routing are violated, necessitating a verdict of **`REQUEST_CHANGES`**.

---

## 4. Caveats

- **Integrity Assessment**: No integrity violations were detected. There are no hardcoded test shortcuts, facade mocks, or fabricated logs. The implementation is genuine, well-structured bare-metal Zig code. The issue is an algorithmic/heuristic defect in report decoding.
- **Non-blocking Scheduling and Multi-Interface Parsing**: As verified in Observations 2, 3, and 4, the multi-interface descriptor retention and UHCI interrupt queue scheduling are fully functional and properly designed.

---

## 5. Conclusion

**Verdict: `REQUEST_CHANGES`**

Milestone 3 cannot be approved until Finding 1 is resolved. Worker M3 must:
1. Fix `src/drivers/usb/hid.zig` `decodeMouseReport` to correctly decode standard Boot protocol mouse reports without false report-ID prefix shifts on button presses.
2. Ensure `mouse.left_button`, `mouse.right_button`, and `mouse.middle_button` correctly reflect clicks from 4-byte USB mouse reports.
3. Optionally route byte 3 (wheel) to `mouse.updateFromUsbWithWheel()`.
4. Add an empirical unit/stress test in `tools/test_hid_stress.zig` that directly feeds a 4-byte report with button clicks (`[0x01, 0, 0, 0]`, `[0x02, 0, 0, 0]`, `[0x04, 0, 0, 0]`) into `decodeMouseReport` and asserts that `left_button`, `right_button`, and `middle_button` are set to `true`.

---

## 6. Verification Method

To independently reproduce the issue and verify the required fix:

1. **Reproduction of Finding 1 (Counterexample in Zig)**:
   Add the following test case to `tools/test_hid_stress.zig`:
   ```zig
   {
       var prev: [4]u8 = [_]u8{0} ** 4;
       // Standard 4-byte boot report: Left button pressed (0x01), no motion
       const left_click_report = [_]u8{ 0x01, 0x00, 0x00, 0x00 };
       decodeMouseReport(&left_click_report, &prev);
       try std.testing.expect(left_button == true); // Fails under current code because is_prefixed == true!
   }
   ```
2. **Build and Test Verification**:
   ```bash
   zig build
   zig build -Drelease
   python3 tools/test_runner.py
   python3 tools/e2e_test_suite.py --tier 3
   zig run tools/test_hid_stress.zig
   ```
   *Expected Result after fix*: All builds and tests pass, and `left_button == true` assertion succeeds.
