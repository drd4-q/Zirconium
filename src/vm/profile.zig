//! Guest profiles: what a guest kernel needs, and what the hypervisor will
//! pretend it is.
//!
//! A guest kernel is written against a machine.  Linux 2.4 on a 1998 i386
//! expects an 8259 PIC, an 8254 PIT, one core and a 1024x768 framebuffer
//! with 15-bit colour; a modern x86_64 Linux expects an APIC, an I/O APIC,
//! ACPI, several cores and a large framebuffer.  Emulating the *wrong*
//! machine is not "more capable", it is *broken*: a guest that probes for a
//! device that is not there takes a fallback path it was never tested on.
//!
//! So DynamicalKVM does not hand every guest the same machine.  It picks the
//! machine that fits the guest, and the machine is described by a profile:
//! the set of devices that exist, the CPU feature set, how much RAM, and
//! what the display looks like.
//!
//! Two ways to get a profile:
//!
//!   * **Declared** - the operator names one when creating the machine.  This
//!     is what you want for a known guest.
//!   * **Auto-selected** - the hypervisor watches what the guest does while
//!     it probes and picks the profile that fits what it turned out to need.
//!     `autoSelect()` implements that decision; `Observations` is the record
//!     the probe phase fills in.
//!
//! The point of the auto path is that "an old system" and "a new system" do
//! not have to be declared by hand.  The hypervisor notices that a guest
//! programmed the 8259 rather than the I/O APIC, that it never touched the
//! APIC, that its CPUID leaf stops at 1, and it hands back the matching
//! machine - a weak CPU and a small display included.

const std = @import("std");
const profiles = @import("profiles.zig");

// The types and the table live in `profiles.zig`, which is pure data so
// that the build tool can read it too.  They are re-exported here because
// this is the module the kernel talks to.
pub const CpuModel = profiles.CpuModel;
pub const DisplaySpec = profiles.DisplaySpec;
pub const Devices = profiles.Devices;
pub const Profile = profiles.Profile;
pub const known_profiles = profiles.known_profiles;
pub const padded = profiles.padded;

/// Find a profile by name.
pub fn findProfile(name: []const u8) ?Profile {
    return profiles.findProfile(name);
}

/// What the hypervisor observed about a guest while it was probing.
///
/// The probe phase of a guest's boot is a series of small tells: which
/// interrupt controller it programmed, which CPUID leaves it read, whether
/// it looked for a PCI bus at all.  Recording them and deciding afterwards
/// is much more robust than committing to a machine up front, and it is what
/// makes the "just work" case work: point DynamicalKVM at a kernel image and
/// it works out what the kernel expects to find.
pub const Observations = struct {
    /// The guest wrote to the 8259's mask registers.
    used_8259_pic: bool = false,
    /// The guest read the I/O APIC's ID register.
    used_ioapic: bool = false,
    /// The guest wrote to the local APIC's timer or EOI register.
    used_lapic: bool = false,
    /// The guest read ACPI tables (the PCI hotplug or the MP table).
    used_acpi: bool = false,
    /// The guest scanned the PCI configuration space.
    used_pci: bool = false,
    /// The highest CPUID leaf the guest asked for.
    cpuid_max_leaf: u32 = 0,
    /// The guest asked for the SSE feature bit.
    wanted_sse: bool = false,
    /// The guest asked for the SSE2 feature bit.
    wanted_sse2: bool = false,
    /// The guest asked for the AVX feature bit.
    wanted_avx: bool = false,
    /// The guest was started in legacy (non-multiboot) boot mode.
    legacy_boot: bool = false,
    /// The guest's own idea of its screen size, if it announced one.
    announced_width: u32 = 0,
    announced_height: u32 = 0,
};

/// Choose the machine that fits what the guest turned out to need.
///
/// The rules, in order of how much they matter:
///
///   1. **The interrupt controller.**  A guest that programs the 8259 is a
///      guest whose kernel was written for a machine with a 8259, and it
///      will not use the I/O APIC.  Give it one and it takes a fallback
///      path it was never tested on.
///   2. **The processor.**  The strongest feature the guest asked for sets
///      the model, but never more than it asked for: a guest that only
///      asked for SSE gets a Pentium, not a Core 2, because the emulated
///      CPU's *absence* of a feature is what makes the guest take its
///      intended fallback path.
///   3. **The PCI bus.**  No PCI means no virtio devices, so a guest that
///      never scanned PCI gets a machine with no PCI bus.
///   4. **The display.**  A guest that announced a screen size gets that
///      size; one that did not gets the modest default, because a modern
///      large framebuffer is not what an old kernel expects.
pub fn autoSelect(obs: Observations) Profile {
    // The processor: the strongest feature the guest asked for.
    const cpu: CpuModel = if (obs.wanted_avx)
        .x86_64
    else if (obs.wanted_sse2)
        .core2
    else if (obs.wanted_sse)
        .pentium
    else if (obs.legacy_boot)
        .i386
    else
        .x86_64;

    // The interrupt controller.  The 8259 is present on every x86 machine,
    // but whether the *guest* uses it decides whether there is an I/O APIC.
    const use_ioapic = obs.used_ioapic and !obs.used_8259_pic;
    const use_lapic = obs.used_lapic and cpu != .i386;

    // The display.
    var display: DisplaySpec = .{ .width = 1024, .height = 768, .bpp = 32 };
    if (obs.announced_width != 0 and obs.announced_height != 0) {
        display.width = obs.announced_width;
        display.height = obs.announced_height;
    } else if (cpu == .i386) {
        // An old guest that said nothing gets an old display.
        display = .{ .width = 640, .height = 480, .bpp = 16 };
    }

    // The architecture: a guest that never touched SSE2 and boots in legacy
    // mode is a 32-bit guest.
    const arch: []const u8 = if (cpu == .i386 or (obs.legacy_boot and !obs.wanted_sse2)) "i386" else "x86_64";

    var profile: Profile = .{
        .name = "auto",
        .os = "unknown",
        .arch = arch,
        .cpu = cpu,
        .devices = .{
            .pic_8259 = true,
            .pit_8254 = true,
            .ioapic = use_ioapic,
            .lapic = use_lapic,
            .apic_timer = use_lapic,
            .acpi = obs.used_acpi,
            .pci = obs.used_pci,
            .gpu = true,
            .block = obs.used_pci,
            .net = obs.used_pci,
            .console = true,
        },
        .display = display,
        .ram_mb = if (cpu == .i386) 64 else 256,
        .max_cores = if (cpu == .i386) 1 else 2,
    };

    // If the auto-selected machine matches a known profile, use that profile
    // so the operator sees a name they can recognise.
    for (known_profiles) |known| {
        if (known.cpu == profile.cpu and
            known.arch == profile.arch and
            known.display.width == profile.display.width and
            known.display.height == profile.display.height and
            known.devices.ioapic == profile.devices.ioapic and
            known.devices.lapic == profile.devices.lapic)
        {
            profile.name = known.name;
            profile.os = known.os;
            profile.ram_mb = known.ram_mb;
            profile.max_cores = known.max_cores;
            break;
        }
    }

    return profile;
}

/// Print the known profiles.
pub fn printProfiles(writeFn: *const fn (s: []const u8) void, writeDecFn: *const fn (v: u64) void) void {
    writeFn("Known guest profiles:\n\n");
    for (known_profiles) |p| {
        writeFn("  ");
        writeFn(p.name);
        writeFn("\n      ");
        writeFn(p.os);
        writeFn("/");
        writeFn(p.arch);
        writeFn("  ");
        writeFn(p.cpu.name());
        writeFn("  ");
        writeDecFn(p.ram_mb);
        writeFn("MB  ");
        writeFn(p.display.name());
        writeFn("\n");
    }
    writeFn("\n");
}
