# Comprehensive USB Host Controller & Subsystem Architecture Survey Report (xHCI, EHCI, UHCI)

**Author:** Explorer 2 (USB Subsystem & Host Controllers Architecture Explorer)  
**Target:** Zirconium Bare-Metal x86_64 Kernel  
**Date:** 2026-09-20  
**Scope:** Complete architecture, requirements, and design for full USB host controller support (xHCI, EHCI, UHCI), unified controller abstraction, device enumeration pipeline, DMA memory management, and asynchronous non-blocking transfer scheduling.

---

## 1. Executive Summary

Zirconium is a bare-metal 64-bit x86 kernel written in Zig (0.16.0), featuring identity-mapped memory (64 GB mapped with 2MB huge pages in `src/entry.S`), a physical memory manager (`src/kernel/pmm.zig`), a virtual memory manager (`src/kernel/vmm.zig`), ring-3 user space, a custom TCP/IP stack over e1000, and a VGA-text/framebuffer shell.

An initial USB implementation exists in `src/drivers/usb.zig` and `src/programs/usb.zig`. However, an architectural audit reveals:
1. **Controller Coverage is Incomplete:** Only a rudimentary UHCI driver is implemented. For EHCI and xHCI, `src/drivers/usb.zig` lines 751–765 merely inspect PCI BAR0 and print mock/fake connected port strings without executing any hardware initialization, register setup, or queue scheduling.
2. **UHCI Implementation Suffers from Singletons and Blocking Waits:** The current UHCI code relies on static global arrays (`frame_list`, `ctrl_qh`, `ctrl_tds`), prohibiting multiple controllers. Control transfers execute blocking spin-waits with `delayMs(10)` (up to 500 ms per transfer), which blocks the entire kernel if a transfer stalls or a device is unplugged.
3. **Composite Devices are Broken:** The device model (`UsbDevice`) stores a single `dev_type`, `interface_num`, and `ep_in`. When enumerating composite wireless dongles (e.g., Logitech Unifying or generic 2.4GHz keyboard/mouse combos), Interface 1 overwrites Interface 0, dropping keyboard or mouse input.
4. **No Transfer Engine for Bulk/Interrupt Devices:** Endpoints are not tracked beyond a single hardcoded interrupt IN endpoint. There is no abstraction for Bulk IN/OUT endpoints required for USB 2.4GHz Wi-Fi adapters (RTL8188EU / RTL8192CU) or USB mass storage.

This report establishes the complete architecture to support xHCI, EHCI, and UHCI concurrently, provide a unified `UsbController` abstraction, handle multi-interface composite devices, manage DMA memory via PMM, and execute asynchronous non-blocking transfers.

---

## 2. PCI Discovery & Resource Configuration

### 2.1 PCI Class, Subclass, and Prog-IF Matching
In PCI 3.0 / PCI Express specifications, USB host controllers belong to:
- **Base Class:** `0x0C` (Serial Bus Controller)
- **Subclass:** `0x03` (USB Controller)
- **Programming Interface (Prog-IF):**
  - `0x00`: **UHCI** (Universal Host Controller Interface, USB 1.1)
  - `0x10`: **OHCI** (Open Host Controller Interface, USB 1.1)
  - `0x20`: **EHCI** (Enhanced Host Controller Interface, USB 2.0)
  - `0x30`: **xHCI** (Extensible Host Controller Interface, USB 3.x / USB 3.2)

### 2.2 BAR Mapping Strategy
`src/drivers/pci.zig` provides `readBar(bus, dev, func, bar_num)` and `getBarSize(bus, dev, func, bar_num)`. However, controller types differ fundamentally in BAR assignments:

1. **UHCI (Prog-IF 0x00):**
   - Base address is in **BAR4** (PCI configuration offset `0x20`).
   - Bit 0 is `1` (I/O Space).
   - I/O Base address: `bar4 & 0xFFFC` (16-bit port I/O). Size is 32 bytes (ports `0x00`..`0x1F`).
   - Commands use x86 port I/O instructions (`inb`, `outb`, `inw`, `outw`, `inl`, `outl`).

2. **EHCI (Prog-IF 0x20):**
   - Base address is in **BAR0** (PCI configuration offset `0x10`).
   - Bit 0 is `0` (Memory Space). Bits 2:1 are `00` (32-bit addressable MMIO).
   - Base address: `bar0 & 0xFFFFFFF0`. Size is typically 1024 bytes.
   - Operational registers begin at offset `CAPLENGTH` (read from MMIO byte offset 0).

3. **xHCI (Prog-IF 0x30):**
   - Base address is in **BAR0** (PCI configuration offset `0x10`).
   - Bit 0 is `0` (Memory Space). Bits 2:1 are `10` (64-bit addressable MMIO).
   - **Crucial:** BAR0 provides the low 32 bits, while BAR1 (offset `0x14`) provides the high 32 bits!
   - 64-bit MMIO Base:
     ```zig
     const bar0 = pci.readBar(bus, dev, func, 0);
     const bar1 = pci.readBar(bus, dev, func, 1);
     const mmio_base: usize = @intCast((@as(u64, bar1) << 32) | (bar0 & 0xFFFFFFF0));
     ```
   - In Zirconium, `src/entry.S` identity-maps 64 GB of physical space (`0x0`..`0x0FFFFFFFFF`). Because PCI MMIO on x86 platforms sits either below 4GB (typically in `0xC0000000`..`0xFEFFFFFF`) or in the 64-bit window below 64GB, `mmio_base` can be dereferenced directly using volatile pointer access.
   - If hardware maps BAR0 above 64 GB, `vmm.mapPage` would map the MMIO pages; however, for all QEMU and modern standard BIOS configurations, it falls within identity-mapped space.

### 2.3 PCI Command Register Configuration
Every USB host controller acts as a DMA Bus Master. Before accessing registers:
- Read PCI Command Register (offset `0x04`).
- Set Bit 0 (`I/O Space Enable`) — mandatory for UHCI.
- Set Bit 1 (`Memory Space Enable`) — mandatory for EHCI & xHCI.
- Set Bit 2 (`Bus Master Enable`) — mandatory for all controllers to perform DMA.
- Set Bit 10 (`Interrupt Disable`) to 1 if using pure polling mode, or 0 if routing INTx.
- Existing helper `pci.enableBusMaster(bus, dev, func)` sets `(1 << 2) | (1 << 1) | 1`, satisfying these requirements.

---

## 3. xHCI (USB 3.x) Architecture & Design

xHCI replaces the legacy host/companion architecture. It natively manages USB 1.1, 2.0, and 3.x ports without companion controllers, using a hardware-managed device slot and endpoint context model.

### 3.1 Register Spaces
xHCI MMIO consists of four main register spaces:

| Space | Offset | Key Registers / Fields |
|---|---|---|
| **Capability** | `mmio_base + 0x00` | `CAPLENGTH` (1B, offset to Operational regs), `HCIVERSION` (2B), `HCSPARAMS1` (MaxSlots, MaxIntrs, MaxPorts), `HCSPARAMS2` (MaxScratchpadBufs), `HCCPARAMS1` (CSZ context size bit 2, xECP extended cap bit 31:16), `DBOFF` (Doorbell offset), `RTSOFF` (Runtime offset) |
| **Operational** | `mmio_base + CAPLENGTH` | `USBCMD` (R/S bit 0, HCRST bit 1, INTE bit 2), `USBSTS` (HCH bit 0, HSE bit 2, CNR bit 11), `PAGESIZE` (4KB bit 0), `DNCTRL`, `CRCR` (Command Ring Control, 64-bit), `DCBAAP` (Device Context Base Address Array Pointer, 64-bit), `CONFIG` (MaxSlotsEn, bits 7:0), `PORTSC[1..MaxPorts]` (offset `0x400 + (port-1)*0x10`) |
| **Runtime** | `mmio_base + RTSOFF` | `MFINDEX` (offset 0x00), Interrupter 0: `IMAN` (offset 0x20, IP bit 0, IE bit 1), `IMOD` (offset 0x24), `ERSTSZ` (offset 0x28, segment count), `ERSTBA` (offset 0x30, 64-bit table phys addr), `ERDP` (offset 0x38, 64-bit dequeue pointer, EHB bit 3) |
| **Doorbell** | `mmio_base + DBOFF` | Array of 32-bit registers: Doorbell 0 = Host Controller (Command Ring), Doorbell 1..MaxSlots = Device Slots (Bits 7:0 = Target Endpoint ID, bits 31:16 = Stream ID) |

### 3.2 BIOS Handoff (USBLEGSUP)
On bare metal, the BIOS SMM driver owns the xHCI controller at boot:
1. Check `HCCPARAMS1.xECP` (bits 31:16). If non-zero, calculate extended capability offset: `ext_cap = mmio_base + (xECP << 2)`.
2. Walk capability list until Cap ID == `1` (USB Legacy Support).
3. Read `USBLEGSUP` (offset 0): Bit 16 is `HC OS Owned Semaphore`, Bit 24 is `HC BIOS Owned Semaphore`.
4. Write `1` to Bit 16 (`OS Owned`).
5. Poll Bit 24 (`BIOS Owned`) until cleared to `0` (with a 1000 ms timeout).
6. Clear SMIs in `USBLEGCTLSTS` (offset 4).

### 3.3 Controller Reset & Initialization Sequence
1. **Halt Controller:** Read `USBSTS`. If `HCH` (bit 0) is 0, clear `USBCMD.R_S` (bit 0). Wait until `USBSTS.HCH == 1`.
2. **Reset Controller:** Write `1` to `USBCMD.HCRST` (bit 1). Wait until `USBCMD.HCRST == 0`.
3. **Wait for Ready:** Wait until `USBSTS.CNR` (bit 11, Controller Not Ready) clears to `0`.
4. **Configure Max Device Slots:** Read `HCSPARAMS1.MaxSlots`. Set `CONFIG.MaxSlotsEn = min(MaxSlots, 16)`.
5. **Setup DCBAA (Device Context Base Address Array):**
   - Allocate a 64-byte aligned table of `(MaxSlotsEn + 1)` 64-bit pointers.
   - Check `HCSPARAMS2.MaxScratchpadBufs`. If > 0:
     - Allocate an array of `MaxScratchpadBufs` 64-bit physical pointers.
     - Allocate a 4KB physical page for each scratchpad buffer and record its physical address.
     - Set `dcbaa[0] = scratchpad_array_phys`.
   - Write physical address of DCBAA to `DCBAAP` (64-bit register).
6. **Setup Command Ring:**
   - Allocate 4KB page (holds 256 TRBs of 16 bytes each).
   - Set TRB 255 as a Link TRB (Type 6): parameter = `cmd_ring_phys`, control = `(6 << 10) | (1 << 1)` (TC: Toggle Cycle).
   - Set Producer Cycle State = 1, Enqueue Index = 0.
   - Write `CRCR = cmd_ring_phys | 1` (RCS = 1).
7. **Setup Event Ring:**
   - Allocate 4KB page for Event Ring (holds 256 TRBs).
   - Allocate 64-byte aligned Event Ring Segment Table (ERST) with 1 entry:
     - `entry.base = event_ring_phys`, `entry.size = 256`, `entry.reserved = 0`.
   - Set Consumer Cycle State = 1, Dequeue Index = 0.
   - Write Runtime Register `ERSTSZ = 1`.
   - Write Runtime Register `ERSTBA = erst_phys`.
   - Write Runtime Register `ERDP = event_ring_phys | (1 << 3)` (EHB clear).
   - Write Runtime Register `IMAN = 2` (Interrupt Enable).
8. **Start Controller:**
   - Write `USBCMD = (1 << 0) | (1 << 2)` (Run/Stop = 1, Interrupter Enable = 1).
   - Wait until `USBSTS.HCH == 0`.

### 3.4 Transfer Request Blocks (TRBs) & Ring Management
All xHCI communication uses 16-byte TRBs:
```
Offset  Size  Field
0x00    8B    Parameter (physical buffer address or command-specific parameter)
0x08    4B    Status (transfer length, completion code, residual count)
0x0C    4B    Control (Cycle Bit [0], TC [1], ISP [2], CH [4], IOC [5], IDT [6], TRB Type [15:10])
```

- **Command TRBs:**
  - `Enable Slot` (Type 9): Returns assigned `SlotID` via Command Completion Event.
  - `Address Device` (Type 11): Points to Input Context; commands controller to configure EP0 and assign address.
  - `Configure Endpoint` (Type 12): Configures non-control endpoints (Interrupt IN, Bulk IN/OUT).
  - `Evaluate Context` (Type 13): Updates max packet size or slot parameters.
- **Transfer TRBs (on Endpoint Transfer Rings):**
  - `Setup Stage` (Type 2): Immediate data holding 8-byte `UsbSetupPacket`.
  - `Data Stage` (Type 3): Points to buffer, specifies direction (IN/OUT).
  - `Status Stage` (Type 4): Direction opposite of data stage, IOC=1.
  - `Normal` (Type 1): Used for Bulk and Interrupt transfers.
- **Event TRBs (read from Event Ring):**
  - `Transfer Event` (Type 32): TRB pointer, completion code, SlotID, Endpoint ID.
  - `Command Completion Event` (Type 33): Command TRB pointer, completion code, SlotID.
  - `Port Status Change Event` (Type 34): Port ID that triggered connect/reset change.

### 3.5 Context Size & Layout (CSZ = 0 vs 1)
`HCCPARAMS1` bit 2 (`CSZ`) determines context structure size:
- `CSZ == 0`: 32 bytes per context (Slot Context = 32B, Endpoint Context = 32B).
- `CSZ == 1`: 64 bytes per context (Slot Context = 64B, Endpoint Context = 64B).
- Input Context layout:
  - Input Control Context (32B or 64B): `drop_flags` at dword 0, `add_flags` at dword 1.
  - Slot Context (32B or 64B).
  - 31 Endpoint Contexts (EP0, EP1-OUT, EP1-IN, etc.).
- The driver MUST check `CSZ` dynamically to compute context offsets:
  `ctx_stride = if ((hccparams1 & (1 << 2)) != 0) 64 else 32`.

### 3.6 PORTSC and Reset Sequencing
Each port register `PORTSC` (`0x400 + (port-1)*0x10`) controls port state:
- `CCS` (bit 0): Current Connect Status.
- `PED` (bit 1): Port Enabled/Disabled.
- `PR` (bit 4): Port Reset.
- `PLS` (bits 8:5): Port Link State (0 = U0, 7 = Polling, 3 = U3/Suspend).
- `PP` (bit 9): Port Power.
- `Speed` (bits 13:10): 1 = Full (12M), 2 = Low (1.5M), 3 = High (480M), 4 = SuperSpeed (5G), 5 = SuperSpeedPlus (10G).
- **Reset Sequence:**
  - On USB 3.x ports: Connection triggers hardware auto-training to Link State U0; `PED` automatically becomes 1.
  - On USB 2.0 ports: When `CCS == 1` and `PED == 0`, write `PORTSC = (portsc & ~RW1C_MASK) | (1 << 4) | (1 << 9)` (assert `PR=1`, keep `PP=1`).
  - Do NOT write 1s to R/W1C change bits (`CSC` bit 17, `PEC` bit 18, `WRC` bit 19, `PRC` bit 21, `PLC` bit 22) during command writes unless explicitly clearing them!
  - Wait for `PRC` (bit 21) or `PR == 0` and `PED == 1`. Read bits 13:10 for speed.

---

## 4. EHCI (USB 2.0) Architecture & Design

EHCI provides High-Speed (480 Mbps) connectivity. When low-speed or full-speed devices connect, EHCI routes them to companion controllers unless an integrated TT (Transaction Translator) hub is present.

### 4.1 Register Layout
- **Capability Registers:**
  - `CAPLENGTH` (offset 0x00, 1 byte): Offset to operational registers.
  - `HCSPARAMS` (offset 0x04, 4 bytes): `N_PORTS` (bits 3:0), `N_CC` (companion controllers, bits 15:12).
  - `HCCPARAMS` (offset 0x08, 4 bytes): `EECP` (EHCI Extended Capabilities Pointer, bits 15:8).
- **Operational Registers (`mmio_base + CAPLENGTH`):**
  - `USBCMD` (offset 0x00, 4 bytes): `RS` (bit 0), `HCRESET` (bit 1), `PSE` (Periodic Schedule Enable, bit 4), `ASE` (Async Schedule Enable, bit 5).
  - `USBSTS` (offset 0x04, 4 bytes): `USBINT` (bit 0), `USBERRINT` (bit 1), `PCD` (bit 2), `HCHalted` (bit 12).
  - `PERIODICLISTBASE` (offset 0x14, 4 bytes): Physical address of 4KB-aligned 1024-entry Periodic Frame List.
  - `ASYNCLISTADDR` (offset 0x18, 4 bytes): Physical address of circular Queue Head list for Control/Bulk.
  - `CONFIGFLAG` (offset 0x40, 4 bytes): **Bit 0 (`CF`) must be set to `1`!** If `CF == 0`, all root ports are routed to companion UHCI/OHCI controllers!
  - `PORTSC[1..N_PORTS]` (offset `0x44 + (port-1)*4`):
    - `CCS` (bit 0): Current Connect Status.
    - `PE` (bit 2): Port Enable.
    - `PR` (bit 8): Port Reset. Write 1 to assert reset; hold for 50ms; write 0 to terminate.
    - `Line Status` (bits 11:10): `01b` = Low-Speed (K-state).
    - `PP` (bit 12): Port Power (write 1 to power port).
    - `PO` (bit 13): Port Owner (write 1 to release port to companion controller).

### 4.2 Descriptors: Queue Heads (QH) & Transfer Descriptors (qTD)
- **Queue Head (QH, 32-byte aligned, 68 bytes total):**
  - `horizontal_link` (u32): Points to next QH (bit 0 = Terminate, bit 1 = Type: 01b = QH).
  - `ep_characteristics` (u32): Device Address (bits 6:0), Endpoint (bits 11:8), Speed (bits 13:12: 10b=High), Data Toggle Control (bit 14), Head of Reclamation (bit 15), Max Packet (bits 26:16).
  - `ep_capabilities` (u32): Interrupt schedule mask (s-mask, bits 7:0), split completion mask (c-mask, bits 15:8), Mult (bits 31:30).
  - `current_qtd` (u32): Hardware-updated pointer to active qTD.
  - `overlay_qtd`: 32-byte working cache matching qTD layout.
- **Queue Element Transfer Descriptor (qTD, 32-byte aligned):**
  - `next_qtd` (u32): Physical address of next qTD (bit 0 = 1 for terminate).
  - `alt_next_qtd` (u32): Alternate next qTD on short packet or error.
  - `token` (u32):
    - Bit 7: `Active` (1 = hardware owned, 0 = completed).
    - Bits 9:8: `PID` (`00b` = OUT, `01b` = IN, `10b` = SETUP).
    - Bits 11:10: `CERR` (Error counter = 3).
    - Bit 15: `IOC` (Interrupt On Completion).
    - Bits 30:16: `Total Bytes` (up to 16 KB..20 KB).
    - Bit 31: `Data Toggle` (0 = DATA0, 1 = DATA1).
  - `buffer_pointers`: `[5]u32` (physical addresses of 4KB pages; buffer 0 contains byte offset, buffers 1..4 hold page frame addresses).

### 4.3 Schedules & Companion Routing
1. **Asynchronous Schedule:** Circular linked list of QHs (`ASYNCLISTADDR`). Head QH has `H` bit (15) set. Used for Control transfers (EP0) and Bulk transfers (Wi-Fi / Mass Storage). Enabled via `USBCMD.ASE = 1`.
2. **Periodic Schedule:** 1024-entry array of 32-bit pointers (`PERIODICLISTBASE`). Entries point to interrupt QHs (for keyboard/mouse). Enabled via `USBCMD.PSE = 1`.
3. **Companion Routing:** If `PORTSC.LineStatus == 01b` (Low-speed device) or if a Full-speed device connects to an EHCI controller with companion controllers (`HCSPARAMS.N_CC > 0`), set `PORTSC.PO = 1`. The port instantly switches to the companion UHCI controller!

---

## 5. UHCI (USB 1.1) Architecture & Design

UHCI provides Low-Speed (1.5 Mbps) and Full-Speed (12 Mbps) operation, configured via x86 I/O ports.

### 5.1 Register Map (BAR4 I/O Space)
- `USBCMD` (offset 0x00, 2 bytes): `RS` (bit 0), `HCRESET` (bit 1), `GRESET` (bit 2), `CF` (bit 6 = 1), `MAXP` (bit 7 = 1 for 64-byte max packet).
- `USBSTS` (offset 0x02, 2 bytes): `USBINT` (bit 0), `USBEI` (bit 1), `HCHalted` (bit 5).
- `USBINTR` (offset 0x04, 2 bytes): Interrupt enable (set to 0 for polling).
- `FRNUM` (offset 0x06, 2 bytes): Current 1ms frame index (0..1023).
- `FRBASEADD` (offset 0x08, 4 bytes): 4KB-aligned physical address of 1024-entry Frame List.
- `SOFMOD` (offset 0x0C, 1 byte): 0x40 (1ms SOF timing).
- `PORTSC1` (offset 0x10, 2 bytes) & `PORTSC2` (offset 0x12, 2 bytes):
  - `CCS` (bit 0): Current Connect Status.
  - `CSC` (bit 1): Connect Status Change (write 1 to clear).
  - `PE` (bit 2): Port Enable (1 = enabled).
  - `LSDA` (bit 8): Low Speed Device Attached (1 = 1.5 Mbps, 0 = 12 Mbps).
  - `PR` (bit 9): Port Reset (write 1 to assert reset, wait 50ms, write 0 to deassert, then enable port).

### 5.2 Descriptors & Schedule Structure
- **Frame List:** 1024 32-bit physical pointers (`[1024]u32 align(4096)`). Bit 0 = 1 (Terminate), Bit 1 = 1 (points to QH), Bit 1 = 0 (points to TD).
- **Queue Head (QH, 16-byte aligned):**
  - `head_link` (u32): Physical address of next QH (bit 1 = 1, bit 0 = terminate).
  - `element_link` (u32): Physical address of first TD or next QH (bit 1 = 1 if QH, 0 if TD, bit 0 = terminate).
- **Transfer Descriptor (TD, 16-byte aligned):**
  - `link` (u32): Points to next TD (bit 2 = Depth/Breadth, bit 1 = QH/TD, bit 0 = Terminate).
  - `ctrl_status` (u32): Bit 23 = `Active`, Bit 26 = `LowSpeed` (LS), Bits 28:27 = `C_ERR` (3), Bit 29 = `SPD` (Short Packet Detect), Bits 22:17 = Error status, Bits 10:0 = Actual Length.
  - `token` (u32): Bits 7:0 = `PID` (`0x7D`=SETUP, `0x69`=IN, `0xE1`=OUT), Bits 14:8 = `DevAddr`, Bits 18:15 = `Endpoint`, Bit 19 = `Toggle`, Bits 31:21 = `MaxLen` (len - 1).
  - `buffer` (u32): 32-bit physical address of data buffer.

### 5.3 Audit of Current `src/drivers/usb.zig` and Required Fixes
1. **Remove Global Static Arrays:** `frame_list`, `ctrl_qh`, `ctrl_tds`, `ctrl_buf` must belong to per-controller instances (`UhciController`), dynamically allocated via `pmm.allocPage()`.
2. **Fix Port Enable Logic:** In UHCI, clearing port reset (`PR=0`) often disables the port. The driver must explicitly re-enable the port (`PE=1`) and verify `PE==1` before starting enumeration.
3. **Multi-device Scheduling:** Instead of linking one global list that overwrites frame entries, each device's QH must be inserted into an interrupt schedule cascade with defined polling intervals (1ms, 8ms, 32ms).
4. **Non-blocking Control Transfers:** Replace the blocking `delayMs(10)` loop with a non-blocking state machine or polling check.

---

## 6. Unified USB Host Controller Abstraction

To manage xHCI, EHCI, and UHCI transparently, the USB subsystem requires a clean polymorphic architecture.

### 6.1 Common Enums & Data Types

```zig
pub const UsbSpeed = enum(u8) {
    low = 0,               // 1.5 Mbps (USB 1.1)
    full = 1,              // 12 Mbps (USB 1.1 / 2.0)
    high = 2,              // 480 Mbps (USB 2.0)
    super_speed = 3,       // 5 Gbps (USB 3.0)
    super_speed_plus = 4,  // 10 Gbps (USB 3.1)

    pub fn name(self: UsbSpeed) []const u8 {
        return switch (self) {
            .low => "Low-Speed (1.5 Mbps)",
            .full => "Full-Speed (12 Mbps)",
            .high => "High-Speed (480 Mbps)",
            .super_speed => "SuperSpeed (5 Gbps)",
            .super_speed_plus => "SuperSpeed+ (10 Gbps)",
        };
    }
};

pub const UsbTransferType = enum(u8) {
    control = 0,
    interrupt = 1,
    bulk = 2,
    isochronous = 3,
};

pub const UsbTransferStatus = enum(u8) {
    idle,
    pending,
    in_progress,
    completed,
    stalled,
    nak,
    babble,
    error_crc,
    error_timeout,
    error_io,
};

pub const UsbSetupPacket = extern struct {
    bmRequestType: u8,
    bRequest: u8,
    wValue: u16,
    wIndex: u16,
    wLength: u16,
};
```

### 6.2 Endpoint & Interface Model (Composite Device Support)

To solve Requirement R3 (supporting composite devices such as wireless keyboard/mouse combos without overwriting interface descriptors), endpoints and interfaces must be distinct entities:

```zig
pub const MAX_DEVICE_ENDPOINTS: usize = 8;
pub const MAX_DEVICE_INTERFACES: usize = 4;

pub const UsbEndpoint = struct {
    ep_addr: u8,               // Bits 3:0 = num, Bit 7 = direction (1=IN, 0=OUT)
    transfer_type: UsbTransferType,
    max_packet_size: u16,
    interval_ms: u8,
    toggle: u1 = 0,
    active: bool = false,
    
    // Controller-specific handle / index
    hw_endpoint_id: u8 = 0,    // xHCI DCI (1..31)
    hw_queue_ptr: usize = 0,   // EHCI / UHCI QH pointer
};

pub const UsbInterface = struct {
    interface_num: u8,
    class_code: u8,            // 0x03 = HID, 0x02 = CDC, 0xFF = Vendor (e.g. Wi-Fi)
    subclass_code: u8,         // 0x01 = Boot Interface (for HID)
    protocol_code: u8,         // 0x01 = Keyboard, 0x02 = Mouse
    driver_type: UsbDriverType, // .keyboard, .mouse, .wifi, .none
    endpoints: [4]UsbEndpoint,
    endpoint_count: usize = 0,
    
    // Per-interface input state buffers
    report_buf: [64]u8 = [_]u8{0} ** 64,
    prev_report: [64]u8 = [_]u8{0} ** 64,
    report_len: usize = 0,
};

pub const UsbDevice = struct {
    active: bool = false,
    ctrl_id: u8 = 0,
    port_num: u8 = 0,
    address: u8 = 0,
    speed: UsbSpeed = .full,
    vendor_id: u16 = 0,
    product_id: u16 = 0,
    ep0_max_packet: u16 = 8,
    num_configurations: u8 = 1,
    
    // xHCI specific
    slot_id: u8 = 0,
    
    // Interfaces (Composite device support)
    interfaces: [MAX_DEVICE_INTERFACES]UsbInterface = undefined,
    interface_count: usize = 0,
    
    // Device-level stats
    total_packets_recv: u32 = 0,
    total_packets_sent: u32 = 0,
};
```

### 6.3 Unified UsbController Virtual Dispatch / Tagged Union

```zig
pub const UsbControllerVTable = struct {
    poll: *const fn (ctx: *anyopaque) void,
    checkPorts: *const fn (ctx: *anyopaque) void,
    controlTransfer: *const fn (
        ctx: *anyopaque,
        dev: *UsbDevice,
        setup: *const UsbSetupPacket,
        data: ?[]u8,
        is_in: bool,
    ) UsbTransferStatus,
    setupEndpoint: *const fn (
        ctx: *anyopaque,
        dev: *UsbDevice,
        ep: *UsbEndpoint,
    ) bool,
    queueAsyncTransfer: *const fn (
        ctx: *anyopaque,
        dev: *UsbDevice,
        ep: *UsbEndpoint,
        buffer: []u8,
        len: usize,
    ) bool,
    pollAsyncTransfer: *const fn (
        ctx: *anyopaque,
        dev: *UsbDevice,
        ep: *UsbEndpoint,
    ) UsbTransferStatus,
};

pub const UsbController = struct {
    id: u8,
    ctrl_type: UsbControllerType,
    bus: u8,
    dev: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    io_base: u16,
    mmio_base: usize,
    num_ports: u8,
    ports: [16]UsbPortStatus,
    
    ctx: *anyopaque,
    vtable: *const UsbControllerVTable,
};
```

---

## 7. Standard USB Device Enumeration Pipeline

Enumeration must follow the USB 2.0 / USB 3.x specifications reliably without race conditions:

```
[Port Connect Detected]
         │
         ▼
[Port Reset & Debounce] ──── (50ms reset assertion -> 20ms recovery)
         │
         ▼
[Speed Detection] ────────── (Low, Full, High, SuperSpeed)
         │
         ▼
[Controller Slot / EP0 Setup]
  ├── xHCI: Issue Enable Slot Command -> Obtain SlotID
  └── EHCI/UHCI: Set up EP0 address 0 in temporary QH
         │
         ▼
[Read First 8 Bytes of Device Descriptor] (GET_DESCRIPTOR, Device, Length 8)
  └── Extract bMaxPacketSize0 (8, 16, 32, 64, or 512 bytes)
         │
         ▼
[Assign Device Address]
  ├── xHCI: Issue Address Device Command (sets slot context + internal address)
  └── EHCI/UHCI: Issue SET_ADDRESS(new_addr) -> Wait 20ms recovery
         │
         ▼
[Read Full 18-Byte Device Descriptor]
  └── Extract idVendor, idProduct, bDeviceClass, bNumConfigurations
         │
         ▼
[Read 9-Byte Configuration Descriptor Header]
  └── Extract wTotalLength (length of full descriptor tree)
         │
         ▼
[Read Full Configuration Tree (wTotalLength)]
  └── Parse: Configuration Descriptor
             ├── Interface Descriptor 0 (e.g. Keyboard)
             │     ├── HID Descriptor
             │     └── Endpoint Descriptor (Interrupt IN)
             ├── Interface Descriptor 1 (e.g. Mouse)
             │     ├── HID Descriptor
             │     └── Endpoint Descriptor (Interrupt IN)
             └── Interface Descriptor 2 (e.g. Wi-Fi / Vendor)
                   ├── Endpoint Descriptor (Bulk IN)
                   └── Endpoint Descriptor (Bulk OUT)
         │
         ▼
[SET_CONFIGURATION (1)]
         │
         ▼
[Configure Endpoints in Hardware]
  ├── xHCI: Issue Configure Endpoint Command (input context with EP contexts)
  ├── EHCI: Insert QHs into Asynchronous and Periodic Frame Lists
  └── UHCI: Insert QHs and TDs into 1024-entry Frame List
         │
         ▼
[Protocol Configuration & Driver Attachment]
  ├── If HID: SET_PROTOCOL(0) [Boot], SET_IDLE(0) [Report on change]
  ├── If Wi-Fi: Initialize RTL8188EU/RTL8192CU registers & firmware
  └── Arm asynchronous transfer queues for active endpoints
```

---

## 8. DMA Memory Allocation & Management (PMM)

### 8.1 Hardware Alignment & Addressing Constraints
All USB controllers bypass the CPU MMU and read physical memory via PCI Bus Master DMA. Descriptors and transfer buffers have strict hardware alignment and addressing limits:

| Controller | Data Structure | Hardware Alignment | Addressing Limit | Notes |
|---|---|---|---|---|
| **UHCI** | Frame List | **4096 bytes** | **< 4 GB (32-bit)** | Exactly 1024 32-bit pointers (4KB) |
| **UHCI** | Queue Head (QH) | **16 bytes** | **< 4 GB (32-bit)** | 16 bytes total |
| **UHCI** | Transfer Descriptor (TD) | **16 bytes** | **< 4 GB (32-bit)** | 16 bytes total |
| **EHCI** | Periodic Frame List | **4096 bytes** | **< 4 GB (32-bit)** | 1024 32-bit pointers (4KB) |
| **EHCI** | Queue Head (QH) | **32 bytes** | **< 4 GB (32-bit)** | 68 bytes total |
| **EHCI** | Transfer Descriptor (qTD)| **32 bytes** | **< 4 GB (32-bit)** | 32 bytes total |
| **xHCI** | DCBAA Table | **64 bytes** | 64-bit | (MaxSlots + 1) * 8 bytes |
| **xHCI** | Scratchpad Array | **64 bytes** | 64-bit | MaxScratchpadBufs * 8 bytes |
| **xHCI** | Scratchpad Buffers | **4096 bytes** | 64-bit | 4KB physical page each |
| **xHCI** | Command / Event Ring | **64 bytes** | 64-bit | Page-aligned (4KB) recommended |
| **xHCI** | ERST Table | **64 bytes** | 64-bit | 16 bytes per segment |
| **xHCI** | Input / Device Context | **64 bytes** | 64-bit | Size depends on CSZ (32B vs 64B) |
| **xHCI** | Transfer Rings | **64 bytes** | 64-bit | Page-aligned (4KB) per active EP |

### 8.2 Leveraging PMM and Identity Mapping
In Zirconium:
1. `src/kernel/pmm.zig:allocPage()` allocates one 4KB page, scanning physical memory from 1 MB upwards.
2. `pmm.allocPages(count)` allocates `count` physically contiguous 4KB pages.
3. Because `src/entry.S:57-111` identity-maps the first 64 GB with 2MB huge pages (`phys == virt`), any address returned by `pmm.allocPage()` can be directly dereferenced as a pointer `@ptrFromInt(phys_addr)` without page-table remapping.
4. Furthermore, because allocations begin above 1 MB and grow upward, early kernel allocations are strictly below 4GB, satisfying the 32-bit physical addressing requirements of UHCI and EHCI.

### 8.3 Recommended USB DMA Slab Allocator (`UsbDmaPool`)
Rather than burning an entire 4KB page for every 16-byte TD or 32-byte qTD, a dedicated `UsbDmaPool` should manage descriptors:
```zig
pub const UsbDmaPool = struct {
    page_phys: usize,
    used_offset: usize,

    pub fn init() ?UsbDmaPool {
        const page = pmm.allocPage() orelse return null;
        @memset(@as([*]u8, @ptrFromInt(page))[0..4096], 0);
        return UsbDmaPool{ .page_phys = page, .used_offset = 0 };
    }

    pub fn allocAligned(self: *UsbDmaPool, comptime T: type, alignment: usize) ?*T {
        const aligned = (self.used_offset + alignment - 1) & ~(alignment - 1);
        if (aligned + @sizeOf(T) > 4096) return null;
        self.used_offset = aligned + @sizeOf(T);
        return @ptrCast(@alignCast(@as([*]u8, @ptrFromInt(self.page_phys + aligned))));
    }

    pub fn getPhys(self: *const UsbDmaPool, ptr: *const anyopaque) u32 {
        return @intCast(@intFromPtr(ptr));
    }
};
```

---

## 9. Transfer Queue & Asynchronous Polling Mechanism

### 9.1 Eliminating Kernel Stalls & Busy-Waits
The primary flaw in the existing USB driver is blocking spin-waits. For example, during enumeration, if `uhciControlTransfer` fails to receive an answer, it executes `delayMs(10)` 50 times (500 ms delay with `hlt`).

To ensure fluid system performance (60 FPS GUI, responsive typing, and line-rate Wi-Fi packet processing):
1. **Zero Busy-Wait Transfers:**
   - Transfers are posted to controller rings/queues non-blockingly.
   - Status checking evaluates hardware completion flags (xHCI Event Ring TRB cycle bit, EHCI qTD `Active` bit 7, UHCI TD `Active` bit 23).
   - If active, the check returns immediately (`.in_progress`) without calling `delayMs` or halting the CPU.
2. **State-Machine Enumeration:**
   - Root port debounce, reset, and descriptor fetches are structured as state-machine steps indexed by timer ticks.
   - Example: Port reset asserts `PR=1` and sets `reset_end_tick = timer.ticks + 5` (50 ms). Subsequent poll ticks check if `timer.ticks >= reset_end_tick`, deassert reset, and transition to `GET_DEV_DESC_8`.
3. **Continuous Background Polling Integration:**
   - **Keyboard Poll:** `src/drivers/keyboard.zig:pollKey()` invokes `usb.poll()`. If a completed report is present, keystrokes are processed and the next interrupt transfer is re-armed in under 2 microseconds.
   - **Mouse Poll:** `src/drivers/mouse.zig:poll()` updates mouse position and button state from completed packets.
   - **Network Poll:** `src/net/mod.zig:poll()` (invoked in network wait loops and TCP socket processing) drains bulk IN completion buffers from USB Wi-Fi adapters.
   - **Scheduler Tick:** `src/kernel/scheduler.zig:scheduleTick()` (invoked at 100Hz from PIT IRQ0) polls root port connection changes and manages timeouts.

---

## 10. Architectural Comparison & Summary Table

| Feature | xHCI (USB 3.x) | EHCI (USB 2.0) | UHCI (USB 1.1) |
|---|---|---|---|
| **PCI Class/Sub/PI** | `0x0C` / `0x03` / `0x30` | `0x0C` / `0x03` / `0x20` | `0x0C` / `0x03` / `0x00` |
| **Register Interface**| 64-bit MMIO (BAR0 + BAR1) | 32-bit MMIO (BAR0) | 16-bit Port I/O (BAR4) |
| **Speeds Supported** | Low, Full, High, SuperSpeed, SS+ | High-Speed (480 Mbps) only | Low (1.5M), Full (12M) |
| **Port Routing** | Direct root port control | Routes Low/Full to companion | Dedicated root ports |
| **BIOS Handoff** | Extended Cap 1 (USBLEGSUP) | Extended Cap (EECP USBLEGSUP) | N/A (or SMM BIOS disable) |
| **Primary Queues** | Command Ring, Event Ring, EP Rings | Async List (QHs), Periodic (1024) | Frame List (1024), QHs, TDs |
| **Transfer Descriptors**| 16-byte TRB | 32-byte qTD | 16-byte TD |
| **Device Addressing** | Slot ID + Address Device Command | Software assigned SET_ADDRESS | Software assigned SET_ADDRESS |
| **Context Model** | Device/Slot/Endpoint Contexts (CSZ) | Queue Head Overlay Cache | Queue Head Element Links |
| **Doorbell Mechanism** | MMIO Doorbell Array (Host + Slots) | USBCMD Run/Stop & Async Doorbell | USBCMD Run bit + Frame List |
| **Completion Notice** | Event Ring Transfer Event TRBs | qTD Active bit (bit 7) clears | TD Active bit (bit 23) clears |
| **DMA Contiguity** | 4KB pages for rings/contexts | 4KB aligned frame list, 5 page ptrs | 4KB aligned frame list, contiguous |

---

## 11. Implementation Roadmap & Verification Strategy

### 11.1 Proposed File Layout
To keep kernel code modular and adhere to the project layout:
- `src/drivers/usb/` (new directory module):
  - `mod.zig`: Public API (`init`, `poll`, `devices`, `printUsbStatus`).
  - `types.zig`: Descriptors, standard requests, common structs (`UsbSpeed`, `UsbSetupPacket`).
  - `pci_detect.zig`: PCI scanning, BAR extraction, companion pairing.
  - `xhci.zig`: Full xHCI controller driver (rings, contexts, doorbells, ports).
  - `ehci.zig`: Full EHCI controller driver (async/periodic lists, QHs, qTDs, companion routing).
  - `uhci.zig`: Full UHCI controller driver (multi-controller, non-blocking transfers).
  - `hub.zig`: Root port status management and reset state machine.
  - `device.zig`: Unified device and interface descriptor parser, multi-interface composite dongle manager.
  - `hid.zig`: Boot keyboard/mouse parser, report decoders, keycode mapping.
  - `dma.zig`: PMM-backed aligned descriptor slab allocator (`UsbDmaPool`).

### 11.2 Verification Commands & Testing
1. **Automated Test Harness Compatibility:**
   - Must run and pass `python3 tools/test_runner.py` with 100% of markers passing.
   - USB initialization must execute smoothly during boot without delaying scheduler startup or user tasks.
2. **QEMU Multi-Controller Test Configurations:**
   - **xHCI test:**
     ```bash
     qemu-system-x86_64 ... -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-mouse,bus=xhci.0
     ```
   - **EHCI + UHCI companion test:**
     ```bash
     qemu-system-x86_64 ... -device ich9-usb-ehci1,id=ehci -device ich9-usb-uhci1,masterbus=ehci.0,firstport=0,companion=true -device usb-kbd,bus=ehci.0
     ```
   - **UHCI standalone test:**
     ```bash
     qemu-system-x86_64 ... -device piix3-usb-uhci,id=uhci -device usb-kbd,bus=uhci.0
     ```
3. **Shell Diagnostics Verification:**
   - Run `usb` or `lsusb` in shell: verify all controllers (xHCI, EHCI, UHCI) appear with accurate PCI locations, BARs, port counts, connected peripheral details, and packet statistics.
