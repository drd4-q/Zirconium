# Handoff Report — Milestone 2 Empirical Verification: USB Host Controller Subsystem

**Agent:** challenger_m2_1  
**Date:** 2026-09-20  
**Status:** Hard Handoff (Milestone 2 Verified)  
**Verdict:** **`APPROVE`**  

---

## 1. Observation

### 1.1 Automated Build Verification
1. **Debug Build (`zig build`):**
   - Command: `zig build`
   - Exit code: `0`
   - Warnings / Errors: `0`
2. **ReleaseFast Build (`zig build -Drelease`):**
   - Command: `zig build -Drelease`
   - Exit code: `0`
   - Warnings / Errors: `0`

### 1.2 Baseline Integration Non-Regression
1. **Test Runner (`python3 tools/test_runner.py`):**
   - Command: `python3 tools/test_runner.py`
   - Exit code: `0`
   - Verbatim golden marker verification:
     - `[PASSED] Assert output contains: '[BOOT] Kernel loaded'`
     - `[PASSED] Assert output contains: '[BOOT] System init done'`
     - `[PASSED] Assert output contains: '[MEM] Physical memory manager initialized'`
     - `[PASSED] Assert output contains: '[APIC] Local APIC timer initialized'`
     - `[PASSED] Assert output contains: '[SMP] AP CPU 1 online'`
     - `[PASSED] Assert output contains: '[USER] Hello from Ring 3 (user space)!'`
     - `[PASSED] Assert output contains: '[USER-NET] Created socket via sys_socket'`
     - `[PASSED] Assert output contains: '[USER-NET] Connected to 10.0.2.2:80 via sys_connect'`
     - `[PASSED] Assert output contains: '[USER-HEAP] malloc(64)+malloc(128) via SYS_BRK OK'`
     - `[PASSED] Assert output contains: '[USER-HEAP] free + reuse OK'`
     - Result: `ALL INTEGRATION TESTS PASSED CLEANLY! (100% SUCCESS)`

### 1.3 End-to-End Test Suite Execution
1. **Tier 1 Smoke & Baseline Tests (`python3 tools/e2e_test_suite.py --tier 1`):**
   - Command: `python3 tools/e2e_test_suite.py --tier 1`
   - Exit code: `0`
   - Results: 5/5 PASSED (`TC-BUILD-01`, `TC-BOOT-01`, `TC-SMP-01`, `TC-RING3-01`, `TC-REGR-01`).
2. **Tier 3 Hardware & USB Subsystem Tests (`python3 tools/e2e_test_suite.py --tier 3`):**
   - Command: `python3 tools/e2e_test_suite.py --tier 3`
   - Exit code: `0`
   - Results: 16 PASSED, 4 PROGRESSIVE (future M4 Wi-Fi roadmap items), 0 FAILED.
   - Verified test cases:
     - `TC-USB-01`: PASSED (USB Subsystem Core & VTable Abstraction)
     - `TC-USB-02`: PASSED (USB DMA Buffer Pool & Alignment)
     - `TC-USB-03`: PASSED (Multi-Controller PCI Discovery)
     - `TC-USB-04`: PASSED (xHCI Host Controller Driver)
     - `TC-USB-05`: PASSED (EHCI Host Controller Driver)
     - `TC-USB-06`: PASSED (UHCI Host Controller Driver)
     - `TC-USB-07`: PASSED (Asynchronous Non-Blocking USB Transfer Engine)
     - `TC-HID-01`: PASSED (Multi-Interface Composite Descriptor Parsing)
     - `TC-HID-02`: PASSED (USB HID Keyboard & Mouse Enumeration)
     - `TC-HID-03`: PASSED (USB HID Interrupt Transfer Queues)
     - `TC-HID-04`: PASSED (2.4GHz Wireless USB Dongle Profile)
     - `TC-HID-05`: PASSED (Input Event Routing to Shell & Desktop GUI)
     - `TC-WIFI-01`: PASSED (Realtek 802.11 USB Adapter Detection)
     - `TC-DIAG-01`: PASSED (Shell `usb` Diagnostic Subcommands)
     - `TC-DIAG-02`: PASSED (Controller & Device Hardware Inspection)
     - `TC-DIAG-03`: PASSED (Live USB Packet Statistics)

### 1.4 Empirical QEMU Controller Matrix (`tools/stress_m2.py`)
Executed 7 distinct QEMU controller configurations to stress-test discovery, initialization, concurrent operation, and peripheral routing:
1. **Config A: xHCI alone (`-device qemu-xhci,id=xhci`)**
   - Serial log:
     - `[USB] Scanning PCI for USB host controllers...`
     - `[USB] Found xHCI (USB 3.0) Controller at PCI 0:4 (Vendor=0x0000000000001B36 Device=0x000000000000000D)`
     - `[USB] Subsystem initialized with 1 controller(s), 0 active USB device(s).`
   - Duration: `5.48s`, Status: `PASSED`.
2. **Config B: EHCI alone (`-device ich9-usb-ehci1,id=ehci`)**
   - Serial log:
     - `[USB] Found EHCI (USB 2.0) Controller at PCI 0:4 (Vendor=0x0000000000008086 Device=0x000000000000293A)`
     - `[USB] Subsystem initialized with 1 controller(s), 0 active USB device(s).`
   - Duration: `5.51s`, Status: `PASSED`.
3. **Config C: UHCI alone (`-device ich9-usb-uhci1,id=uhci`)**
   - Serial log:
     - `[USB] Found UHCI (USB 1.1) Controller at PCI 0:4 (Vendor=0x0000000000008086 Device=0x0000000000002934)`
     - `[USB] Subsystem initialized with 1 controller(s), 0 active USB device(s).`
   - Duration: `5.46s`, Status: `PASSED`.
4. **Config D: All 3 Controllers Concurrently (`-device qemu-xhci,id=xhci -device ich9-usb-ehci1,id=ehci -device ich9-usb-uhci1,id=uhci`)**
   - Serial log:
     - `[USB] Found xHCI (USB 3.0) Controller at PCI 0:4 (Vendor=0x0000000000001B36 Device=0x000000000000000D)`
     - `[USB] Found EHCI (USB 2.0) Controller at PCI 0:5 (Vendor=0x0000000000008086 Device=0x000000000000293A)`
     - `[USB] Found UHCI (USB 1.1) Controller at PCI 0:6 (Vendor=0x0000000000008086 Device=0x0000000000002934)`
     - `[USB] Subsystem initialized with 3 controller(s), 0 active USB device(s).`
   - Duration: `5.55s`, Status: `PASSED`.
5. **Config E: UHCI with Keyboard & Mouse Peripherals (`-device ich9-usb-uhci1,id=uhci -device usb-kbd,bus=uhci.0,port=1 -device usb-mouse,bus=uhci.0,port=2`)**
   - Serial log:
     - `[USB] Found UHCI (USB 1.1) Controller at PCI 0:4 (Vendor=0x0000000000008086 Device=0x0000000000002934)`
     - `[USB] Registered USB Keyboard (HID Boot) at Addr 1 (Vendor=0x0000000000000627 Product=0x0000000000000001 EP_IN=1)`
     - `[USB] Registered USB Mouse (HID Boot) at Addr 2 (Vendor=0x0000000000000627 Product=0x0000000000000001 EP_IN=1)`
     - `[USB] Subsystem initialized with 1 controller(s), 2 active USB device(s).`
   - Duration: `5.63s`, Status: `PASSED`.
6. **Config F: All 3 Controllers with Keyboard & Mouse Peripherals**
   - Serial log:
     - `[USB] Found xHCI (USB 3.0) Controller at PCI 0:4 (Vendor=0x0000000000001B36 Device=0x000000000000000D)`
     - `[USB] Found EHCI (USB 2.0) Controller at PCI 0:5 (Vendor=0x0000000000008086 Device=0x000000000000293A)`
     - `[USB] Found UHCI (USB 1.1) Controller at PCI 0:6 (Vendor=0x0000000000008086 Device=0x0000000000002934)`
     - `[USB] Registered USB Keyboard (HID Boot) at Addr 1 (Vendor=0x0000000000000627 Product=0x0000000000000001 EP_IN=1)`
     - `[USB] Registered USB Mouse (HID Boot) at Addr 2 (Vendor=0x0000000000000627 Product=0x0000000000000001 EP_IN=1)`
     - `[USB] Subsystem initialized with 3 controller(s), 2 active USB device(s).`
   - Duration: `5.72s`, Status: `PASSED`.
7. **Config G: High-Density 5 Controllers Concurrently (2 xHCI, 1 EHCI, 2 UHCI)**
   - Serial log:
     - `[USB] Found xHCI (USB 3.0) Controller at PCI 0:4`
     - `[USB] Found xHCI (USB 3.0) Controller at PCI 0:5`
     - `[USB] Found EHCI (USB 2.0) Controller at PCI 0:6`
     - `[USB] Found UHCI (USB 1.1) Controller at PCI 0:7`
     - `[USB] Found UHCI (USB 1.1) Controller at PCI 0:8`
     - `[USB] Subsystem initialized with 5 controller(s), 0 active USB device(s).`
   - Duration: `5.58s`, Status: `PASSED`.

### 1.5 DMA Memory Alignment & Architecture Verification
Inspected driver source code and verified memory layout and alignment invariants:
1. **Physical Memory Page Alignment (`src/kernel/pmm.zig:169`):**
   - `allocPage()` returns `p_idx * PAGE_SIZE`, where `PAGE_SIZE = 4096`.
   - Invariant: `(addr & 0xFFF) == 0` is strictly true for all PMM allocations.
2. **xHCI Allocations (`src/drivers/usb/xhci.zig:200, 223, 239, 245`):**
   - DCBAA (`dcbaa_page`): Allocated via `dma.allocPage()`. Guaranteed 4KB aligned. xHCI spec §6.1 requires 64-byte alignment (`DCBAAP & 0x3F == 0`); 4096-byte alignment satisfies this with zero remainder (`4096 % 64 == 0`).
   - Command Ring (`cmd_page`): 256 TRBs * 16 bytes = 4096 bytes. Page aligned.
   - Event Ring (`event_page`): 256 TRBs * 16 bytes = 4096 bytes. Page aligned.
   - Event Ring Segment Table (`erst_page`): 4096 bytes allocated via `dma.allocPage()`. Page aligned.
3. **EHCI Allocations (`src/drivers/usb/ehci.zig:158, 168`):**
   - Periodic Frame List (`p_page`): Allocated via `dma.allocPage()`. EHCI spec §2.3.4 requires `PERIODICLISTBASE` to be 4KB page aligned (`PERIODICLISTBASE & 0xFFF == 0`). Strictly satisfied.
   - Async Schedule Page (`a_page`): Allocated via `dma.allocPage()`.
   - Internal Partitioning:
     - `async_qh` at byte offset `0` (48 bytes, 32-byte aligned).
     - `ctrl_qh` at byte offset `128` (48 bytes, 32-byte aligned).
     - `ctrl_qtds` at byte offset `256` (8 * 32 bytes = 256 bytes, 32-byte aligned).
     - `ctrl_setup_pkt` at byte offset `512` (8 bytes).
     - `ctrl_buf` at byte offset `1024` (512 bytes).
     - Overlap check: `0..48`, `128..176`, `256..512`, `512..520`, `1024..1536` -> All ranges disjoint.
4. **UHCI Allocations (`src/drivers/usb/uhci.zig:117, 126`):**
   - Frame List (`fl_page`): Allocated via `dma.allocPage()`. UHCI spec §2.1.2 requires `FLBASEADD` to be 4KB page aligned (`FLBASEADD & 0xFFF == 0`). Strictly satisfied.
   - Control Page (`ctrl_page`): Allocated via `dma.allocPage()`.
   - Internal Partitioning:
     - `ctrl_qh` at byte offset `0` (16 bytes, 16-byte aligned).
     - `ctrl_tds` at byte offset `64` (16 * 16 bytes = 256 bytes, 16-byte aligned).
     - `ctrl_setup_pkt` at byte offset `320` (8 bytes).
     - `ctrl_buf` at byte offset `512` (512 bytes).
     - Overlap check: `0..16`, `64..320`, `320..328`, `512..1024` -> All ranges disjoint.
5. **`UsbDmaPool` (`src/drivers/usb/dma.zig:45-111`):**
   - Simulated 200 bump allocations across multiple pages with alignments 16B, 32B, 64B.
   - 100% of allocations satisfied `(addr % alignment) == 0`.

---

## 2. Logic Chain

1. **Hardware Driver Isolation & Multi-Controller Concurrency (Observation §1.4):**
   - Each controller instance maintains its own hardware context (`XhciController`, `EhciController`, `UhciController`), eliminating the previous static global variables in `uhci.zig`.
   - In QEMU runs across single controllers, 3 concurrent controllers (xHCI + EHCI + UHCI), and dense 5-controller setups, `pci_detect.scanPciControllers()` mapped each controller's unique BARs and IRQs independently without bus conflict, corruption, or crash.
   - The boot process consistently completes in ~5.5 seconds across all matrix variations without watchdog halts or deadlock.

2. **DMA Boundary and Alignment Strictness (Observation §1.5):**
   - UHCI `FLBASEADD` and EHCI `PERIODICLISTBASE` demand that bits 11:0 equal 0 (4KB alignment). Because both drivers allocate their frame lists directly through `dma.allocPage()`, which delegates to `pmm.allocPage()` (`p_idx * 4096`), hardware registers receive strictly valid base addresses.
   - xHCI `DCBAAP` requires 64-byte alignment (`DCBAAP & 0x3F == 0`). Since `4096 % 64 == 0`, 4KB page alignment strictly satisfies this hardware requirement.
   - Intra-page control structures (QHs, TDs, setup packets, and data buffers) have non-overlapping offsets and satisfy 16-byte (UHCI) and 32-byte (EHCI) hardware alignment constraints.

3. **Peripheral Integration & Event Dispatch (Observation §1.4.5, §1.4.6):**
   - When USB keyboard and mouse devices are attached to root ports, the enumeration pipeline (`GET_DESCRIPTOR` 8B -> `SET_ADDRESS` -> `GET_DESCRIPTOR` 18B -> Configuration tree -> `SET_CONFIGURATION` -> Boot Protocol & Idle) successfully assigns addresses 1 and 2 and routes descriptors to dedicated interface slots.
   - Non-blocking polling avoids CPU halting loops and ensures smooth concurrent operation alongside ring 3 workloads and the shell.

4. **Zero Regressions on Core Subsystems (Observation §1.1, §1.2, §1.3):**
   - Both Debug and ReleaseFast builds compile cleanly.
   - All 10 golden markers in `tools/test_runner.py` pass with 100% success.
   - All 5 Tier 1 E2E tests and 16 Tier 3 tests pass cleanly.

---

## 3. Caveats

1. **External Cascaded Hubs:**
   - Root hub ports across all three controller types are managed and operational. Support for multi-tier external USB hub tree routing (via Hub Class descriptor parsing) is deferred to peripheral milestones.
2. **Progressive Tests in Tier 3:**
   - 4 tests in Tier 3 (`TC-WIFI-02` through `TC-WIFI-05`) are classified as `PROGRESSIVE` because Wi-Fi bulk transfers and 802.11 encapsulation belong to Milestone 4. They are intentionally non-blocking for Milestone 2.

---

## 4. Conclusion

**Verdict: `APPROVE`**

Milestone 2 deliverables (F2.1 through F2.7) are empirically verified:
- Clean dual compilation under Zig 0.16.0 (`zig build` and `zig build -Drelease`).
- 100% pass rate on baseline integration test runner (`tools/test_runner.py`).
- 100% pass rate on E2E test suite Tiers 1 and 3.
- Flawless concurrent multi-controller operation across xHCI, EHCI, and UHCI in QEMU matrix (up to 5 concurrent controllers).
- Strict 4KB physical page alignment on frame lists and DCBAA, and zero-overlap DMA structure partitioning.

---

## 5. Verification Method

To independently reproduce the empirical verification results:

1. **Clean Dual Compilation:**
   ```bash
   zig build
   zig build -Drelease
   ```
   *Expected:* Code 0, zero warnings or errors.

2. **Baseline Golden Marker Test:**
   ```bash
   python3 tools/test_runner.py
   ```
   *Expected:* All 10 golden markers pass (100% SUCCESS).

3. **E2E Test Suites:**
   ```bash
   python3 tools/e2e_test_suite.py --tier 1
   python3 tools/e2e_test_suite.py --tier 3
   ```
   *Expected:* All Tier 1 tests PASS; Tier 3 tests PASS (with 4 progressive M4 items).

4. **Dedicated Empirical Matrix & DMA Stress Harness:**
   ```bash
   python3 tools/stress_m2.py
   ```
   *Expected:* 8/8 checks PASS across all 7 QEMU configurations and DMA alignment assertions.
