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
/// A piece of the machine that is not RAM: a device the guest's page tables
/// can point at.
pub const DeviceRegion = struct {
    /// Where the guest sees it.
    guest_base: u64,
    /// Where it actually is in the host.
    host_base: u64,
    /// How big it is.
    bytes: u64,
};

/// The most device regions one machine can have.
pub const MAX_REGIONS: usize = 4;

pub const Memory = struct {
    /// The host physical address of the guest's RAM.
    ram_base: u64 = 0,
    /// How much RAM the guest has.
    ram_bytes: u64 = 0,
    /// The guest physical address of the PML4 the guest booted with.
    cr3_gpa: u64 = 0,
    /// The devices the guest's page tables can point at.
    regions: [MAX_REGIONS]DeviceRegion = [_]DeviceRegion{.{ .guest_base = 0, .host_base = 0, .bytes = 0 }} ** MAX_REGIONS,
    region_count: usize = 0,

    /// True when the machine has RAM at all.
    pub fn present(self: Memory) bool {
        return self.ram_bytes != 0;
    }

    /// Add a device region the guest's page tables can point at.
    pub fn addRegion(self: *Memory, guest_base: u64, host_base: u64, bytes: u64) void {
        if (self.region_count >= MAX_REGIONS) return;
        self.regions[self.region_count] = .{
            .guest_base = guest_base,
            .host_base = host_base,
            .bytes = bytes,
        };
        self.region_count += 1;
    }

    /// The host address of a guest physical address.
    ///
    /// RAM is the machine's RAM; anything else has to be a device region, or
    /// the guest is touching memory that does not exist.
    pub fn hostAddressFor(self: Memory, gpa: u64) ?u64 {
        if (gpa < self.ram_bytes) return self.ram_base + gpa;
        var i: usize = 0;
        while (i < self.region_count) : (i += 1) {
            const r = self.regions[i];
            if (gpa >= r.guest_base and gpa < r.guest_base + r.bytes) {
                return r.host_base + (gpa - r.guest_base);
            }
        }
        return null;
    }

    /// The host physical address of a guest physical address.
    ///
    /// Guest physical addresses above the RAM are not RAM at all - they are
    /// where the guest's devices are mapped.
    pub fn guestToHost(self: Memory, gpa: u64) ?u64 {
        return self.hostAddressFor(gpa);
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
            const gpa = base + (gva & 0x1F_FFFF);
            return self.hostAddressFor(gpa) orelse error.OutsideRam;
        }

        const pt_gpa = pd_entry & PTE_ADDR_MASK;
        if (pt_gpa >= self.ram_bytes) return error.OutsideRam;

        // ── Page table ──────────────────────────────────────────────
        const pt_entry = try self.readEntry(pt_gpa, pt_index);
        if ((pt_entry & PTE_PRESENT) == 0) return error.NotPresent;
        const page_gpa = pt_entry & PTE_ADDR_MASK;

        // The guest physical address the guest meant.  It may be RAM or a
        // device: the hypervisor's own device is mapped above the RAM, and a
        // guest that reads it is not doing anything wrong.
        const gpa = page_gpa + offset;
        return self.hostAddressFor(gpa) orelse error.OutsideRam;
    }

    /// Read one entry of a page table that lives in the guest's RAM.
    fn readEntry(self: Memory, table_gpa: u64, index: u64) TranslateError!u64 {
        const entry_gpa = table_gpa + index * 8;
        const value = self.readWord(entry_gpa) orelse return error.OutsideRam;
        return value;
    }
};

/// The flags of a page table entry the hypervisor builds.
const PTE_FLAGS: u64 = PTE_PRESENT | PTE_WRITE | PTE_USER;

/// The guest physical address the hypervisor's device is mapped at.
///
/// It is outside the guest's RAM on purpose: a guest that believes it has a
/// device at 4 GB looks like a PC with a device above the 1 GB line, and the
/// guest's own allocator never hands that address out.
pub const DEVICE_GPA: u64 = 0x0000_0001_0000_0000;

/// The guest physical address of the shared window.
pub const WINDOW_GPA: u64 = 0x0000_0001_0010_0000;

/// Build the guest's initial page tables.
///
/// The guest inherits three things: its RAM mapped identically, the
/// hypervisor's device at `device_gpa`, and nothing else.  A real guest
/// builds its own tables as soon as it is in long mode; these are the ones it
/// starts with.
///
/// The tables live at the top of the guest's RAM, in the last 64 KB:
/// PML4, PDPT, two page directories and one page table for the device.
pub fn setupInitialTables(memory: *Memory, device_phys: u64, window_phys: u64) bool {
    if (!memory.present()) return false;
    if (memory.ram_bytes < 0x10000) return false;

    // The device the guest may talk to, and the window it shares with the
    // hypervisor.  Both live outside the guest's RAM - a guest that believes
    // it has a device at 4 GB looks like a PC with a device above the 1 GB
    // line, and its own allocator never hands that address out.
    memory.addRegion(DEVICE_GPA, device_phys, 0x1000);
    memory.addRegion(WINDOW_GPA, window_phys, 0x1_0000);

    const pml4_gpa = memory.ram_bytes - 0x10000;
    const pdpt_gpa = pml4_gpa + 0x1000;
    const pd0_gpa = pdpt_gpa + 0x1000;
    const pd1_gpa = pd0_gpa + 0x1000;
    const pt0_gpa = pd1_gpa + 0x1000;

    // The RAM, identity mapped with 2 MB pages.
    const pd0_entries: u64 = (memory.ram_bytes + 0x1FFFFF) / 0x200000;
    var i: u64 = 0;
    while (i < pd0_entries) : (i += 1) {
        if (!memory.writeWord(pd0_gpa + i * 8, (i * 0x200000) | PTE_FLAGS | PTE_HUGE)) return false;
    }
    // The rest of the 1 GB the first directory covers is not there.
    while (i < 512) : (i += 1) {
        if (!memory.writeWord(pd0_gpa + i * 8, 0)) return false;
    }

    // The device's page table: the register block and the shared window.
    //
    // The entries hold **guest** physical addresses, like every other entry
    // in the guest's page tables - it is the walk that turns them into host
    // addresses.  Putting the host address here instead would make the walk
    // look for a guest address that does not exist, and the guest's access to
    // the device would fault.
    if (!memory.writeWord(pt0_gpa + 0 * 8, DEVICE_GPA | PTE_FLAGS)) return false;
    var w: u64 = 1;
    while (w < 16) : (w += 1) {
        if (!memory.writeWord(pt0_gpa + w * 8, WINDOW_GPA + (w - 1) * 4096 | PTE_FLAGS)) return false;
    }
    while (w < 512) : (w += 1) {
        if (!memory.writeWord(pt0_gpa + w * 8, 0)) return false;
    }

    // The page directory for the device's gigabyte.
    if (!memory.writeWord(pd1_gpa + 0 * 8, pt0_gpa | PTE_FLAGS)) return false;
    var d: u64 = 1;
    while (d < 512) : (d += 1) {
        if (!memory.writeWord(pd1_gpa + d * 8, 0)) return false;
    }

    // The page directory pointer table: the RAM's gigabyte and the device's.
    if (!memory.writeWord(pdpt_gpa + 0 * 8, pd0_gpa | PTE_FLAGS)) return false;
    if (!memory.writeWord(pdpt_gpa + 4 * 8, pd1_gpa | PTE_FLAGS)) return false;
    var p: u64 = 1;
    while (p < 512) : (p += 1) {
        if (p == 4) continue;
        if (!memory.writeWord(pdpt_gpa + p * 8, 0)) return false;
    }

    // And the PML4.
    if (!memory.writeWord(pml4_gpa + 0 * 8, pdpt_gpa | PTE_FLAGS)) return false;
    var q: u64 = 1;
    while (q < 512) : (q += 1) {
        if (!memory.writeWord(pml4_gpa + q * 8, 0)) return false;
    }

    memory.cr3_gpa = pml4_gpa;
    return true;
}
