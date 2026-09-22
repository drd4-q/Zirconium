# Progress — Milestone 2 USB Subsystem Architecture

Last visited: 2026-09-20T11:36:00Z

## Status Overview
- Current Phase: Completed
- Target: F2.1 to F2.7 (xHCI, EHCI, UHCI, Unified Subsystem, DMA Allocator, Async Scheduling, Backwards Compatibility)

## Completed Tasks
- [x] Read and analyzed DISPATCH.md, ORIGINAL_REQUEST.md, PROJECT.md, AGENTS.md, explorer survey report, and handoff report.
- [x] Verified baseline dual build (`zig build`, `zig build -Drelease`) and test runner (10/10 markers passing).
- [x] Initialized BRIEFING.md and progress.md.
- [x] Created `src/drivers/usb/types.zig` with standard USB definitions, descriptors, speeds, transfer types, setup packet.
- [x] Created `src/drivers/usb/dma.zig` with PMM-backed aligned DMA buffer pool (`UsbDmaPool`).
- [x] Created `src/drivers/usb/pci_detect.zig` for discovering UHCI, EHCI, xHCI PCI devices and configuring BARs / bus master.
- [x] Created `src/drivers/usb/uhci.zig` for multi-controller instance-based UHCI driver.
- [x] Created `src/drivers/usb/ehci.zig` for EHCI driver with async/periodic schedules, QH/qTDs, PORTSC management.
- [x] Created `src/drivers/usb/xhci.zig` for xHCI driver with rings, DCBAA, doorbells, PORTSC, port reset.
- [x] Created `src/drivers/usb/device.zig` for unified device management and standard enumeration pipeline.
- [x] Created `src/drivers/usb/mod.zig` for unified subsystem coordinator and non-blocking polling loop.
- [x] Updated `src/drivers/usb.zig` as the top-level backwards-compatible interface exporting all required types, variables, and functions.
- [x] Verified clean dual build (`zig build` & `zig build -Drelease`) with 0 errors and 0 warnings.
- [x] Verified `tools/test_runner.py` passes 100% (all 10 markers).
- [x] Verified all Milestone 1 & 2 tests (TC-BUILD-01, TC-BOOT-01, TC-SMP-01, TC-RING3-01, TC-REGR-01, TC-USB-01 to TC-USB-07) pass 100%.
- [x] Written handoff report to `handoff.md`.
