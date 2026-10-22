//! The guest profiles: the machines the hypervisor can present.
//!
//! This file is pure data - the types and the table of known profiles - with
//! no dependencies on the kernel, so that **the build tool can read it too**.
//! The configuration generator validates the `profile` field of every machine
//! against this table, and a profile that is spelled wrong is a build error
//! rather than a machine that never comes up.

const std = @import("std");

/// The emulated processor's feature set.
///
/// This is the "weak CPU" part of the auto-emulation: a guest written for an
/// older processor must not see instructions or registers it would not have
/// had, because a guest that uses a feature the emulated CPU lacks crashes
/// instead of taking its intended fallback path.
pub const CpuModel = enum {
    /// 8086/80386 era: no FPU in the FPU sense, no SSE, no APIC.
    i386,
    /// Pentium era: SSE, but no SSE2, no local APIC timer.
    pentium,
    /// Core 2 era: SSE2, no AVX, local APIC.
    core2,
    /// Modern: everything.
    x86_64,

    pub fn name(self: CpuModel) []const u8 {
        return switch (self) {
            .i386 => "i386 (no SSE, no APIC)",
            .pentium => "Pentium (SSE, no SSE2)",
            .core2 => "Core 2 (SSE2, local APIC)",
            .x86_64 => "x86-64 (SSE2/AVX, full APIC)",
        };
    }

    /// The CPUID feature bits a guest would see.
    pub fn hasSse(self: CpuModel) bool {
        return self != .i386;
    }

    pub fn hasSse2(self: CpuModel) bool {
        return self == .core2 or self == .x86_64;
    }

    pub fn hasAvx(self: CpuModel) bool {
        return self == .x86_64;
    }

    /// The highest CPUID leaf the emulated CPU answers.
    pub fn maxCpuidLeaf(self: CpuModel) u32 {
        return switch (self) {
            .i386 => 1,
            .pentium => 2,
            .core2 => 4,
            .x86_64 => 0x14,
        };
    }
};

/// The display a guest is given.
///
/// A guest written for old hardware expects a small framebuffer with 15/16
/// bit colour.  Handing it a 4K 32bpp display is not a favour - the guest's
/// own code has a fixed idea of the screen size and of the pixel format, and
/// a mismatch shows up as a corrupted console, not as a nicer one.
pub const DisplaySpec = struct {
    width: u32 = 1024,
    height: u32 = 768,
    /// Bits per pixel.  The compositor always stores 0x00RRGGBB internally and
    /// converts on the way out, so this is a property of the *guest*, not of
    /// the host's shadow buffer.
    bpp: u32 = 32,

    pub fn name(self: DisplaySpec) []const u8 {
        return switch (self.bpp) {
            16 => "VGA 16bpp",
            24 => "VGA 24bpp",
            else => "VGA 32bpp",
        };
    }
};

/// The set of devices a guest can see.
pub const Devices = struct {
    /// The 8259 pair of interrupt controllers.
    pic_8259: bool = true,
    /// The 8254 programmable interval timer.
    pit_8254: bool = true,
    /// The I/O APIC.
    ioapic: bool = false,
    /// The local APIC in each vCPU.
    lapic: bool = false,
    /// The local APIC timer.
    apic_timer: bool = false,
    /// The ACPI tables.
    acpi: bool = false,
    /// A PCI bus (and therefore the virtio devices on it).
    pci: bool = true,
    /// The hypervisor's own GPU device.
    gpu: bool = true,
    /// The hypervisor's block device.
    block: bool = true,
    /// The hypervisor's network device.
    net: bool = true,
    /// The hypervisor's console (a serial-like port).
    console: bool = true,
};

/// A complete description of the machine a guest sees.
pub const Profile = struct {
    /// Short name, as used on the command line.
    name: []const u8,
    /// The operating system this profile is meant for.
    os: []const u8,
    /// The architecture the guest is built for.
    arch: []const u8,
    cpu: CpuModel = .x86_64,
    devices: Devices = .{},
    display: DisplaySpec = .{},
    /// Guest RAM, in megabytes.
    ram_mb: u32 = 128,
    /// How many vCPUs the guest may use.
    max_cores: u8 = 1,

    pub fn describe(self: Profile, buf: []u8) []const u8 {
        var fbs = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        const w = &fbs.writer;
        w.print("{s}/{s} cpu={s} ram={d}MB cores<={d} {s}", .{
            self.os,
            self.arch,
            self.cpu.name(),
            self.ram_mb,
            self.max_cores,
            self.display.name(),
        }) catch {};
        const out = w.buffered();
        const n = @min(out.len, buf.len);
        @memcpy(buf[0..n], out[0..n]);
        return buf[0..n];
    }
};

/// The profiles DynamicalKVM knows about.
pub const known_profiles = [_]Profile{
    .{
        .name = "linux-i386-legacy",
        .os = "linux",
        .arch = "i386",
        .cpu = .i386,
        .devices = .{
            .pic_8259 = true,
            .pit_8254 = true,
            .ioapic = false,
            .lapic = false,
            .apic_timer = false,
            .acpi = false,
            .pci = false,
            .gpu = true,
            .block = true,
            .net = false,
            .console = true,
        },
        .display = .{ .width = 640, .height = 480, .bpp = 16 },
        .ram_mb = 32,
        .max_cores = 1,
    },
    .{
        .name = "linux-i386",
        .os = "linux",
        .arch = "i386",
        .cpu = .pentium,
        .devices = .{
            .pic_8259 = true,
            .pit_8254 = true,
            .ioapic = true,
            .lapic = false,
            .apic_timer = false,
            .acpi = true,
            .pci = true,
            .gpu = true,
            .block = true,
            .net = true,
            .console = true,
        },
        .display = .{ .width = 1024, .height = 768, .bpp = 32 },
        .ram_mb = 128,
        .max_cores = 2,
    },
    .{
        .name = "linux-x86_64",
        .os = "linux",
        .arch = "x86_64",
        .cpu = .x86_64,
        .devices = .{
            .pic_8259 = true,
            .pit_8254 = true,
            .ioapic = true,
            .lapic = true,
            .apic_timer = true,
            .acpi = true,
            .pci = true,
            .gpu = true,
            .block = true,
            .net = true,
            .console = true,
        },
        .display = .{ .width = 1280, .height = 800, .bpp = 32 },
        .ram_mb = 512,
        .max_cores = 4,
    },
    .{
        .name = "android-x86_64",
        .os = "android",
        .arch = "x86_64",
        .cpu = .x86_64,
        .devices = .{
            .pic_8259 = true,
            .pit_8254 = true,
            .ioapic = true,
            .lapic = true,
            .apic_timer = true,
            .acpi = true,
            .pci = true,
            .gpu = true,
            .block = true,
            .net = true,
            .console = true,
        },
        .display = .{ .width = 1280, .height = 800, .bpp = 32 },
        .ram_mb = 1024,
        .max_cores = 4,
    },
    .{
        .name = "xnu-darwin",
        .os = "xnu",
        .arch = "x86_64",
        .cpu = .core2,
        .devices = .{
            .pic_8259 = true,
            .pit_8254 = true,
            .ioapic = true,
            .lapic = true,
            .apic_timer = true,
            .acpi = true,
            .pci = true,
            .gpu = true,
            .block = true,
            .net = true,
            .console = true,
        },
        .display = .{ .width = 1024, .height = 768, .bpp = 32 },
        .ram_mb = 512,
        .max_cores = 2,
    },
    .{
        .name = "bsd-x86_64",
        .os = "bsd",
        .arch = "x86_64",
        .cpu = .x86_64,
        .devices = .{
            .pic_8259 = true,
            .pit_8254 = true,
            .ioapic = true,
            .lapic = true,
            .apic_timer = true,
            .acpi = true,
            .pci = true,
            .gpu = true,
            .block = true,
            .net = true,
            .console = true,
        },
        .display = .{ .width = 1024, .height = 768, .bpp = 32 },
        .ram_mb = 256,
        .max_cores = 2,
    },
};

/// Find a profile by name.
pub fn findProfile(name: []const u8) ?Profile {
    for (known_profiles) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}
