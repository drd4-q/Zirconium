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

    /// Move a device region to a new guest physical address.
    ///
    /// A guest that programs a base address register has said where it wants
    /// the device, and the hypervisor puts it there: the region moves with
    /// it.
    pub fn moveRegion(self: *Memory, index: usize, guest_base: u64) bool {
        if (index >= self.region_count) return false;
        self.regions[index].guest_base = guest_base;
        return true;
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
/// It is the PCI memory window - the same place a real PC puts its devices:
/// above the RAM (a guest never has 3.75 GB of it) and inside the low 4 GB,
/// so a guest that only knows how to program a 32-bit base address register
/// can still reach it.
pub const DEVICE_GPA: u64 = 0x0000_0000_F000_0000;

/// The guest physical address of the shared window.
pub const WINDOW_GPA: u64 = 0x0000_0000_F001_0000;

/// How many page directories the hypervisor keeps for a guest.
pub const POOL_PDS: usize = 8;

/// How many page tables the hypervisor keeps for a guest.
pub const POOL_PTS: usize = 8;

/// How much room the hypervisor's page tables take at the top of the guest's
/// RAM: the PML4, the PDPT, the two pools and the slack between them.
pub const TABLE_BYTES: u64 = 0x20000;

/// The page tables the hypervisor builds for a guest.
///
/// The guest inherits them and can replace them: a real guest builds its own
/// as soon as it is in long mode.  They live at the top of the guest's own
/// RAM, so the guest can see them - which is what a real machine does.
///
/// The tables are grown as devices are mapped: a guest that programs a base
/// address register chooses where its device goes, and the tables have to
/// follow it there.
pub const Tables = struct {
    memory: *Memory,
    pml4_gpa: u64 = 0,
    pdpt_gpa: u64 = 0,
    /// The pool of page directories, and the pool of page tables.
    pd_pool_gpa: u64 = 0,
    pt_pool_gpa: u64 = 0,
    pd_used: [POOL_PDS]bool = [_]bool{false} ** POOL_PDS,
    pt_used: [POOL_PTS]bool = [_]bool{false} ** POOL_PTS,

    /// Lay the tables out and empty them.
    pub fn init(self: *Tables, memory: *Memory) bool {
        self.memory = memory;
        if (!memory.present()) return false;
        if (memory.ram_bytes < 0x10000) return false;

        // The tables live at the top of the guest's RAM: the PML4, the PDPT,
        // the pool of page directories and the pool of page tables.  The
        // whole lot has to fit inside the RAM, or the last page of the pool
        // falls off the end of it.
        self.pml4_gpa = memory.ram_bytes - TABLE_BYTES;
        self.pdpt_gpa = self.pml4_gpa + 0x1000;
        self.pd_pool_gpa = self.pdpt_gpa + 0x1000;
        self.pt_pool_gpa = self.pd_pool_gpa + POOL_PDS * 0x1000;

        // Empty every table, so an entry that is not there is not present.
        var i: u64 = 0;
        while (i < ENTRIES) : (i += 1) {
            if (!memory.writeWord(self.pml4_gpa + i * 8, 0)) return false;
            if (!memory.writeWord(self.pdpt_gpa + i * 8, 0)) return false;
        }
        i = 0;
        while (i < POOL_PDS) : (i += 1) {
            if (!self.clearPage(self.pd_pool_gpa + i * 0x1000)) return false;
        }
        i = 0;
        while (i < POOL_PTS) : (i += 1) {
            if (!self.clearPage(self.pt_pool_gpa + i * 0x1000)) return false;
        }

        // The PML4 points at the PDPT and nothing else.
        if (!memory.writeWord(self.pml4_gpa, self.pdpt_gpa | PTE_FLAGS)) return false;
        memory.cr3_gpa = self.pml4_gpa;
        return true;
    }

    fn clearPage(self: *Tables, gpa: u64) bool {
        var i: u64 = 0;
        while (i < ENTRIES) : (i += 1) {
            if (!self.memory.writeWord(gpa + i * 8, 0)) return false;
        }
        return true;
    }

    /// Map the guest's RAM identically, with 2 MB pages.
    ///
    /// The RAM is one contiguous block, so the whole of it fits in the first
    /// gigabyte - which is one page directory, and 2 MB pages are plenty.
    pub fn mapRam(self: *Tables) bool {
        const pd_gpa = self.allocPd() orelse return false;
        if (!self.memory.writeWord(self.pdpt_gpa, pd_gpa | PTE_FLAGS)) return false;

        const entries: u64 = (self.memory.ram_bytes + 0x1FFFFF) / 0x200000;
        var i: u64 = 0;
        while (i < entries) : (i += 1) {
            if (!self.memory.writeWord(pd_gpa + i * 8, (i * 0x200000) | PTE_FLAGS | PTE_HUGE)) return false;
        }
        while (i < ENTRIES) : (i += 1) {
            if (!self.memory.writeWord(pd_gpa + i * 8, 0)) return false;
        }
        return true;
    }

    /// Map one 4 KB page of a device at a guest physical address.
    ///
    /// The entry holds the **guest** physical address, like every other entry
    /// in the guest's page tables: it is the walk that turns it into a host
    /// address, and the device's region is what says where it really is.
    pub fn mapPage(self: *Tables, gpa: u64, flags: u64) bool {
        const pdpt_index = (gpa >> 30) & 0x1FF;
        const pd_index = (gpa >> 21) & 0x1FF;
        const pt_index = (gpa >> 12) & 0x1FF;

        // The page directory for this gigabyte.
        var pd_gpa = self.memory.readWord(self.pdpt_gpa + pdpt_index * 8) orelse return false;
        if ((pd_gpa & PTE_PRESENT) == 0) {
            pd_gpa = self.allocPd() orelse return false;
            if (!self.memory.writeWord(self.pdpt_gpa + pdpt_index * 8, pd_gpa | PTE_FLAGS)) return false;
        } else {
            pd_gpa &= PTE_ADDR_MASK;
        }

        // The page table for this 2 MB.
        const pd_entry = self.memory.readWord(pd_gpa + pd_index * 8) orelse return false;
        var pt_gpa: u64 = 0;
        if ((pd_entry & PTE_PRESENT) == 0) {
            pt_gpa = self.allocPt() orelse return false;
            if (!self.memory.writeWord(pd_gpa + pd_index * 8, pt_gpa | PTE_FLAGS)) return false;
        } else if ((pd_entry & PTE_HUGE) != 0) {
            // The RAM's 2 MB pages are already there.  A device cannot share
            // a page with RAM, so the guest has to put it somewhere else.
            return false;
        } else {
            pt_gpa = pd_entry & PTE_ADDR_MASK;
        }

        return self.memory.writeWord(pt_gpa + pt_index * 8, gpa | flags);
    }

    /// Map a device's registers at a guest physical address.
    ///
    /// The whole range is mapped, a page at a time, so a device with a
    /// 64 KB window gets all of it.
    pub fn mapDevice(self: *Tables, gpa: u64, bytes: u64) bool {
        var offset: u64 = 0;
        while (offset < bytes) : (offset += PAGE_SIZE) {
            if (!self.mapPage(gpa + offset, PTE_FLAGS)) return false;
        }
        return true;
    }

    /// Take a page directory out of the pool.
    fn allocPd(self: *Tables) ?u64 {
        var i: usize = 0;
        while (i < POOL_PDS) : (i += 1) {
            if (!self.pd_used[i]) {
                self.pd_used[i] = true;
                return self.pd_pool_gpa + i * 0x1000;
            }
        }
        return null;
    }

    /// Take a page table out of the pool.
    fn allocPt(self: *Tables) ?u64 {
        var i: usize = 0;
        while (i < POOL_PTS) : (i += 1) {
            if (!self.pt_used[i]) {
                self.pt_used[i] = true;
                return self.pt_pool_gpa + i * 0x1000;
            }
        }
        return null;
    }
};
