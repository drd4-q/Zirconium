# Original User Request

## 2026-09-20T05:58:21Z

Perform a comprehensive codebase audit and stability overhaul of the Zirconium x86_64 bare-metal kernel, fix all identified bugs across core subsystems, and implement support for USB 2.4GHz wireless devices (HID wireless keyboard/mouse composite dongles and 2.4GHz USB Wi-Fi network adapters) for both modern bare-metal hardware and QEMU.

Working directory: /home/dr4d/Zirconium
Integrity mode: development

## Requirements

### R1. Comprehensive Kernel Audit and Bug Fixing
Conduct an end-to-end audit of all core kernel subsystems (physical and virtual memory managers, kernel heap allocator, SMP scheduler, interrupt handling, VFS/FAT16, TCP/IP network stack, and user-space syscalls). Identify and fix logic errors, potential panics, memory leaks, synchronization issues, and hardware-compatibility regressions, ensuring full stability.

### R2. USB Host Controller Support (xHCI, EHCI, UHCI)
Ensure the USB subsystem supports host controller discovery and operation across modern real hardware and virtualized targets. Implement and refine xHCI (USB 3.x), EHCI (USB 2.0), and UHCI (USB 1.1) controller initialization, root port management, reset sequencing, and asynchronous transfer scheduling.

### R3. USB 2.4GHz Wireless HID Peripherals
Support 2.4GHz wireless USB receivers and dongles (such as Logitech Unifying and generic wireless keyboard/mouse combos). Handle single and composite multi-interface configurations, interrupt endpoint transfer queues, and boot/report protocol event processing, routing keyboard keystrokes and mouse movement/button events into the kernel's input queues for both VGA text shell and graphical framebuffer modes.

### R4. USB 2.4GHz Wireless Network Adapter Support
Provide driver support for common 2.4GHz USB wireless network adapters (e.g. Realtek 802.11 b/g/n chipsets such as RTL8188EU / RTL8192CU), enabling device initialization, firmware/register configuration, frame transmission and reception, and integration with the kernel's existing network routing and packet dispatch pipeline.

### R5. Diagnostics and Shell Utilities
Provide diagnostics within the kernel shell (extending the `usb` command and system logs) to inspect detected controllers, root ports, attached wireless devices, endpoint descriptors, and real-time packet statistics.

## Acceptance Criteria

### Automated Build & Test Harness
- [ ] Both `zig build` (Debug) and `zig build -Drelease` (ReleaseFast) compile cleanly without errors or regressions.
- [ ] The automated test harness (`python3 tools/test_runner.py`) passes 100% of integration checks and test markers.

### Core Kernel Stability
- [ ] Memory manager (PMM/VMM) and kernel heap operate stably without page faults or leaks under continuous usage.
- [ ] SMP multi-core bringup and scheduler operate without deadlocks or AP initialization failures.
- [ ] Shell commands, file system operations on ramfs and FAT16, and network utilities execute without unexpected kernel panics.

### USB Subsystem & Peripheral Verification
- [ ] Host controllers (xHCI on real hardware / QEMU, EHCI, and UHCI) are properly detected via PCI, initialized, and report root port status.
- [ ] 2.4GHz wireless HID dongles (keyboard and mouse) are recognized, enumerated, and can drive shell typing and GUI cursor movement.
- [ ] Multi-interface composite USB devices correctly attach distinct handlers for keyboard and mouse interfaces rather than overwriting interface descriptors.
- [ ] 2.4GHz wireless network adapter is enumerated, link status is determined, and packets can be exchanged through the kernel network stack.
- [ ] The `usb` shell command displays human-readable information about all active host controllers, ports, and connected 2.4GHz wireless devices.
