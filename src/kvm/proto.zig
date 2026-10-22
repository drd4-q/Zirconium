//! The ZVP protocol - the shared interface between a guest driver and the
//! hypervisor.
//!
//! This file is the UAPI: it is imported by the hypervisor's device
//! implementation *and* by the guest driver, so the two cannot drift apart.
//! It contains nothing but constants, so a freestanding guest program can
//! include it.
//!
//! The register block is at BAR0 of the device's PCI function; the shared
//! window is at BAR1.  Both are memory-mapped, and a guest finds the device
//! the ordinary way: by scanning the PCI bus for a function whose vendor and
//! device ID it recognises.

/// The magic value in REG_MAGIC: "ZVP1".
pub const MAGIC: u32 = 0x5A565031;

/// The protocol version.
pub const VERSION: u32 = 1;

// ─── Register offsets ───────────────────────────────────────────────

pub const REG_MAGIC: usize = 0x000;
pub const REG_VERSION: usize = 0x004;
pub const REG_CAPS: usize = 0x008;
pub const REG_MAX_CMD: usize = 0x00C;
pub const REG_CMD: usize = 0x010;
pub const REG_STATUS: usize = 0x014;
pub const REG_ARG0: usize = 0x018;
pub const REG_ARG1: usize = 0x01C;
pub const REG_ARG2: usize = 0x020;
pub const REG_ARG3: usize = 0x024;
pub const REG_RESULT0: usize = 0x028;
pub const REG_RESULT1: usize = 0x02C;
pub const REG_EVENT: usize = 0x030;
pub const REG_EVENT_ACK: usize = 0x034;
pub const REG_HOST_CLOCK: usize = 0x038;
pub const REG_GUEST_CLOCK: usize = 0x03C;
pub const REG_WINDOW_PHYS: usize = 0x040;
pub const REG_WINDOW_SIZE: usize = 0x048;
pub const REG_MACHINE_INDEX: usize = 0x04C;
pub const REG_PCI_VENDOR: usize = 0x050;
pub const REG_PCI_DEVICE: usize = 0x054;
/// The doorbell: the guest writes its command sequence number here, and the
/// hypervisor answers by writing the same number to REG_SERVICED.
///
/// A status *flag* cannot work here: the guest writes the registers
/// directly, so the hypervisor never sees the write and cannot clear the
/// flag.  A sequence number is unambiguous - the guest waits for the exact
/// number it rang, so a stale answer from the previous command can never be
/// mistaken for the current one.
pub const REG_DOORBELL: usize = 0x058;
/// The command sequence the hypervisor has finished servicing.
pub const REG_SERVICED: usize = 0x05C;

// ─── Commands ───────────────────────────────────────────────────────

/// "Are you there?" - the driver checks this before anything else.
pub const CMD_PING: u32 = 1;
/// Read the machine's identity into the shared window.
pub const CMD_IDENTITY: u32 = 2;
/// Set the accent colour the hypervisor uses for this machine.
pub const CMD_SET_ACCENT: u32 = 3;
/// Post a message to the hypervisor, from the shared window.
pub const CMD_POST: u32 = 4;
/// Read the hypervisor's clock.
pub const CMD_CLOCK: u32 = 5;
/// Report an observation: the driver tells the hypervisor what it found
/// while probing, and the hypervisor uses it to choose the machine it should
/// have shown the guest.
pub const CMD_OBSERVE: u32 = 6;
/// Which machine this is.
pub const CMD_MACHINE: u32 = 7;
/// The accent colour is set through the argument register.
pub const CMD_COUNT: u32 = 8;

pub const MAX_CMD: u32 = 8;

// ─── Status ─────────────────────────────────────────────────────────

pub const STATUS_IDLE: u32 = 0;
pub const STATUS_BUSY: u32 = 1;
pub const STATUS_DONE: u32 = 2;
pub const STATUS_ERROR: u32 = 3;

// ─── Events (hypervisor to guest) ───────────────────────────────────

pub const EVENT_CLOCK_SYNC: u32 = 1 << 0;
pub const EVENT_RESET: u32 = 1 << 1;

// ─── The observation bits a guest can report ────────────────────────
//
// The bit numbers match `identity.Observations`.  A guest driver reports
// what it found while probing, and the hypervisor re-chooses the machine it
// presents.  The bit order matters: it is the order in which the
// hypervisor's rules are applied.

pub const OBS_8259_PIC: u32 = 0;
pub const OBS_IOAPIC: u32 = 1;
pub const OBS_LAPIC: u32 = 2;
pub const OBS_ACPI: u32 = 3;
pub const OBS_PCI: u32 = 4;
pub const OBS_SSE: u32 = 5;
pub const OBS_SSE2: u32 = 6;
pub const OBS_AVX: u32 = 7;
pub const OBS_LEGACY_BOOT: u32 = 8;

// ─── Where a guest finds the device ──────────────────────────────────

/// The user virtual address the ZVP register block is mapped at, when the
/// hypervisor maps it into a guest's address space.
pub const REGS_VADDR: u64 = 0x0000_7000_0000;
/// The user virtual address the shared window is mapped at.
pub const WINDOW_VADDR: u64 = 0x0000_7010_0000;

/// The size of the register block.
pub const REGS_SIZE: usize = 4096;
/// The size of the shared window.
pub const WINDOW_SIZE: usize = 64 * 1024;

/// The identity blob's size, as `identity.writeBlob` writes it.
pub const IDENTITY_BLOB_SIZE: usize = 4 * 12 + 16 + 8 + 24 + 32 + 48;
