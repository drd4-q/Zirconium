//! Compile a declarative kernel configuration into a Zig module.
//!
//! Reads a JSON configuration (see `config/kernel.json`), validates it, and
//! writes a Zig source file that the kernel imports as `@import("config")`.
//!
//! Everything the generator emits is a compile-time constant, so a disabled
//! feature costs nothing at runtime and the kernel cannot disagree with the
//! configuration file about what is enabled.
//!
//! Usage:
//!   gen_config --input <config.json> --output <config.zig>
//!              [--set-feature <name>=<true|false>]...
//!
//! The `--set-feature` overrides exist so the build system can layer a
//! command-line switch on top of the file (the kernel's `-Dselftest=true`).

const std = @import("std");
const profiles = @import("vm_profiles");

// ─── The schema ─────────────────────────────────────────────────────

/// Is this a profile the kernel knows?
fn isKnownProfile(name: []const u8) bool {
    return profiles.findProfile(name) != null;
}

/// Every feature the kernel knows about.  The kernel's `config.Feature` enum
/// is generated from this list, so adding a feature here and using
/// `config.features.<name>` in the kernel is all that is needed.
const feature_names = [_][]const u8{
    "usb",
    "hid",
    "network",
    "storage",
    "smp",
    "gui",
    "lua",
    "fat32",
    "ahci",
    "usb_wifi",
    "kvm",
    "selftest",
};

/// Every stage the boot sequence can contain.  The kernel's `config.Stage`
/// enum is generated from this list, and the kernel's stage runner has to
/// handle each one - an exhaustive switch makes a missing stage a compile
/// error rather than a silently skipped init.
const stage_names = [_][]const u8{
    "gdt",
    "framebuffer",
    "system",
    "syscall64",
    "memory",
    "filesystem",
    "kernel",
    "pci",
    "storage",
    "machines",
    "guests",
    "network",
    "input",
    "bluetooth",
    "smp",
    "scheduler",
    "shell",
};

const Config = struct {
    kernel: Kernel,
    timer: Timer,
    heap: Heap,
    network: Network,
    features: std.json.Value,
    boot: Boot,
    /// The machines the hypervisor runs.  This is the heart of the
    /// configuration: a ZVM is defined by the machines it runs, not by the
    /// host's own features.
    machines: Machines = .{},
};

/// The machines the hypervisor runs.
const Machines = struct {
    list: []const MachineSpec = &.{},
};

/// One machine the hypervisor runs.
const MachineSpec = struct {
    /// The name the operator sees.
    name: []const u8,
    /// The profile: the machine the guest is shown.  "auto" means the
    /// hypervisor decides from what the guest turns out to need.
    profile: []const u8 = "auto",
    /// Where the guest's kernel image is, on the host's filesystem.
    image: []const u8 = "",
    /// Whether the machine is started at boot.
    autostart: bool = true,
    /// How many vCPUs to give it.  0 means "let the partitioner decide".
    cores: u8 = 0,
    /// How much RAM to give it, in megabytes.  0 means "let the partitioner
    /// decide".
    ram_mb: u32 = 0,
    /// The order the machines are started in.  Lower starts first.
    order: u32 = 0,
};

const Kernel = struct {
    name: []const u8,
    version: []const u8,
};

const Timer = struct {
    hz: u32,
};

const Heap = struct {
    kernel_kb: u32,
};

const Network = struct {
    ip: []const u8,
    prefix: u8,
    gateway: []const u8,
    dns: []const u8,
};

const Boot = struct {
    stages: []const StageSpec,
};

const StageSpec = struct {
    name: []const u8,
    requires: ?[]const u8 = null,
};

// ─── Helpers ────────────────────────────────────────────────────────

fn isKnown(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Parse a dotted-quad address.  The kernel's addressing is fixed at four
/// octets; anything else is a configuration error, not a runtime surprise.
fn parseIp(text: []const u8) ![4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) return error.InvalidIpAddress;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIpAddress;
        i += 1;
    }
    if (i != 4) return error.InvalidIpAddress;
    return out;
}

fn writeIp(writer: anytype, ip: [4]u8) !void {
    try writer.print("[4]u8{{ {d}, {d}, {d}, {d} }}", .{ ip[0], ip[1], ip[2], ip[3] });
}

// ─── Main ───────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const debug_io = std.Options.debug_io;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arg_it.deinit();

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var overrides: std.ArrayList([2][]const u8) = .empty;

    // Skip the executable name.
    _ = arg_it.next();

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--input")) {
            if (arg_it.next()) |val| {
                input_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--output")) {
            if (arg_it.next()) |val| {
                output_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--set-feature")) {
            if (arg_it.next()) |spec| {
                const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.BadFeatureOverride;
                try overrides.append(allocator, .{ spec[0..eq], spec[eq + 1 ..] });
            }
        } else {
            std.debug.print("gen_config: unknown argument '{s}'\n", .{arg});
            return error.UnknownArgument;
        }
    }

    const in_path = input_path orelse return error.MissingInput;
    const out_path = output_path orelse return error.MissingOutput;

    const dir = std.Io.Dir.cwd();
    const infile = try dir.openFile(debug_io, in_path, .{});
    defer infile.close(debug_io);
    const size = try infile.length(debug_io);
    const text = try allocator.alloc(u8, size);
    defer allocator.free(text);
    _ = try infile.readPositionalAll(debug_io, text, 0);

    const config = try std.json.parseFromSliceLeaky(Config, allocator, text, .{
        .ignore_unknown_fields = true,
    });

    // ─── Validate and apply the feature table ─────────────────────
    // The feature table is parsed dynamically so the generator can report an
    // unknown feature by name instead of a generic JSON error.
    const features_obj = switch (config.features) {
        .object => |o| o,
        else => return error.FeaturesMustBeAnObject,
    };

    var enabled: std.StringHashMap(bool) = .init(allocator);
    defer enabled.deinit();

    for (feature_names) |name| {
        const value = features_obj.get(name) orelse {
            std.debug.print("gen_config: feature '{s}' is missing from the configuration\n", .{name});
            return error.MissingFeature;
        };
        switch (value) {
            .bool => |b| try enabled.put(name, b),
            else => {
                std.debug.print("gen_config: feature '{s}' must be true or false\n", .{name});
                return error.BadFeatureValue;
            },
        }
    }

    // Any key in the object that is not a known feature is a typo; silently
    // ignoring it would mean a misspelled feature looks disabled forever.
    // Keys starting with '$' are comments and are skipped.
    var it = features_obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len > 0 and key[0] == '$') continue;
        if (!isKnown(&feature_names, key)) {
            std.debug.print("gen_config: unknown feature '{s}'\n", .{key});
            return error.UnknownFeature;
        }
    }

    // Command-line overrides win over the file.
    for (overrides.items) |ov| {
        if (!isKnown(&feature_names, ov[0])) {
            std.debug.print("gen_config: override for unknown feature '{s}'\n", .{ov[0]});
            return error.UnknownFeature;
        }
        const value = std.mem.eql(u8, ov[1], "true") or std.mem.eql(u8, ov[1], "1") or
            std.mem.eql(u8, ov[1], "on");
        const was = enabled.get(ov[0]).?;
        try enabled.put(ov[0], value);
        if (was != value) {
            std.debug.print("gen_config: feature '{s}' overridden {s} -> {s}\n", .{
                ov[0], if (was) "true" else "false", if (value) "true" else "false",
            });
        }
    }

    // ─── Resolve the boot sequence ────────────────────────────────
    var stages: std.ArrayList(StageSpec) = .empty;    for (config.boot.stages) |spec| {
        if (!isKnown(&stage_names, spec.name)) {
            std.debug.print("gen_config: unknown boot stage '{s}'\n", .{spec.name});
            return error.UnknownStage;
        }
        if (spec.requires) |req| {
            if (!isKnown(&feature_names, req)) {
                std.debug.print("gen_config: stage '{s}' requires unknown feature '{s}'\n", .{ spec.name, req });
                return error.UnknownFeature;
            }
            if (!enabled.get(req).?) {
                // The feature is off: drop the stage rather than run it
                // half-initialised.
                std.debug.print("gen_config: stage '{s}' dropped (feature '{s}' is off)\n", .{ spec.name, req });
                continue;
            }
        }
        try stages.append(allocator, spec);
    }

    // ─── Resolve the machines ─────────────────────────────────────
    // A machine is a real thing the hypervisor will run, so the
    // configuration is checked hard: a machine with no name, or two with
    // the same one, would be a mystery at boot.
    var machines: std.ArrayList(MachineSpec) = .empty;
    for (config.machines.list) |spec| {
        if (spec.name.len == 0) {
            std.debug.print("gen_config: a machine has no name\n", .{});
            return error.UnnamedMachine;
        }
        for (machines.items) |existing| {
            if (std.mem.eql(u8, existing.name, spec.name)) {
                std.debug.print("gen_config: two machines are called '{s}'\n", .{spec.name});
                return error.DuplicateMachine;
            }
        }
        if (spec.profile.len != 0 and !std.mem.eql(u8, spec.profile, "auto")) {
            if (!isKnownProfile(spec.profile)) {
                std.debug.print("gen_config: machine '{s}' wants the unknown profile '{s}'\n", .{ spec.name, spec.profile });
                return error.UnknownProfile;
            }
        }
        try machines.append(allocator, spec);
    }
    // Start order: by `order`, then by the order in the file.  A stable sort
    // keeps the file's order for the machines that do not say.
    std.mem.sort(MachineSpec, machines.items, {}, struct {
        fn lessThan(_: void, a: MachineSpec, b: MachineSpec) bool {
            return a.order < b.order;
        }
    }.lessThan);

    // ─── Validate the tunables ───────────────────────────────────
    if (config.timer.hz == 0 or config.timer.hz > 1000) {
        std.debug.print("gen_config: timer.hz must be 1..1000\n", .{});
        return error.BadTimerRate;
    }
    if (config.heap.kernel_kb == 0) {
        std.debug.print("gen_config: heap.kernel_kb must be positive\n", .{});
        return error.BadHeapSize;
    }
    if (config.network.prefix > 32) {
        std.debug.print("gen_config: network.prefix must be 0..32\n", .{});
        return error.BadPrefix;
    }
    const ip = try parseIp(config.network.ip);
    const gateway = try parseIp(config.network.gateway);
    const dns = try parseIp(config.network.dns);

    // ─── Emit ─────────────────────────────────────────────────────
    var out_buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &out_buf.writer;

    try w.writeAll(
        \\//! Generated by tools/gen_config.zig - do not edit.
        \\//!
        \\//! Source: config/kernel.json
        \\//! Regenerated on every build; change the JSON, not this file.
        \\//!
        \\//! Everything here is a compile-time constant, so a disabled feature
        \\//! costs nothing at runtime.
        \\
        \\
    );

    try w.print("pub const kernel_name = \"{s}\";\n", .{config.kernel.name});
    try w.print("pub const kernel_version = \"{s}\";\n\n", .{config.kernel.version});

    // The feature enum, so the kernel can talk about features by name.
    try w.writeAll("/// Every feature the kernel knows about.\npub const Feature = enum {\n");
    for (feature_names) |name| {
        try w.print("    {s},\n", .{name});
    }
    try w.writeAll("};\n\n");

    // The feature table.
    try w.writeAll("/// Compile-time feature switches.\npub const features = struct {\n");
    for (feature_names) |name| {
        try w.print("    pub const {s} = {s};\n", .{ name, if (enabled.get(name).?) "true" else "false" });
    }
    try w.writeAll("};\n\n");

    // A lookup by name, so the kernel can ask "is this feature on?" without
    // a switch at every call site.
    try w.writeAll("/// Is a feature enabled?\npub fn featureEnabled(f: Feature) bool {\n    return switch (f) {\n");
    for (feature_names) |name| {
        try w.print("        .{s} => features.{s},\n", .{ name, name });
    }
    try w.writeAll("    };\n}\n\n");

    // The stage enum.
    try w.writeAll("/// One step of the boot sequence.\npub const Stage = enum {\n");
    for (stage_names) |name| {
        try w.print("    {s},\n", .{name});
    }
    try w.writeAll("};\n\n");

    // The boot sequence itself.
    try w.writeAll(
        \\/// The boot sequence, in order.
        \\///
        \\/// Stages whose required feature is disabled were removed by the
        \\/// generator, so this list is exactly what the kernel will run.
        \\
    );
    try w.writeAll("pub const boot_stages = [_]Stage{\n");
    for (stages.items) |spec| {
        try w.print("    .{s},\n", .{spec.name});
    }
    try w.writeAll("};\n\n");

    // The machines the hypervisor runs.  This is the heart of the
    // configuration: a ZVM is defined by the machines it runs.
    try w.writeAll(
        \\/// One machine the hypervisor runs.
        \\pub const MachineSpec = struct {
        \\    /// The name the operator sees.
        \\    name: []const u8,
        \\    /// The profile: the machine the guest is shown.  "auto" means the
        \\    /// hypervisor decides from what the guest turns out to need.
        \\    profile: []const u8 = "auto",
        \\    /// Where the guest's kernel image is, on the host's filesystem.
        \\    image: []const u8 = "",
        \\    /// Whether the machine is started at boot.
        \\    autostart: bool = true,
        \\    /// How many vCPUs to give it.  0 means "let the partitioner decide".
        \\    cores: u8 = 0,
        \\    /// How much RAM to give it, in megabytes.  0 means "let the
        \\    /// partitioner decide".
        \\    ram_mb: u32 = 0,
        \\    /// The order the machines are started in.  Lower starts first.
        \\    order: u32 = 0,
        \\};
        \\
        \\
    );
    try w.writeAll("/// The machines the hypervisor runs, in start order.\npub const machines = [_]MachineSpec{\n");
    for (machines.items) |m| {
        try w.print("    .{{ .name = \"{s}\", .profile = \"{s}\", .image = \"{s}\", .autostart = {s}, .cores = {d}, .ram_mb = {d}, .order = {d} }},\n", .{
            m.name,
            m.profile,
            m.image,
            if (m.autostart) "true" else "false",
            m.cores,
            m.ram_mb,
            m.order,
        });
    }
    try w.writeAll("};\n\n");

    // Tunables.
    try w.print("/// System timer tick rate, in hertz.\npub const timer_hz: u32 = {d};\n\n", .{config.timer.hz});
    try w.print("/// Kernel heap size, in bytes.\npub const heap_kernel_bytes: usize = {d} * 1024;\n\n", .{
        config.heap.kernel_kb,
    });
    try w.writeAll("/// Static IPv4 address.\npub const net_ip = ");
    try writeIp(w, ip);
    try w.writeAll(";\n/// Static IPv4 gateway.\npub const net_gateway = ");
    try writeIp(w, gateway);
    try w.writeAll(";\n/// Static IPv4 DNS resolver.\npub const net_dns = ");
    try writeIp(w, dns);
    try w.print(";\n/// Prefix length of the static configuration.\npub const net_prefix: u8 = {d};\n", .{config.network.prefix});

    // Write it out.
    const outfile = try dir.createFile(debug_io, out_path, .{});
    defer outfile.close(debug_io);
    _ = try outfile.writePositionalAll(debug_io, out_buf.written(), 0);

    // A short summary for the build log.
    var enabled_count: usize = 0;
    for (feature_names) |name| {
        if (enabled.get(name).?) enabled_count += 1;
    }
    std.debug.print(
        "[config] {s} {s}: {d}/{d} features, {d} boot stages\n",
        .{ config.kernel.name, config.kernel.version, enabled_count, feature_names.len, stages.items.len },
    );
}
