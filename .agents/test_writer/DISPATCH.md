# Dispatch: E2E Testing Track — Test Suite & Infrastructure

## 2026-09-20T06:08:00Z

You are the Test Writer (`test_writer`) for the E2E Testing Track of the Zirconium project.
Your working directory is `/home/dr4d/Zirconium/.agents/test_writer`.
The project root is `/home/dr4d/Zirconium`.

CRITICAL INSTRUCTIONS:
1. You MUST read `/home/dr4d/Zirconium/.agents/ORIGINAL_REQUEST.md` before doing anything else.
2. Read `/home/dr4d/Zirconium/.agents/PROJECT.md`, `/home/dr4d/Zirconium/AGENTS.md`, and `/home/dr4d/Zirconium/tools/test_runner.py`.

OBJECTIVE:
Design and build a comprehensive, requirement-driven, opaque-box E2E test suite and test runner based on the Feature Inventory in `PROJECT.md`:
1. **Create `TEST_INFRA.md`** at `/home/dr4d/Zirconium/TEST_INFRA.md` following the template in Project Pattern:
   - Test Philosophy: Opaque-box, requirement-driven, Category-Partition, BVA, Pairwise, Real-World Workload Testing.
   - Feature Inventory mapping all features (F1.1 - F6.3) to test cases across Tier 1, Tier 2, Tier 3, Tier 4.
   - Test Architecture & Runner design.
2. **Implement Test Suite & Test Runner**:
   - Write tests and runner under `tools/` (e.g. `tools/e2e_test_suite.py` or extending test runner capabilities).
   - Ensure tests can test:
     - Core kernel stability (memory allocations, SMP bringup, syscalls, VFS, network).
     - USB host controllers (xHCI, EHCI, UHCI) in QEMU with simulated USB devices.
     - USB HID keyboard and mouse devices.
     - USB Wi-Fi network device detection and packet dispatch.
     - Shell commands and `usb` diagnostics.
   - All tests must be non-destructive and must NOT break or regress the standard `python3 tools/test_runner.py`.
3. **Publish `TEST_READY.md`** at `/home/dr4d/Zirconium/TEST_READY.md` when complete, summarizing coverage across Tiers 1-4 and providing the exact runner command.
4. Document your deliverables in `/home/dr4d/Zirconium/.agents/test_writer/handoff.md`.
5. Send a completion message via `send_message` to your parent.

REMINDER: You are working on the E2E Testing Track. You do NOT modify kernel source code (`src/`).
