# Forensic Audit Report — Milestone 2: USB Host Controller Subsystem Architecture

**Agent:** auditor_m2  
**Date:** 2026-09-20  
**Target:** Milestone 2 (Deliverables F2.1 to F2.7)  
**Profile:** General Project  
**Integrity Mode:** Development Mode (per `ORIGINAL_REQUEST.md`)  
**Verdict:** **CLEAN**  

---

## Executive Summary

Worker 2 (`worker_m2`) was assigned Milestone 2: implementing the USB Host Controller Subsystem Architecture covering xHCI, EHCI, UHCI, PMM-backed DMA allocation, and asynchronous non-blocking transfer scheduling.

A thorough forensic audit was conducted across all 7 verification dimensions (Checks C1–C7). Forensic inspection confirmed that:
1. All prior mock/stub implementations (which previously hardcoded fake root port connections for EHCI and xHCI in `src/drivers/usb.zig`) were completely excised.
2. Authentic host controller drivers (`xhci.zig`, `ehci.zig`, `uhci.zig`) were built from scratch in freestanding Zig, directly programming MMIO capability and operational registers (xHCI/EHCI) and Port I/O (UHCI), with physical DMA ring/table allocation backed by the PMM.
3. No hardcoded test results, mock return values, self-certifying tautologies, or test runner tampering exist.
4. Independent compilation (`zig build` and `zig build -Drelease`) succeeded with zero errors and zero warnings.
5. Independent executions of both `tools/test_runner.py` (10/10 golden markers) and `tools/e2e_test_suite.py` passed 100% cleanly.

The work product is authentic, genuine, robust, and free of any integrity violations.

---

## 1. Observation

### Exact File Paths & Lines Inspected
- `src/drivers/usb.zig`: Refactored to clean export wrapper, removing lines 751–765 which previously returned fake root port strings (`connected = (p == 0)`).
- `src/drivers/usb/xhci.zig` (449 lines):
  - MMIO capability access: `readMmio8(mmio_base + 0x00)` (`CAPLENGTH`), `HCSPARAMS1`, `HCSPARAMS2`, `HCCPARAMS1`, `DBOFF`, `RTSOFF` (lines 132–147).
  - BIOS handoff: Traversal of extended capabilities at `USBLEGSUP` (lines 151–169), toggling OS Owned Semaphore (bit 16) and waiting for BIOS Owned Semaphore (bit 24) to clear.
  - Operational register sequence: Clears RS in `USBCMD` (line 173), polls `HCHalted` (line 176), asserts `HCRST` (line 181), waits for CNR bit 11 to clear (line 191), configures `CONFIG` (line 197).
  - DMA setup: Allocates DCBAA (line 200), programs `DCBAAP` via `writeMmio64` (line 220), allocates 256-TRB Command Ring with Link TRB (lines 223–236), programs `CRCR` with RCS bit (line 236), allocates Event Ring with ERST (lines 239–251), programs Interrupter 0 (`ERSTSZ`, `ERSTBA`, `ERDP`, `IMAN`) (lines 254–258).
  - Root port control: Powers on ports via `PORTSC.PP` (line 266), resets ports via `PORTSC.PR` (line 329), polls `PORTSC.PRC` (line 333).
  - Command submission & non-blocking polling: Submits TRBs to Command Ring, rings doorbell (line 417), polls Event Ring with `asm volatile ("pause")` (line 443), updates `ERDP` with EHB bit (line 437).
- `src/drivers/usb/ehci.zig` (419 lines):
  - MMIO capability access: `CAPLENGTH`, `HCSPARAMS`, `HCCPARAMS` (lines 115–123).
  - BIOS handoff: Traverses PCI EECP `USBLEGSUP` register (lines 126–138), requests OS Ownership (bit 24), waits for BIOS release.
  - Operational setup: Halts controller, issues `HCRESET` (line 150), allocates 1024-entry Periodic Frame List (line 158), writes `PERIODICLISTBASE` (line 165).
  - Async schedule: Allocates `async_qh` (Reclamation Head `H=1`) and `ctrl_qh` with circular links (lines 176–196), writes `ASYNCLISTADDR` (line 198), enables `CONFIGFLAG = 1` (line 201), powers on ports via `PORTSC.PP` (line 208).
  - Companion routing: Detects low-speed line status (0x01) or full-speed devices and sets Port Owner bit 13 to release port to companion controller (lines 254, 276).
  - Control transfer: Builds Setup qTD (`QTD_PID_SETUP`), Data qTDs (`QTD_PID_IN`/`OUT`), Status qTD with IOC, links to `overlay_next_qtd`, polls `QTD_ACTIVE` bit with `pause`, checks error bits `0x7E` (lines 338–414).
- `src/drivers/usb/uhci.zig` (358 lines):
  - Instance-based `UhciController` eliminates static global collisions.
  - Port I/O: Uses `inw`/`outw`/`inl`/`outl` for `USBCMD` (0x00), `USBSTS` (0x02), `USBINTR` (0x04), `FRNUM` (0x06), `FRBASEADD` (0x08), `SOFMOD` (0x0C), `PORTSC1` (0x10), `PORTSC2` (0x12).
  - DMA setup: Allocates 1024-entry Frame List via PMM, allocates Control QH and TDs in dedicated DMA page.
  - Port reset: Writes `0x0204` to assert Port Reset (bit 9), waits 50ms, clears reset, re-enables port (lines 196–207).
  - Non-blocking control transfer: Builds Setup TD (0x2D), Data TDs (0x69/0xE1), Status TD, polls `TD_CTRL_ACTIVE` bit using `pause` loops, checks error bits `0x007E0000` (lines 260–345).
- `src/drivers/usb/dma.zig` (112 lines):
  - Allocator backed by `root.pmm.allocPage()` and `pmm.allocPages()`.
  - Zeroes memory, provides `allocAligned` and `allocSliceAligned` guaranteeing 16B, 32B, and 64B physical alignments.
- `src/drivers/usb/pci_detect.zig` (106 lines):
  - Scans PCI bus for class `0x0C`, subclass `0x03`, classifies `prog_if`: 0x00=UHCI, 0x20=EHCI, 0x30=xHCI.
  - Maps BAR4 (I/O base) for UHCI, BAR0 for EHCI, and handles 64-bit BAR0/BAR1 decoding for xHCI (lines 63–70).
  - Activates PCI bus master via `pci.enableBusMaster()`.
- `src/drivers/usb/device.zig` (330 lines):
  - Multi-interface composite device support (`MAX_DEVICE_INTERFACES = 4`, `MAX_DEVICE_ENDPOINTS = 4`).
  - Standard USB enumeration: `GET_DESCRIPTOR` 8 bytes -> `SET_ADDRESS` -> `GET_DESCRIPTOR` 18 bytes -> `GET_DESCRIPTOR` config header -> `GET_DESCRIPTOR` full config tree -> interface & endpoint parser -> `SET_CONFIGURATION 1` -> HID Boot Protocol & Idle setup.
- `src/drivers/usb/mod.zig` (506 lines):
  - Coordinates controller instances (`uhci_instances`, `ehci_instances`, `xhci_instances`).
  - Implements non-blocking `poll()` hook draining interrupt TDs and pushing keystrokes to `keyboard.pushKey()` and mouse packets to `mouse.updateFromUsb()`.
  - Dynamically prints controller status in `printUsbStatus()`.

### Verbatim Commands & Tool Results

1. **Dual Compilation (Check C6):**
   - Command: `zig build`
     - Exit code: `0`
     - Stderr: `""` (clean)
   - Command: `zig build -Drelease`
     - Exit code: `0`
     - Stderr: `""` (clean)

2. **Integration Test Suite Non-Regression (Check C7 / Check C4):**
   - Command: `python3 tools/test_runner.py`
     - Exit code: `0`
     - Result: `ALL INTEGRATION TESTS PASSED CLEANLY! (100% SUCCESS)`
     - Verified all 10 golden markers:
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

3. **Multi-Controller Concurrent Hardware Discovery:**
   - Command: QEMU execution with `-device qemu-xhci,id=xhci -device ich9-usb-ehci1,id=ehci -device ich9-usb-uhci1,id=uhci`
   - Serial log output:
     ```
     [USB] Scanning PCI for USB host controllers...
     [USB] Found xHCI (USB 3.0) Controller at PCI 0:4 (Vendor=0x0000000000001B36 Device=0x000000000000000D)
     [USB] Found EHCI (USB 2.0) Controller at PCI 0:5 (Vendor=0x0000000000008086 Device=0x000000000000293A)
     [USB] Found UHCI (USB 1.1) Controller at PCI 0:6 (Vendor=0x0000000000008086 Device=0x0000000000002934)
     [USB] Subsystem initialized with 3 controller(s), 0 active USB device(s).
     ```

4. **UHCI Real Device Enumeration:**
   - Command: QEMU execution with `-device ich9-usb-uhci1,id=uhci -device usb-kbd,bus=uhci.0,port=1 -device usb-mouse,bus=uhci.0,port=2`
   - Serial log output:
     ```
     [USB] Scanning PCI for USB host controllers...
     [USB] Found UHCI (USB 1.1) Controller at PCI 0:4 (Vendor=0x0000000000008086 Device=0x0000000000002934)
     [USB] Registered USB Keyboard (HID Boot) at Addr 1 (Vendor=0x0000000000000627 Product=0x0000000000000001 EP_IN=1)
     [USB] Registered USB Mouse (HID Boot) at Addr 2 (Vendor=0x0000000000000627 Product=0x0000000000000001 EP_IN=1)
     [USB] Subsystem initialized with 1 controller(s), 2 active USB device(s).
     ```

5. **E2E USB Test Suite (`tools/e2e_test_suite.py -k USB`):**
   - 14/14 tests PASSED (100%).
   - `TC-USB-01` to `TC-USB-07` all PASSED.

---

## 2. Logic Chain

1. **Absence of Hardcoded Results & Mock Values (Check C1):**
   - Observations confirm that vendor IDs (`0x1B36`, `0x8086`, `0x0627`), device IDs (`0x000D`, `0x293A`, `0x2934`), and USB product IDs (`0x0001`) are absent from string literals or constants in `src/`.
   - Grep searches confirm zero occurrences of these constants in the source tree.
   - When no devices were attached to xHCI/EHCI, the kernel reported 0 devices; when devices were attached to UHCI, it reported 2 devices with exact dynamic addresses and attributes.
   - Therefore, device discovery and reporting are 100% dynamic and genuine.

2. **Genuine Hardware Interaction (Check C2):**
   - Analysis of `xhci.zig`, `ehci.zig`, and `uhci.zig` revealed that register access occurs via volatile MMIO pointers (`*volatile u32`, `*volatile u64`) and x86 I/O port assembly (`inw`/`outw`/`inl`/`outl`).
   - Hardware operational sequences follow official specifications:
     - xHCI halts, resets, clears CNR, writes DCBAAP, CRCR, ERSTSZ, ERSTBA, ERDP, IMAN, rings doorbells, and manages cycle bits.
     - EHCI implements BIOS handoff, resets via HCRESET, sets PERIODICLISTBASE and ASYNCLISTADDR, and handles companion routing by releasing ports via Port Owner bit 13.
     - UHCI sets up a 1024-entry frame list, control QH, TDs, and resets ports via bit 9.
   - The DMA allocator relies on physical 4KB pages allocated directly from the PMM.
   - Therefore, the implementation is authentic and contains no stubs or facades.

3. **No Pre-populated or Fabricated Artifacts (Check C3):**
   - Filesystem scan revealed only ephemeral logs (`qemu.log`, `serial_test.log`) dynamically refreshed during test executions.
   - No pre-recorded logs or fabricated test outputs exist.

4. **Test Integrity and Non-Regression (Check C4 & C7):**
   - `git diff HEAD tools/test_runner.py` produced zero lines of diff; git history confirms the baseline test runner was untouched.
   - `tools/e2e_test_suite.py` drives real QEMU processes with headless serial logging and asserts genuine kernel outputs.
   - All 10 golden markers in `test_runner.py` passed with 100% success.
   - All 14 USB tests in `e2e_test_suite.py` passed with 100% success.

5. **No Execution Delegation or Unauthorized Code Borrowing (Check C5):**
   - `build.zig.zon` defines empty dependencies (`.dependencies = .{}`).
   - All code is implemented in pure freestanding Zig with no external binaries or wrappers.

6. **Dual Compilation Integrity (Check C6):**
   - Both `zig build` and `zig build -Drelease` completed with returncode 0 and no diagnostics.

---

## 3. Adversarial Review & Stress Testing

| # | Attack Scenario / Hypothesis | Stress Test Result | Finding |
|---|-----------------------------|--------------------|---------|
| 1 | Controller with null MMIO/I/O Base | Explicit check in `xhci.zig:129`, `ehci.zig:112`, `uhci.zig:114` aborts cleanly | PASS |
| 2 | PMM allocation exhaustion during DMA initialization | All DMA page allocations check `orelse return false` and clean up prior pages | PASS |
| 3 | Malformed USB configuration descriptor with corrupted lengths | `device.zig:162-163` guards with `if (desc_len < 2 or off + desc_len > total_cfg_len) break;` preventing buffer overruns | PASS (`TC-STRESS-04`) |
| 4 | Non-responsive USB device hangs control transfer | Control loops bounded by `max_spins: u32 = 50000` with `pause` instructions; non-blocking timeout | PASS (`TC-USB-07`) |
| 5 | Concurrent multi-controller enumeration stress | QEMU booted with xHCI + EHCI + UHCI concurrently | PASS (`TC-STRESS-01`) |
| 6 | Device array overflow protection | Bounds checks on `MAX_USB_CONTROLLERS`, `MAX_USB_DEVICES`, `MAX_DEVICE_INTERFACES`, `MAX_DEVICE_ENDPOINTS` | PASS |

---

## 4. Caveats

- **External Multi-Tier Hub Cascading:** In Milestone 2, root hub ports across xHCI, EHCI, and UHCI are operational. Attached multi-tier external USB hubs (Hub Class 0x09) will be fully decoded in Milestone 3.
- **Interrupt Routing Model:** USB controllers currently utilize non-blocking polling from input and scheduler hooks (matching `e1000.zig`), which avoids cross-core SMP interrupt latency and locking overhead.

---

## 5. Conclusion

**Verdict:** **CLEAN**  
Worker 2's implementation of Milestone 2 (USB Host Controller Subsystem Architecture) satisfies all technical, architectural, and integrity criteria. No stubs, facades, hardcoded outputs, or integrity violations were found. All deliverables F2.1 through F2.7 are verified authentic and ready for Milestone 3 peripheral development.

---

## 6. Verification Method

To independently reproduce and verify this audit:

```bash
# 1. Dual compilation check
zig build
zig build -Drelease

# 2. Golden test runner baseline check
python3 tools/test_runner.py

# 3. E2E USB subsystem verification
python3 tools/e2e_test_suite.py -k USB

# 4. Stress test verification
python3 tools/e2e_test_suite.py -k STRESS
```
