/// The display compositor.
///
/// DynamicalKVM runs several guest systems at once, and each of them has its
/// own display.  This module owns the *physical* framebuffer and decides
/// what is on it:
///
///   host   - the Zirconium console has the whole screen.  This is the
///            normal mode: the hypervisor is a host, not a desktop.
///   solo   - one guest fills the screen.
///   tile   - every guest is shown at once, in a grid.  This is the "several
///            systems side by side" view.
///   focus  - the focused guest fills the screen, with a strip along the
///            bottom showing the others.  Tab / Shift-Tab move between
///            systems without going back to the host.
///
/// The layout is a *mode*, not a window manager: a guest either has the
/// screen, a cell in a grid, or nothing.  That is the right shape for a
/// hypervisor - there is no desktop to drag windows around on, there are
/// machines.
const std = @import("std");
const root = @import("root");
const fb = @import("../framebuffer.zig");
const output_mod = @import("output.zig");
const font = @import("font.zig");
const console = @import("console.zig");

const serial = root.serial;

pub const Output = output_mod.Output;
pub const Rect = output_mod.Rect;
pub const MAX_OUTPUTS = output_mod.MAX_OUTPUTS;

pub const Layout = enum {
    /// The host console owns the screen.
    host,
    /// The focused guest owns the screen.
    solo,
    /// Every guest is shown at once, in a grid.
    tile,
    /// The focused guest owns the screen; a strip shows the others.
    focus,

    pub fn name(self: Layout) []const u8 {
        return switch (self) {
            .host => "host",
            .solo => "solo",
            .tile => "tile",
            .focus => "focus",
        };
    }

    /// True when a guest display is visible in this layout.
    pub fn showsGuests(self: Layout) bool {
        return self != .host;
    }
};

/// Height of the status strip drawn under the guests.
const STRIP_H: u32 = 20;

var outputs: [MAX_OUTPUTS]Output = undefined;
var output_count: usize = 0;
var layout: Layout = .host;
var focus_index: usize = 0;

/// Add a virtual display.  Returns its index.
pub fn addOutput(o: Output) !usize {
    if (output_count >= MAX_OUTPUTS) return error.TooManyOutputs;
    outputs[output_count] = o;
    output_count += 1;
    return output_count - 1;
}

/// Remove a virtual display and free its memory.
pub fn removeOutput(index: usize) void {
    if (index >= output_count) return;
    outputs[index].deinit();
    var i = index;
    while (i + 1 < output_count) : (i += 1) {
        outputs[i] = outputs[i + 1];
    }
    output_count -= 1;
    if (focus_index >= output_count and output_count > 0) {
        focus_index = output_count - 1;
    }
}

pub fn clearOutputs() void {
    var i: usize = 0;
    while (i < output_count) : (i += 1) {
        outputs[i].deinit();
    }
    output_count = 0;
    focus_index = 0;
}

pub fn count() usize {
    return output_count;
}

pub fn get(index: usize) ?*Output {
    if (index >= output_count) return null;
    return &outputs[index];
}

pub fn currentLayout() Layout {
    return layout;
}

pub fn focused() usize {
    return focus_index;
}

pub fn setFocus(index: usize) void {
    if (output_count == 0) return;
    focus_index = index % output_count;
}

pub fn focusNext() void {
    if (output_count == 0) return;
    focus_index = (focus_index + 1) % output_count;
}

pub fn focusPrev() void {
    if (output_count == 0) return;
    focus_index = (focus_index + output_count - 1) % output_count;
}

/// Change the layout.
///
/// Switching back to the host has to repaint the console: the guest layouts
/// composite over the whole screen, so the console's pixels are gone.
pub fn setLayout(l: Layout) void {
    const was_guest = layout.showsGuests();
    layout = l;
    if (l == .host) {
        // The console owns the screen again.
        console.redrawAll();
    } else if (!was_guest) {
        // Leaving host mode: the guest layouts cover the screen anyway.
        fb.markDirtyRect(0, 0, fb.fb_width, fb.fb_height);
    }
}

/// Draw the current layout onto the physical framebuffer.
///
/// Guest layouts are composited into the shadow and flushed; the host layout
/// leaves the screen to the console.
pub fn composite() void {
    if (!fb.active) return;
    if (!layout.showsGuests()) return;
    if (output_count == 0) return;

    switch (layout) {
        .host => return,
        .solo => compositeSolo(),
        .tile => compositeTile(),
        .focus => compositeFocus(),
    }
    fb.flush();
}

/// One guest, scaled to fill the screen.
fn compositeSolo() void {
    const o = &outputs[focus_index];
    fb.blitScaled(o.pixels, o.stride_px, o.width, o.height, 0, 0, fb.fb_width, fb.fb_height);
}

/// Every guest at once, in a grid.
fn compositeTile() void {
    const n = output_count;
    // As square a grid as the count allows.
    var cols: u32 = 1;
    while (cols * cols < n) : (cols += 1) {}
    const rows: u32 = @intCast(@divTrunc(n + cols - 1, cols));

    const cell_w = fb.fb_width / cols;
    const cell_h = fb.fb_height / rows;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const o = &outputs[i];
        const cx = @as(u32, @intCast(i % cols)) * cell_w;
        const cy = @as(u32, @intCast(i / cols)) * cell_h;
        // A one-pixel gutter keeps two guests from bleeding into each other.
        const w = if (cell_w > 2) cell_w - 1 else cell_w;
        const h = if (cell_h > 2) cell_h - 1 else cell_h;
        fb.blitScaled(o.pixels, o.stride_px, o.width, o.height, cx, cy, w, h);
        // The focused guest gets a border.
        if (i == focus_index) {
            fb.drawRectBorder(cx, cy, w, h, 2, 0x40, 0xC0, 0xFF);
        }
    }
}

/// The focused guest, scaled to fill the screen above the status strip.
fn compositeFocus() void {
    const o = &outputs[focus_index];
    const view_h = if (fb.fb_height > STRIP_H + 8) fb.fb_height - STRIP_H else fb.fb_height;
    fb.blitScaled(o.pixels, o.stride_px, o.width, o.height, 0, 0, fb.fb_width, view_h);
    drawStrip(view_h);
}

/// The strip along the bottom: the other systems, and the focused one
/// highlighted.  This is how you *see* that the other machines are alive
/// while one of them has the screen.
fn drawStrip(y: u32) void {
    const h = @min(STRIP_H, fb.fb_height -| y);
    if (h == 0) return;
    fb.fillRect(0, y, fb.fb_width, h, 0x18, 0x1A, 0x24);

    // One cell per guest, showing a downscaled thumbnail.
    const n = output_count;
    const cell_w = fb.fb_width / @as(u32, @intCast(n));
    if (cell_w == 0) return;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const o = &outputs[i];
        const cx = @as(u32, @intCast(i)) * cell_w;
        const thumb_h = if (h > 4) h - 4 else h;
        fb.blitScaled(o.pixels, o.stride_px, o.width, o.height, cx, y + 2, cell_w -| 1, thumb_h);
        if (i == focus_index) {
            fb.drawRectBorder(cx, y, cell_w, h, 2, 0x40, 0xC0, 0xFF);
        }
    }
}

/// Which machine's thumbnail is at this screen x?
///
/// Used by the viewer: clicking a thumbnail in the strip moves the focus
/// there, so the systems can be reached without a keyboard.
pub fn outputAtX(x: u32) ?usize {
    if (output_count == 0) return null;
    const cell_w = fb.fb_width / @as(u32, @intCast(output_count));
    if (cell_w == 0) return null;
    const index = x / cell_w;
    if (index >= output_count) return null;
    return index;
}

/// The y coordinate at which the status strip starts.
pub fn stripTop() u32 {
    if (fb.fb_height > STRIP_H + 8) return fb.fb_height - STRIP_H;
    return fb.fb_height;
}

/// Print the layout state to the serial log - the console is not visible
/// while the guests own the screen.
pub fn printStatus(writeFn: *const fn (s: []const u8) void, writeDecFn: *const fn (v: u64) void) void {
    writeFn("=== DynamicalKVM display ===\n\n");
    writeFn("  Layout: ");
    writeFn(layout.name());
    writeFn("\n  Outputs: ");
    writeDecFn(output_count);
    writeFn("\n  Focused: ");
    writeDecFn(focus_index);
    writeFn("\n\n");
}
