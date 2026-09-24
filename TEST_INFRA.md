# Zirconium Kernel E2E Testing Infrastructure & Specification

**Document Version:** 1.0.0  
**Target System:** Zirconium x86_64 Bare-Metal Operating System Kernel  
**Date:** 2026-09-20  
**Author:** Test Writer (`test_writer`), E2E Testing Track  

---

## 1. Test Philosophy & Methodologies

The Zirconium End-to-End (E2E) test infrastructure is designed to provide authoritative, requirement-driven, deterministic, and adversarial verification of the operating system across its full lifecycle.

### 1.1 Opaque-Box & Requirement-Driven Testing
Testing treats the kernel and virtual hardware as an opaque system, verifying requirements against observable outputs (serial telemetry on COM1 `/dev/ttyS0`, VGA/framebuffer display memory at `0xB8000`, PCI configuration state, network frames, and QEMU hardware status) rather than peering into internal private symbols. All assertions trace directly to requirements R1–R5 and features F1.1–F6.3 in `PROJECT.md`.

### 1.2 Category-Partition Method
System inputs and operational states are partitioned into distinct operational categories:
- **Processor Modes & Execution Contexts:** Ring 0 (Kernel Supervisor) vs. Ring 3 (User Space); BSP (Bootstrap Processor) vs. AP (Application Processor Cores 1..3).
- **Memory Addressing:** Kernel Identity Mapped (0..64GB, 2MB huge pages) vs. User Virtual Pages (4KB pages, `0x02000000..0x04000000`).
- **USB Host Controller Standards:** UHCI (USB 1.1, I/O ports via BAR4), EHCI (USB 2.0, 32-bit MMIO via BAR0), xHCI (USB 3.x, 64-bit MMIO via BAR0/BAR1).
- **USB Device Interfaces:** Standard HID Boot Keyboard, Standard HID Boot Mouse, Multi-interface Composite Wireless Receivers (Logitech Unifying / Generic 2.4GHz), Vendor-Specific Wireless Network Adapters (Realtek RTL8188EU / RTL8192CU).
- **Network Interfaces:** Intel e1000 Gigabit, Realtek RTL8169, USB 2.4GHz Wireless (`.usb_wifi`).

### 1.3 Boundary Value Analysis (BVA)
Boundary conditions tested across kernel subsystems include:
- **Memory & Allocators:** 0-byte allocations, 1-byte allocations, 4KB page boundaries, non-contiguous physical page chunks (preventing illegal arena coalescing), heap exhaustion.
- **Syscall Buffers:** Memory boundaries between user-space and kernel identity space (`USER_BASE` to `USER_STACK_TOP`); user pointers crossing into kernel page tables.
- **Connection & Handle Tables:** TCP connection table capacity (boundary at 4 connections, ensuring immediate slot recycling on RST/FIN), FAT16 open handle table (boundary at 32 file handles), file cache (boundary at 128 cached files).
- **USB Descriptors & Packets:** Max packet sizes (8, 16, 32, 64 bytes for control/interrupt; 512 bytes for High-Speed Bulk; 1024 bytes for SuperSpeed); 0-byte data stages, multi-interface descriptor boundary parsing.

### 1.4 Pairwise & Combinatorial Testing
Hardware combinations and configurations evaluated in QEMU:
- UHCI Standalone + USB Keyboard
- UHCI Standalone + USB Mouse
- UHCI + Composite Dongle (Interface 0 Keyboard + Interface 1 Mouse)
- xHCI Standalone + USB Keyboard + USB Mouse
- EHCI + UHCI Companion Controller Routing
- Concurrent Multi-Controller (xHCI + EHCI + UHCI) + Dual Network (e1000 + USB) + Virtio-blk Storage
- SMP Multi-Core (1 CPU, 2 CPUs, 4 CPUs) with concurrent interrupt delivery

### 1.5 Real-World Workload Testing
- **Boot and Bringup:** Cold boot through Multiboot/GRUB, ACPI MADT detection, APIC timer initialization, AP core INIT-SIPI-SIPI wake-up.
- **User-Space Lifecycle:** Ring 3 ELF loading, `int 0x80` syscall dispatch, `SYS_BRK` dynamic heap allocation, free-list reuse, socket creation, TCP connection handshake to gateway `10.0.2.2:80`, HTTP transmission, task exit.
- **Interactive Shell & USB Input:** Hardware event polling, keystroke conversion from USB HID to `keyboard.pushKey()`, mouse displacement updates to `mouse.updateFromUsb()`, shell diagnostic command execution (`usb`, `usb ls`, `usb -v`, `usb wifi`, `usb stats`).

---

## 2. Test Architecture & Runner Design

```
+---------------------------------------------------------------------------------------+
|                                  Test Runner Entry Point                              |
|                       tools/e2e_test_suite.py  /  tools/test_runner.py               |
+---------------------------------------------------------------------------------------+
                                           |
                +--------------------------+--------------------------+
                |                                                     |
                v                                                     v
   +--------------------------+                         +--------------------------+
   |  Build & Image Pipeline  |                         |  Configuration Manager   |
   | - zig build (Debug)      |                         | - Hardware Profiles      |
   | - zig build -Drelease    |                         | - QEMU CLI Composition   |
   | - Dynamic ISO Patcher    |                         | - Network / Disk Setup   |
   +--------------------------+                         +--------------------------+
                |                                                     |
                +--------------------------+--------------------------+
                                           |
                                           v
                   +-----------------------------------------------+
                   |           QEMU Orchestration Engine           |
                   | - Subprocess lifecycle (start/monitor/kill)   |
                   | - Serial stream listener (/dev/ttyS0 COM1)    |
                   | - QMP / Human Monitor Command Dispatcher      |
                   | - Timeout & hang detection                    |
                   +-----------------------------------------------+
                                           |
                                           v
                   +-----------------------------------------------+
                   |           Telemetry & Pattern Engine          |
                   | - Marker sequence assertion                   |
                   | - Log regular expression extraction           |
                   | - Anomaly & kernel panic detection            |
                   +-----------------------------------------------+
                                           |
                +--------------------------+--------------------------+
                |                          |                          |
                v                          v                          v
      [ Tier 1: Smoke ]          [ Tier 2: Subsystem ]       [ Tier 3: USB/HW ]
      (Boot, SMP, Ring 3)        (Memory, VFS, Net, Fault)   (xHCI, EHCI, UHCI, HID)
                                           |
                                           v
                              [ Tier 4: Adversarial/Stress ]
                              (Boundary, Exhaustion, Multi-HC)
                                           |
                                           v
                   +-----------------------------------------------+
                   |          Reporting & Verification Engine      |
                   | - Console Summary Table                       |
                   | - JSON Telemetry Artifact                     |
                   | - Non-Regression Status (test_runner.py)      |
                   +-----------------------------------------------+
```

### 2.1 Hardware Profiles (QEMU Configurations)
1. **Config `Baseline`**: Standard configuration matching `tools/test_runner.py`:
   `qemu-system-x86_64 -cdrom kernel.iso -boot d -m 512M -smp 4 -display none -serial stdio -netdev user,id=net0 -device e1000,netdev=net0,mac=52:54:52:54:52:54 -no-reboot`
2. **Config `UHCI-HID`**: Universal Host Controller with attached HID keyboard and mouse:
   `... -device ich9-usb-uhci1,id=uhci -device usb-kbd,bus=uhci.0,port=1 -device usb-mouse,bus=uhci.0,port=2`
3. **Config `xHCI-SuperSpeed`**: Modern USB 3.0 Extensible Host Controller:
   `... -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-mouse,bus=xhci.0`
4. **Config `EHCI-Companion`**: USB 2.0 Enhanced Host Controller paired with UHCI companion:
   `... -device ich9-usb-ehci1,id=ehci -device ich9-usb-uhci1,masterbus=ehci.0,firstport=0,companion=true -device usb-kbd,bus=ehci.0`
5. **Config `Multi-Controller-Full`**: Concurrent xHCI, EHCI, and UHCI controllers with multiple peripheral devices:
   `... -device qemu-xhci,id=xhci -device ich9-usb-ehci1,id=ehci -device ich9-usb-uhci1,id=uhci -device usb-kbd,bus=xhci.0 -device usb-mouse,bus=uhci.0 -device usb-net,bus=xhci.0`
6. **Config `Storage-FAT16`**: Block device attached with 64MB FAT16 filesystem:
   `... -drive file=disk.img,format=raw,if=virtio`

---

## 3. Comprehensive Feature Inventory Mapping

| Feature ID | Feature Name | Description | Milestone | Target Tier | Test Case ID(s) | Testing Technique | Authoritative Expected Output |
|---|---|---|---|---|---|---|---|
| **F1.1** | SYSCALL IF Masking | Mask IF (bit 9) in `IA32_FMASK` in `src/arch/syscall64.zig` to prevent user-stack interrupts on ring 0 entry | M1 | Tier 2 | `TC-CORE-01` | Opaque Telemetry / Assembly Verification | `[SYSCALL64] syscall/sysret enabled, LSTAR=` with FMASK containing bit 9 masked; zero user-stack corruption |
| **F1.2** | Heap Expansion Safety | Prevent coalescing across disjoint physical page chunks in `src/kernel/kalloc.zig` | M1 | Tier 2 | `TC-MEM-01` | BVA / Resource Stress | `[KHEAP] Initialized`; dynamic expansions maintain distinct chunk bounds; zero heap node corruption |
| **F1.3** | VFS BSS Handle Fix | Eliminate `kfree` on static BSS array `open_files` upon file close in `src/fs/vfs.zig` / `ramfs.zig` | M1 | Tier 2 | `TC-VFS-01` | Category-Partition / Lifecycle | `[VFS] Initialized`, `[RAMFS] Initialized`; file open and close completes without heap header corruption |
| **F1.4** | Ring 3 Fault Isolation | Terminate faulted user tasks on exceptions (#GP, #PF, #DE) without kernel panic in `src/arch/isr.zig` | M1 | Tier 2 | `TC-CORE-02` | Adversarial / Fault Injection | Faulted ring 3 task exits with signal code; OS remains responsive; no `=== KERNEL PANIC ===` |
| **F1.5** | Per-CPU SMP TSS | Allocate per-CPU TSS and `RSP0` kernel stacks to prevent AP stack collisions in `src/arch/smp.zig` / `gdt.zig` | M1 | Tier 2 | `TC-SMP-01` | Multi-Core Concurrency | All 3 AP cores online (`[SMP] AP CPU 1 online`, `2`, `3`); zero RSP0 cross-talk or stack corruption |
| **F1.6** | TCP Slot Recycling | Reset `conn.id = -1` on connection close, RST, or timeout in `src/net/tcp.zig` | M1 | Tier 2 | `TC-NET-01` | BVA / State Exhaustion | Sockets can be repeatedly opened and closed; connection slot reallocated cleanly; no socket exhaustion |
| **F1.7** | FAT16 Handle Recycling | Properly clear `open_handle_used` and recycle cache entries in `src/fs/fat16.zig` | M1 | Tier 2 | `TC-VFS-02` | Boundary Stress | Repeated open/read/close of FAT16 files does not exhaust 32 handles or 128 file cache slots |
| **F1.8** | Net Device Abstraction | Route all protocol packet transmissions (`arp`, `dhcp`, `icmp`, `tcp`, `udp`) through `net.sendFrame()` | M1 | Tier 2 | `TC-NET-02` | Interface Contract | All outgoing packets route through unified `sendFrame`; works seamlessly across e1000 and `.usb_wifi` |
| **F2.1** | USB Subsystem Core | Unified `UsbController` vtable and modular structure under `src/drivers/usb/` | M2 | Tier 3 | `TC-USB-01` | Architectural Interface | `[USB] Subsystem initialized`; vtable calls dispatch controller-specific operations cleanly |
| **F2.2** | USB DMA Allocator | `UsbDmaPool` using PMM for 16B/32B/64B physically aligned DMA buffers | M2 | Tier 3 | `TC-USB-02` | Boundary / Alignment | PMM-backed DMA descriptors allocated at exact hardware alignments (16B UHCI, 32B EHCI, 64B xHCI) |
| **F2.3** | USB PCI Controller Discovery | Scan and initialize xHCI, EHCI, and UHCI controllers via PCI with 64-bit BAR and bus master enable | M2 | Tier 3 | `TC-USB-03` | PCI Scan / Device Query | Logs `[USB] Found UHCI ...`, `[USB] Found EHCI ...`, `[USB] Found xHCI ...` with correct PCI bus:dev and BAR |
| **F2.4** | xHCI Controller Driver | Full xHCI implementation (rings, contexts, doorbells, PORTSC, reset, transfers) | M2 | Tier 3 | `TC-USB-04` | QEMU Emulation | Detection and initialization of `qemu-xhci` / `nec-usb-xhci`; successful port reset and event ring polling |
| **F2.5** | EHCI Controller Driver | Full EHCI implementation (Async/Periodic schedules, QHs, qTDs, PORTSC, companion routing) | M2 | Tier 3 | `TC-USB-05` | QEMU Emulation | Detection and initialization of `ich9-usb-ehci1`; async schedule enable; companion port handover |
| **F2.6** | UHCI Multi-Controller Driver | Instance-based UHCI driver supporting multiple controllers without static globals | M2 | Tier 3 | `TC-USB-06` | Multi-Instance Verification | Multiple UHCI instances (`ich9-usb-uhci1`, `uhci2`) initialize independently with separate frame lists |
| **F2.7** | Async USB Scheduling | Non-blocking transfer state machine eliminating 500ms blocking spin-waits | M2 | Tier 3 | `TC-USB-07` | Latency / Non-Blocking | Zero CPU halt spin-waits during USB transfer checking; poll hook returns immediately if active |
| **F3.1** | Multi-Interface Composite Parsing | Parse and store multi-interface descriptors without overwriting interface records | M3 | Tier 3 | `TC-HID-01` | Equivalence Partitioning | Both Interface 0 (Keyboard) and Interface 1 (Mouse) recorded and activated simultaneously |
| **F3.2** | USB HID Protocol Driver | Boot Protocol and Report Protocol handler for keyboards and mice | M3 | Tier 3 | `TC-HID-02` | Protocol Specification | `[USB] Registered USB Keyboard (HID Boot)`, `[USB] Registered USB Mouse (HID Boot)` |
| **F3.3** | Interrupt Transfer Queues | Asynchronous interrupt IN endpoint transfer scheduling for HID inputs | M3 | Tier 3 | `TC-HID-03` | Asynchronous I/O | Periodic interrupt IN TDs/TRBs armed and re-armed upon completion |
| **F3.4** | 2.4GHz Wireless Dongle Support | Logitech Unifying and generic 2.4GHz composite keyboard/mouse receivers | M3 | Tier 3 | `TC-HID-04` | Real-World Hardware Profile | Enumerates VID 0x046D PID 0xC52B and generic dongles; binds independent keyboard and mouse queues |
| **F3.5** | Input Event Routing | Route keystrokes to `keyboard.pushKey()` and mouse packets to `mouse.updateFromUsb()` | M3 | Tier 3 | `TC-HID-05` | End-to-End Pipeline | Keystrokes appear in shell/GUI; mouse coordinate updates reflect in `mouse.mx` / `mouse.my` |
| **F4.1** | Realtek USB Wi-Fi Driver | RTL8188EU / RTL8192CU chipset identification, register setup, and EEPROM read | M4 | Tier 3 | `TC-WIFI-01` | Device Identification | Detects Realtek VID `0x0BDA` PID `0x8179` / `0x8192`; reads MAC address from `REG_MACID` (0x50..0x55) |
| **F4.2** | Wi-Fi Vendor Control Protocol | Vendor control transfers (`bRequest = 0x05`) for MAC address and hardware initialization | M4 | Tier 3 | `TC-WIFI-02` | Protocol Verification | Successful 8/16/32-bit register reads/writes on EP0 using vendor request `0x05` |
| **F4.3** | Bulk Transfer TX/RX | Bulk IN and Bulk OUT transfer scheduling for wireless packet delivery | M4 | Tier 3 | `TC-WIFI-03` | Packet Transfer Pipeline | 32-byte `TX_DESC_8188E` prepended to outgoing frames; 24-byte `RX_DESC_8188E` parsed on receive |
| **F4.4** | 802.11 / 802.3 Frame Conversion | Encapsulate outgoing 802.3 frames and decapsulate incoming 802.11 frames | M4 | Tier 3 | `TC-WIFI-04` | Packet Encapsulation | Converts Ethernet II frames to/from 802.11 MAC frames; handles LLC/SNAP headers |
| **F4.5** | Wireless Net Stack Integration | Integrate Wi-Fi NIC into `src/net/mod.zig` alongside e1000 and RTL8169 | M4 | Tier 3 | `TC-WIFI-05` | Net Subsystem Binding | `net.active_nic = .usb_wifi`; DHCP, ARP, and TCP operate transparently over wireless interface |
| **F5.1** | `usb` Command Subcommands | Interactive shell command with subcommands: `ls`, `-v`, `wifi`, `stats` | M5 | Tier 3 | `TC-DIAG-01` | CLI Subcommand Parsing | Subcommand dispatch handles `usb`, `usb ls`, `usb -v`, `usb wifi`, `usb stats` |
| **F5.2** | Controller & Device Diagnostics | Display active host controllers, root ports, attached devices, endpoints | M5 | Tier 3 | `TC-DIAG-02` | Human-Readable Output | Formatted table listing PCI location, controller type, ports, attached devices, and speeds |
| **F5.3** | Live USB Statistics | Live packet and transfer counters for USB HID and Wi-Fi adapters | M5 | Tier 3 | `TC-DIAG-03` | Live Telemetry | Accurate packet count, byte counters, and error stats rendered in shell |
| **F6.1** | Test Runner Non-Regression | Ensure all 10 boot and ring 3 markers in `tools/test_runner.py` pass 100% | M6 | Tier 1 | `TC-REGR-01` | Non-Regression / Golden Markers | 100% pass across all 10 markers in `python3 tools/test_runner.py` |
| **F6.2** | Clean Dual Build | Ensure `zig build` and `zig build -Drelease` compile cleanly with zero warnings | M6 | Tier 1 | `TC-BUILD-01` | Dual Toolchain Compilation | Exit code 0 for both Debug and ReleaseFast builds; zero compiler errors |
| **F6.3** | Comprehensive E2E Test Suite | Automated test verification of core stability, USB controllers, HID, and Wi-Fi | M6 | Tier 4 | `TC-E2E-ALL` | Full Suite Execution | Complete multi-tier execution covering Tiers 1–4 with detailed telemetry report |

---

## 4. Test Tier Definitions & Test Cases

### Tier 1: Sanity, Smoke & Non-Regression Tests
- **Objective:** Fast-feedback verification of kernel compilation, ISO generation, system boot, SMP AP bringup, Ring 3 syscall execution, and socket connectivity.
- **Execution Target:** < 15 seconds.
- **Test Cases:**
  - `TC-BUILD-01`: Verify clean compilation of both `zig build` (Debug) and `zig build -Drelease` (ReleaseFast).
  - `TC-BOOT-01`: Verify multiboot verification, GDT ring 3 segments, IDT 256 gates, PMM/VMM initialization, and kernel heap initialization.
  - `TC-SMP-01`: Verify ACPI MADT parsing, LAPIC timer periodic mode (100 Hz), and all 3 secondary AP cores coming online (`[SMP] AP CPU 1 online`, `2`, `3`).
  - `TC-RING3-01`: Verify Ring 3 entry, user serial output, `SYS_BRK` allocation and free-list reuse (`[USER-HEAP] free + reuse OK`).
  - `TC-REGR-01`: Full pass of `python3 tools/test_runner.py` with all 10 golden markers.

### Tier 2: Subsystem & Hardening Tests
- **Objective:** Validate subsystem isolation, memory management safeguards, filesystem resource lifecycle, and network abstractions.
- **Execution Target:** < 30 seconds.
- **Test Cases:**
  - `TC-MEM-01`: Memory Manager Contiguity & Expansion: Verify PMM allocator stability and assert `kalloc` heap expansion does not coalesce non-contiguous memory chunks (F1.2).
  - `TC-CORE-01`: Architectural SYSCALL Security: Verify `IA32_FMASK` masks IF (bit 9), ensuring ring 0 entry executes with interrupts masked until kernel stack switch (F1.1).
  - `TC-CORE-02`: Ring 3 Exception Fault Isolation: Verify that user-space faults (#GP, #PF, #DE) terminate the faulted task gracefully without triggering a system-wide kernel panic (F1.4).
  - `TC-VFS-01`: VFS Static Handle Safety: Verify that `vfs.close()` on RAMFS file handles does not call `kfree()` on static BSS memory `open_files[i]` (F1.3).
  - `TC-VFS-02`: FAT16 Handle & Cache Slot Recycling: Verify that opening, reading, and closing files on FAT16 volumes recycles `open_handle_used` entries and file cache slots (F1.7).
  - `TC-NET-01`: TCP Connection Slot Recycling: Verify that closed, reset, or timed-out TCP connections reset `conn.id = -1`, allowing new connections without exhaustion (F1.6).
  - `TC-NET-02`: Unified Network Device Abstraction: Verify that packet transmission across all protocols is dispatched through `net.sendFrame()` (F1.8).

### Tier 3: USB Host Controllers, Peripherals & Wi-Fi Tests
- **Objective:** Exercise simulated USB hardware in QEMU across xHCI, EHCI, and UHCI, testing device enumeration, composite HID dongles, and Realtek Wi-Fi.
- **Execution Target:** < 45 seconds.
- **Test Cases:**
  - `TC-USB-01`: USB Subsystem Modular Structure & VTable Dispatch: Verify unified `UsbController` vtable operation (F2.1).
  - `TC-USB-02`: USB DMA Pool Physical Alignment: Verify `UsbDmaPool` allocates physically aligned descriptor structures (16B, 32B, 64B) backed by PMM (F2.2).
  - `TC-USB-03`: Multi-Controller PCI Detection: Launch QEMU with UHCI, EHCI, and xHCI; assert detection of all 3 controllers with correct PCI bus:dev:func and BARs (F2.3).
  - `TC-USB-04`: xHCI (USB 3.0) Controller Operation: Verify xHCI initialization, DCBAA setup, command ring, event ring, and root port status in QEMU (`qemu-xhci`) (F2.4).
  - `TC-USB-05`: EHCI (USB 2.0) Controller & Companion Routing: Verify EHCI initialization (`ich9-usb-ehci1`) and companion port handover to UHCI (F2.5).
  - `TC-USB-06`: UHCI Multi-Controller Support: Verify multiple UHCI controller instances operating without static global collisions (F2.6).
  - `TC-USB-07`: Asynchronous Non-Blocking Transfer Scheduling: Verify that USB transfer polling returns immediately without blocking CPU spin-waits (F2.7).
  - `TC-HID-01`: Multi-Interface Composite Parsing: Verify that a composite USB device (keyboard + mouse) allocates distinct interfaces without scalar record overwriting (F3.1).
  - `TC-HID-02`: USB HID Keyboard & Mouse Enumeration: Verify detection and configuration of `usb-kbd` and `usb-mouse` via Boot Protocol (F3.2).
  - `TC-HID-03`: Interrupt Transfer Scheduling: Verify interrupt IN endpoint queues for HID devices (F3.3).
  - `TC-HID-04`: 2.4GHz Wireless Receiver Dongle Profile: Verify Logitech Unifying and generic 2.4GHz dongle profile matching (F3.4).
  - `TC-HID-05`: Input Routing to Shell & GUI: Verify keyboard scancodes route to `keyboard.pushKey()` and mouse packets to `mouse.updateFromUsb()` (F3.5).
  - `TC-WIFI-01`: Realtek USB Wi-Fi Device Identification: Verify recognition of Realtek RTL8188EU / RTL8192CU chipsets (F4.1).
  - `TC-WIFI-02`: Vendor Control Register Access Protocol: Verify 802.11 vendor control requests (`bRequest = 0x05`) for register read/write and MAC retrieval (F4.2).
  - `TC-WIFI-03`: Bulk TX/RX Transfer Scheduling: Verify Bulk OUT (`TX_DESC_8188E`) and Bulk IN (`RX_DESC_8188E`) packet queues (F4.3).
  - `TC-WIFI-04`: 802.11 / 802.3 Frame Encapsulation & Decapsulation (F4.4).
  - `TC-WIFI-05`: Wireless Network Stack Integration: Verify `.usb_wifi` integration in `net/mod.zig` (F4.5).
  - `TC-DIAG-01`: `usb` Command Subcommands: Verify shell subcommands (`usb`, `usb ls`, `usb -v`, `usb wifi`, `usb stats`) (F5.1).
  - `TC-DIAG-02`: Detailed Controller & Root Port Diagnostics: Verify formatted hardware inspection output (F5.2).
  - `TC-DIAG-03`: Live USB Transfer & Packet Statistics: Verify live transfer counters (F5.3).

### Tier 4: Adversarial, Stress, Boundary & Endurance Tests
- **Objective:** Push the operating system to boundary conditions, resource limits, and hardware edge cases.
- **Execution Target:** < 60 seconds.
- **Test Cases:**
  - `TC-STRESS-01`: Multi-Controller Concurrent Enumeration: Simultaneously attach xHCI, EHCI, UHCI, USB Keyboard, USB Mouse, and USB Network adapter; assert zero race conditions or kernel panics.
  - `TC-STRESS-02`: Rapid Socket Allocation & Teardown Stress: Cycle 50 connection requests through `sys_socket`, `sys_connect`, and `sys_close` to confirm zero socket slot leakage under rapid churn.
  - `TC-STRESS-03`: FAT16 File Handle Churn Stress: Open and close 100 file handles sequentially on a mounted FAT16 volume, asserting handle recycling.
  - `TC-STRESS-04`: Corrupt / Malformed USB Descriptor Resilience: Verify that malformed or truncated USB descriptor streams do not cause out-of-bounds memory reads or kernel faults.
  - `TC-STRESS-05`: Non-Regression Full Harness Assertion: Continuous execution of full suite verifying that baseline `python3 tools/test_runner.py` maintains 100% pass rate.

---

## 5. Execution Guide & CLI Commands

### 5.1 Quick Non-Regression Smoke Test
Runs the standard integration test verifying 100% of baseline boot, SMP, Ring 3, and network markers:
```bash
python3 tools/test_runner.py
```

### 5.2 Comprehensive E2E Test Suite
Runs the full multi-tier E2E test runner:
```bash
python3 tools/e2e_test_suite.py --all
```

### 5.3 Running Specific Tiers
```bash
python3 tools/e2e_test_suite.py --tier 1     # Smoke & Baseline Boot Tests
python3 tools/e2e_test_suite.py --tier 2     # Subsystem Hardening & Fault Isolation
python3 tools/e2e_test_suite.py --tier 3     # USB Host Controllers & Peripheral Drivers
python3 tools/e2e_test_suite.py --tier 4     # Adversarial & Stress Scenarios
```

### 5.4 Running by Feature or Keyword Filter
```bash
python3 tools/e2e_test_suite.py -k usb       # All USB-related test cases
python3 tools/e2e_test_suite.py -k F2.3      # Specific feature test
python3 tools/e2e_test_suite.py -k wifi      # Wi-Fi test cases
```

### 5.5 Generating JSON Test Report
```bash
python3 tools/e2e_test_suite.py --all --json test_report.json
```

### 5.6 FAT32 + Kernel Log Fixture
```bash
python3 tools/test_fat32_log.py
```
The test creates a temporary 1 GiB MBR/FAT32 image, boots it with QEMU, and verifies `KERNEL.LOG`, nested file creation, multi-cluster append/copy, and a file whose first cluster is above `0xFFFF`.
