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

pub const Output = output_mod.Output;
pub const Profile = profile_mod.Profile;
pub const Observations = profile_mod.Observations;
pub const Budget = resources_mod.Budget;
pub const Identity = identity_mod.Identity;
pub const Zvp = zvp_mod.Zvp;

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
    name: [16]u8 = [_]u8{0} ** 16,
    profile: Profile = undefined,
    /// The identity this machine is presented with.  Every machine gets a
    /// different one, so two guests never see the same computer.
    identity: Identity = .{},
    /// The hypervisor's own device, as this machine sees it.
    device: Zvp = .{},
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

        var q: u8 = 0;
        while (q < quanta) : (q += 1) {
            self.emulated_ticks +%= 1;
        }
        self.render();
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
