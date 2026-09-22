## 2026-09-20T05:59:46Z

You are Explorer 3 for the Survey phase of the Zirconium project.
Your working directory is `/home/dr4d/Zirconium/.agents/explorer_survey_3`.
The project root is `/home/dr4d/Zirconium`.

CRITICAL INSTRUCTIONS:
1. You MUST read `/home/dr4d/Zirconium/.agents/ORIGINAL_REQUEST.md` before doing anything else.
2. Read `/home/dr4d/Zirconium/AGENTS.md` and `/home/dr4d/Zirconium/TODO.md`.
3. Investigate USB 2.4GHz wireless peripherals, Wi-Fi networking, shell diagnostics, and test verification:
   - Existing Input Queues & GUI: Examine `src/drivers/keyboard.zig`, `src/drivers/mouse.zig`, `src/system/gui.zig`, and `src/shell.zig`. How are keyboard scancodes/characters and mouse motion/button packets buffered, and how can USB HID events be seamlessly routed into both VGA text shell and GUI?
   - USB 2.4GHz Wireless HID Peripherals: Single and composite multi-interface dongles (such as Logitech Unifying and generic 2.4GHz keyboard/mouse combos). Analyze USB HID class (0x03), Boot Protocol vs Report Protocol, multi-interface descriptor parsing (ensuring Interface 0 keyboard and Interface 1 mouse both get separate active interrupt transfer endpoints rather than overwriting each other).
   - USB 2.4GHz Wireless Network Adapters: Realtek 802.11 b/g/n chipsets (RTL8188EU, RTL8192CU). Device identification (VID/PID), bulk IN/OUT transfer endpoints, register/EEPROM initialization, MAC frame transmission and reception, and integration with `src/net/mod.zig` and the kernel network dispatch loop.
   - Diagnostics & Shell Utilities: Requirements for the `usb` shell command (listing controllers, ports, attached wireless devices, endpoint descriptors, transfer statistics). Check how shell commands are implemented in `src/programs/` and registered in `src/shell.zig`.
   - Build & Testing Harness: Analyze `build.zig`, `tools/test_runner.py`, and `run.sh`. How QEMU options (`-device qemu-xhci`, `-device usb-ehci`, `-device ich9-usb-uhci1`, `-device usb-kbd`, `-device usb-mouse`, etc.) can be used for automated and integration testing without breaking existing test markers.
4. Write your comprehensive report to `/home/dr4d/Zirconium/.agents/explorer_survey_3/survey_report.md`.
5. Write your handoff report to `/home/dr4d/Zirconium/.agents/explorer_survey_3/handoff.md`.
6. Send a message to your parent using `send_message` with a summary of findings and the path to your handoff report.
Remember: You are read-only. Do not modify kernel source code.
