# Handoff Report — USB Host Controller Architecture Survey (xHCI, EHCI, UHCI)

**Agent:** explorer_survey_2  
**Date:** 2026-09-20  
**Status:** Hard Handoff (Investigation Complete)  
**Report Artifact:** `/home/dr4d/Zirconium/.agents/explorer_survey_2/survey_report.md`

---

## 1. Observation

1. **Current USB Driver Implementation (`src/drivers/usb.zig`):**
   - **EHCI & xHCI are stubs:** At `src/drivers/usb.zig:751-765`:
     ```zig
     } else if (ctype == .ehci or ctype == .xhci) {
         ctrl.io_base = 0;
         ctrl.mmio_base = dev.bar0 & 0xFFFFFFF0;
         ctrl.num_ports = 4;
         var p: u8 = 0;
         while (p < ctrl.num_ports) : (p += 1) {
             ctrl.ports[p] = .{
                 .port = p + 1,
                 .connected = (p == 0),
                 .enabled = true,
                 .speed = if (ctype == .xhci) "SuperSpeed (5 Gbps)" else "High-Speed (480 Mbps)",
                 .device_desc = if (p == 0) (if (ctype == .xhci) "USB 3.0 Storage / Hub" else "USB 2.0 High-Speed Hub") else "No device",
             };
         }
     }
     ```
     No operational registers, command rings, periodic/asynchronous schedules, or transfer descriptors are configured for either controller.
   - **UHCI is bound to global singletons:** At `src/drivers/usb.zig:152-160`:
     ```zig
     var frame_list: [1024]u32 align(4096) = [_]u32{1} ** 1024;
     var ctrl_qh: UhciQh align(16) = .{};
     var ctrl_tds: [16]UhciTd align(16) = [_]UhciTd{.{}} ** 16;
     var ctrl_setup_pkt: UsbSetupPacket align(16) = undefined;
     var ctrl_buf: [512]u8 align(16) = [_]u8{0} ** 512;
     ```
     This structure prevents multiple UHCI controllers from functioning without state corruption.
   - **Blocking transfer delays:** At `src/drivers/usb.zig:413-440`:
     `uhciControlTransfer` executes a loop up to 50 iterations with `delayMs(10)`, calling `hlt` while waiting for PIT ticks, blocking the kernel for up to 500 ms per transfer if a device stalls or disconnects.
   - **Single-interface device model overwrites composite dongles:** At `src/drivers/usb.zig:121-141`, `UsbDevice` contains only single fields (`dev_type: UsbDeviceType`, `interface_num: u8`, `ep_in: u8`). In `enumerateUhciDevice` (lines 534-561), iterating over interface descriptors repeatedly overwrites `iface_num` and `ep_in`, breaking multi-interface composite devices (e.g. 2.4GHz wireless keyboard/mouse combos).

2. **PCI Discovery & BAR Management (`src/drivers/pci.zig`):**
   - `pci.scan()` scans buses 0..255, devices 0..31, functions 0..7.
   - `PciDevice` (lines 8-20) stores `bar0` and `bar1` as `u32`.
   - `pci.enableBusMaster(bus, dev, func)` (lines 130-133) sets bits 0 (I/O), 1 (Memory), and 2 (Bus Master).
   - For xHCI 64-bit BAR0: BAR0 holds the lower 32 bits, and BAR1 (offset 0x14) holds the upper 32 bits: `(@as(u64, bar1) << 32) | (bar0 & 0xFFFFFFF0)`.

3. **Memory & Address Space (`src/entry.S`, `src/kernel/pmm.zig`, `src/kernel/vmm.zig`):**
   - In `src/entry.S:57, 87-111`, 64 Page Directories map the first 64 GB of physical address space using 2MB huge pages (`phys_addr == virt_addr`).
   - In `src/kernel/pmm.zig:158-214`, `allocPage()` and `allocPages()` allocate 4KB-aligned pages starting from 1MB upwards, guaranteeing that early kernel allocations fall below 4GB (satisfying UHCI and EHCI 32-bit physical addressing requirements).

4. **Integration Hooks:**
   - Driver initialized at `src/shell.zig:86` via `usb_drv.init()`.
   - Polling called at `src/drivers/keyboard.zig:140` (`@import("usb.zig").poll()`) and `src/drivers/mouse.zig:216` (`@import("usb.zig").poll()`).
   - Network stack calls `net.poll()` at `src/drivers/e1000.zig` and `src/net/*`, where USB Wi-Fi polling can be hooked.
   - Shell command `usb` / `lsusb` dispatched at `src/shell.zig:239-240` to `src/programs/usb.zig:run()`.

---

## 2. Logic Chain

1. **Hardware Coverage:**
   - Modern x86 PCs and virtualized environments use xHCI for all USB ports (USB 3.x, 2.0, 1.1).
   - Virtualized QEMU default environments and older systems utilize EHCI (USB 2.0) and UHCI (USB 1.1).
   - Because `src/drivers/usb.zig` stubbed EHCI and xHCI with dummy connected port strings, neither controller operates. Supporting USB hardware across QEMU and modern bare-metal requires full implementations of xHCI, EHCI, and UHCI.
2. **Composite Peripheral Support (Requirement R3):**
   - Wireless 2.4GHz USB receivers (e.g. Logitech Unifying, generic combo receivers) provide multiple interfaces on a single physical device: Interface 0 for Keyboard and Interface 1 for Mouse.
   - Because `src/drivers/usb.zig` holds only a single `interface_num` and `ep_in` per device, the loop in `enumerateUhciDevice` overwrites Interface 0 when it reaches Interface 1.
   - Therefore, the data model must be restructured to decouple `UsbDevice` into multiple `UsbInterface` elements, each managing its own endpoints, report buffers, and driver bindings.
3. **Preventing Kernel Hangs:**
   - In `uhciControlTransfer`, blocking on `delayMs(10)` puts the CPU in `hlt` state up to 50 times per failed packet. If an unattached or noisy port initiates transfers, boot and shell commands freeze.
   - Replacing blocking waits with an asynchronous state machine and non-blocking transfer status checks ensures the kernel never stalls.
4. **Memory Contiguity for DMA:**
   - USB controllers are bus masters requiring physical DMA buffers.
   - Because Zirconium identity-maps 0..64GB, physical addresses match virtual pointer addresses directly.
   - `pmm.allocPage()` provides 4KB-aligned physical pages. A slab allocator (`UsbDmaPool`) built on `pmm.allocPage()` efficiently fulfills 16-byte (UHCI), 32-byte (EHCI), and 64-byte (xHCI) alignment constraints.

---

## 3. Caveats

1. **OHCI (Open Host Controller Interface, Prog-IF 0x10):** OHCI was primarily used on older non-Intel chipsets (SiS, ALi, AMD) and Apple hardware. Standard PC and QEMU x86 systems use UHCI for USB 1.1. OHCI is omitted from the active implementation plan in favor of UHCI/EHCI/xHCI, but the controller enum reserves Prog-IF 0x10.
2. **xHCI Interrupter IRQs vs Polling:** The design specifies non-blocking polling for event ring processing (matching `e1000.zig`). While MSI/MSI-X or legacy INTx could be configured, polling avoids race conditions across SMP cores and eliminates interrupt storm risks.
3. **USB Hub Class (External Hubs):** Root hubs are fully supported across all three controllers. Cascaded multi-tier external USB hubs require Hub Class descriptor parsing and port power switching, which can be layered onto the `UsbDevice` abstraction once root ports are operational.

---

## 4. Conclusion

1. The USB subsystem requires refactoring into a modular directory structure under `src/drivers/usb/`:
   - `types.zig`: Standard descriptors, transfer enums, setup packets.
   - `pci_detect.zig`: Multi-controller discovery and BAR setup.
   - `xhci.zig`: Full xHCI implementation (Command/Event/Transfer rings, contexts, doorbells, PORTSC).
   - `ehci.zig`: Full EHCI implementation (Async/Periodic schedules, QHs, qTDs, companion routing).
   - `uhci.zig`: Re-architected UHCI driver (multi-controller instances, non-blocking transfers).
   - `device.zig`: Unified device manager with multi-interface composite device support.
   - `dma.zig`: PMM-backed aligned DMA allocator (`UsbDmaPool`).
   - `mod.zig`: Top-level public interface for initialization, polling, and diagnostics.
2. The detailed survey report containing register layouts, bitfields, data structures, and enumeration state machines has been written to `/home/dr4d/Zirconium/.agents/explorer_survey_2/survey_report.md`.

---

## 5. Verification Method

1. **Static Review of Survey Artifact:**
   - Inspect `/home/dr4d/Zirconium/.agents/explorer_survey_2/survey_report.md` for complete register mappings, TRB/QH/qTD/TD bitfields, DMA alignment rules, and enumeration pipeline diagrams.
2. **Kernel Build & Existing Integration Test Suite:**
   - Run: `zig build` (Debug mode).
   - Run: `zig build -Drelease` (ReleaseFast mode).
   - Run: `python3 tools/test_runner.py`.
   - Invalidation condition: Test runner fails any of the 10 required boot markers or compilation errors are introduced.
