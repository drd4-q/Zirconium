# Orchestrator Plan — Zirconium Core Overhaul & USB Subsystem

## Phase 0: Survey & Full Scope Mapping
- [ ] Dispatch 3 parallel Explorers:
  - Explorer 1: Core Subsystems Audit (PMM, VMM, kalloc, SMP scheduler, interrupts, VFS/FAT16, TCP/IP, syscalls)
  - Explorer 2: USB Host Controllers (xHCI, EHCI, UHCI architecture, PCI discovery, port management, transfers)
  - Explorer 3: USB 2.4GHz Wireless Peripherals (HID dongles, RTL8188EU/RTL8192CU Wi-Fi, shell diagnostics, testing infra)
- [ ] Synthesize findings into `PROJECT.md` (Feature Inventory, Architecture, Milestones, Interface Contracts, Code Layout).
- [ ] Spawn E2E Testing Track Orchestrator / test writers to build test infrastructure in parallel.

## Phase 1: Milestone Execution (Implementation Track)
- Milestone 1: Core Subsystems Audit & Stability Fixes
  - PMM/VMM/kalloc leak & fault hardening, SMP lockup prevention, interrupt safety, VFS/FAT16 path & sector edge cases, TCP/IP correctness & socket bounds, syscall robustness.
- Milestone 2: USB Host Controller Subsystem Architecture (xHCI, EHCI, UHCI)
  - Controller PCI discovery & MMIO/IO initialization, port status management, reset & speed negotiation, transfer descriptor rings, async polling/scheduler.
- Milestone 3: USB 2.4GHz Wireless HID Peripherals & Input Event Routing
  - Single and composite multi-interface dongles (Logitech Unifying & generic), interrupt transfers, boot & report protocol parsing, keystroke & mouse routing into VGA text shell and GUI.
- Milestone 4: USB 2.4GHz Wireless Network Adapter Driver & Net Stack Integration
  - RTL8188EU / RTL8192CU USB Wi-Fi device initialization, register/EEPROM setup, TX/RX bulk/interrupt transfers, frame encapsulation/decapsulation, integration with `net/mod.zig`.
- Milestone 5: USB Diagnostics & `usb` Shell Command Overhaul
  - Interactive shell command displaying controllers, root ports, attached wireless devices, endpoint descriptors, and live packet/transfer statistics.
- Milestone 6: Final Integration, E2E Test Suite Pass (100%), and Adversarial Coverage Hardening

## Phase 2: Dual Track Verification & Completion Report
- [ ] Clean build: `zig build` and `zig build -Drelease`.
- [ ] Integration test: `python3 tools/test_runner.py` passes 100%.
- [ ] Comprehensive verification of all acceptance criteria.
- [ ] Handoff to Sentinel.
