# Handoff Report — Milestone 2 Review & Adversarial Challenge

**Agent:** reviewer_m2_1 (Reviewer 1 & Adversarial Critic)  
**Date:** 2026-09-20  
**Target Milestone:** Milestone 2 (USB Host Controller Subsystem Architecture: xHCI, EHCI, UHCI, DMA, Async Scheduling)  
**Verdict:** `APPROVE`  

---

## 1. Observation

### 1.1 Direct Source Code Inspection
1. **xHCI Implementation (`src/drivers/usb/xhci.zig`):**
   - Capability MMIO registers correctly read: `cap_len = readMmio8(self.mmio_base + 0x00)` (lines 132–133), `HCSPARAMS1` (lines 135–137), `HCSPARAMS2` (lines 139–140), `HCCPARAMS1` (lines 142–144), `db_regs` (line 146), `rt_regs` (line 147).
   - BIOS Handoff (USBLEGSUP) implemented via extended capability pointer `xecp` (lines 150–169), requesting OS ownership (bit 16) and awaiting BIOS release (bit 24 == 0).
   - Controller halt and reset sequences verified: clears RS bit, awaits `HCHalted` (bit 0 of `USBSTS`), sets `HCRST`, and awaits clearance of `CNR` (Controller Not Ready, bit 11) (lines 171–193).
   - Max device slots configured in `CONFIG` register (lines 196–197).
   - DCBAA allocated with 4KB PMM alignment, initialized with scratchpad array base at `dcbaa[0]` if needed, and programmed into 64-bit `DCBAAP` register (lines 200–220).
   - Command Ring allocated with 256 `XhciTrb`s, terminating in a Link TRB with Toggle Cycle (TC=1) at index 255, and programmed into 64-bit `CRCR` register with `RCS = 1` (lines 222–236).
   - Event Ring with ERST table and primary interrupter initialized (`ERSTSZ = 1`, `ERSTBA`, `ERDP` with `EHB` bit 3, `IMAN = 2`) (lines 238–259).
   - Root Hub PORTSC: Port Power enabled (bit 9), preserving status change flags (`& ~0x00FE0000`), Port Reset assertion (bit 4) with `PRC` clearance (bit 21), and speed decoding (lines 261–268, 320–374).
   - Doorbell ringing at `db_regs + target_slot * 4` and command submission with cycle toggle tracking (lines 393–447).

2. **EHCI Implementation (`src/drivers/usb/ehci.zig`):**
   - Capability registers parsed: `cap_len` (lines 115–116), `HCSPARAMS` for `num_ports` and `num_companions` (lines 118–120), `HCCPARAMS` for `eecp` (lines 122–123).
   - BIOS Handoff through PCI extended capability `eecp` (lines 126–137), setting OS ownership (bit 24) and awaiting BIOS release (bit 16 == 0).
   - Controller halt (clearing RS, awaiting `HCHalted` bit 12) and reset (`HCRESET` bit 1) (lines 140–155).
   - 1024-entry Periodic Frame List (4KB aligned) allocated via `dma.allocPage()`, terminate bit 1 initialized, written to `PERIODICLISTBASE` (lines 157–165).
   - Circular Asynchronous Schedule: `async_qh` configured as Head of Reclamation (H=1, bit 15) linking to `ctrl_qh`, and `ctrl_qh` linking back to `async_qh` with `0x02` (QH type) (lines 167–198).
   - Port ownership routing: `CONFIGFLAG = 1` (line 201). Port power bit 12 enabled (lines 204–209). Low-speed and failed-full-speed detection gracefully routes ownership to companion controllers (Port Owner bit 13) (lines 250–263, 274–284).
   - Transfer scheduling with `EhciQh` and `EhciQtd` structures containing full 5-element buffer arrays for cross-page transfers, active bit polling, error code checking, and non-blocking timeout handling (lines 320–417).

3. **UHCI Implementation (`src/drivers/usb/uhci.zig`):**
   - Fully instance-encapsulated: `UhciController` contains per-instance `io_base`, `frame_list`, `ctrl_qh`, `ctrl_tds`, `ctrl_setup_pkt`, and `ctrl_buf` (lines 79–101). Zero static globals.
   - 1024-entry Frame List allocated from dedicated 4KB PMM page, each entry initialized to point to control QH with terminate/QH select bit 1 (lines 116–123, 150–156).
   - Control structures allocated on a separate 4KB PMM page with 16-byte alignment (lines 125–140).
   - Standard register sequence: `USBCMD` reset (0x0002), IRQs disabled for polling mode, `USBSTS` cleared, `FRNUM` cleared, `SOFMOD` programmed to 0x40 (1ms frame interval), and `USBCMD` set to 0x00C1 (Run=1, Configured=1, MaxPacket 64=1) (lines 142–159).
   - Port reset with 50ms pulse, port enable check, and low-speed status bit decoding (lines 183–246).
   - Control transfer engine with setup PID `0x2D`, data toggle handling (`0x69` IN / `0xE1` OUT), null status stage (`0x7FF` length token), and bounded non-blocking pause polling loop (lines 248–346).

4. **DMA Pool & Memory Management (`src/drivers/usb/dma.zig`):**
   - `allocPage()` and `allocPages()` directly invoke `root.pmm.allocPage()` / `allocPages()` and zero the allocated memory (lines 8–20).
   - In Zirconium's 0..64GB identity-mapped address space, physical addresses strictly equal virtual addresses, guaranteeing that pointers passed to MMIO registers and descriptor link pointers are valid hardware physical addresses (lines 30–41).
   - `UsbDmaPool` bump/slab allocator ensures strict power-of-two alignment within 4KB boundaries without cross-page boundary crossing (lines 45–111).
   - Explicit `deinit()` and page deallocation methods prevent kernel memory leaks (lines 54–64).

5. **Non-Blocking Polling & Backwards Compatibility (`src/drivers/usb/mod.zig` & `src/drivers/usb.zig`):**
   - `usb.poll()` in `src/drivers/usb/mod.zig:327` is strictly non-blocking: checks volatile TD active status bit (`uhci.TD_CTRL_ACTIVE`), immediately returns if pending, processes packet if complete, updates toggle bit, re-arms TD, and returns without calling `hlt` or spin-delaying.
   - Keyboard keystrokes routed to `keyboard.pushKey(ch)` and mouse events to `mouse.updateFromUsb(buttons, dx, dy)` (lines 366, 377).
   - Complete backwards compatibility: `src/drivers/usb.zig` re-exports all legacy types, variables (`controllers`, `controller_count`, `usb_devices`, `usb_device_count`), functions (`init`, `poll`, `scan`, `getControllers`, `getControllerCount`, `getDevices`, `getDeviceCount`, `printUsbStatus`, `usbKeyToAscii`), maintaining seamless operation for `shell.zig`, `programs/usb.zig`, `keyboard.zig`, and `mouse.zig`.

6. **Integrity Audit:**
   - No mock or hardcoded strings substituting for real hardware registers.
   - All register operations perform genuine I/O (`inw`, `outw`, `readMmio32`, `writeMmio32`, `readMmio64`, `writeMmio64`, `readConfig`, `writeConfig`).
   - PCI scanner dynamically discovers device classes 0x0C/0x03 and maps BARs.
   - Standard USB 8-byte setup packets and descriptor request trees are issued dynamically over the bus.

### 1.2 Independent Verification Results
1. **Clean Dual Compilation:**
   - `zig build`: Exit code 0 (0 errors, 0 warnings).
   - `zig build -Drelease`: Exit code 0 (0 errors, 0 warnings).
2. **Automated Kernel Integration Test Runner (`tools/test_runner.py`):**
   - Exit code 0, all 10 golden markers verified (100% SUCCESS):
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
3. **E2E Test Suite (`tools/e2e_test_suite.py`):**
   - Tier 1 (Core & Baseline): 5/5 tests passed (100%).
   - Tier 3 (Milestone 2 USB Subsystem): 7/7 tests passed:
     - `TC-USB-01` (USB Subsystem Core & VTable Abstraction): PASSED
     - `TC-USB-02` (USB DMA Buffer Pool & Alignment): PASSED
     - `TC-USB-03` (Multi-Controller PCI Discovery): PASSED
     - `TC-USB-04` (xHCI Host Controller Operation): PASSED
     - `TC-USB-05` (EHCI Host Controller Operation): PASSED
     - `TC-USB-06` (UHCI Host Controller Operation): PASSED
     - `TC-USB-07` (Asynchronous Non-Blocking USB Transfer Engine): PASSED
4. **Empirical Adversarial Stress Suite (`tools/stress_m2.py`):**
   - Challenge 1 (Unattached Ports & Timing Stress): PASSED (3 concurrent controllers with 0 devices boot in 5.67s, 4 UHCI controllers with 8 unattached ports boot in 5.64s, partial port population boots in 5.71s with zero CPU stalls).
   - Challenge 2 (Rapid Polling & Memory Leak Stress): PASSED (Static oracle confirmed zero allocations in `usb.poll()`, wrapping counter arithmetic `+%=`, volatile active guard; live 10s QEMU endurance test ran with zero panics; note: `stress_m2.py:run_qemu_test` uses blocking `readline()` requiring non-None `stop_pattern` or non-blocking I/O).
   - Challenge 3 (Multi-Device Attachment & Registry Safety): PASSED (Concurrent keyboard and mouse on UHCI enumerated with distinct addresses 1 and 2, address-scoped TD token encoding, Queue Head horizontal linking, and device registry bounds guard).


---

## 2. Logic Chain

1. **Hardware Register and Spec Compliance (F2.1, F2.3, F2.4, F2.5, F2.6):**
   - *Observation:* `pci_detect.scanPciControllers()` scans PCI configuration space for class `0x0C`, subclass `0x03` across prog-if values `0x00` (UHCI), `0x20` (EHCI), and `0x30` (xHCI). It activates PCI Bus Master capability and configures 64-bit MMIO BARs for xHCI and BAR4 I/O ports for UHCI.
   - *Logic:* Initializing each controller according to its architectural specification (MMIO for xHCI/EHCI, I/O ports for UHCI) allows multiple heterogeneous controllers to co-exist without address overlap or state collision. Real QEMU tests confirmed concurrent detection and bring-up of `qemu-xhci`, `ich9-usb-ehci1`, and `ich9-usb-uhci1`.

2. **DMA Contiguity and Memory Safety (F2.2):**
   - *Observation:* `dma.allocPage()` allocates 4096-byte aligned pages directly from the PMM.
   - *Logic:* Because Zirconium maps 0..64GB with 2MB identity-mapped pages, physical addresses are identical to virtual pointers. Allocating from PMM guarantees physical memory contiguity and alignment for UHCI 1024-entry frame lists (4KB), EHCI periodic lists (4KB), and xHCI DCBAA / Rings (64-byte aligned within 4KB pages).

3. **Multi-Controller Instance Safety (F2.6):**
   - *Observation:* In `uhci.zig`, `UhciController` encapsulates all controller registers, frame list pointers, and control queue heads.
   - *Logic:* By eliminating static global arrays from `uhci.zig`, the driver supports multiple concurrent UHCI instances (verified with up to 4 concurrent UHCI controllers in `tools/stress_m2.py`).

4. **Asynchronous Non-Blocking Transfer Scheduling (F2.7):**
   - *Observation:* Control transfers use bounded pause loops (max 50,000 pauses) rather than 500ms `hlt` delay loops. Polling in `mod.zig:327` inspects the hardware `ACTIVE` bit and immediately returns if not ready.
   - *Logic:* This completely eliminates boot stalls and CPU freezes when querying unattached ports or waiting for device responses. All 10 golden integration markers in `tools/test_runner.py` continue to pass with zero timing degradation.

5. **Subsystem Backwards Compatibility:**
   - *Observation:* `src/drivers/usb.zig` preserves all legacy interfaces, types, and global variables (`controllers`, `usb_devices`).
   - *Logic:* Existing callers in `shell.zig`, `programs/usb.zig`, `keyboard.zig`, and `mouse.zig` compile and operate without regressions.

---

## 3. Caveats

1. **Multi-Tier External USB Hub Cascading:**
   - Root ports on xHCI, EHCI, and UHCI controllers are fully initialized and managed. Enumeration of devices connected downstream through multi-tier external USB hubs (requiring Hub Class descriptor decoding and TT/Transaction Translator handling) is deferred to subsequent peripheral milestones (M3/M4).
2. **EHCI/xHCI Transfer Queuing for Peripherals:**
   - In Milestone 2, root port reset, link state management, and speed negotiation are implemented for xHCI and EHCI. Dynamic device enumeration and interrupt transfer queueing are currently hooked on UHCI root ports, while full device enumeration on xHCI/EHCI will be activated in Milestone 3 for HID and Milestone 4 for Wi-Fi adapters.
3. **Interrupt Routing (Polling Mode vs MSI/MSI-X):**
   - USB controllers are driven via non-blocking polling hooks from input and scheduler tick routines (identical to the architectural model of `e1000.zig`), avoiding IRQ sharing conflicts across SMP cores.

---

## 4. Conclusion

The Milestone 2 deliverables (F2.1 through F2.7) are robustly implemented, adhere to hardware specifications, and pass all functional, build, and adversarial stress criteria with zero regressions and zero integrity violations.

**Verdict:** `APPROVE`

---

## 5. Verification Method

To independently reproduce and verify this assessment:

1. **Dual Build Verification:**
   ```bash
   zig build
   zig build -Drelease
   ```
   *Expected:* Exit code 0 with zero warnings.

2. **Core Integration Test Suite:**
   ```bash
   python3 tools/test_runner.py
   ```
   *Expected:* All 10 golden test markers pass (100% SUCCESS).

3. **E2E Test Suite (Tier 1 & Tier 3):**
   ```bash
   python3 tools/e2e_test_suite.py --tier 1
   python3 tools/e2e_test_suite.py --tier 3
   ```
   *Expected:* All Tier 1 and Tier 3 Milestone 2 tests (`TC-USB-01` through `TC-USB-07`) report `PASSED`.

4. **Empirical Adversarial Stress Suite:**
   ```bash
   python3 tools/stress_m2.py
   ```
   *Expected:* All 3 adversarial challenge categories report `PASSED` (Exit code 0).
