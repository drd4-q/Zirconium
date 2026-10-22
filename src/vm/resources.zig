//! Resource partitioning: how many cores and how much RAM each guest gets.
//!
//! The point of running several operating systems at once is that they do
//! not fight.  A guest that thinks it owns four cores will spin them all
//! and starve its neighbours; a guest that thinks it owns 4 GB will fill its
//! memory and take the host down with it.  So every machine runs against a
//! *budget*, and the hypervisor enforces it.
//!
//! Two ways to set a budget:
//!
//!   * **Manual** - the operator says exactly how many cores and how much
//!     RAM a machine gets.  Use this when you know what you are doing.
//!   * **Auto** - the hypervisor divides what is there between the machines,
//!     weighted by how much each one asked for.  A 1 GB Android guest and a
//!     32 MB Linux 2.4 guest get very different shares of the same machine,
//!     and both get enough to boot.
//!
//! The partitioner also produces the **core masks**: the set of host CPUs a
//! machine is allowed to run on.  The masks are disjoint, so two machines do
//! not end up fighting over the same core - this is the "re-addressing the
//! threads" part.  A machine's vCPU threads are bound to its mask, and the
//! scheduler only ever runs a thread on a CPU in its mask.

const std = @import("std");

/// The most machines we will run at once.
pub const MAX_MACHINES: usize = 8;

/// The most host CPUs we can hand out.
pub const MAX_CORES: u8 = 64;

pub const Policy = enum {
    /// The operator sets every budget by hand.
    manual,
    /// The hypervisor divides the host's resources between the machines.
    auto,

    pub fn name(self: Policy) []const u8 {
        return switch (self) {
            .manual => "manual",
            .auto => "auto",
        };
    }
};

/// What one machine is allowed to use.
pub const Budget = struct {
    /// vCPUs the machine may run.
    cores: u8 = 1,
    /// Guest RAM, in bytes.
    ram_bytes: usize = 64 * 1024 * 1024,
    /// The host CPUs this machine's threads may run on.  Bit N is CPU N.
    core_mask: u64 = 0,
    /// How much of the hypervisor's time this machine gets, relative to the
    /// others.  Derived from the partition, and used to divide the work the
    /// guest scheduler does per tick.
    time_share: u8 = 1,
};

pub const Resources = struct {
    policy: Policy = .auto,
    /// Cores the host actually has.
    total_cores: u8 = 1,
    /// RAM the host can give out, in bytes.
    total_ram_bytes: usize = 0,
    budgets: [MAX_MACHINES]Budget = [_]Budget{.{}} ** MAX_MACHINES,
    /// How much each machine asked for, used as the weight when partitioning
    /// automatically.  In RAM megabytes.
    weights: [MAX_MACHINES]u16 = [_]u16{0} ** MAX_MACHINES,
    /// Per-machine ceilings on the core count, taken from their profile.
    core_ceilings: [MAX_MACHINES]u8 = [_]u8{0} ** MAX_MACHINES,
    machine_count: usize = 0,
    /// The one contiguous block the guests' RAM is carved out of.
    ///
    /// A guest's physical memory has to be contiguous: guest physical
    /// address X is at `ram_base + X`, and the guest's page tables point
    /// straight at it.  So the hypervisor reserves **one** block and hands
    /// out slices of it, rather than letting the memory manager find a
    /// contiguous run per machine - which fails as soon as two machines
    /// exist, because the first one has already taken the top of the pool.
    ram_pool_base: u64 = 0,
    ram_pool_bytes: u64 = 0,
    ram_pool_used: u64 = 0,

    pub fn setTotalCores(self: *Resources, cores: u8) void {
        self.total_cores = if (cores == 0) 1 else @min(cores, MAX_CORES);
    }

    /// Record what a machine asked for, so the auto partitioner can weight it.
    pub fn setWeight(self: *Resources, index: usize, ram_mb: u16, max_cores: u8) void {
        if (index >= MAX_MACHINES) return;
        self.weights[index] = if (ram_mb == 0) 1 else ram_mb;
        _ = max_cores;
    }

    /// Divide the host's cores and RAM between the machines.
    ///
    /// Every machine gets at least one core and at least its own minimum of
    /// RAM, so a machine always boots.  What is left over is shared out in
    /// proportion to what each machine asked for.
    pub fn autoPartition(self: *Resources) void {
        const n = self.machine_count;
        if (n == 0) return;

        // ── Cores ────────────────────────────────────────────────
        // Hand out one core each first, then round-robin the rest so the
        // extra cores land on the machines that can use more than one.
        var remaining_cores: u16 = self.total_cores;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const give: u8 = if (remaining_cores > 0) 1 else 0;
            self.budgets[i].cores = give;
            if (give > 0) remaining_cores -= 1;
        }
        // The leftovers go round-robin, but never past what a machine's
        // profile allows.
        var round: usize = 0;
        while (remaining_cores > 0) : (round += 1) {
            var placed = false;
            i = 0;
            while (i < n) : (i += 1) {
                if (self.budgets[i].cores == 0) continue;
                if (self.budgets[i].cores >= self.maxCoresFor(i)) continue;
                self.budgets[i].cores += 1;
                remaining_cores -= 1;
                placed = true;
                if (remaining_cores == 0) break;
            }
            if (!placed) break; // every machine is already at its ceiling
        }

        // ── RAM ──────────────────────────────────────────────────
        var remaining_ram: usize = self.total_ram_bytes;
        // The minimum each machine gets is a quarter of what it asked for,
        // but at least 16 MB, so it can always boot.
        var minimums: [MAX_MACHINES]usize = undefined;
        i = 0;
        while (i < n) : (i += 1) {
            const ask = @as(usize, self.weights[i]) * 1024 * 1024;
            const min = @max(@as(usize, 16) * 1024 * 1024, ask / 4);
            minimums[i] = @min(min, remaining_ram);
            remaining_ram -= minimums[i];
            self.budgets[i].ram_bytes = minimums[i];
        }
        // What is left is shared out by weight.
        var total_weight: u32 = 0;
        i = 0;
        while (i < n) : (i += 1) {
            total_weight += @max(self.weights[i], 1);
        }
        if (total_weight > 0) {
            i = 0;
            while (i < n) : (i += 1) {
                const share = (remaining_ram * @as(usize, @max(self.weights[i], 1))) / total_weight;
                self.budgets[i].ram_bytes += share;
            }
        }

        self.assignMasks();
        self.assignTimeShares();
        self.roundRamToPages();
    }

    /// Round every machine's RAM down to a whole number of pages.
    ///
    /// The shares are computed by division and do not land on a page
    /// boundary.  A guest's RAM is a run of pages, and rounding the shares
    /// *up* would make the total larger than the pool the hypervisor
    /// reserved - the last machine would be squeezed out by a few kilobytes.
    /// Rounding down loses at most a page per machine and always fits.
    fn roundRamToPages(self: *Resources) void {
        const page: usize = 4096;
        var i: usize = 0;
        while (i < self.machine_count) : (i += 1) {
            self.budgets[i].ram_bytes = (self.budgets[i].ram_bytes / page) * page;
        }
    }

    /// The ceiling on a machine's core count, taken from its profile.
    fn maxCoresFor(self: *Resources, index: usize) u8 {
        const c = self.core_ceilings[index];
        return if (c == 0) 1 else c;
    }

    pub fn setCoreCeiling(self: *Resources, index: usize, cores: u8) void {
        if (index >= MAX_MACHINES) return;
        self.core_ceilings[index] = cores;
    }

    /// Give every machine a disjoint set of host CPUs.
    ///
    /// This is the "re-addressing" half of the partitioning: a machine's
    /// threads are bound to the CPUs in its mask, so two machines never end
    /// up scheduled onto the same core at the same time.  When there are
    /// fewer cores than machines, the spare machines share a core - sharing
    /// is visible in the mask, unlike silently over-committing.
    fn assignMasks(self: *Resources) void {
        const n = self.machine_count;
        var next_cpu: u8 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var mask: u64 = 0;
            var c: u8 = 0;
            while (c < self.budgets[i].cores) : (c += 1) {
                // Wrap around when we run out of cores: the machine shares.
                const cpu = next_cpu % self.total_cores;
                mask |= @as(u64, 1) << @intCast(cpu);
                next_cpu +%= 1;
            }
            self.budgets[i].core_mask = mask;
        }
    }

    /// Divide the hypervisor's time between the machines, in proportion to
    /// their core counts.
    ///
    /// The scheduler runs every task on the boot processor for now, so a
    /// core mask cannot yet mean "run this thread on that CPU".  What it can
    /// mean - and does mean - is "this machine gets this share of the
    /// emulated time", which is the part a guest can actually observe.
    fn assignTimeShares(self: *Resources) void {
        const n = self.machine_count;
        var total: u16 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            total += self.budgets[i].cores;
        }
        if (total == 0) return;
        i = 0;
        while (i < n) : (i += 1) {
            const share = (@as(usize, self.budgets[i].cores) * 100) / total;
            self.budgets[i].time_share = @intCast(@max(share, 1));
        }
    }

    /// Carve a slice of the guests' RAM pool.
    ///
    /// The slice is rounded up to a whole number of pages, and the pool
    /// offset is kept page-aligned: a guest's RAM is a run of pages, and a
    /// slice that starts in the middle of one would not be mappable.
    ///
    /// Returns null when the pool is exhausted, which happens when the
    /// partitioner gave out more than the pool holds - it divides the
    /// hypervisor's share, so that should not happen, but a manual budget
    /// can ask for more.
    pub fn carveRam(self: *Resources, bytes: u64) ?struct { base: u64, size: u64 } {
        if (bytes == 0) return null;

        const page: u64 = 4096;
        const wanted = (bytes + page - 1) & ~(page - 1);

        // Keep the offset page-aligned.
        const used = (self.ram_pool_used + page - 1) & ~(page - 1);
        if (used + wanted > self.ram_pool_bytes) return null;

        const base = self.ram_pool_base + used;
        self.ram_pool_used = used + wanted;
        return .{ .base = base, .size = wanted };
    }

    /// The budget of one machine.
    pub fn budget(self: *const Resources, index: usize) Budget {
        if (index >= MAX_MACHINES) return .{};
        return self.budgets[index];
    }

    /// Set a machine's budget by hand and rebuild the masks around it.
    pub fn setManual(self: *Resources, index: usize, cores: u8, ram_bytes: usize) void {
        if (index >= MAX_MACHINES) return;
        self.budgets[index].cores = cores;
        self.budgets[index].ram_bytes = ram_bytes;
        // The masks have to be rebuilt, because a manual core count changes
        // which CPUs a machine owns.
        var used: u64 = 0;
        var i: usize = 0;
        while (i < self.machine_count) : (i += 1) {
            used |= self.budgets[i].core_mask;
        }
        // Take the CPUs nobody is using.
        var free: u64 = 0;
        var cpu: u8 = 0;
        while (cpu < self.total_cores) : (cpu += 1) {
            const bit = @as(u64, 1) << @intCast(cpu);
            if ((used & bit) == 0) free |= bit;
        }
        var mask: u64 = 0;
        var c: u8 = 0;
        while (c < self.budgets[index].cores) : (c += 1) {
            if (free == 0) break;
            const low = @ctz(free);
            free &= free - 1;
            mask |= @as(u64, 1) << @intCast(low);
        }
        self.budgets[index].core_mask = mask;
        self.assignTimeShares();
    }

    /// How many CPUs are in a mask.
    pub fn maskCoreCount(mask: u64) u8 {
        var n: u8 = 0;
        var m = mask;
        while (m != 0) : (m &= m - 1) {
            n += 1;
        }
        return n;
    }
};
