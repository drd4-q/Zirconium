# Handoff Report — Milestone 2: USB Host Controller Subsystem Architecture

**Agent:** worker_m2  
**Date:** 2026-09-20  
**Status:** Hard Handoff (Milestone 2 Complete)  
**Deliverables:** F2.1 to F2.7  

---

## 1. Observation

1. **Previous Subsystem Limitations:**
   - `src/drivers/usb.zig` previously had stubs for EHCI and xHCI (lines 751–765) that merely printed mock connected port strings without configuring MMIO registers, command rings, or schedules.
   - The UHCI driver relied on static global arrays (`frame_list`, `ctrl_qh`, `ctrl_tds`, `ctrl_setup_pkt`, `ctrl_buf`) at lines 152–160, preventing support for multiple UHCI controllers.
   - Control transfers in `uhciControlTransfer` utilized blocking spin-waits with `delayMs(10)` loops (up to 500ms), stalling the CPU with `hlt` when waiting on unattached or slow devices.
   - `UsbDevice` lacked support for multi-interface composite devices, overwriting `iface_num` and `ep_in` when parsing multiple interface descriptors.

2. **Implemented Subsystem Components:**
   - `src/drivers/usb/types.zig`: Standard USB descriptors (`UsbDeviceDescriptor`, `UsbConfigDescriptor`, `UsbInterfaceDescriptor`, `UsbEndpointDescriptor`, `UsbHidDescriptor`), setup packet (`UsbSetupPacket`), speeds (`UsbSpeed`), transfer types (`UsbTransferType`), statuses (`UsbTransferStatus`), device classes (`UsbDeviceClass`), device types (`UsbDeviceType`), port status (`UsbPortStatus`), and endpoint/interface data models (`UsbEndpoint`, `UsbInterface`).
   - `src/drivers/usb/dma.zig`: PMM-backed aligned DMA buffer allocator (`UsbDmaPool`), `allocPage()`, `allocPages()`, `freePage()`, `freePages()`, physical-to-virtual address helpers.
   - `src/drivers/usb/pci_detect.zig`: Multi-controller PCI detection for class `0x0C`, subclass `0x03`, prog-if `0x00` (UHCI), `0x20` (EHCI), `0x30` (xHCI), BAR mapping (including 64-bit BAR for xHCI), and bus master activation.
   - `src/drivers/usb/uhci.zig`: Multi-controller instance-based UHCI driver (`UhciController`) with per-instance 1024-entry Frame List allocated via PMM DMA, per-controller control queue heads and transfer descriptors, port status/reset via I/O base ports, and non-blocking transfer scheduling.
   - `src/drivers/usb/ehci.zig`: Full EHCI host controller driver (`EhciController`) with Capability MMIO (`CAPLENGTH`, `HCIVERSION`, `HCSPARAMS`, `HCCPARAMS`), Operational MMIO (`USBCMD`, `USBSTS`, `PERIODICLISTBASE`, `ASYNCLISTADDR`, `CONFIGFLAG`, `PORTSC`), BIOS handoff (`USBLEGSUP`), 1024-entry Periodic Frame List, circular Asynchronous Queue Head list, and companion routing.
   - `src/drivers/usb/xhci.zig`: Full xHCI host controller driver (`XhciController`) with Capability MMIO (`CAPLENGTH`, `HCIVERSION`, `HCSPARAMS1`, `HCSPARAMS2`, `HCCPARAMS1`, `DBOFF`, `RTSOFF`), Operational MMIO (`USBCMD`, `USBSTS`, `CRCR`, `DCBAAP`, `CONFIG`, `PORTSC`), Runtime MMIO (Interrupter 0, `ERSTSZ`, `ERSTBA`, `ERDP`, `IMAN`), Doorbell array, DCBAA allocation, Command Ring, Event Ring with ERST, and port reset sequencing.
   - `src/drivers/usb/device.zig`: Unified device representation supporting composite devices (`MAX_DEVICE_INTERFACES = 4`), standard enumeration pipeline (`GET_DESCRIPTOR` 8 bytes -> `SET_ADDRESS` -> `GET_DESCRIPTOR` 18 bytes -> `GET_DESCRIPTOR` Configuration -> parse interfaces and endpoints -> `SET_CONFIGURATION` -> configure HID Boot Protocol & Idle).
   - `src/drivers/usb/mod.zig`: Top-level coordinator managing controller instances, device registration, and non-blocking `poll()` hook processing keyboard keystrokes and mouse movement.
   - `src/drivers/usb.zig`: Top-level backwards-compatible interface re-exporting all standard types, global variables (`controllers`, `controller_count`, `usb_devices`, `usb_device_count`), and functions (`init`, `poll`, `scan`, `getControllers`, `getControllerCount`, `getDevices`, `getDeviceCount`, `printUsbStatus`, `usbKeyToAscii`).
   - `src/drivers/pci.zig`: Exported `readConfig` and `writeConfig` as `pub fn` to permit PCI extended capability traversal.

3. **Compilation and Test Execution Results:**
   - `zig build`: Exited 0 with 0 errors and 0 warnings.
   - `zig build -Drelease`: Exited 0 with 0 errors and 0 warnings.
   - `python3 tools/test_runner.py`: Exited 0, all 10 golden markers verified (100% SUCCESS):
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
   - E2E Test Suite Validation:
     - `TC-BUILD-01`: PASSED (Clean dual compilation)
     - `TC-BOOT-01`: PASSED (14 core boot markers verified)
     - `TC-SMP-01`: PASSED (4 CPUs online via ACPI and APIC INIT-SIPI-SIPI)
     - `TC-RING3-01`: PASSED (Ring 3 user execution & socket connect OK)
     - `TC-REGR-01`: PASSED (100% of baseline golden markers verified)
     - `TC-USB-01`: PASSED (USB subsystem core & vtable verified)
     - `TC-USB-02`: PASSED (PMM-backed DMA allocation & alignment verified)
     - `TC-USB-03`: PASSED (PCI scanner discovered xHCI, EHCI, and UHCI concurrently)
     - `TC-USB-04`: PASSED (xHCI controller detected with 64-bit MMIO BAR and operational state)
     - `TC-USB-05`: PASSED (EHCI controller detected with 32-bit MMIO BAR and root port management)
     - `TC-USB-06`: PASSED (UHCI controller initialized with 1024-entry frame list and port I/O base)
     - `TC-USB-07`: PASSED (USB transfers scheduled without kernel stalling)

---

## 2. Logic Chain

1. **Hardware Controller Coverage (F2.1, F2.3, F2.4, F2.5, F2.6):**
   - By creating dedicated driver structures (`XhciController` in `xhci.zig`, `EhciController` in `ehci.zig`, `UhciController` in `uhci.zig`), hardware registers and scheduling rings are managed independently according to their respective specifications (MMIO for xHCI/EHCI, Port I/O for UHCI).
   - In QEMU tests with `-device qemu-xhci -device ich9-usb-ehci1 -device ich9-usb-uhci1`, `pci_detect.scanPciControllers()` correctly detected and initialized all three controllers concurrently without conflicts.

2. **DMA Contiguity and Memory Safety (F2.2):**
   - UHCI requires a 4KB-aligned 1024-entry Frame List and 16-byte aligned QHs/TDs. EHCI requires a 4KB-aligned Periodic Frame List and 32-byte aligned QHs/qTDs. xHCI requires 64-byte aligned DCBAA, rings, and contexts.
   - `UsbDmaPool` and `dma.allocPage()` use `root.pmm.allocPage()` to guarantee physical contiguous memory and alignment. Because Zirconium's page tables identity-map 0..64GB, physical addresses match virtual pointer values directly.

3. **Composite Peripheral Support (F3.1 Foundation in F2.4):**
   - Refactoring `UsbDevice` to hold an array of `UsbInterface` objects (each with up to 4 `UsbEndpoint` records) allows composite devices (e.g. keyboard + mouse on a single dongle) to retain distinct endpoint addresses and transfer buffers.
   - In QEMU UHCI testing with `-device usb-kbd -device usb-mouse`, both devices were successfully enumerated and assigned addresses without overwriting interface records.

4. **Non-Blocking Transfer Scheduling (F2.7):**
   - Replacing blocking `delayMs(10)` spin loops with status register checks (`TD_CTRL_ACTIVE`, `QTD_ACTIVE`, and Event Ring cycle bits) and polling in `usb.poll()` guarantees that disconnected ports or slow endpoints do not freeze the CPU or delay the boot pipeline.

5. **Backwards Compatibility:**
   - `src/drivers/usb.zig` re-exports all legacy types, variables (`controllers`, `controller_count`, `usb_devices`, `usb_device_count`), and functions (`init`, `poll`, `scan`, `printUsbStatus`, `usbKeyToAscii`), ensuring existing callers in `shell.zig`, `programs/usb.zig`, `keyboard.zig`, `mouse.zig`, and `tty.zig` compile and execute without modifications.

---

## 3. Caveats

1. **External USB Hub Cascading:**
   - Root ports across xHCI, EHCI, and UHCI controllers are fully initialized and managed. Multi-tier external hubs attached to root ports require Hub Class descriptor decoding, which will be handled in subsequent peripheral milestones.
2. **Interrupt Polling vs MSI/MSI-X:**
   - USB controllers are driven via non-blocking polling from input/scheduler tick hooks (matching `e1000.zig`), avoiding IRQ routing complexity and race conditions across SMP cores.

---

## 4. Conclusion

Milestone 2 is completely implemented and verified. All deliverables (F2.1 through F2.7) are operational with genuine hardware register interaction, DMA memory management, multi-controller instance tracking, composite device descriptor parsing, non-blocking transfer scheduling, and 100% backwards compatibility with the existing Zirconium codebase.

---

## 5. Verification Method

1. **Clean Dual Compilation:**
   ```bash
   zig build
   zig build -Drelease
   ```
   *Expected:* Both build commands exit with code 0 and zero warnings.

2. **Automated Kernel Integration Test Runner:**
   ```bash
   python3 tools/test_runner.py
   ```
   *Expected:* All 10 golden integration markers pass (100% SUCCESS).

3. **E2E Test Suite Validation:**
   ```bash
   python3 -c "
   import sys; sys.path.insert(0, 'tools')
   import e2e_test_suite as e2e
   ctx = e2e.TestContext()
   tests = [
       ('TC-BUILD-01', e2e.test_build_clean),
       ('TC-BOOT-01', e2e.test_boot_subsystems),
       ('TC-SMP-01', e2e.test_smp_bringup),
       ('TC-RING3-01', e2e.test_ring3_heap_socket),
       ('TC-REGR-01', e2e.test_baseline_regression),
       ('TC-USB-01', e2e.test_usb_subsystem_core),
       ('TC-USB-02', e2e.test_usb_dma_pool),
       ('TC-USB-03', e2e.test_usb_pci_discovery),
       ('TC-USB-04', e2e.test_usb_xhci_driver),
       ('TC-USB-05', e2e.test_usb_ehci_driver),
       ('TC-USB-06', e2e.test_usb_uhci_driver),
       ('TC-USB-07', e2e.test_usb_async_scheduling),
   ]
   for tid, fn in tests:
       st, msg, _ = fn(ctx)
       print(f'{tid}: {st} - {msg}')
   "
   ```
   *Expected:* All tests report `PASSED`.
