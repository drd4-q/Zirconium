//! The display stack: the DRM model on top of the bootloader's framebuffer.
//!
//! Ported from the Linux kernel's:
//!
//!   * `drivers/video/fbdev/simplefb.c` - the framebuffer the bootloader
//!     hands over: a linear framebuffer with a stride, and nothing else.
//!   * `drivers/gpu/drm/drm_connector.c` - the connector.
//!   * `drivers/gpu/drm/drm_crtc.c` - the CRTC.
//!   * `drivers/gpu/drm/drm_fbdev_client.c` - the fbdev emulation.
//!   * `drivers/gpu/drm/drm_edid.c` - the EDID parser.
//!
//! The kernel's display is exactly Linux's "simple framebuffer": the
//! bootloader sets a mode and the kernel draws into the memory it was
//! given.  What this stack adds is the model around it - a connector that
//! says whether a display is there, a CRTC that holds the mode, and an
//! fbdev that a program can talk to.

const serial = @import("../../system/serial.zig");
const edid_mod = @import("edid.zig");
const connector_mod = @import("connector.zig");
const fbdev_mod = @import("fbdev.zig");
const ddc = @import("ddc.zig");

pub const Edid = edid_mod.Edid;
pub const Mode = edid_mod.Mode;
pub const Connector = connector_mod.Connector;
pub const Status = connector_mod.Status;
pub const Crtc = fbdev_mod.Crtc;
pub const FbDev = fbdev_mod.FbDev;
pub const FrameBuffer = fbdev_mod.FrameBuffer;

/// The connector of the display the bootloader set up.
pub var connector: Connector = .{ .name = "eDP-1" };

/// The CRTC that drives it.
pub var crtc: Crtc = undefined;

/// The fbdev on top of that.
pub var fbdev: FbDev = undefined;

/// The framebuffer itself.
pub var framebuffer: FrameBuffer = .{};

/// True once `init()` has run.
pub var initialized: bool = false;

/// Set the display stack up.
///
/// The framebuffer is the one the bootloader gave us: its address, its
/// geometry and its stride are already known, so all this does is wrap them
/// in the DRM model and, when the machine has a display adapter that can
/// talk DDC, ask the display what it can do.
pub fn init(base: usize, width: u32, height: u32, pitch: u32, bpp: u8) void {
    if (initialized) return;
    initialized = true;

    framebuffer = FrameBuffer{
        .addr = base,
        .width = width,
        .height = height,
        .pitch = pitch,
        .bpp = bpp,
        .format = if (bpp == 32) fbdev_mod.Format.xrgb8888 else fbdev_mod.Format.rgb565,
    };

    // The display the bootloader set up is connected as far as the kernel
    // knows: it is the one the console is drawn on.
    connector.setStatus(.connected);

    // Ask the display what it is.  A machine without a display adapter
    // that speaks DDC simply has no EDID, and the connector stays on the
    // mode the bootloader chose.
    if (readEdid()) |edid| {
        connector.setEdid(edid);
        serial.serialWrite("[DRM] EDID read: ");
        serial.serialWrite(edid.manufacturer[0..3]);
        serial.serialWrite(" ");
        serial.serialWrite(edid.name());
        serial.serialWrite("\n");
    } else {
        serial.serialWrite("[DRM] No EDID; using the bootloader's mode\n");
    }

    // The connector's mode list starts with the mode the framebuffer is
    // actually in, so that a program asking for "the current mode" gets
    // the truth.
    var current = Mode{
        .clock_khz = 0,
        .h_active = @truncate(width),
        .v_active = @truncate(height),
        .h_total = @truncate(width),
        .v_total = @truncate(height),
    };
    if (connector.preferredMode()) |preferred| {
        current = preferred;
    }
    _ = connector.setMode(current);
    crtc = Crtc{ .connector = &connector, .mode = current };
    crtc.enable();

    fbdev.setup(&crtc, &framebuffer);

    serial.serialWrite("[DRM] Connector ");
    serial.serialWrite(connector.name);
    serial.serialWrite(" status=");
    serial.serialWrite(@tagName(connector.status));
    serial.serialWrite(" modes=");
    serial.serialWriteDec(connector.modeCount());
    serial.serialWrite("\n");
}

/// Read the EDID of the display, if the machine has one that can talk.
fn readEdid() ?Edid {
    const raw = ddc.readEdid() orelse return null;
    return Edid.parse(&raw);
}

/// Write the state of the stack to the serial log.
pub fn printStatus(
    write: *const fn (s: []const u8) void,
    writeDec: *const fn (v: u64) void,
) void {
    write("[DRM] Display stack\n");
    write("  connector : ");
    write(connector.name);
    write("\n  status    : ");
    write(@tagName(connector.status));
    write("\n  mode      : ");
    writeDec(fbdev.var_info.xres);
    write("x");
    writeDec(fbdev.var_info.yres);
    write(" @ ");
    writeDec(fbdev.var_info.bits_per_pixel);
    write(" bpp\n");

    if (connector.edid) |e| {
        write("  EDID\n");
        write("    manufacturer : ");
        write(e.manufacturer[0..3]);
        write("\n    product code : ");
        writeDec(e.product_code);
        write("\n    serial       : ");
        writeDec(e.serial_number);
        write("\n    made in      : ");
        writeDec(e.year);
        write("\n    name         : ");
        write(e.name());
        write("\n    size         : ");
        writeDec(e.h_size_cm);
        write(" x ");
        writeDec(e.v_size_cm);
        write(" cm\n");
    } else {
        write("  EDID       : none\n");
    }

    write("  modes      : ");
    writeDec(connector.modeCount());
    write("\n");
}
