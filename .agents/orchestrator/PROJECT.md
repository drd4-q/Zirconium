# Project: Zirconium Kernel Stability Overhaul & USB Subsystem

## Architecture

Zirconium is an x86_64 bare-metal operating system kernel written in Zig. It boots in long mode via Multiboot/GRUB with 2MB identity-mapped pages (0..64GB), SMP multi-core bringup via ACPI/MADT and APIC INIT-SIPI-SIPI trampoline, cooperative scheduling, VFS (ramfs + FAT16 over virtio-blk), ring 3 user-space with INT 0x80 and SYSCALL/SYSRET ABIs, and an in-kernel TCP/IP stack over e1000.

The architecture extensions introduce:
1. **Hardened Core Subsystems**:
   - `src/arch/syscall64.zig` & `src/arch/isr.S`: IF masking in `IA32_FMASK` to close the ring 3 privilege escalation and user-stack interrupt hazard.
   - `src/kernel/kalloc.zig`: Chunk-aware free-list management forbidding coalescing across non-contiguous physical page boundaries.
   - `src/fs/vfs.zig` & `src/fs/ramfs.zig`: Safe handle closure without invoking `kfree` on static BSS descriptors.
   - `src/arch/isr.zig`: Fault isolation terminating user tasks on ring 3 faults (#GP, #PF, #DE) without kernel panics.
   - `src/arch/smp.zig` & `src/arch/gdt.zig`: Per-CPU TSS allocation and independent `RSP0` stacks.
   - `src/net/tcp.zig` & `src/fs/fat16.zig`: Full connection and handle recycling on teardown.
   - `src/net/mod.zig`: Unified network device abstraction routing all protocol packet transmissions (`arp`, `dhcp`, `icmp`, `tcp`, `udp`) through `net.sendFrame()` instead of directly invoking `e1000.transmit()`.
2. **Modular USB Subsystem (`src/drivers/usb/`)**:
   - `types.zig`: Standard USB descriptors (Device, Config, Interface, Endpoint, HID), setup packets, transfer types, speeds.
   - `dma.zig`: `UsbDmaPool` using PMM physical pages for 16-byte (UHCI), 32-byte (EHCI), and 64-byte (xHCI) aligned descriptors.
   - `pci_detect.zig`: PCI scanning for host controllers (class 0x0C, subclass 0x03, prog-if 0x00=UHCI, 0x20=EHCI, 0x30=xHCI), BAR mapping, bus master enable.
   - `xhci.zig`: xHCI host controller (Capability/Operational/Runtime/Doorbell MMIO, DCBAA, Command Ring, Event Ring with ERST, Transfer Rings, Slot & Endpoint Contexts, PORTSC root hub reset & speed negotiation).
   - `ehci.zig`: EHCI host controller (Periodic & Asynchronous schedules, Queue Heads, Queue Element Transfer Descriptors, PORTSC, port reset).
   - `uhci.zig`: Instance-based UHCI driver supporting multiple controllers, 1024-entry Frame List, QHs, TDs, non-blocking transfer scheduling.
   - `device.zig`: Unified USB device and multi-interface management. Supports composite devices by allocating dedicated interface descriptors and endpoint transfer queues.
   - `mod.zig`: Top-level initialization, non-blocking polling hook, device registry, and diagnostics export.
3. **USB 2.4GHz Wireless HID Peripherals**:
   - `hid.zig`: Class 0x03 parser supporting Boot and Report protocols.
   - `composite.zig`: Preserves both Interface 0 (keyboard) and Interface 1 (mouse) for composite wireless receivers (Logitech Unifying and generics), scheduling concurrent interrupt IN transfers.
   - Routing: Dispatches keyboard scancodes to `keyboard.pushKey()` and mouse packets to `mouse.updateFromUsb()`, seamlessly driving both the VGA text shell and graphical framebuffer desktop.
4. **USB 2.4GHz Wireless Network Adapter Driver**:
   - `src/drivers/usb/rtl8188eu.zig`: Realtek 802.11 b/g/n (RTL8188EU / RTL8192CU) device driver using USB bulk endpoints for TX/RX and vendor control transfers (`bRequest = 0x05`) for register/EEPROM configuration and MAC address retrieval.
   - 802.3 Ethernet frame encapsulation/decapsulation to/from 802.11 MAC frames.
   - Seamless integration with `net/mod.zig` via `.usb_wifi` in `NicType`.
5. **Diagnostics and Shell Utilities**:
   - Overhauled `src/programs/usb.zig` supporting subcommands (`usb`, `usb ls`, `usb -v`, `usb wifi`, `usb stats`) to display controllers, root ports, attached wireless devices, endpoints, and live transfer counters.

---

## Feature Inventory

| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| F1.1 | SYSCALL IF Masking | Mask IF (bit 9) in `IA32_FMASK` in `src/arch/syscall64.zig` to prevent user-stack interrupts on ring 0 entry | M1 | Survey (Explorer 1) |
| F1.2 | Heap Expansion Safety | Prevent coalescing across disjoint physical page chunks in `src/kernel/kalloc.zig` | M1 | Survey (Explorer 1) |
| F1.3 | VFS BSS Handle Fix | Eliminate `kfree` on static BSS array `open_files` upon file close in `src/fs/vfs.zig` / `ramfs.zig` | M1 | Survey (Explorer 1) |
| F1.4 | Ring 3 Fault Isolation | Terminate faulted user tasks on exceptions (#GP, #PF, #DE) without kernel panic in `src/arch/isr.zig` | M1 | Survey (Explorer 1) |
| F1.5 | Per-CPU SMP TSS | Allocate per-CPU TSS and `RSP0` kernel stacks to prevent AP stack collisions in `src/arch/smp.zig` / `gdt.zig` | M1 | Survey (Explorer 1) |
| F1.6 | TCP Slot Recycling | Reset `conn.id = -1` on connection close, RST, or timeout in `src/net/tcp.zig` | M1 | Survey (Explorer 1) |
| F1.7 | FAT16 Handle Recycling | Properly clear `open_handle_used` and recycle cache entries in `src/fs/fat16.zig` | M1 | Survey (Explorer 1) |
| F1.8 | Net Device Abstraction | Route all protocol packet transmissions (`arp`, `dhcp`, `icmp`, `tcp`, `udp`) through `net.sendFrame()` | M1 | Survey (Explorer 1) |
| F2.1 | USB Subsystem Core | Unified `UsbController` vtable and modular structure under `src/drivers/usb/` | M2 | Survey (Explorer 2) |
| F2.2 | USB DMA Allocator | `UsbDmaPool` using PMM for 16B/32B/64B physically aligned DMA buffers | M2 | Survey (Explorer 2) |
| F2.3 | USB PCI Controller Discovery | Scan and initialize xHCI, EHCI, and UHCI controllers via PCI with 64-bit BAR and bus master enable | M2 | Survey (Explorer 2) |
| F2.4 | xHCI Controller Driver | Full xHCI implementation (rings, contexts, doorbells, PORTSC, reset, transfers) | M2 | Survey (Explorer 2) |
| F2.5 | EHCI Controller Driver | Full EHCI implementation (Async/Periodic schedules, QHs, qTDs, PORTSC, companion routing) | M2 | Survey (Explorer 2) |
| F2.6 | UHCI Multi-Controller Driver | Instance-based UHCI driver supporting multiple controllers without static globals | M2 | Survey (Explorer 2) |
| F2.7 | Async USB Scheduling | Non-blocking transfer state machine eliminating 500ms blocking spin-waits | M2 | Survey (Explorer 2) |
| F3.1 | Multi-Interface Composite Parsing | Parse and store multi-interface descriptors without overwriting interface records | M3 | Survey (Explorer 3) |
| F3.2 | USB HID Protocol Driver | Boot Protocol and Report Protocol handler for keyboards and mice | M3 | Survey (Explorer 3) |
| F3.3 | Interrupt Transfer Queues | Asynchronous interrupt IN endpoint transfer scheduling for HID inputs | M3 | Survey (Explorer 3) |
| F3.4 | 2.4GHz Wireless Dongle Support | Logitech Unifying and generic 2.4GHz composite keyboard/mouse receivers | M3 | Survey (Explorer 3) |
| F3.5 | Input Event Routing | Route keystrokes to `keyboard.pushKey()` and mouse packets to `mouse.updateFromUsb()` | M3 | Survey (Explorer 3) |
| F4.1 | Realtek USB Wi-Fi Driver | RTL8188EU / RTL8192CU chipset identification, register setup, and EEPROM read | M4 | Survey (Explorer 3) |
| F4.2 | Wi-Fi Vendor Control Protocol | Vendor control transfers (`bRequest = 0x05`) for MAC address and hardware initialization | M4 | Survey (Explorer 3) |
| F4.3 | Bulk Transfer TX/RX | Bulk IN and Bulk OUT transfer scheduling for wireless packet delivery | M4 | Survey (Explorer 3) |
| F4.4 | 802.11 / 802.3 Frame Conversion | Encapsulate outgoing 802.3 frames and decapsulate incoming 802.11 frames | M4 | Survey (Explorer 3) |
| F4.5 | Wireless Net Stack Integration | Integrate Wi-Fi NIC into `src/net/mod.zig` alongside e1000 and RTL8169 | M4 | Survey (Explorer 3) |
| F5.1 | `usb` Command Subcommands | Interactive shell command with subcommands: `ls`, `-v`, `wifi`, `stats` | M5 | Survey (Explorer 3) |
| F5.2 | Controller & Device Diagnostics | Display active host controllers, root ports, attached devices, endpoints | M5 | Survey (Explorer 3) |
| F5.3 | Live USB Statistics | Live packet and transfer counters for USB HID and Wi-Fi adapters | M5 | Survey (Explorer 3) |
| F6.1 | Test Runner Non-Regression | Ensure all 10 boot and ring 3 markers in `tools/test_runner.py` pass 100% | M6 | ORIGINAL_REQUEST §Acceptance |
| F6.2 | Clean Dual Build | Ensure `zig build` and `zig build -Drelease` compile cleanly with zero warnings | M6 | ORIGINAL_REQUEST §Acceptance |
| F6.3 | Comprehensive E2E Test Suite | Automated test verification of core stability, USB controllers, HID, and Wi-Fi | M6 | ORIGINAL_REQUEST §Acceptance |

---

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Core Kernel Stability Overhaul & Net Abstraction | F1.1, F1.2, F1.3, F1.4, F1.5, F1.6, F1.7, F1.8 | none | DONE |
| M2 | USB Host Controller Subsystem Architecture (xHCI, EHCI, UHCI) | F2.1, F2.2, F2.3, F2.4, F2.5, F2.6, F2.7 | M1 | DONE |
| M3 | USB 2.4GHz Wireless HID Peripherals & Input Event Routing | F3.1, F3.2, F3.3, F3.4, F3.5 | M2 | IN_PROGRESS |
| M4 | USB 2.4GHz Wireless Network Adapter Driver & Net Integration | F4.1, F4.2, F4.3, F4.4, F4.5 | M1, M2 | PLANNED |
| M5 | Diagnostics & `usb` Shell Command Overhaul | F5.1, F5.2, F5.3 | M2, M3, M4 | PLANNED |
| M6 | Final Integration, 100% E2E Test Pass & Adversarial Hardening | F6.1, F6.2, F6.3 | M1-M5, E2E Test Track | PLANNED |

---

## Interface Contracts

### 1. Kernel Network Core ↔ Network Drivers
- **Function**: `net.sendFrame(packet: []const u8) void`
  - Routes outgoing frames to the currently active NIC (`.e1000`, `.rtl8169`, or `.usb_wifi`).
- **Function**: `net.receiveFrame(buf: []u8) ?usize`
  - Drains received frames from the active NIC during `net.poll()`.
- **Enum**: `net.NicType`: `none`, `e1000`, `rtl8169`, `usb_wifi`.

### 2. USB Subsystem ↔ Input Subsystem
- **Function**: `keyboard.pushKey(ch: u8) void`
  - Ingests ASCII key characters converted from USB HID scancodes into the direct key ring buffer.
- **Function**: `mouse.updateFromUsb(buttons: u8, dx: i32, dy: i32) void`
  - Updates mouse coordinates and button states for both text console and graphical framebuffer desktop.
- **Polling Hook**: `usb.poll()` called non-blockingly from `keyboard.pollKey()`, `mouse.poll()`, and `net.poll()`.

### 3. USB Host Controller VTable
- **Interface**:
  ```zig
  pub const UsbController = struct {
      ptr: *anyopaque,
      vtable: *const VTable,
      pub const VTable = struct {
          poll: *const fn (ctx: *anyopaque) void,
          controlTransfer: *const fn (ctx: *anyopaque, addr: u8, setup: *const UsbSetupPacket, data: ?[]u8, is_in: bool) bool,
          interruptTransfer: *const fn (ctx: *anyopaque, addr: u8, ep: u8, data: []u8) ?usize,
          bulkTransfer: *const fn (ctx: *anyopaque, addr: u8, ep: u8, data: []u8, is_in: bool) ?usize,
          resetPort: *const fn (ctx: *anyopaque, port: u8) bool,
      };
  };
  ```

---

## Code Layout

- `src/arch/`:
  - `syscall64.zig`: Updated `IA32_FMASK` configuration with IF (bit 9) masked.
  - `isr.zig`: Fault isolation logic terminating user tasks instead of halting kernel.
  - `smp.zig` & `gdt.zig`: Per-CPU TSS descriptors and `RSP0` kernel stack management.
- `src/kernel/`:
  - `kalloc.zig`: Safe heap expansion preventing coalescing across disjoint physical chunks.
- `src/fs/`:
  - `vfs.zig` & `ramfs.zig`: Correct handle closure without `kfree` on static BSS descriptors.
  - `fat16.zig`: Handle and cache slot recycling.
- `src/net/`:
  - `mod.zig`: Unified network transmission abstraction and `.usb_wifi` integration.
  - `tcp.zig`: Connection slot recycling fix.
- `src/drivers/usb/`:
  - `types.zig`: Standard descriptors, setup packets, transfer types.
  - `dma.zig`: PMM-backed aligned DMA buffer pool.
  - `pci_detect.zig`: Multi-controller PCI detection and BAR configuration.
  - `xhci.zig`: xHCI host controller driver.
  - `ehci.zig`: EHCI host controller driver.
  - `uhci.zig`: Refactored UHCI host controller driver.
  - `device.zig`: Multi-interface composite device manager.
  - `hid.zig`: USB 2.4GHz wireless HID keyboard/mouse protocol driver.
  - `rtl8188eu.zig`: Realtek 802.11 USB wireless network driver.
  - `mod.zig`: Unified USB subsystem public interface.
- `src/programs/`:
  - `usb.zig`: Extended `usb` diagnostic shell command with subcommand parser.
