//! The `kvm` command: drive DynamicalKVM.
//!
//!   kvm                     - show the hypervisor's state
//!   kvm list                - list the known guest profiles
//!   kvm add <name> [profile]- create a machine (profile defaults to "auto")
//!   kvm rm <id>             - remove a machine
//!   kvm layout <mode>       - host | solo | tile | focus
//!   kvm focus <id|next|prev>- change the focused machine
//!   kvm policy <auto|manual>- how the resources are divided
//!   kvm budget <id> <cores> <ram_mb> - set one machine's budget by hand
//!   kvm dev [id]         - show a machine's device as a guest sees it
//!   kvm guest [id]       - run the guest driver against a machine
//!   kvm view [seconds] [layout] - full-screen viewer (Tab = next, Esc = back)
//!
//! `tile` shows every machine at once; `solo` and `focus` show one and let
//! you move between them without going back to the host.
const std = @import("std");
const root = @import("root");
const vga = root.vga;
const kvm = @import("../kvm/mod.zig");
const display = @import("../system/gfx/display.zig");
const fb = @import("../system/framebuffer.zig");
const kb = @import("../drivers/keyboard.zig");
const timer = @import("../drivers/timer.zig");
const mouse = @import("../drivers/mouse.zig");

fn vgaWrite(s: []const u8) void {
    vga.write(s);
}

fn vgaWriteDec(v: u64) void {
    vga.writeDec(v);
}

fn vgaWriteHexShort(v: u64) void {
    vga.writeHexShort(v);
}

fn parseUint(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, text, 10) catch null;
}

pub fn run(args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) {
        kvm.printStatus(vgaWrite, vgaWriteDec, vgaWriteHexShort);
        return;
    }

    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const sub = it.next() orelse return;

    if (std.mem.eql(u8, sub, "list")) {
        kvm.profile.printProfiles(vgaWrite, vgaWriteDec);
        return;
    }

    if (std.mem.eql(u8, sub, "add")) {
        const name = it.next() orelse {
            vga.setColor(.light_red, .black);
            vga.write("usage: kvm add <name> [profile]\n");
            vga.setColor(.white, .black);
            return;
        };
        const profile_name = it.next() orelse "auto";
        const id = kvm.addMachine(name, profile_name) catch |err| {
            vga.setColor(.light_red, .black);
            vga.write("kvm add failed: ");
            vga.write(@errorName(err));
            vga.write("\n");
            vga.setColor(.white, .black);
            return;
        };
        vga.setColor(.light_green, .black);
        vga.write("Created machine ");
        vga.writeDec(id);
        vga.write(" '");
        vga.write(name);
        vga.write("'.\n");
        vga.setColor(.white, .black);
        return;
    }

    if (std.mem.eql(u8, sub, "rm")) {
        const id_text = it.next() orelse {
            vga.write("usage: kvm rm <id>\n");
            return;
        };
        const id = parseUint(id_text) orelse {
            vga.write("kvm rm: bad id\n");
            return;
        };
        kvm.removeMachine(id);
        vga.write("Removed machine ");
        vga.writeDec(id);
        vga.write("\n");
        return;
    }

    if (std.mem.eql(u8, sub, "layout")) {
        const mode_text = it.next() orelse {
            vga.write("usage: kvm layout <host|solo|tile|focus>\n");
            return;
        };
        const mode: kvm.Layout = if (std.mem.eql(u8, mode_text, "host"))
            .host
        else if (std.mem.eql(u8, mode_text, "solo"))
            .solo
        else if (std.mem.eql(u8, mode_text, "tile"))
            .tile
        else if (std.mem.eql(u8, mode_text, "focus"))
            .focus
        else {
            vga.write("kvm layout: unknown mode\n");
            return;
        };
        kvm.setLayout(mode);
        vga.write("Layout: ");
        vga.write(mode.name());
        vga.write("\n");
        return;
    }

    if (std.mem.eql(u8, sub, "focus")) {
        const what = it.next() orelse "next";
        if (std.mem.eql(u8, what, "next")) {
            kvm.focusNext();
        } else if (std.mem.eql(u8, what, "prev")) {
            kvm.focusPrev();
        } else if (parseUint(what)) |id| {
            kvm.setFocus(id);
        } else {
            vga.write("usage: kvm focus <id|next|prev>\n");
            return;
        }
        vga.write("Focused machine ");
        vga.writeDec(kvm.focused());
        vga.write("\n");
        return;
    }

    if (std.mem.eql(u8, sub, "policy")) {
        const what = it.next() orelse {
            vga.write("usage: kvm policy <auto|manual>\n");
            return;
        };
        if (std.mem.eql(u8, what, "auto")) {
            kvm.setPolicy(.auto);
        } else if (std.mem.eql(u8, what, "manual")) {
            kvm.setPolicy(.manual);
        } else {
            vga.write("kvm policy: unknown policy\n");
            return;
        }
        vga.write("Resource policy: ");
        vga.write(kvm.resourceState().policy.name());
        vga.write("\n");
        return;
    }

    if (std.mem.eql(u8, sub, "budget")) {
        const id_text = it.next() orelse {
            vga.write("usage: kvm budget <id> <cores> <ram_mb>\n");
            return;
        };
        const cores_text = it.next() orelse {
            vga.write("usage: kvm budget <id> <cores> <ram_mb>\n");
            return;
        };
        const ram_text = it.next() orelse {
            vga.write("usage: kvm budget <id> <cores> <ram_mb>\n");
            return;
        };
        const id = parseUint(id_text) orelse 0;
        const cores = parseUint(cores_text) orelse 0;
        const ram = parseUint(ram_text) orelse 0;
        kvm.setBudget(id, @intCast(cores), ram);
        vga.write("Machine ");
        vga.writeDec(id);
        vga.write(" budget: ");
        vga.writeDec(cores);
        vga.write(" vCPU, ");
        vga.writeDec(ram);
        vga.write(" MB\n");
        return;
    }

    if (std.mem.eql(u8, sub, "dev")) {
        var index: usize = 0;
        if (it.next()) |text| {
            index = @intCast(parseUint(text) orelse 0);
        }
        const m = kvm.getMachine(index) orelse {
            vga.write("kvm dev: no such machine\n");
            return;
        };
        showDevice(m);
        return;
    }

    if (std.mem.eql(u8, sub, "guest")) {
        // Run the guest driver against a machine: the round trip over the
        // hypervisor's own device.
        var index: usize = 0;
        if (it.next()) |text| {
            index = @intCast(parseUint(text) orelse 0);
        }
        kvm.runGuestDriver(index) catch |err| {
            vga.setColor(.light_red, .black);
            vga.write("kvm guest failed: ");
            vga.write(@errorName(err));
            vga.write("\n");
            vga.setColor(.white, .black);
            return;
        };
        vga.write("Guest driver finished.\n");
        return;
    }

    if (std.mem.eql(u8, sub, "view")) {
        var seconds: u32 = 0;
        var start_layout: kvm.Layout = .focus;
        if (it.next()) |text| {
            // A layout name in the first position means the seconds were left
            // out: "kvm view tile".
            if (parseUint(text)) |s| {
                seconds = s;
                if (it.next()) |layout_text| {
                    start_layout = parseLayout(layout_text) orelse start_layout;
                }
            } else {
                start_layout = parseLayout(text) orelse start_layout;
                if (it.next()) |s_text| {
                    seconds = parseUint(s_text) orelse 0;
                }
            }
        }
        runViewer(seconds, start_layout);
        return;
    }

    vga.write("kvm: unknown subcommand.  Try 'kvm' for the state.\n");
}

/// Parse a layout name.
fn parseLayout(text: []const u8) ?kvm.Layout {
    if (std.mem.eql(u8, text, "host")) return .host;
    if (std.mem.eql(u8, text, "solo")) return .solo;
    if (std.mem.eql(u8, text, "tile")) return .tile;
    if (std.mem.eql(u8, text, "focus")) return .focus;
    return null;
}

/// Cycle the compositing layout while the viewer is running.
///
/// The host layout is not in the cycle: the viewer's whole point is that the
/// guests own the screen, and going back to the host console is what Esc is
/// for.
fn cycleLayout() void {
    const next: kvm.Layout = switch (kvm.layout()) {
        .focus => .tile,
        .tile => .solo,
        .solo => .focus,
        .host => .focus,
    };
    kvm.setLayout(next);
}

/// Show a machine's device the way a guest would see it.
///
/// The configuration space is printed in the classic PCI layout, because
/// that is what a guest's driver reads.  The vendor and device IDs are the
/// machine's own, so this is the identity a guest would bind to.
fn showDevice(m: *kvm.Machine) void {
    vga.setColor(.light_cyan, .black);
    vga.write("Device of machine ");
    vga.writeDec(m.id);
    vga.write(" '");
    vga.write(m.nameSlice());
    vga.write("'\n\n");
    vga.setColor(.white, .black);

    const cs = &m.device.config_space;
    vga.write("  PCI configuration space:\n");
    vga.write("    vendor  device  class      BAR0       BAR2\n");
    vga.write("    ");
    vga.writeHexShort(readLe16(cs, 0x00));
    vga.write("    ");
    vga.writeHexShort(readLe16(cs, 0x02));
    vga.write("    ");
    vga.writeHexShort((@as(u32, cs[0x0B]) << 16) | (@as(u32, cs[0x0A]) << 8) | @as(u32, cs[0x09]));
    vga.write("    ");
    vga.writeHexShort(readLe32(cs, 0x10));
    vga.write("    ");
    vga.writeHexShort(readLe32(cs, 0x18));
    vga.write("\n\n");

    vga.write("  Identity:\n");
    vga.write("    persona:    ");
    vga.write(m.identity.personaName());
    vga.write("\n    OEM:        ");
    vga.write(m.identity.oemId());
    vga.write("\n    manufacturer: ");
    vga.write(m.identity.manufacturer());
    vga.write("\n    product:    ");
    vga.write(m.identity.product());
    vga.write("\n    cpu:        ");
    vga.write(m.identity.cpuBrand());
    vga.write("\n    uuid:       ");
    for (m.identity.uuid) |b| {
        vga.writeHexShort(b);
        vga.write("-");
    }
    vga.write("\n    hypervisor: ");
    vga.write(if (m.identity.hypervisor_leaf_present) "VISIBLE" else "invisible");
    vga.write("\n\n");
}

fn readLe16(buf: []const u8, at: usize) u16 {
    return @as(u16, buf[at]) | (@as(u16, buf[at + 1]) << 8);
}

fn readLe32(buf: []const u8, at: usize) u32 {
    return @as(u32, buf[at]) |
        (@as(u32, buf[at + 1]) << 8) |
        (@as(u32, buf[at + 2]) << 16) |
        (@as(u32, buf[at + 3]) << 24);
}

/// The full-screen viewer.
///
/// The guests own the screen while this runs: the compositor draws them and
/// the host console is not visible.  Tab and Shift-Tab move between the
/// machines, clicking a thumbnail in the strip moves the focus there, and
/// Esc comes back to the host.
///
/// `seconds` limits how long the viewer runs, which is what the automated
/// screenshot harness uses.
fn runViewer(seconds: u32, start_layout: kvm.Layout) void {
    if (kvm.machineCount() == 0) {
        vga.write("kvm view: no machines.\n");
        return;
    }
    if (!fb.active) {
        vga.write("kvm view: needs a framebuffer.\n");
        return;
    }

    kvm.setLayout(start_layout);

    var prev_left = mouse.left_button;
    const start_ticks = timer.tickCount();

    while (true) {
        // Let the guests run and redraw.
        kvm.poll();

        if (seconds > 0) {
            // timer.ticks runs at 100 Hz, so 100 ticks is a second.
            const elapsed = (timer.tickCount() - start_ticks) / 100;
            if (elapsed >= seconds) break;
        }

        if (kb.pollKey()) |k| {
            switch (k) {
                0x1B => break, // Esc
                '\t' => {
                    kvm.focusNext();
                    continue;
                },
                // Cycle how the guests are shown: one at a time, all at
                // once, and one at a time with the others in a strip.
                't' => {
                    cycleLayout();
                    continue;
                },
                // A digit focuses that machine directly.
                '1'...'8' => {
                    const index: usize = @intCast(k - '1');
                    if (index < kvm.machineCount()) {
                        kvm.setFocus(index);
                    }
                    continue;
                },
                else => {},
            }
        }

        // A click in the strip picks the machine whose thumbnail was hit.
        mouse.poll();
        if (mouse.left_button and !prev_left) {
            const my: u32 = if (mouse.my < 0) 0 else @intCast(mouse.my);
            if (my >= display.stripTop()) {
                const mx: u32 = if (mouse.mx < 0) 0 else @intCast(mouse.mx);
                if (display.outputAtX(mx)) |index| {
                    kvm.setFocus(index);
                }
            }
        }
        prev_left = mouse.left_button;
    }

    // Back to the host: the console has to be repainted, because the guest
    // layouts composited over the whole screen.
    kvm.setLayout(.host);
    vga.clear();
}
