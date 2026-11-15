//! A guest machine: one operating system running under DynamicalKVM.
//!
//! A machine owns everything that belongs to one guest:
//!
//!   * a **profile** - the machine it thinks it is (see `profile.zig`),
//!   * a **budget** - the cores and RAM it is allowed to use,
//!   * a **virtual display** - the framebuffer it draws into,
//!   * its **vCPUs**.
//!
//! The vCPUs are where the CPU emulator goes.  Until there is one, each
//! vCPU runs a *guest console* renderer: it draws the machine's identity,
//! its emulated processor, its resources and a live counter into the
//! machine's virtual display.  That is enough to exercise the whole display
//! path - several independent displays, composited side by side or one at a
//! time, each updating on its own - and it is exactly the surface a real
//! emulator will draw into.

const std = @import("std");
const root = @import("root");
const serial = root.serial;
const timer = @import("../drivers/timer.zig");
const font = @import("../system/gfx/font.zig");
const output_mod = @import("../system/gfx/output.zig");
const profile_mod = @import("profile.zig");
const resources_mod = @import("resources.zig");
const identity_mod = @import("identity.zig");
const zvp_mod = @import("devices/zvp.zig");
const cpu_mod = @import("cpu.zig");
const mmu_mod = @import("mmu.zig");
const pci_mod = @import("pci.zig");
const proto = @import("proto.zig");

pub const Output = output_mod.Output;
pub const Profile = profile_mod.Profile;
pub const Observations = profile_mod.Observations;
pub const Budget = resources_mod.Budget;
pub const Identity = identity_mod.Identity;
pub const Zvp = zvp_mod.Zvp;
pub const Cpu = cpu_mod.Cpu;
pub const PciBus = pci_mod.Bus;
pub const Tables = mmu_mod.Tables;

pub const State = enum {
    /// Created, not yet probed.
    created,
    /// The hypervisor is watching what the guest does.
    probing,
    /// Running.
    running,
    /// Paused by the operator.
    paused,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .created => "created",
            .probing => "probing",
            .running => "running",
            .paused => "paused",
        };
    }
};

pub const Machine = struct {
    id: u32 = 0,
    name: [16]u8 = @splat(0),
    profile: Profile = undefined,
    /// The identity this machine is presented with.  Every machine gets a
    /// different one, so two guests never see the same computer.
    identity: Identity = .{},
    /// The hypervisor's own device, as this machine sees it.
    device: Zvp = .{},
    /// The PCI bus the guest sees.  The hypervisor's device is on it, and a
    /// guest finds it the ordinary way: by scanning the bus.
    pci: PciBus = .{},
    /// The page tables the hypervisor built for the guest.
    tables: Tables = undefined,
    /// The virtual CPU.  It keeps its state between slices, so a guest that
    /// is stopped and started again carries on where it was.
    cpu: Cpu = .{},
    /// The index of this machine's display in the compositor's output list.
    /// The compositor owns the buffer; the machine writes into it.
    output_index: usize = 0,
    budget: Budget = .{},
    /// How many vCPUs this machine currently has.
    vcpu_count: u8 = 1,
    state: State = .created,
    /// What the hypervisor saw while the guest was probing.
    observations: Observations = .{},
    /// Ticks of emulated time this machine has run for.
    emulated_ticks: u64 = 0,
    /// The guest's kernel has been loaded into this machine's memory.
    guest_loaded: bool = false,
    /// The guest physical address of the entry point.
    guest_entry_gpa: u64 = 0,
    /// The guest physical address of the boot information block.
    guest_mbinfo_gpa: u64 = 0,
    /// The guest physical address of the initial stack top.
    guest_stack_gpa: u64 = 0,
    /// How many bytes of the guest image were loaded.
    guest_bytes: usize = 0,
    /// Where the guest's image was read from.
    guest_image: [64]u8 = @splat(0),
    /// The colour used for this machine's decorations, so several machines
    /// are told apart at a glance in the tiled view.
    accent: u32 = 0x40C0FF,

    /// This machine's display, as owned by the compositor.
    ///
    /// The compositor owns the buffer - it is what draws it on the screen -
    /// and the machine writes into it, so there is exactly one copy.
    pub fn output(self: *Machine) ?*Output {
        return @import("../system/gfx/display.zig").get(self.output_index);
    }

    pub fn nameSlice(self: *const Machine) []const u8 {
        const n = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..n];
    }

    /// The path the guest's image was loaded from.
    pub fn guestImagePath(self: *const Machine) []const u8 {
        const n = std.mem.indexOfScalar(u8, &self.guest_image, 0) orelse self.guest_image.len;
        return self.guest_image[0..n];
    }

    /// Record where the guest's image comes from.
    pub fn setGuestImage(self: *Machine, path: []const u8) void {
        @memset(&self.guest_image, 0);
        const n = @min(path.len, self.guest_image.len - 1);
        @memcpy(self.guest_image[0..n], path[0..n]);
    }

    pub fn setName(self: *Machine, value: []const u8) void {
        @memset(&self.name, 0);
        const n = @min(value.len, self.name.len);
        @memcpy(self.name[0..n], value[0..n]);
    }

    /// Run one slice of emulated time.
    ///
    /// `quanta` is how many vCPU quanta this machine gets in this round; the
    /// resource partitioner decides that, so a machine with a smaller budget
    /// advances less per tick and its clock visibly runs slower than its
    /// neighbour's.
    pub fn runSlice(self: *Machine, quanta: u8) void {
        if (self.state == .paused) return;
        if (self.state == .created) self.state = .running;

        if (self.guest_loaded) {
            self.runCpu(quanta);
        } else {
            // No guest yet: the machine shows what it is instead of running
            // something, so an operator can see it come up.
            var q: u8 = 0;
            while (q < quanta) : (q += 1) {
                self.emulated_ticks +%= 1;
            }
            self.render();
        }
    }

    /// Execute a slice of the guest's instructions.
    fn runCpu(self: *Machine, quanta: u8) void {
        // A guest that has halted is done: there is nothing to emulate and
        // the shell's input loop polls the machines on every character.
        if (self.cpu.halted) return;

        // A quantum is a few hundred instructions: enough for the guest to
        // make progress, small enough that a guest that spins cannot take the
        // host's CPU away from the other machines.
        const budget: u64 = @as(u64, quanta) * 256;
        self.cpu.run(budget);
        self.emulated_ticks +%= self.cpu.instructions;

        // Hand the guest's console output to the host's log.
        if (!self.cpu.uart.drained()) {
            const text = self.cpu.uart.take();
            serial.serialWrite("[");
            serial.serialWrite(self.nameSlice());
            serial.serialWrite("] ");
            serial.serialWrite(text);
        }

        if (self.cpu.trapped) {
            const err = self.cpu.trap;
            const rip = self.cpu.trap_rip;
            self.cpu.trapped = false;
            serial.serialWrite("[ZVM] Machine ");
            serial.serialWriteDec(self.id);
            serial.serialWrite(" '");
            serial.serialWrite(self.nameSlice());
            serial.serialWrite("' trapped at guest 0x");
            serial.serialWriteHex(rip);
            serial.serialWrite(": ");
            serial.serialWrite(@errorName(err));
            serial.serialWrite("\n");
            // A trapped guest is stopped, not restarted: running it again
            // would trap again in the same place.
            self.state = .paused;
        }
    }

    /// Prepare the virtual CPU and start the guest.
    ///
    /// The guest inherits its RAM mapped identically and the hypervisor's
    /// device at a fixed guest physical address, and starts at the entry
    /// point its image declared, with the boot information in the first
    /// argument register.
    pub fn startGuest(self: *Machine) bool {
        if (!self.guest_loaded) return false;

        // The device the guest may talk to, and the window it shares with
        // the hypervisor.  Both live outside the guest's RAM: a guest that
        // believes it has a device at 4 GB looks like a PC with a device
        // above the 1 GB line, and its own allocator never hands that
        // address out.
        self.device.memory.addRegion(mmu_mod.DEVICE_GPA, self.device.regs_phys, 0x1000);
        self.device.memory.addRegion(mmu_mod.WINDOW_GPA, self.device.window_phys, 0x1_0000);

        self.tables = .{ .memory = &self.device.memory };
        const ok = self.tables.init(&self.device.memory) and
            self.tables.mapRam() and
            self.tables.mapDevice(mmu_mod.DEVICE_GPA, 0x1000) and
            self.tables.mapDevice(mmu_mod.WINDOW_GPA, 0x1_0000);
        if (!ok) {
            serial.serialWrite("[ZVM] Machine ");
            serial.serialWriteDec(self.id);
            serial.serialWrite(": could not build the guest's page tables\n");
            return false;
        }

        // The PCI bus.  The hypervisor's device is on it, at the slot a
        // real chipset device would occupy.
        self.pci = .{};
        self.pci.tables = &self.tables;
        self.pci.memory = &self.device.memory;
        if (self.pci.add(0, 0x1E, 0)) |f| {
            f.config = self.device.config_space;
            f.bar_kind[0] = 1; // BAR0: the register block
            f.bar_host[0] = self.device.regs_phys;
            f.bar_bytes[0] = 0x1000;
            f.bar_gpa[0] = mmu_mod.DEVICE_GPA;
            f.bar_region[0] = 0;
            f.bar_kind[2] = 1; // BAR2: the shared window
            f.bar_host[2] = self.device.window_phys;
            f.bar_bytes[2] = 0x1_0000;
            f.bar_gpa[2] = mmu_mod.WINDOW_GPA;
            f.bar_region[2] = 1;
        }

        self.cpu = .{ .memory = &self.device.memory };
        self.cpu.pci = &self.pci;
        self.cpu.identity = self.identity;
        self.cpu.rip = self.guest_entry_gpa;
        self.cpu.regs[cpu_mod.RSP] = self.guest_stack_gpa;
        self.cpu.regs[cpu_mod.RDI] = self.guest_mbinfo_gpa;
        self.cpu.regs[cpu_mod.RSI] = self.guest_mbinfo_gpa;

        serial.serialWrite("[ZVM] Machine ");
        serial.serialWriteDec(self.id);
        serial.serialWrite(" '");
        serial.serialWrite(self.nameSlice());
        serial.serialWrite("': started at guest 0x");
        serial.serialWriteHex(self.guest_entry_gpa);
        serial.serialWrite("\n");
        return true;
    }

    /// Draw the guest console into this machine's virtual display.
    fn render(self: *Machine) void {
        const o = self.output() orelse return;
        if (o.capacity_px == 0) return;

        const w = o.width;
        const h = o.height;

        // Background: a dark tint of the accent colour, so the tiled view
        // shows clearly which machine is which.
        o.clear(0x101018);

        // A coloured header bar with the machine's name.
        const bar_h: u32 = if (h > 24) 22 else h;
        o.fillRect(0, 0, w, bar_h, self.accent);
        _ = drawText(o, 4, 3, self.nameSlice(), 0x000000, self.accent);

        // The emulated machine.
        var y: u32 = bar_h + 6;
        if (h > 96) {
            y = drawText(o, 4, y, "profile: ", 0x9090A0, 0x101018);
            y = drawText(o, 4, y, self.profile.name, 0xFFFFFF, 0x101018);
            y = drawText(o, 4, y, "cpu:     ", 0x9090A0, 0x101018);
            y = drawText(o, 4, y, self.profile.cpu.name(), 0xFFFFFF, 0x101018);
            y = drawText(o, 4, y, "display: ", 0x9090A0, 0x101018);
            var dims: [24]u8 = undefined;
            const dim_text = std.fmt.bufPrint(&dims, "{d}x{d} {d}bpp", .{ o.width, o.height, self.profile.display.bpp }) catch "1024x768 32bpp";
            y = drawText(o, 4, y, dim_text, 0xFFFFFF, 0x101018);
        }

        // The resources this machine was given.
        if (h > 160) {
            y = drawText(o, 4, y, "budget:  ", 0x9090A0, 0x101018);
            var buf: [48]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d} vCPU  {d} MB  cores={s}", .{
                self.budget.cores,
                self.budget.ram_bytes / (1024 * 1024),
                maskToString(self.budget.core_mask),
            }) catch "?";
            y = drawText(o, 4, y, text, 0xFFFFFF, 0x101018);
        }

        // A live counter: the machine's own clock, advancing by however much
        // emulated time it was given.
        if (h > 200) {
            var buf: [32]u8 = undefined;
            const secs = self.emulated_ticks / 100;
            const text = std.fmt.bufPrint(&buf, "uptime: {d}s", .{secs}) catch "?";
            _ = drawText(o, 4, h - 20, text, 0x60E080, 0x101018);
        }

        // A colour bar along the bottom, so a scaled-down thumbnail in the
        // strip is still recognisable.
        const bar_y = if (h > 12) h - 8 else 0;
        const steps = 8;
        var i: u32 = 0;
        while (i < steps) : (i += 1) {
            const bw = w / steps;
            const hue = (i * 32) & 0xFF;
            o.fillRect(i * bw, bar_y, bw, h - bar_y, (hue << 16) | (0x40 << 8) | 0x80);
        }
    }
};

/// Render a string into a virtual display with the 8x16 font.
fn drawText(o: *Output, x: u32, y: u32, text: []const u8, fg: u32, bg: u32) u32 {
    var cx = x;
    for (text) |ch| {
        if (cx + @as(u32, @intCast(font.GLYPH_W)) > o.width) break;
        const g = font.glyph(ch);
        var gy: usize = 0;
        while (gy < @as(usize, font.GLYPH_H)) : (gy += 1) {
            const bits = g[gy];
            var gx: usize = 0;
            while (gx < @as(usize, font.GLYPH_W)) : (gx += 1) {
                const on = ((@as(u8, 0x80) >> @intCast(gx)) & bits) != 0;
                o.setPixelRaw(cx + @as(u32, @intCast(gx)), y + @as(u32, @intCast(gy)), if (on) fg else bg);
            }
        }
        cx += @as(u32, @intCast(font.GLYPH_W));
    }
    return y + @as(u32, @intCast(font.GLYPH_H));
}

/// Render a CPU mask as a short string, e.g. "0-1" or "2".
fn maskToString(mask: u64) []const u8 {
    if (mask == 0) return "none";
    var buf: [24]u8 = undefined;
    var n: usize = 0;
    var cpu: u8 = 0;
    var first = true;
    while (cpu < 64) : (cpu += 1) {
        const bit = @as(u64, 1) << @intCast(cpu);
        if ((mask & bit) == 0) continue;
        if (!first and n + 1 < buf.len) {
            buf[n] = ',';
            n += 1;
        }
        first = false;
        const written = std.fmt.bufPrint(buf[n..], "{d}", .{cpu}) catch "";
        n += written.len;
    }
    return buf[0..n];
}
