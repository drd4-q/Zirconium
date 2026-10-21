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
pub const machine_mod = @import("machine.zig");
pub const display = @import("../system/gfx/display.zig");
pub const fb = @import("../system/framebuffer.zig");

pub const Profile = profile.Profile;
pub const Observations = profile.Observations;
pub const Budget = resources.Budget;
pub const Machine = machine_mod.Machine;
pub const Output = machine_mod.Output;
pub const Layout = display.Layout;

pub const MAX_MACHINES = resources.MAX_MACHINES;

var machines: [MAX_MACHINES]Machine = undefined;
var machine_count: usize = 0;
var res: resources.Resources = .{};
var initialized: bool = false;

/// Bring the hypervisor up.
///
/// The host's own resources are the budget: every core the host has and all
/// the memory the physical memory manager can give out are available to be
/// divided between the guests.
pub fn init() void {
    if (initialized) return;
    initialized = true;

    // The number of host CPUs.  The APIC is initialised before this runs, so
    // the LAPIC count is known by now.
    const cpu_count = @import("../arch/smp.zig").cpuCount();
    res.setTotalCores(@intCast(@min(cpu_count, @as(usize, resources.MAX_CORES))));

    // Memory the host can hand out: everything the PMM has free.
    const free_pages = @import("../kernel/pmm.zig").free_pages;
    res.total_ram_bytes = free_pages * 4096;

    serial.serialWrite("[KVM] DynamicalKVM ready: ");
    serial.serialWriteDec(cpu_count);
    serial.serialWrite(" cores, ");
    serial.serialWriteDec(res.total_ram_bytes / (1024 * 1024));
    serial.serialWrite(" MB of RAM available\n");
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

    // The compositor owns the display buffer; the machine writes into it.
    var out = Output.init(p.display.width, p.display.height, name, p.name) catch
        return error.OutOfMemory;
    const out_index = display.addOutput(out) catch {
        out.deinit();
        return error.TooManyOutputs;
    };
    m.output_index = out_index;

    res.machine_count = machine_count + 1;
    res.setWeight(machine_count, @intCast(p.ram_mb), p.max_cores);
    res.setCoreCeiling(machine_count, p.max_cores);

    machines[machine_count] = m;
    machine_count += 1;

    // A new machine changes the partition, so recompute it.
    repartition();

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

    return m.id;
}

/// Remove a machine and free its display.
pub fn removeMachine(index: usize) void {
    if (index >= machine_count) return;
    display.removeOutput(index);
    var i = index;
    while (i + 1 < machine_count) : (i += 1) {
        machines[i] = machines[i + 1];
        machines[i].id = @intCast(i);
    }
    machine_count -= 1;
    res.machine_count = machine_count;
    repartition();
}

/// Recompute the partition from the current machine list.
pub fn repartition() void {
    res.machine_count = machine_count;
    if (res.policy == .manual) {
        // Only the masks are rebuilt; the operator's numbers stand.
        res.autoPartition();
        return;
    }
    res.autoPartition();
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

/// Print the state of the hypervisor.
pub fn printStatus(writeFn: *const fn (s: []const u8) void, writeDecFn: *const fn (v: u64) void) void {
    writeFn("=== DynamicalKVM ===\n\n");
    writeFn("  Machines: ");
    writeDecFn(machine_count);
    writeFn(" / ");
    writeDecFn(MAX_MACHINES);
    writeFn("\n  Policy:   ");
    writeFn(res.policy.name());
    writeFn("\n  Host:     ");
    writeDecFn(res.total_cores);
    writeFn(" cores, ");
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
        writeFn("\n\n");
    }
}
