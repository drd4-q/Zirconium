//! The guest's memory: its RAM, and the MMU that walks its page tables.
//!
//! A guest kernel builds its own page tables in its own memory and points
//! its CR3 at them.  The hypervisor has to walk those tables to find out
//! where a guest address actually is - that is what makes a guest's memory
//! access possible at all, and it is the first thing a CPU emulator needs.
//!
//! Two address spaces are in play, and confusing them is the classic bug:
//!
//!   * The **guest physical** address: what the guest's page tables talk
//!     about.  It is a number in the guest's own address space, starting at
//!     zero.
//!   * The **host physical** address: where those bytes actually live in
//!     this machine's RAM.
//!
//! The machine's RAM is one contiguous block of host memory, so the two are
//! related by a constant offset: `host = ram_base + guest`.  The page
//! walker below turns a guest virtual address into a host physical one by
//! walking the guest's tables, reading each level out of the guest's RAM.

/// A page table entry's flags we care about.
pub const PTE_PRESENT: u64 = 1 << 0;
pub const PTE_WRITE: u64 = 1 << 1;
pub const PTE_USER: u64 = 1 << 2;
pub const PTE_PWT: u64 = 1 << 3;
pub const PTE_PCD: u64 = 1 << 4;
pub const PTE_ACCESSED: u64 = 1 << 5;
pub const PTE_DIRTY: u64 = 1 << 6;
pub const PTE_HUGE: u64 = 1 << 7;
pub const PTE_GLOBAL: u64 = 1 << 8;
pub const PTE_NX: u64 = 1 << 63;

/// The address bits of a page table entry.
pub const PTE_ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;

/// The number of entries in a page table.
pub const ENTRIES: usize = 512;

pub const PAGE_SIZE: u64 = 4096;

/// Why a translation failed.
///
/// The numbers are part of the device protocol: the hypervisor reports the
/// reason to the guest, and a guest driver wants to know *why* its access
/// failed, not just that it did.
pub const TranslateError = error{
    /// No page table mapped this part of the address.
    NotPresent,
    /// The walk left the guest's RAM.
    OutsideRam,
    /// The walk hit a reserved bit pattern.
    Malformed,
};

/// The numeric code for a translation failure.
pub fn translateErrorCode(err: TranslateError) u32 {
    return switch (err) {
        error.NotPresent => 1,
        error.OutsideRam => 2,
        error.Malformed => 3,
    };
}

/// The guest's memory map.
pub const Memory = struct {
    /// The host physical address of the guest's RAM.
    ram_base: u64 = 0,
    /// How much RAM the guest has.
    ram_bytes: u64 = 0,
    /// The guest physical address of the PML4 the guest booted with.
    cr3_gpa: u64 = 0,

    /// True when the machine has RAM at all.
    pub fn present(self: Memory) bool {
        return self.ram_bytes != 0;
    }

    /// The host physical address of a guest physical address.
    ///
    /// Guest physical addresses above the RAM are not RAM at all - they are
    /// where the guest's devices would be mapped, once there are any.
    pub fn guestToHost(self: Memory, gpa: u64) ?u64 {
        if (gpa >= self.ram_bytes) return null;
        return self.ram_base + gpa;
    }

    /// Read a byte of the guest's RAM.
    pub fn readByte(self: Memory, gpa: u64) ?u8 {
        const host = self.guestToHost(gpa) orelse return null;
        const p: [*]const volatile u8 = @ptrFromInt(host);
        return p[0];
    }

    /// Read a 64-bit word of the guest's RAM.
    pub fn readWord(self: Memory, gpa: u64) ?u64 {
        const host = self.guestToHost(gpa) orelse return null;
        const p: [*]const volatile u64 = @ptrFromInt(host);
        return p[0];
    }

    /// Write a 64-bit word into the guest's RAM.
    pub fn writeWord(self: Memory, gpa: u64, value: u64) bool {
        const host = self.guestToHost(gpa) orelse return false;
        const p: [*]volatile u64 = @ptrFromInt(host);
        p[0] = value;
        return true;
    }

    /// Translate a guest virtual address into a host physical address.
    ///
    /// This is the page walker: PML4 -> PDPT -> PD -> PT, exactly as the
    /// hardware does it.  A huge page short-circuits the last two levels.
    pub fn translate(self: Memory, gva: u64) TranslateError!u64 {
        if (!self.present()) return error.OutsideRam;

        const pml4_index = (gva >> 39) & 0x1FF;
        const pdpt_index = (gva >> 30) & 0x1FF;
        const pd_index = (gva >> 21) & 0x1FF;
        const pt_index = (gva >> 12) & 0x1FF;
        const offset = gva & (PAGE_SIZE - 1);

        // ── PML4 ────────────────────────────────────────────────────
        const pml4_entry = try self.readEntry(self.cr3_gpa, pml4_index);
        if ((pml4_entry & PTE_PRESENT) == 0) return error.NotPresent;
        const pdpt_gpa = pml4_entry & PTE_ADDR_MASK;
        if (pdpt_gpa >= self.ram_bytes) return error.OutsideRam;

        // ── PDPT ───────────────────────────────────────────────────
        const pdpt_entry = try self.readEntry(pdpt_gpa, pdpt_index);
        if ((pdpt_entry & PTE_PRESENT) == 0) return error.NotPresent;
        const pd_gpa = pdpt_entry & PTE_ADDR_MASK;
        if (pd_gpa >= self.ram_bytes) return error.OutsideRam;

        // ── Page directory ──────────────────────────────────────────
        const pd_entry = try self.readEntry(pd_gpa, pd_index);
        if ((pd_entry & PTE_PRESENT) == 0) return error.NotPresent;

        // A huge page ends the walk here: the 2 MB (or 1 GB) is mapped
        // directly by the directory entry.
        if ((pd_entry & PTE_HUGE) != 0) {
            const base = pd_entry & PTE_ADDR_MASK & ~@as(u64, 0x1F_FFFF);
            return base + (gva & 0x1F_FFFF);
        }

        const pt_gpa = pd_entry & PTE_ADDR_MASK;
        if (pt_gpa >= self.ram_bytes) return error.OutsideRam;

        // ── Page table ──────────────────────────────────────────────
        const pt_entry = try self.readEntry(pt_gpa, pt_index);
        if ((pt_entry & PTE_PRESENT) == 0) return error.NotPresent;
        const page_gpa = pt_entry & PTE_ADDR_MASK;

        // The guest physical address the guest meant.
        const gpa = page_gpa + offset;
        if (gpa >= self.ram_bytes) return error.OutsideRam;
        return self.ram_base + gpa;
    }

    /// Read one entry of a page table that lives in the guest's RAM.
    fn readEntry(self: Memory, table_gpa: u64, index: u64) TranslateError!u64 {
        const entry_gpa = table_gpa + index * 8;
        const value = self.readWord(entry_gpa) orelse return error.OutsideRam;
        return value;
    }
};
