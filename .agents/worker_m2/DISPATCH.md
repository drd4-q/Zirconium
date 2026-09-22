# Dispatch Task: Milestone 2 — USB Host Controller Subsystem Architecture (xHCI, EHCI, UHCI)

**Assigned To**: Worker 2 (`worker_m2`)  
**Role**: USB Host Controller Subsystem Engineer  
**Date**: 2026-09-20  
**Project Root**: `/home/dr4d/Zirconium`  
**Working Directory**: `/home/dr4d/Zirconium/.agents/worker_m2`  

---

## 1. Mandatory Reading Before Any Implementation
1. `/home/dr4d/Zirconium/.agents/ORIGINAL_REQUEST.md` (authoritative user requirements)
2. `/home/dr4d/Zirconium/.agents/PROJECT.md` (master architecture, milestone boundaries, code layout)
3. `/home/dr4d/Zirconium/AGENTS.md` (toolchain rules, test markers, non-preemption, coding constraints)
4. `/home/dr4d/Zirconium/.agents/explorer_survey_2/survey_report.md` & `handoff.md` (detailed xHCI, EHCI, UHCI hardware specs, register maps, DMA alignment, ring buffers, transfer scheduling)

---

## 2. Mandatory Integrity Warning
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A `teamwork_preview_auditor` will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

---

## 3. Scope & Exclusive Write Ownership
You have exclusive write ownership of:
- `src/drivers/usb.zig` (top-level coordinator and backwards-compatible export interface)
- `src/drivers/usb/types.zig` (standard USB descriptors, setup packet, speeds, endpoints, classes)
- `src/drivers/usb/dma.zig` (PMM-backed physically contiguous DMA buffer allocator)
- `src/drivers/usb/pci_detect.zig` (multi-controller PCI scanner, class 0x0C, subclass 0x03, prog-if 0x00/0x20/0x30, BAR configuration)
- `src/drivers/usb/xhci.zig` (xHCI host controller driver: capability/operational/runtime/doorbell MMIO, DCBAA, command ring, event ring, transfer rings, PORTSC)
- `src/drivers/usb/ehci.zig` (EHCI host controller driver: capability/operational MMIO, async/periodic lists, QH/qTD, PORTSC, port reset)
- `src/drivers/usb/uhci.zig` (multi-controller instance-based UHCI driver, PMM frame list, QH/TD chain)
- `src/drivers/usb/device.zig` (USB device abstraction, standard control requests, enumeration pipeline)
- `src/drivers/usb/mod.zig` (unified USB host controller interface, transfer queue, async polling loop)

You may also update `src/drivers/pci.zig` if needed for BAR helpers, or register USB init in `src/drivers/usb.zig`.

---

## 4. Key Functional Requirements (F2.1 - F2.7)
1. **F2.1 xHCI Host Controller Driver**:
   - Capability MMIO: `CAPLENGTH`, `HCIVERSION`, `HCSPARAMS1`, `HCCPARAMS1`, `DBOFF`, `RTSOFF`.
   - Operational MMIO: `USBCMD`, `USBSTS`, `CRCR`, `DCBAAP`, `CONFIG`, `PORTSC`.
   - Runtime MMIO: Event Ring Segment Table (`ERST`), Event Ring Dequeue Pointer (`ERDP`).
   - Doorbell registers for Command Ring and Device Slots.
   - Command Ring and Event Ring initialization using PMM DMA pages.
   - Port Status & Control (`PORTSC`): Reset sequencing, link status, speed detection.
   - Device context base address array (DCBAA) and slot context setup.
2. **F2.2 EHCI Host Controller Driver**:
   - Capability MMIO: `CAPLENGTH`, `HCSPARAMS`, `HCCPARAMS`.
   - Operational MMIO: `USBCMD`, `USBSTS`, `ASYNCLISTADDR`, `PERIODICLISTBASE`, `PORTSC`.
   - BIOS handoff (USBLEGSUP in EECP).
   - Controller reset (`USBCMD.HCRST`) and halt check.
   - Asynchronous list (Queue Heads and qTDs) and periodic schedule.
   - Root hub port reset sequencing and speed detection.
3. **F2.3 & F2.6 UHCI Multi-Controller Driver**:
   - Refactor UHCI from static global singleton arrays to per-instance state supporting multiple controllers concurrently.
   - Allocate 1024-entry Frame List via PMM DMA memory (4KB aligned).
   - Queue Head (QH) and Transfer Descriptor (TD) structures.
   - Root hub port reset and status checking via I/O base ports (`PORTSC1`, `PORTSC2`).
4. **F2.4 Unified USB Subsystem Architecture**:
   - Unified `UsbController` interface with virtual method table (`vtable`) or clean polymorphism.
   - Standard device enumeration pipeline:
     - Detect port connection -> Port Reset -> Speed Detection.
     - Get Device Descriptor (first 8 bytes) -> Set Address -> Get Full Device Descriptor.
     - Get Configuration Descriptor & Interface / Endpoint Descriptors -> Set Configuration.
5. **F2.5 DMA Memory Allocation**:
   - Use `pmm.allocPages()` for physically contiguous, page-aligned DMA buffers (DCBAA, Rings, Frame Lists, QHs, TDs).
   - Maintain physical-to-virtual address mapping (in Zirconium's 64GB identity map, `phys == virt`).
6. **F2.7 Async USB Scheduling**:
   - Replace blocking spin-waits (`delayMs(10)` loops up to 500ms) with non-blocking transfer state tracking.
   - Advance transfers on periodic `usb.poll()` calls from scheduler/timer tick without stalling CPU execution.
7. **Backwards Compatibility**:
   - Preserve all public functions and types in `src/drivers/usb.zig` (`init()`, `poll()`, `scan()`, `getControllers()`, `getControllerCount()`, `getDevices()`, `getDeviceCount()`, `UsbController`, `UsbDevice`, etc.) so `src/shell.zig`, `src/programs/usb.zig`, `src/drivers/keyboard.zig`, `src/drivers/mouse.zig`, and `src/system/tty.zig` compile cleanly without modification.

---

## 5. Verification & Acceptance Criteria
1. `zig build` compiles with 0 errors and 0 warnings.
2. `zig build -Drelease` compiles with 0 errors and 0 warnings.
3. `python3 tools/test_runner.py` passes all 10 golden markers (100% SUCCESS).
4. `python3 tools/e2e_test_suite.py --tier 1` passes 100%.
5. Write handoff report to `/home/dr4d/Zirconium/.agents/worker_m2/handoff.md` and notify parent via `send_message`.

---

## 2026-09-20T11:27:21Z

You are Worker 2 (`worker_m2`) for Milestone 2 of the Zirconium project.
Your working directory is `/home/dr4d/Zirconium/.agents/worker_m2`.
The project root is `/home/dr4d/Zirconium`.

CRITICAL INSTRUCTIONS:
1. Your `DISPATCH.md` is pre-populated at `/home/dr4d/Zirconium/.agents/worker_m2/DISPATCH.md`. Read it and `/home/dr4d/Zirconium/.agents/ORIGINAL_REQUEST.md` before starting work.
2. Read `/home/dr4d/Zirconium/.agents/PROJECT.md`, `/home/dr4d/Zirconium/AGENTS.md`, and the survey findings in `/home/dr4d/Zirconium/.agents/explorer_survey_2/survey_report.md` and `handoff.md`.

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

EXCLUSIVE WRITE OWNERSHIP:
You have exclusive write ownership of:
- `src/drivers/usb.zig` (top-level coordinator and backwards-compatible export interface)
- `src/drivers/usb/types.zig`
- `src/drivers/usb/dma.zig`
- `src/drivers/usb/pci_detect.zig`
- `src/drivers/usb/xhci.zig`
- `src/drivers/usb/ehci.zig`
- `src/drivers/usb/uhci.zig`
- `src/drivers/usb/device.zig`
- `src/drivers/usb/mod.zig`

Implement all Milestone 2 deliverables (F2.1 - F2.7):
1. xHCI Host Controller Driver (USB 3.x, MMIO capability/operational/runtime/doorbell registers, command/event rings, DCBAA, PORTSC, port reset).
2. EHCI Host Controller Driver (USB 2.0, MMIO capability/operational registers, async/periodic schedule, QH/qTD, PORTSC, port reset).
3. UHCI Multi-Controller Driver (USB 1.1, instance-based state supporting multiple controllers without static globals, PMM frame list, QH/TD chain).
4. Unified USB Host Controller interface and standard device enumeration pipeline (port detect -> reset -> get descriptor -> set address -> set config).
5. DMA memory management using PMM for physically contiguous, page-aligned buffers.
6. Async USB transfer scheduling (non-blocking transfer tracking in `usb.poll()` instead of 500ms blocking spin-waits).
7. Top-level backward compatibility in `src/drivers/usb.zig` so existing code (`shell.zig`, `programs/usb.zig`, `keyboard.zig`, `mouse.zig`, `tty.zig`) compiles without errors.

VERIFICATION:
Run `zig build`, `zig build -Drelease`, and `python3 tools/test_runner.py` (all 10 markers must pass).
Write your handoff report to `/home/dr4d/Zirconium/.agents/worker_m2/handoff.md` and send a message to caller via `send_message`.
