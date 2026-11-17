//! DynamicalKVM: run several operating systems at once, each with its own
//! machine, its own resources and its own display.
//!
//! The kernel itself has no programs of its own - it is a hypervisor with a
//! device model.  Everything the operator sees comes from a guest: a Linux,
//! an Android, an XNU, a BSD.  The host's own shell is there to *drive* the
//! machines, not to be one.
//!
//! This module ties the pieces together:
//!
//!   `profile.zig`    - what machine a guest is shown (declared or
//!                       auto-selected from what the guest turns out to use)
//!   `resources.zig`  - how many cores and how much RAM each guest gets,
//!                       and which host CPUs its threads are bound to
//!   `machine.zig`    - one guest: its profile, its budget, its display
//!   `gfx/display.zig`- the compositor that puts the guests on the screen
//!
//! The CPU emulator is not here yet: a machine's vCPU runs a guest console
//! renderer, which draws the machine's identity and its resources into the
//! machine's virtual display.  Everything above that - the displays, the
//! compositing, the layout modes, the resource partitioning, the device
//! selection - is real and works today.

const std = @import("std");
const root = @import("root");
const serial = root.serial;

pub const profile = @import("profile.zig");
pub const resources = @import("resources.zig");
pub const identity = @import("identity.zig");
pub const zvp = @import("devices/zvp.zig");
pub const loader = @import("loader.zig");
pub const machine_mod = @import("machine.zig");
pub const display = @import("../system/gfx/display.zig");
pub const fb = @import("../system/framebuffer.zig");

pub const Profile = profile.Profile;
pub const Observations = profile.Observations;
pub const Budget = resources.Budget;
pub const Machine = machine_mod.Machine;
pub const Output = machine_mod.Output;
pub const Identity = machine_mod.Identity;
pub const Zvp = machine_mod.Zvp;
pub const Layout = display.Layout;

pub const MAX_MACHINES = resources.MAX_MACHINES;

var machines: [MAX_MACHINES]Machine = undefined;
var machine_count: usize = 0;
var res: resources.Resources = .{};
var initialized: bool = false;
/// The seed every machine's identity is derived from.  It is different on
/// every boot, so the identities are different on every boot.
var boot_seed: u64 = 0;
/// Set while a batch of machines is being created, so the partition is
/// computed once at the end rather than after every machine.
var suspend_repartition: bool = false;
/// A counter that makes each machine's identity differ from the others'.
var machine_serial: u64 = 0;

/// The memory the machines in the configuration ask for, in bytes.
///
/// A profile carries the amount of RAM its guest expects - a Linux 2.4 guest
/// wants 32 MB, a modern x86_64 one a gigabyte - and a machine's entry in
/// `config/kernel.json` may override it.  Summing the asks is what sizes the
/// guests' RAM pool: the host keeps the rest of its memory, which is what an
/// operator who boots a hypervisor on a 32 GB machine expects to see.
fn configuredDemand() usize {
    const config = @import("config");
    var asked: usize = 0;
    for (config.machines) |spec| {
        const p = if (std.mem.eql(u8, spec.profile, "auto"))
            profile.findProfile("linux-x86_64") orelse continue
        else
            profile.findProfile(spec.profile) orelse continue;
        const mb: u32 = if (spec.ram_mb != 0) spec.ram_mb else p.ram_mb;
        asked += @as(usize, mb) * 1024 * 1024;
    }
    return asked;
}

/// Bring the hypervisor up.
///
/// The host's own resources are the budget: every core the host has, and as
/// much memory as the machines in the configuration ask for.  A guest that
/// needs more gets it by asking for more - in its profile or in its entry in
/// `config/kernel.json` - not by taking whatever the host happens to have
/// free.
pub fn init() void {
    if (initialized) return;
    initialized = true;

    // The number of host CPUs.  The APIC is initialised before this runs, so
    // the LAPIC count is known by now.
    const cpu_count = @import("../arch/smp.zig").cpuCount();
    res.setTotalCores(@intCast(@min(cpu_count, @as(usize, resources.MAX_CORES))));

    // Memory the host can hand out.  The pool is sized to what the machines
    // in the configuration actually ask for, not to a fraction of the
    // machine's RAM: a 32 GB host whose two guests asked for a gigabyte and
    // a half must not hand 24 GB to them, or the kernel looks as if it had
    // eaten three quarters of the memory.  Each profile carries the amount
    // of RAM its guest expects, and a machine may override it.
    //
    // The three-quarter cap stays: a configuration that asks for more than
    // the host can spare gets what is left, so the guests' display buffers,
    // the shadow buffer and the kernel heap still have room of their own.
    const pmm = @import("../kernel/pmm.zig");
    const host_cap = (pmm.free_pages * 4096) * 3 / 4;
    const demand = configuredDemand();
    // A configuration that names no machines keeps the whole fraction: the
    // operator is going to add machines at runtime, and the pool cannot be
    // grown after it has been reserved.
    res.total_ram_bytes = if (demand != 0) @min(demand, host_cap) else host_cap;

    // The guests' RAM is one contiguous block, carved up per machine.  A
    // guest's physical memory has to be contiguous - guest physical address X
    // is at ram_base + X and its page tables point straight at that - so the
    // block is reserved once, here, rather than the memory manager being
    // asked for a contiguous run per machine.
    //
    // The memory of a real machine is not one block: the firmware reserves
    // holes for the PCI address space and for the display adapters, so the
    // largest run of free pages is a fraction of the memory there is.  A
    // request for the whole pool can therefore fail even when there is
    // plenty of memory - so the size is halved until it fits, and the
    // guests get what the machine can really hand out.
    const wanted_pool_pages = res.total_ram_bytes / 4096;
    var pool_pages = wanted_pool_pages;
    const min_pool_pages: usize = (16 * 1024 * 1024) / 4096;
    while (pool_pages >= min_pool_pages) {
        if (pmm.allocPages(pool_pages)) |pool| {
            res.ram_pool_base = pool;
            res.ram_pool_bytes = pool_pages * 4096;
            // The partitioner divides the pool, so the total it works with
            // has to be the pool and not the (unrounded) number it came from:
            // the pool is a whole number of pages and the total is not, and
            // the last machine would be squeezed out by the difference.
            res.total_ram_bytes = res.ram_pool_bytes;
            if (pool_pages != wanted_pool_pages) {
                serial.serialWrite("[KVM] The memory is not one block; the guests' RAM pool is ");
                serial.serialWriteDec(res.ram_pool_bytes / (1024 * 1024));
                serial.serialWrite(" MB\n");
            }
            break;
        }
        pool_pages /= 2;
    }
    if (res.ram_pool_bytes == 0) {
        serial.serialWrite("[KVM] Could not reserve a contiguous block for the guests' RAM\n");
        res.total_ram_bytes = 0;
    }

    serial.serialWrite("[KVM] DynamicalKVM ready: ");
    serial.serialWriteDec(cpu_count);
    serial.serialWrite(" cores, ");
    serial.serialWriteDec(res.total_ram_bytes / (1024 * 1024));
    serial.serialWrite(" MB of guest RAM, ");
    serial.serialWriteDec((pmm.free_pages * 4096) / (1024 * 1024));
    serial.serialWrite(" MB free for the host\n");

    // The seed the machine identities are derived from.  It has to be
    // different on every boot, or a guest could recognise the machine it was
    // given last time - which is exactly the fingerprinting the identity
    // layer exists to prevent.
    boot_seed = collectEntropy();
    serial.serialWrite("[KVM] Identity seed: 0x");
    serial.serialWriteHex(boot_seed);
    serial.serialWrite("\n");
}

/// Gather entropy for the identity seed.
///
/// None of these sources is cryptographic, and none of them needs to be: the
/// point is that a guest cannot predict the machine it is going to be given.
/// The timestamp counter moves at the core's clock rate, the local APIC timer
/// is running, the memory manager's state depends on how much was allocated
/// before, and the tick count depends on how long the boot took.
fn collectEntropy() u64 {
    var tsclo: u32 = 0;
    var tschi: u32 = 0;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (tsclo),
          [hi] "={edx}" (tschi),
    );
    const tsc = (@as(u64, tschi) << 32) | tsclo;
    const apic = @import("../drivers/apic.zig");
    const timer = @import("../drivers/timer.zig");
    const pmm = @import("../kernel/pmm.zig");

    const parts = [_]u64{
        tsc,
        @as(u64, @intCast(timer.tickCount())),
        @as(u64, @intCast(pmm.free_pages)),
        @as(u64, @intCast(@intFromPtr(&machines))),
        0x5A56_5031,
    };
    _ = apic;
    return identity.mixSeed(&parts);
}

/// The seed the machine identities are derived from.
pub fn identitySeed() u64 {
    return boot_seed;
}

pub fn machineCount() usize {
    return machine_count;
}

pub fn getMachine(index: usize) ?*Machine {
    if (index >= machine_count) return null;
    return &machines[index];
}

pub fn resourceState() *resources.Resources {
    return &res;
}

/// Create a machine.
///
/// `profile_name` selects the machine the guest is shown.  The name
/// `"auto"` means "work it out from what the guest does" - the profile is
/// decided by `profile.autoSelect()` once the guest has been observed, and
/// starts as the generic modern machine until then.
pub fn addMachine(name: []const u8, profile_name: []const u8) !u32 {
    if (!initialized) init();
    if (machine_count >= MAX_MACHINES) return error.TooManyMachines;

    var p: Profile = undefined;
    if (std.mem.eql(u8, profile_name, "auto")) {
        // Until the guest is observed, show it a modern machine; the probe
        // phase replaces this with the auto-selected profile.
        p = profile.findProfile("linux-x86_64").?;
        p.name = "auto";
    } else {
        p = profile.findProfile(profile_name) orelse return error.UnknownProfile;
    }

    var m: Machine = .{
        .id = @intCast(machine_count),
        .profile = p,
        .accent = accentFor(machine_count),
    };
    m.setName(name);

    // Every machine is presented as a *different* computer: a different
    // vendor, a different device id, a different UUID, a different CPU.
    // Two guests on the same hypervisor must not be able to tell they are
    // on the same one, and a guest that reboots must not find the machine it
    // had last time.
    machine_serial += 1;
    m.identity = identity.generate(machine_count, boot_seed ^ (machine_serial *% 0x9E3779B97F4A7C15));

    // The hypervisor's own device, carrying that identity.
    m.device = Zvp.init(@intCast(machine_count), m.identity) catch return error.OutOfMemory;

    // The compositor owns the display buffer; the machine writes into it.
    var out = Output.init(p.display.width, p.display.height, name, p.name) catch {
        m.device.deinit();
        return error.OutOfMemory;
    };
    const out_index = display.addOutput(out) catch {
        out.deinit();
        m.device.deinit();
        return error.TooManyOutputs;
    };
    m.output_index = out_index;

    res.machine_count = machine_count + 1;
    res.setWeight(machine_count, @intCast(p.ram_mb), p.max_cores);
    res.setCoreCeiling(machine_count, p.max_cores);

    machines[machine_count] = m;
    machine_count += 1;

    // A new machine changes the partition, so recompute it - and with it the
    // RAM every machine gets.  The autoload creates several machines and
    // partitions once at the end, so the repartition is suspended until then.
    if (!suspend_repartition) repartition();

    serial.serialWrite("[KVM] Machine ");
    serial.serialWriteDec(m.id);
    serial.serialWrite(" '");
    serial.serialWrite(name);
    serial.serialWrite("' profile=");
    serial.serialWrite(p.name);
    serial.serialWrite(" cores=");
    serial.serialWriteDec(res.budget(machine_count - 1).cores);
    serial.serialWrite(" ram=");
    serial.serialWriteDec(res.budget(machine_count - 1).ram_bytes / (1024 * 1024));
    serial.serialWrite("MB\n");
    // The identity, on the serial log as well: it is the thing a guest
    // fingerprints, so it has to be inspectable.
    serial.serialWrite("[KVM]   identity: ");
    serial.serialWrite(m.identity.personaName());
    serial.serialWrite(" PCI ");
    serial.serialWriteHex(m.identity.vendor_id);
    serial.serialWrite(":");
    serial.serialWriteHex(m.identity.device_id);
    serial.serialWrite(" OEM ");
    serial.serialWrite(m.identity.oemId());
    serial.serialWrite(" cpu=");
    serial.serialWrite(m.identity.cpuBrand());
    serial.serialWrite("\n");

    return m.id;
}

/// Remove a machine and free its display.
pub fn removeMachine(index: usize) void {
    if (index >= machine_count) return;
    display.removeOutput(index);
    machines[index].device.deinit();
    var i = index;
    while (i + 1 < machine_count) : (i += 1) {
        machines[i] = machines[i + 1];
        machines[i].id = @intCast(i);
    }
    machine_count -= 1;
    res.machine_count = machine_count;
    repartition();
}

/// Give every machine the RAM its budget says it gets.
///
/// The RAM is carved out of the one contiguous pool, in order, so the slices
/// are adjacent and the guests' physical memory is really contiguous.  The
/// partitioner divides the pool between the machines, so the slices always
/// fit.
fn allocateAllRam() void {
    res.ram_pool_used = 0;

    var i: usize = 0;
    while (i < machine_count) : (i += 1) {
        const bytes = res.budget(i).ram_bytes;
        if (bytes == 0) continue;

        const slice = res.carveRam(bytes) orelse {
            serial.serialWrite("[ZVM] Could not give machine ");
            serial.serialWriteDec(i);
            serial.serialWrite(" its ");
            serial.serialWriteDec(bytes / (1024 * 1024));
            serial.serialWrite(" MB: the guests' RAM pool is exhausted\n");
            continue;
        };

        machines[i].device.setMemory(.{
            .ram_base = slice.base,
            .ram_bytes = slice.size,
            .cr3_gpa = 0,
        });
        serial.serialWrite("[ZVM] Machine ");
        serial.serialWriteDec(i);
        serial.serialWrite(" RAM: ");
        serial.serialWriteDec(slice.size / (1024 * 1024));
        serial.serialWrite(" MB at 0x");
        serial.serialWriteHex(slice.base);
        serial.serialWrite("\n");
    }
}

/// Recompute the partition from the current machine list.
pub fn repartition() void {
    res.machine_count = machine_count;
    res.autoPartition();
    // The budgets changed, so the RAM has to be handed out again.  The pool is
    // one block that is never freed, so re-carving it is just resetting an
    // offset.
    allocateAllRam();
}

/// Switch between manual and automatic resource allocation.
pub fn setPolicy(p: resources.Policy) void {
    res.policy = p;
    repartition();
}

/// Set one machine's budget by hand.
pub fn setBudget(index: usize, cores: u8, ram_mb: u32) void {
    if (index >= machine_count) return;
    res.setManual(index, cores, @as(usize, ram_mb) * 1024 * 1024);
    machines[index].budget = res.budget(index);
}

/// Record what a guest did while probing, and re-choose its machine.
///
/// This is the auto-emulation path: the observations decide which devices
/// the guest is shown, and the guest's budget follows from the profile it
/// was given.
pub fn applyObservations(index: usize, obs: Observations) void {
    if (index >= machine_count) return;
    const chosen = profile.autoSelect(obs);
    machines[index].observations = obs;
    machines[index].profile = chosen;
    serial.serialWrite("[KVM] Machine ");
    serial.serialWriteDec(index);
    serial.serialWrite(" auto-selected profile: ");
    serial.serialWrite(chosen.name);
    serial.serialWrite(" cpu=");
    serial.serialWrite(chosen.cpu.name());
    serial.serialWrite("\n");
}

/// Service the hypervisor's devices.
///
/// Called from the tick handler, so it must be bounded and must not block:
/// it only reads a command register, runs a switch and writes the results.
/// A guest that is spinning in a wait loop needs the hypervisor to answer
/// it, and the tick is the only thing that runs while the guest has the
/// CPU.
pub fn serviceDevices() void {
    for (machines[0..machine_count]) |*m| {
        m.device.service();
    }
}

/// Run the guests for a slice of time and put them on the screen.
///
/// Called from the shell's input loop, like the other deferred polling: the
/// tick handler must never block, and emulating a guest is not a bounded
/// operation.
pub fn poll() void {
    if (machine_count == 0) return;

    // Divide the emulated quanta between the machines by their time share.
    // A machine with a bigger budget advances more per poll, which is what a
    // guest can observe.
    var total_share: u32 = 0;
    for (machines[0..machine_count]) |*m| {
        total_share += @max(m.budget.time_share, 1);
    }
    if (total_share == 0) total_share = 1;

    for (machines[0..machine_count]) |*m| {
        const share = @max(m.budget.time_share, 1);
        const quanta: u8 = @intCast(@max((4 * share) / total_share, 1));
        m.runSlice(quanta);
        m.budget = res.budget(m.id);
        // Write out anything a guest posted.  The serial write happens
        // here, in the deferred path, never in the tick handler.
        m.device.flushLog();
    }

    display.composite();
}

/// The layout the compositor is in.
pub fn layout() Layout {
    return display.currentLayout();
}

pub fn setLayout(l: Layout) void {
    display.setLayout(l);
}

pub fn focusNext() void {
    display.focusNext();
}

pub fn focusPrev() void {
    display.focusPrev();
}

pub fn focused() usize {
    return display.focused();
}

pub fn setFocus(index: usize) void {
    display.setFocus(index);
}

/// A colour per machine, so the tiled view tells them apart.
fn accentFor(index: usize) u32 {
    const accents = [_]u32{
        0x40C0FF, // blue
        0xFF8040, // orange
        0x60E080, // green
        0xE060FF, // magenta
        0xFFE040, // yellow
        0xFF6080, // pink
        0x40E0E0, // cyan
        0xC0C0C0, // grey
    };
    return accents[index % accents.len];
}

/// Run the guest driver against a machine.
///
/// The driver is a ring-3 program that behaves exactly as a guest kernel's
/// driver would: it finds the device, checks that it is there, asks the
/// hypervisor what machine it has been given, and reports what it found.
/// The hypervisor's registers and shared window are mapped into the task's
/// address space, so the driver reads and writes them the way it will once
/// it is running under the CPU emulator.
pub fn runGuestDriver(machine_index: usize) !void {
    if (machine_index >= machine_count) return error.NoSuchMachine;
    const m = &machines[machine_index];

    const kvm_test_bin = @import("kvm_test_bin");
    const proto = @import("proto.zig");

    // The guest's RAM is mapped too, so the driver can build page tables in
    // it - which is exactly what a guest kernel does at boot.
    var mappings = [_]@import("../kernel/scheduler.zig").ExtraMapping{
        .{ .vaddr = proto.REGS_VADDR, .paddr = m.device.regs_phys, .size = proto.REGS_SIZE },
        .{ .vaddr = proto.WINDOW_VADDR, .paddr = m.device.window_phys, .size = proto.WINDOW_SIZE },
        .{ .vaddr = proto.GUEST_RAM_VADDR, .paddr = 0, .size = 0 },
    };
    var mapping_count: usize = 2;
    if (m.device.memory.ram_bytes != 0) {
        mappings[2] = .{
            .vaddr = proto.GUEST_RAM_VADDR,
            .paddr = m.device.memory.ram_base,
            .size = m.device.memory.ram_bytes,
        };
        mapping_count = 3;
    }

    const task_id = @import("../kernel/scheduler.zig").addElfUserTaskMapped(
        &kvm_test_bin.data,
        mappings[0..mapping_count],
    ) orelse return error.CannotCreateTask;

    serial.serialWrite("[KVM] Running the guest driver against machine ");
    serial.serialWriteDec(machine_index);
    serial.serialWrite("\n");

    @import("../kernel/scheduler.zig").runTask(task_id);
}

/// Create every machine the configuration asks for.
///
/// This is the **autoload**: a ZVM is defined by the machines it runs, and
/// they come up without the operator having to type anything.  The list is
/// `machines` in `config/kernel.json`; the generator has already checked
/// that the profiles exist and that no two machines share a name.
pub fn autoload() void {
    if (!initialized) init();

    const config = @import("config");
    if (config.machines.len == 0) {
        serial.serialWrite("[ZVM] No machines configured\n");
        return;
    }

    serial.serialWrite("[ZVM] Creating ");
    serial.serialWriteDec(config.machines.len);
    serial.serialWrite(" machine(s) from the configuration\n");

    suspend_repartition = true;
    defer suspend_repartition = false;

    for (config.machines) |spec| {
        const id = addMachine(spec.name, spec.profile) catch |err| {
            serial.serialWrite("[ZVM] Could not create machine '");
            serial.serialWrite(spec.name);
            serial.serialWrite("': ");
            serial.serialWrite(@errorName(err));
            serial.serialWrite("\n");
            continue;
        };
        _ = id;

        // A machine with an explicit budget overrides the partitioner's
        // choice: the operator asked for this machine specifically.
        if (spec.cores != 0 or spec.ram_mb != 0) {
            const m = &machines[machine_count - 1];
            const cores = if (spec.cores != 0) spec.cores else m.budget.cores;
            const ram: u32 = if (spec.ram_mb != 0) spec.ram_mb else @intCast(m.budget.ram_bytes / (1024 * 1024));
            setBudget(machine_count - 1, cores, ram);
        }

        if (spec.image.len != 0) {
            machines[machine_count - 1].setGuestImage(spec.image);
        }
    }

    // Now that every machine exists, the partition can be computed once.
    repartition();
}

/// Load the guest kernels of the autoloaded machines.
///
/// The image is a file on the host's disk, so a guest kernel is just
/// something the operator copied onto it.  The loader places it in the
/// guest's memory and builds the boot information the guest expects.
pub fn loadGuests() void {
    if (machine_count == 0) return;

    var i: usize = 0;
    while (i < machine_count) : (i += 1) {
        const m = &machines[i];
        const path = m.guestImagePath();

        const loaded = loader.loadFromPath(m.device.memory, path) catch |err| {
            serial.serialWrite("[ZVM] Machine ");
            serial.serialWriteDec(i);
            serial.serialWrite(" '");
            serial.serialWrite(m.nameSlice());
            serial.serialWrite("': could not load ");
            serial.serialWrite(path);
            serial.serialWrite(" (");
            serial.serialWrite(@errorName(err));
            serial.serialWrite(")\n");
            continue;
        };

        m.guest_loaded = true;
        m.guest_entry_gpa = loaded.entry_gpa;
        m.guest_mbinfo_gpa = loaded.mbinfo_gpa;
        m.guest_stack_gpa = loaded.stack_gpa;
        m.guest_bytes = loaded.bytes;
        _ = m.startGuest();

        serial.serialWrite("[ZVM] Machine ");
        serial.serialWriteDec(i);
        serial.serialWrite(" '");
        serial.serialWrite(m.nameSlice());
        serial.serialWrite("': loaded ");
        serial.serialWriteDec(loaded.bytes);
        serial.serialWrite(" bytes from ");
        serial.serialWrite(loaded.path);
        serial.serialWrite(", entry at guest 0x");
        serial.serialWriteHex(loaded.entry_gpa);
        serial.serialWrite(", boot info at 0x");
        serial.serialWriteHex(loaded.mbinfo_gpa);
        serial.serialWrite("\n");
    }
}

/// Print the state of the hypervisor.
pub fn printStatus(
    writeFn: *const fn (s: []const u8) void,
    writeDecFn: *const fn (v: u64) void,
    writeHexShortFn: *const fn (v: u64) void,
) void {
    writeFn("=== ZVM ===\n\n");
    writeFn("  Machines: ");
    writeDecFn(machine_count);
    writeFn(" / ");
    writeDecFn(MAX_MACHINES);
    writeFn("\n  Policy:   ");
    writeFn(res.policy.name());
    writeFn("\n  Cores:    ");
    writeDecFn(res.total_cores);
    writeFn(" host cores\n  Guest RAM: ");
    writeDecFn(res.total_ram_bytes / (1024 * 1024));
    writeFn(" MB\n\n");

    if (machine_count == 0) {
        writeFn("  No machines.  'kvm add <name> [profile]' creates one.\n\n");
        return;
    }

    for (machines[0..machine_count]) |*m| {
        writeFn("  [");
        writeDecFn(m.id);
        writeFn("] ");
        writeFn(m.nameSlice());
        writeFn("\n      state:    ");
        writeFn(m.state.name());
        writeFn("\n      profile:  ");
        writeFn(m.profile.name);
        writeFn(" (");
        writeFn(m.profile.os);
        writeFn("/");
        writeFn(m.profile.arch);
        writeFn(")\n      cpu:      ");
        writeFn(m.profile.cpu.name());
        writeFn("\n      display:  ");
        const o = m.output();
        writeDecFn(if (o) |out| out.width else 0);
        writeFn("x");
        writeDecFn(if (o) |out| out.height else 0);
        writeFn("\n      budget:   ");
        writeDecFn(m.budget.cores);
        writeFn(" vCPU, ");
        writeDecFn(m.budget.ram_bytes / (1024 * 1024));
        writeFn(" MB, cores=");
        writeDecFn(resources.Resources.maskCoreCount(m.budget.core_mask));
        writeFn("\n      identity: ");
        writeFn(m.identity.personaName());
        writeFn("  PCI ");
        writeHexShortFn(m.identity.vendor_id);
        writeFn(":");
        writeHexShortFn(m.identity.device_id);
        writeFn("  OEM ");
        writeFn(m.identity.oemId());
        writeFn("\n      device:   ZVP v");
        writeDecFn(m.device.version());
        writeFn(" at 0x");
        writeHexShortFn(m.device.regs_phys);
        writeFn("\n\n");
    }
}
