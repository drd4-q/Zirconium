## 2026-09-20T05:59:46Z

You are Explorer 2 for the Survey phase of the Zirconium project.
Your working directory is `/home/dr4d/Zirconium/.agents/explorer_survey_2`.
The project root is `/home/dr4d/Zirconium`.

CRITICAL INSTRUCTIONS:
1. You MUST read `/home/dr4d/Zirconium/.agents/ORIGINAL_REQUEST.md` before doing anything else.
2. Read `/home/dr4d/Zirconium/AGENTS.md` and `/home/dr4d/Zirconium/TODO.md`.
3. Investigate the requirements and architecture for complete USB Host Controller support across xHCI, EHCI, and UHCI:
   - Examine `src/drivers/pci.zig` for PCI device discovery, class/subclass/prog-if matching, MMIO bar mapping, and command register configuration (Bus Master, Memory Space, I/O space enable).
   - Check existing device initialization sequence in `src/main.zig`, `src/kernel/init.zig`, `src/shell.zig`, and any existing USB references (e.g. `create_usb.sh`).
   - Architect xHCI (USB 3.x, class 0x0C, subclass 0x03, prog-if 0x30): Capability & Operational MMIO registers, Doorbell registers, Runtime registers, DCBAA, Command Ring, Event Ring with ERST, Transfer Rings, Slot/Endpoint Contexts, Port Status and Control (PORTSC), reset sequencing, speed detection.
   - Architect EHCI (USB 2.0, class 0x0C, subclass 0x03, prog-if 0x20): Capability & Operational MMIO, Periodic & Asynchronous Transfer lists, Queue Heads (QH) and Queue Element Transfer Descriptors (qTD), PORTSC, port reset, companion controller routing.
   - Architect UHCI (USB 1.1, class 0x0C, subclass 0x03, prog-if 0x00): I/O port base registers, Frame List (1024 entries), QH and TD structures, PORTSC1/PORTSC2, port reset.
   - Design a unified USB host controller interface (`UsbController` / `UsbHost`) and standard USB device enumeration pipeline (Set Address, Get Descriptor, Set Configuration, endpoint discovery).
   - Detail DMA memory allocation needs using PMM for physically contiguous, page-aligned buffers.
   - Design the transfer queue and async polling/interrupt scheduling mechanism so transfers run without hanging or blocking the kernel.
4. Write your comprehensive report to `/home/dr4d/Zirconium/.agents/explorer_survey_2/survey_report.md`.
5. Write your handoff report to `/home/dr4d/Zirconium/.agents/explorer_survey_2/handoff.md`.
6. Send a message to your parent using `send_message` with a summary of findings and the path to your handoff report.
Remember: You are read-only. Do not modify kernel source code.
