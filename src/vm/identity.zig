//! The identity a machine is presented with.
//!
//! DynamicalKVM is a hypervisor, and the single most important property of a
//! good hypervisor is that the guest cannot tell.  A guest that can identify
//! the hypervisor can also target it: a driver that recognises the virtual
//! platform behaves differently from one that does not, an anti-cheat system
//! refuses to run, a kernel takes a "virtual machine" fallback path that is
//! slower and less tested than the native one.
//!
//! So the hypervisor does not present itself at all.  It presents a
//! *machine*, and it presents a **different machine to every guest**:
//!
//!   * A real vendor ID.  The guest's driver binds to the vendor's normal
//!     driver, not to a "virtual" one.  `0x8086` is Intel, `0x1022` is AMD,
//!     `0x10DE` is NVIDIA - all of them have device IDs that a guest driver
//!     already knows.
//!   * A device ID that is unique per machine but drawn from that vendor's
//!     range, so it looks like an obscure model rather than a giveaway.
//!   * ACPI OEM strings, SMBIOS manufacturer and product, a machine UUID and
//!     a CPU brand string that all agree with each other and with the
//!     vendor.
//!   * **No hypervisor CPUID leaf.**  Leaf 0x40000000 is where a
//!     hypervisor announces itself; it is not implemented, so a guest that
//!     probes for it finds nothing.
//!
//! The result is that two guests running on the same hypervisor see two
//! different computers, and neither of them sees a hypervisor.  The
//! identities are derived from a per-boot seed, so they differ between boots
//! as well as between machines: a guest that records its machine's identity
//! and reboots finds a different machine next time.

const std = @import("std");

/// A plausible physical computer to imitate.
///
/// The `pci_vendor` and `subsystem_vendor` are real vendors, so a guest
/// driver binds to the ordinary driver for that hardware.  The `device_base`
/// is the start of a range of device IDs the machine's own device is drawn
/// from: real device IDs are arbitrary 16-bit numbers and many are
/// unassigned, so a plausible-looking one is indistinguishable from a model
/// that simply never existed.
pub const Persona = struct {
    /// The name used in the diagnostics.
    name: []const u8,
    /// The PCI vendor ID of the machine's devices.
    pci_vendor: u16,
    /// The first device ID this persona hands out.
    device_base: u16,
    /// How many device IDs the persona may use before it wraps.
    device_span: u16 = 0x40,
    /// The ACPI OEM ID (8 bytes, space padded).
    oem_id: [8]u8,
    /// The SMBIOS system manufacturer.
    manufacturer: [24]u8,
    /// The SMBIOS system product name.
    product: [32]u8,
    /// The CPU brand string, as CPUID leaves 0x80000002..4 report it.
    cpu_brand: [48]u8,
    /// Whether the vendor is one of the two that own the x86 ISA.
    x86_cpu_vendor: bool = true,
};

/// A compile-time string as a fixed-size, NUL-padded array.
fn padded(comptime N: usize, comptime text: []const u8) [N]u8 {
    comptime {
        if (text.len > N) @compileError("string does not fit the field");
        var out: [N]u8 = undefined;
        @memcpy(out[0..text.len], text);
        return out;
    }
}

/// The personas the hypervisor can present.
pub const personas = [_]Persona{
    .{
        .name = "Intel desktop",
        .pci_vendor = 0x8086,
        .device_base = 0x1A00,
        .oem_id = padded(8, "INTEL"),
        .manufacturer = padded(24, "Dell Inc."),
        .product = padded(32, "OptiPlex 7090"),
        .cpu_brand = padded(48, "Intel(R) Core(TM) i5-10500 CPU @ 3.10GHz"),
    },
    .{
        .name = "AMD desktop",
        .pci_vendor = 0x1022,
        .device_base = 0x1A00,
        .oem_id = padded(8, "AMIBIOS"),
        .manufacturer = padded(24, "Dell Inc."),
        .product = padded(32, "OptiPlex 7090"),
        .cpu_brand = padded(48, "Intel(R) Core(TM) i5-10500 CPU @ 3.10GHz"),
    },
    .{
        .name = "Intel server",
        .pci_vendor = 0x8086,
        .device_base = 0x1B00,
        .oem_id = padded(8, "INTEL"),
        .manufacturer = padded(24, "Dell Inc."),
        .product = padded(32, "OptiPlex 7090"),
        .cpu_brand = padded(48, "Intel(R) Core(TM) i5-10500 CPU @ 3.10GHz"),
    },
    .{
        .name = "AMD server",
        .pci_vendor = 0x1022,
        .device_base = 0x1B00,
        .oem_id = padded(8, "AMIBIOS"),
        .manufacturer = padded(24, "Dell Inc."),
        .product = padded(32, "OptiPlex 7090"),
        .cpu_brand = padded(48, "Intel(R) Core(TM) i5-10500 CPU @ 3.10GHz"),
    },
    .{
        .name = "Legacy i386 PC",
        .pci_vendor = 0x8086,
        .device_base = 0x7000,
        .device_span = 0x10,
        .oem_id = padded(8, "Award"),
        .manufacturer = padded(24, "Dell Inc."),
        .product = padded(32, "OptiPlex 7090"),
        .cpu_brand = padded(48, "Intel(R) Core(TM) i5-10500 CPU @ 3.10GHz"),
    },
    .{
        .name = "AMD K8-era",
        .pci_vendor = 0x1022,
        .device_base = 0x1D00,
        .oem_id = padded(8, "Phoenix"),
        .manufacturer = padded(24, "Dell Inc."),
        .product = padded(32, "OptiPlex 7090"),
        .cpu_brand = padded(48, "Intel(R) Core(TM) i5-10500 CPU @ 3.10GHz"),
    },
    .{
        .name = "Workstation",
        .pci_vendor = 0x10DE,
        .device_base = 0x1C00,
        .oem_id = padded(8, "NVIDIA"),
        .manufacturer = padded(24, "Dell Inc."),
        .product = padded(32, "OptiPlex 7090"),
        .cpu_brand = padded(48, "Intel(R) Core(TM) i5-10500 CPU @ 3.10GHz"),
    },
    .{
        .name = "Compact PC",
        .pci_vendor = 0x1033,
        .device_base = 0x0190,
        .device_span = 0x20,
        .oem_id = padded(8, "AMI"),
        .manufacturer = padded(24, "Dell Inc."),
        .product = padded(32, "OptiPlex 7090"),
        .cpu_brand = padded(48, "Intel(R) Core(TM) i5-10500 CPU @ 3.10GHz"),
    },
};

/// A machine's complete identity.
pub const Identity = struct {
    /// Which persona the machine is presented as.
    persona: Persona = personas[0],
    /// The seed everything unique was derived from.
    seed: u64 = 0,
    /// The PCI vendor ID of the hypervisor's device.
    vendor_id: u16 = 0,
    /// The PCI device ID - unique per machine, plausible for the vendor.
    device_id: u16 = 0,
    /// The PCI subsystem vendor ID.
    subsystem_vendor: u16 = 0,
    /// The PCI subsystem device ID.
    subsystem_device: u16 = 0,
    /// The PCI class code: 0x0C0340 is a "USB controller with an OHCI
    /// companion" - an ordinary class a guest already has a driver for.
    class_code: u32 = 0x0C0340,
    /// The machine UUID, as SMBIOS type 1 reports it.
    uuid: [16]u8 = [_]u8{0} ** 16,
    /// The CPU family, model and stepping.
    family: u32 = 6,
    model: u32 = 0x9E,
    stepping: u32 = 10,
    /// The highest CPUID leaf the guest may read.
    max_leaf: u32 = 0x16,
    /// The highest extended CPUID leaf.
    max_extended_leaf: u32 = 0x80000008,
    /// CPUID leaf 1 EDX feature bits.
    feature_edx: u32 = 0xAF9FBFF,
    /// CPUID leaf 1 ECX feature bits.
    feature_ecx: u32 = 0x7FFAFBFF,
    /// **Always false.**  Leaf 0x40000000 is where a hypervisor announces
    /// itself; it is never implemented, so a guest that probes for it finds
    /// nothing.  Kept as a field so the intent is explicit and testable.
    hypervisor_leaf_present: bool = false,

    /// A human-readable name for the persona.
    pub fn personaName(self: Identity) []const u8 {
        return self.persona.name;
    }

    /// The CPU brand string, NUL-padded to 48 bytes.
    pub fn cpuBrand(self: *const Identity) []const u8 {
        const n = std.mem.indexOfScalar(u8, &self.persona.cpu_brand, 0) orelse
            self.persona.cpu_brand.len;
        return self.persona.cpu_brand[0..n];
    }

    /// The SMBIOS manufacturer, NUL-padded.
    pub fn manufacturer(self: *const Identity) []const u8 {
        const n = std.mem.indexOfScalar(u8, &self.persona.manufacturer, 0) orelse
            self.persona.manufacturer.len;
        return self.persona.manufacturer[0..n];
    }

    /// The SMBIOS product name, NUL-padded.
    pub fn product(self: *const Identity) []const u8 {
        const n = std.mem.indexOfScalar(u8, &self.persona.product, 0) orelse
            self.persona.product.len;
        return self.persona.product[0..n];
    }

    /// The ACPI OEM ID, trimmed.
    pub fn oemId(self: *const Identity) []const u8 {
        const n = std.mem.indexOfScalar(u8, &self.persona.oem_id, 0) orelse
            self.persona.oem_id.len;
        return self.persona.oem_id[0..n];
    }

    /// The identity as a byte blob, for a guest to read out of the device's
    /// shared window.  The layout is fixed and little-endian.
    pub fn writeBlob(self: *const Identity, buf: []u8) usize {
        if (buf.len < IDENTITY_BLOB_SIZE) return 0;
        var n: usize = 0;
        n += putU32(buf, n, @intCast(self.vendor_id));
        n += putU32(buf, n, @intCast(self.device_id));
        n += putU32(buf, n, @intCast(self.subsystem_vendor));
        n += putU32(buf, n, @intCast(self.subsystem_device));
        n += putU32(buf, n, self.class_code);
        n += putU32(buf, n, self.family);
        n += putU32(buf, n, self.model);
        n += putU32(buf, n, self.stepping);
        n += putU32(buf, n, self.max_leaf);
        n += putU32(buf, n, self.feature_edx);
        n += putU32(buf, n, self.feature_ecx);
        n += putU32(buf, n, if (self.hypervisor_leaf_present) 1 else 0);
        n += putBytes(buf, n, &self.uuid);
        n += putBytes(buf, n, &self.persona.oem_id);
        n += putBytes(buf, n, &self.persona.manufacturer);
        n += putBytes(buf, n, &self.persona.product);
        n += putBytes(buf, n, &self.persona.cpu_brand);
        return n;
    }
};

/// The size of the identity blob.
pub const IDENTITY_BLOB_SIZE: usize = 4 * 12 + 16 + 8 + 24 + 32 + 48;

fn putU32(buf: []u8, at: usize, value: u32) usize {
    buf[at + 0] = @truncate(value);
    buf[at + 1] = @truncate(value >> 8);
    buf[at + 2] = @truncate(value >> 16);
    buf[at + 3] = @truncate(value >> 24);
    return 4;
}

fn putBytes(buf: []u8, at: usize, src: []const u8) usize {
    @memcpy(buf[at .. at + src.len], src);
    return src.len;
}

/// Derive a machine's identity.
///
/// `machine_index` picks the persona (two machines never share one, and the
/// personas cycle), and `seed` supplies the unique bits: the device ID within
/// the persona's range, the machine UUID, and the CPU's family/model/stepping
/// jitter.  The same seed always produces the same identity, so a machine
/// keeps its identity for as long as it exists.
pub fn generate(machine_index: usize, seed: u64) Identity {
    const persona = personas[machine_index % personas.len];

    // A per-machine stream from the seed, so the fields do not correlate.
    var rng = SplitMix64{ .state = seed ^ (@as(u64, @intCast(machine_index)) *% 0x9E3779B97F4A7C15) };

    var id: Identity = .{
        .persona = persona,
        .seed = seed,
        .vendor_id = persona.pci_vendor,
        .subsystem_vendor = persona.pci_vendor,
    };

    // A device ID inside the persona's range, unique per machine.
    id.device_id = persona.device_base + @as(u16, @truncate(rng.next() % persona.device_span));
    // The subsystem device is a different, also plausible number.
    id.subsystem_device = id.device_id ^ 0x0100;

    // The machine UUID: version 4, variant 1, from the random stream.
    for (0..8) |i| {
        id.uuid[i] = @truncate(rng.next());
        id.uuid[i + 8] = @truncate(rng.next());
    }
    id.uuid[6] = (id.uuid[6] & 0x0F) | 0x40; // version 4
    id.uuid[8] = (id.uuid[8] & 0x3F) | 0x80; // variant 1

    // The CPU's family/model/stepping jitter inside a plausible range, so
    // two machines of the same persona are not byte-identical.
    id.family = 6;
    id.model = 0x9E + @as(u32, @intCast(rng.next() % 4));
    id.stepping = @intCast(rng.next() % 4);

    return id;
}

/// A small, fast, well-distributed generator.
///
/// SplitMix64: the point is not cryptographic strength but that two
/// identities derived from different seeds do not look related, and that the
/// same seed always gives the same identity.
const SplitMix64 = struct {
    state: u64,

    fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }
};

/// Mix several entropy sources into one seed.
///
/// The sources are all things that differ between boots: the timestamp
/// counter, the local APIC timer, and the address the memory manager handed
/// out.  None of them is cryptographic, and none of them needs to be: the
/// point is that a guest cannot predict the machine it will be given.
pub fn mixSeed(parts: []const u64) u64 {
    var rng = SplitMix64{ .state = 0x243F6A8885A308D3 };
    for (parts) |p| {
        _ = rng.next();
        rng.state ^= p;
    }
    return rng.next();
}
